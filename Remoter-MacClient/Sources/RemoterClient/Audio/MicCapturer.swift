import Foundation
import AVFoundation

/// Captures local microphone audio via `AVAudioEngine` and converts it to
/// 48,000 Hz mono signed 16-bit LE PCM in 20ms (960-sample / 1920-byte) chunks
/// for low-latency streaming to the remote host's virtual audio input.
public final class MicCapturer: @unchecked Sendable {
    public static let sampleRate: Double = 48_000
    public static let channels: AVAudioChannelCount = 1
    public static let chunkSampleCount: Int = 960
    public static let chunkByteCount: Int = chunkSampleCount * MemoryLayout<Int16>.size // 1920 bytes

    public var onPcmChunk: ((Data) -> Void)?

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isRunning
    }

    private let lock = NSLock()
    private let targetFormat: AVAudioFormat
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var pcmAccumulator = Data()
    private var _isRunning = false

    public init() {
        self.targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.sampleRate,
            channels: Self.channels,
            interleaved: true
        )!
    }

    deinit {
        stop()
    }

    @discardableResult
    public func start() -> Bool {
        lock.lock()
        if _isRunning {
            lock.unlock()
            return true
        }
        lock.unlock()

        let authStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if authStatus == .denied || authStatus == .restricted {
            return false
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            return false
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            return false
        }

        lock.lock()
        self.engine = engine
        self.converter = converter
        self.pcmAccumulator.removeAll(keepingCapacity: true)
        lock.unlock()

        let ratio = Self.sampleRate / inputFormat.sampleRate
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.processInputBuffer(buffer, converter: converter, ratio: ratio)
        }

        do {
            engine.prepare()
            try engine.start()
            lock.lock()
            _isRunning = true
            lock.unlock()
            return true
        } catch {
            inputNode.removeTap(onBus: 0)
            engine.stop()
            lock.lock()
            self.engine = nil
            self.converter = nil
            self.pcmAccumulator.removeAll(keepingCapacity: false)
            self._isRunning = false
            lock.unlock()
            return false
        }
    }

    public func stop() {
        lock.lock()
        let activeEngine = engine
        engine = nil
        converter = nil
        _isRunning = false
        pcmAccumulator.removeAll(keepingCapacity: false)
        lock.unlock()

        if let activeEngine {
            activeEngine.inputNode.removeTap(onBus: 0)
            activeEngine.stop()
        }
    }

    private func processInputBuffer(_ inputBuffer: AVAudioPCMBuffer, converter: AVAudioConverter, ratio: Double) {
        guard inputBuffer.frameLength > 0 else { return }

        let estimatedOutFrames = AVAudioFrameCount(ceil(Double(inputBuffer.frameLength) * ratio)) + 32
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: max(estimatedOutFrames, 64)) else {
            return
        }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        guard status != .error, error == nil, outBuffer.frameLength > 0,
              let int16Ptr = outBuffer.int16ChannelData?[0] else {
            return
        }

        let byteCount = Int(outBuffer.frameLength) * MemoryLayout<Int16>.size
        let converted = Data(bytes: int16Ptr, count: byteCount)

        var chunksToEmit: [Data] = []
        let callback: ((Data) -> Void)?

        lock.lock()
        if _isRunning {
            pcmAccumulator.append(converted)
            while pcmAccumulator.count >= Self.chunkByteCount {
                let chunk = Data(pcmAccumulator.prefix(Self.chunkByteCount))
                pcmAccumulator.removeFirst(Self.chunkByteCount)
                chunksToEmit.append(chunk)
            }
            callback = onPcmChunk
        } else {
            callback = nil
        }
        lock.unlock()

        if let callback {
            for chunk in chunksToEmit {
                callback(chunk)
            }
        }
    }
}
