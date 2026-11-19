import Foundation
import AudioToolbox
import AVFoundation

/// Low-latency native macOS ADTS AAC-LC audio player using `AudioConverterRef` (AudioToolbox)
/// feeding a mutex-protected Float32 ring buffer drained by `AVAudioEngine` + `AVAudioSourceNode`.
public final class AudioPlayer: @unchecked Sendable {

    // MARK: - Public Properties

    public var isEnabled: Bool {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _isEnabled
        }
        set {
            stateLock.lock()
            _isEnabled = newValue
            stateLock.unlock()
            if !newValue {
                ringBuffer.clear()
            }
        }
    }

    public var isMuted: Bool {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _isMuted
        }
        set {
            stateLock.lock()
            _isMuted = newValue
            stateLock.unlock()
        }
    }

    public var volume: Float {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _volume
        }
        set {
            let clamped = max(0.0, min(1.0, newValue))
            stateLock.lock()
            _volume = clamped
            stateLock.unlock()
        }
    }

    // MARK: - Private Types

    /// Thread-safe circular buffer of interleaved stereo Float32 samples.
    private final class FloatRingBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Float]
        private let capacity: Int
        private var readIndex: Int = 0
        private var writeIndex: Int = 0
        private var count: Int = 0

        /// Max buffered samples before dropping oldest to bound audio latency (~180ms at 48kHz stereo).
        private let maxLatencySamples: Int

        init(capacitySamples: Int, maxLatencySamples: Int) {
            self.capacity = capacitySamples
            self.maxLatencySamples = min(capacitySamples, maxLatencySamples)
            self.storage = [Float](repeating: 0, count: capacitySamples)
        }

        func write(_ samples: UnsafeBufferPointer<Float>) {
            guard !samples.isEmpty else { return }
            lock.lock()
            defer { lock.unlock() }

            let incoming = samples.count
            // If writing would exceed maxLatencySamples, advance readIndex to drop oldest audio
            if count + incoming > maxLatencySamples {
                let targetCount = max(0, maxLatencySamples - incoming)
                let toDrop = max(0, count - targetCount)
                if toDrop > 0 {
                    readIndex = (readIndex + toDrop) % capacity
                    count -= toDrop
                }
            }

            let toWrite = min(incoming, capacity - count)
            let startOffset = incoming - toWrite
            for i in 0..<toWrite {
                storage[writeIndex] = samples[startOffset + i]
                writeIndex += 1
                if writeIndex == capacity { writeIndex = 0 }
            }
            count += toWrite
        }

        func read(into left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frameCount: Int, gain: Float) {
            lock.lock()
            let availableFrames = count / 2
            let framesToRead = min(frameCount, availableFrames)

            for i in 0..<framesToRead {
                let l = storage[readIndex]
                readIndex += 1
                if readIndex == capacity { readIndex = 0 }

                let r = storage[readIndex]
                readIndex += 1
                if readIndex == capacity { readIndex = 0 }

                left[i] = l * gain
                right[i] = r * gain
            }
            count -= framesToRead * 2
            lock.unlock()

            if framesToRead < frameCount {
                for i in framesToRead..<frameCount {
                    left[i] = 0
                    right[i] = 0
                }
            }
        }

        func clear() {
            lock.lock()
            readIndex = 0
            writeIndex = 0
            count = 0
            lock.unlock()
        }
    }

    private final class ConverterInputContext {
        let rawPtr: UnsafeMutableRawPointer
        let byteCount: Int
        var packetDesc: AudioStreamPacketDescription
        var consumed: Bool = false

        init(data: Data) {
            self.byteCount = data.count
            self.rawPtr = UnsafeMutableRawPointer.allocate(byteCount: max(1, data.count), alignment: 1)
            data.copyBytes(to: rawPtr.assumingMemoryBound(to: UInt8.self), count: data.count)
            self.packetDesc = AudioStreamPacketDescription(
                mStartOffset: 0,
                mVariableFramesInPacket: 0,
                mDataByteSize: UInt32(data.count)
            )
        }

        deinit {
            rawPtr.deallocate()
        }
    }

    // MARK: - Private State

    private let decodeQueue = DispatchQueue(label: "com.remoter.audio.decoder", qos: .userInteractive)
    private let stateLock = NSLock()

    private var _isEnabled: Bool = true
    private var _isMuted: Bool = false
    private var _volume: Float = 1.0
    private var isRunning: Bool = false

    private var engine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?

    private var converter: AudioConverterRef?
    private var currentSampleRate: Double = 48_000
    private var currentChannels: UInt32 = 2

    // 0.5s stereo capacity at 48kHz (48000 samples), latency cap ~180ms (17280 samples)
    private let ringBuffer = FloatRingBuffer(capacitySamples: 48_000 * 2, maxLatencySamples: 17_280)
    private var pcmScratch = [Float](repeating: 0, count: 4096)

    // ADTS sampling frequency table (ISO/IEC 14496-3)
    private static let adtsSampleRates: [Double] = [
        96000, 88200, 64000, 48000, 44100, 32000,
        24000, 22050, 16000, 12000, 11025, 8000, 7350
    ]

    // MARK: - Lifecycle

    public init() {}

    deinit {
        stop()
    }

    // MARK: - Public API

    public func start() {
        stateLock.lock()
        if isRunning {
            stateLock.unlock()
            return
        }
        isRunning = true
        stateLock.unlock()

        startEngine(sampleRate: currentSampleRate)
    }

    public func stop() {
        stateLock.lock()
        isRunning = false
        stateLock.unlock()

        stopEngine()
        ringBuffer.clear()

        decodeQueue.async { [weak self] in
            self?.disposeConverter()
        }
    }

    /// Enqueues an ADTS-framed AAC-LC packet for asynchronous decoding and playback.
    public func enqueue(_ packet: AudioFramePacket) {
        stateLock.lock()
        let active = isRunning && _isEnabled
        stateLock.unlock()
        guard active, packet.data.count >= 7 else { return }

        decodeQueue.async { [weak self] in
            self?.decodeADTSStream(packet.data)
        }
    }

    // MARK: - AVAudioEngine Management

    private func startEngine(sampleRate: Double) {
        stopEngine()

        let newEngine = AVAudioEngine()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            return
        }

        let ring = self.ringBuffer
        let node = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let frames = Int(frameCount)

            guard let self else {
                for buf in abl {
                    if let data = buf.mData {
                        memset(data, 0, Int(buf.mDataByteSize))
                    }
                }
                return noErr
            }

            self.stateLock.lock()
            let gain: Float = (self._isEnabled && !self._isMuted) ? self._volume : 0.0
            self.stateLock.unlock()

            if abl.count >= 2,
               let leftPtr = abl[0].mData?.assumingMemoryBound(to: Float.self),
               let rightPtr = abl[1].mData?.assumingMemoryBound(to: Float.self) {
                ring.read(into: leftPtr, right: rightPtr, frameCount: frames, gain: gain)
            } else {
                for buf in abl {
                    if let data = buf.mData {
                        memset(data, 0, Int(buf.mDataByteSize))
                    }
                }
            }
            return noErr
        }

        newEngine.attach(node)
        newEngine.connect(node, to: newEngine.mainMixerNode, format: format)

        do {
            try newEngine.start()
            self.engine = newEngine
            self.sourceNode = node
        } catch {
            NSLog("AudioPlayer: Failed to start AVAudioEngine: %@", error.localizedDescription)
        }
    }

    private func stopEngine() {
        if let engine {
            engine.stop()
            if let sourceNode {
                engine.detach(sourceNode)
            }
        }
        sourceNode = nil
        engine = nil
    }

    // MARK: - ADTS Parsing & AudioToolbox AAC-LC Decoding

    private func decodeADTSStream(_ data: Data) {
        var offset = 0
        let total = data.count

        while offset + 7 <= total {
            // Locate ADTS syncword 0xFFF (12 bits)
            let b0 = data[offset]
            let b1 = data[offset + 1]
            guard b0 == 0xFF && (b1 & 0xF0) == 0xF0 else {
                offset += 1
                continue
            }

            let protectionAbsent = (b1 & 0x01) != 0
            let headerLen = protectionAbsent ? 7 : 9
            guard offset + headerLen <= total else { break }

            let b2 = data[offset + 2]
            let b3 = data[offset + 3]
            let b4 = data[offset + 4]
            let b5 = data[offset + 5]

            let freqIndex = Int((b2 >> 2) & 0x0F)
            let channelConfig = UInt32(((b2 & 0x01) << 2) | ((b3 >> 6) & 0x03))
            let frameLength = Int(((UInt16(b3 & 0x03)) << 11) | (UInt16(b4) << 3) | UInt16((b5 >> 5) & 0x07))

            guard frameLength >= headerLen, offset + frameLength <= total else {
                break
            }

            let sampleRate = freqIndex < Self.adtsSampleRates.count ? Self.adtsSampleRates[freqIndex] : 48_000
            let channels: UInt32 = (channelConfig == 1) ? 1 : 2

            let rawAACStart = offset + headerLen
            let rawAACEnd = offset + frameLength
            let rawAAC = data.subdata(in: rawAACStart..<rawAACEnd)

            decodeRawAACFrame(rawAAC, sampleRate: sampleRate, channels: channels)
            offset += frameLength
        }
    }

    private func ensureConverter(sampleRate: Double, channels: UInt32) -> AudioConverterRef? {
        if let existing = converter,
           currentSampleRate == sampleRate,
           currentChannels == channels {
            return existing
        }

        disposeConverter()

        var inDesc = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 0,
            mReserved: 0
        )

        // Output interleaved stereo Float32 PCM at the stream's sample rate
        var outDesc = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, // 2 channels * 4 bytes
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        var newConverter: AudioConverterRef?
        let status = AudioConverterNew(&inDesc, &outDesc, &newConverter)
        guard status == noErr, let created = newConverter else {
            return nil
        }

        let rateChanged = (currentSampleRate != sampleRate)
        currentSampleRate = sampleRate
        currentChannels = channels
        converter = created

        if rateChanged {
            stateLock.lock()
            let running = isRunning
            stateLock.unlock()
            if running {
                DispatchQueue.main.async { [weak self] in
                    self?.startEngine(sampleRate: sampleRate)
                }
            }
        }

        return created
    }

    private func disposeConverter() {
        if let converter {
            AudioConverterDispose(converter)
            self.converter = nil
        }
    }

    private func decodeRawAACFrame(_ rawAAC: Data, sampleRate: Double, channels: UInt32) {
        guard !rawAAC.isEmpty,
              let conv = ensureConverter(sampleRate: sampleRate, channels: channels) else {
            return
        }

        let context = ConverterInputContext(data: rawAAC)
        let unmanaged = Unmanaged.passUnretained(context)

        var outputFrames: UInt32 = 1024
        let requiredFloats = Int(outputFrames) * 2
        if pcmScratch.count < requiredFloats {
            pcmScratch = [Float](repeating: 0, count: requiredFloats)
        }

        let status: OSStatus = pcmScratch.withUnsafeMutableBytes { rawOut in
            var outBufferList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 2,
                    mDataByteSize: UInt32(requiredFloats * MemoryLayout<Float>.size),
                    mData: rawOut.baseAddress
                )
            )

            return AudioConverterFillComplexBuffer(
                conv,
                AudioPlayer.converterInputCallback,
                unmanaged.toOpaque(),
                &outputFrames,
                &outBufferList,
                nil
            )
        }

        if (status == noErr || status == Self.kNoMoreDataStatus), outputFrames > 0 {
            let sampleCount = Int(outputFrames) * 2
            pcmScratch.withUnsafeBufferPointer { buf in
                let slice = UnsafeBufferPointer(start: buf.baseAddress, count: min(sampleCount, buf.count))
                ringBuffer.write(slice)
            }
        }
    }

    private static let kNoMoreDataStatus: OSStatus = 0x6E6D6474 // 'nmdt'

    private static let converterInputCallback: AudioConverterComplexInputDataProc = {
        _, ioNumberDataPackets, ioData, outDataPacketDescription, inUserData in
        guard let inUserData else {
            ioNumberDataPackets.pointee = 0
            return kNoMoreDataStatus
        }

        let ctx = Unmanaged<ConverterInputContext>.fromOpaque(inUserData).takeUnretainedValue()
        if ctx.consumed {
            ioNumberDataPackets.pointee = 0
            return kNoMoreDataStatus
        }

        ctx.consumed = true
        ioNumberDataPackets.pointee = 1

        ioData.pointee.mNumberBuffers = 1
        ioData.pointee.mBuffers.mNumberChannels = 2
        ioData.pointee.mBuffers.mDataByteSize = UInt32(ctx.byteCount)
        ioData.pointee.mBuffers.mData = ctx.rawPtr

        if let outDesc = outDataPacketDescription {
            withUnsafeMutablePointer(to: &ctx.packetDesc) { ptr in
                outDesc.pointee = ptr
            }
        }

        return noErr
    }
}
