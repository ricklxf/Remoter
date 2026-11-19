import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox
import ImageIO
import CoreGraphics
import Darwin

/// Native macOS VideoToolbox hardware decoder for H.264 / H.265 (Annex-B) plus JPEG fallback.
/// Outputs `IOSurface`-backed, Metal-compatible `CVPixelBuffer`s (NV12 for H.264/HEVC, BGRA for JPEG).
public final class VideoDecoder: @unchecked Sendable {

    // MARK: - Public Properties

    public var onDecodedFrame: ((CVPixelBuffer) -> Void)?
    public var onRequestKeyframe: (() -> Void)?

    public var isHardwareAccelerated: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isHardwareAccelerated
    }

    public var lastDecodeMs: Double {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _lastDecodeMs
    }

    // MARK: - Private State

    private let decodeQueue = DispatchQueue(label: "com.remoter.video.decoder", qos: .userInteractive)
    private let stateLock = NSLock()

    private var _isHardwareAccelerated: Bool = false
    private var _lastDecodeMs: Double = 0.0
    private var isInvalidated: Bool = false

    private var activeCodec: VideoCodec?
    private var decompressionSession: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?

    private var spsData: Data?
    private var ppsData: Data?
    private var vpsData: Data?

    private var consecutiveErrors: Int = 0
    private var lastKeyframeRequestTime: CFAbsoluteTime = 0

    // MARK: - Lifecycle

    public init() {}

    deinit {
        invalidate()
    }

    // MARK: - Public API

    /// Decodes a single `VideoFramePacket` asynchronously on the dedicated decoder queue.
    public func decode(_ packet: VideoFramePacket) {
        decodeQueue.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let invalidated = self.isInvalidated
            self.stateLock.unlock()
            guard !invalidated else { return }

            let startTime = CFAbsoluteTimeGetCurrent()

            if self.activeCodec != packet.codec {
                self.resetLockedState()
                self.activeCodec = packet.codec
            }

            switch packet.codec {
            case .h264:
                self.decodeAnnexB(packet, isHEVC: false, startTime: startTime)
            case .h265:
                self.decodeAnnexB(packet, isHEVC: true, startTime: startTime)
            case .jpeg:
                self.decodeJPEG(packet, startTime: startTime)
            }
        }
    }

    /// Resets cached parameter sets and destroys the current `VTDecompressionSession` so the next keyframe cleanly reinitializes.
    public func reset() {
        decodeQueue.async { [weak self] in
            self?.resetLockedState()
        }
    }

    /// Permanently invalidates the decoder and releases all VideoToolbox resources.
    public func invalidate() {
        stateLock.lock()
        isInvalidated = true
        stateLock.unlock()

        decodeQueue.async { [weak self] in
            self?.resetLockedState()
        }
    }

    // MARK: - Internal Reset

    private func resetLockedState() {
        if let session = decompressionSession {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
            decompressionSession = nil
        }
        formatDescription = nil
        spsData = nil
        ppsData = nil
        vpsData = nil
        consecutiveErrors = 0

        stateLock.lock()
        _isHardwareAccelerated = false
        stateLock.unlock()
    }

    // MARK: - H.264 / H.265 Annex-B Decoding

    private func decodeAnnexB(_ packet: VideoFramePacket, isHEVC: Bool, startTime: CFAbsoluteTime) {
        let nalus = splitAnnexBNALUs(packet.data)
        guard !nalus.isEmpty else { return }

        var avccData = Data()
        avccData.reserveCapacity(packet.data.count + 16)
        var paramSetsChanged = false
        var hasVideoSlice = false

        for nalu in nalus {
            guard !nalu.isEmpty else { continue }

            if !isHEVC {
                let naluType = nalu[0] & 0x1F
                switch naluType {
                case 7: // SPS
                    if spsData != nalu {
                        spsData = nalu
                        paramSetsChanged = true
                    }
                    continue
                case 8: // PPS
                    if ppsData != nalu {
                        ppsData = nalu
                        paramSetsChanged = true
                    }
                    continue
                case 6, 9: // SEI, AUD — skip for minimal latency
                    continue
                case 1, 5: // Non-IDR or IDR slice
                    hasVideoSlice = true
                default:
                    break
                }
            } else {
                let naluType = (nalu[0] >> 1) & 0x3F
                switch naluType {
                case 32: // VPS
                    if vpsData != nalu {
                        vpsData = nalu
                        paramSetsChanged = true
                    }
                    continue
                case 33: // SPS
                    if spsData != nalu {
                        spsData = nalu
                        paramSetsChanged = true
                    }
                    continue
                case 34: // PPS
                    if ppsData != nalu {
                        ppsData = nalu
                        paramSetsChanged = true
                    }
                    continue
                case 35, 39, 40: // AUD, Prefix/Suffix SEI
                    continue
                case 0...21: // VCL slice NALUs
                    hasVideoSlice = true
                default:
                    break
                }
            }

            // Write 4-byte big-endian length prefix (AVCC / HVCC format)
            var lengthBE = UInt32(nalu.count).bigEndian
            withUnsafeBytes(of: &lengthBE) { avccData.append(contentsOf: $0) }
            avccData.append(nalu)
        }

        // Update format description if first time or parameter sets changed mid-stream
        let hasRequiredParams = isHEVC
            ? (vpsData != nil && spsData != nil && ppsData != nil)
            : (spsData != nil && ppsData != nil)

        if (formatDescription == nil || paramSetsChanged) && hasRequiredParams {
            updateFormatDescription(isHEVC: isHEVC)
        }

        guard let formatDesc = formatDescription, decompressionSession != nil else {
            // Parameter sets haven't arrived yet; request a keyframe (rate-limited)
            requestKeyframeIfNeeded()
            return
        }

        guard hasVideoSlice && !avccData.isEmpty else { return }

        decodeSliceBuffer(avccData, formatDescription: formatDesc, ptsMs: packet.ptsMs, startTime: startTime)
    }

    private func updateFormatDescription(isHEVC: Bool) {
        var newDesc: CMVideoFormatDescription?
        var status: OSStatus = -1

        if !isHEVC {
            guard let sps = spsData, let pps = ppsData else { return }
            sps.withUnsafeBytes { spsBuf in
                pps.withUnsafeBytes { ppsBuf in
                    guard let spsPtr = spsBuf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                          let ppsPtr = ppsBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                    let pointers = [spsPtr, ppsPtr]
                    let sizes = [sps.count, pps.count]
                    status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: 2,
                        parameterSetPointers: pointers,
                        parameterSetSizes: sizes,
                        nalUnitHeaderLength: 4,
                        formatDescriptionOut: &newDesc
                    )
                }
            }
        } else {
            guard let vps = vpsData, let sps = spsData, let pps = ppsData else { return }
            vps.withUnsafeBytes { vpsBuf in
                sps.withUnsafeBytes { spsBuf in
                    pps.withUnsafeBytes { ppsBuf in
                        guard let vpsPtr = vpsBuf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                              let spsPtr = spsBuf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                              let ppsPtr = ppsBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                        let pointers = [vpsPtr, spsPtr, ppsPtr]
                        let sizes = [vps.count, sps.count, pps.count]
                        status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 3,
                            parameterSetPointers: pointers,
                            parameterSetSizes: sizes,
                            nalUnitHeaderLength: 4,
                            extensions: nil,
                            formatDescriptionOut: &newDesc
                        )
                    }
                }
            }
        }

        guard status == noErr, let desc = newDesc else { return }

        if let oldDesc = formatDescription,
           CMFormatDescriptionEqual(oldDesc, otherFormatDescription: desc),
           decompressionSession != nil {
            return
        }

        formatDescription = desc

        if let existing = decompressionSession,
           VTDecompressionSessionCanAcceptFormatDescription(existing, formatDescription: desc) {
            return
        }

        recreateDecompressionSession(formatDescription: desc)
    }

    private func recreateDecompressionSession(formatDescription: CMVideoFormatDescription) {
        if let old = decompressionSession {
            VTDecompressionSessionWaitForAsynchronousFrames(old)
            VTDecompressionSessionInvalidate(old)
            decompressionSession = nil
        }

        let decoderSpec: [CFString: Any] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true
        ]

        let destinationAttrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]
        ]

        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: decoderSpec as CFDictionary,
            imageBufferAttributes: destinationAttrs as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &session
        )

        guard status == noErr, let created = session else {
            stateLock.lock()
            _isHardwareAccelerated = false
            stateLock.unlock()
            return
        }

        // Configure for low-latency real-time streaming
        VTSessionSetProperty(created, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)

        var hwUsed: CFTypeRef?
        let propStatus = withUnsafeMutablePointer(to: &hwUsed) { ptr in
            VTSessionCopyProperty(
                created,
                key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                allocator: kCFAllocatorDefault,
                valueOut: UnsafeMutableRawPointer(ptr)
            )
        }
        let isHW = (propStatus == noErr) && ((hwUsed as? Bool) ?? false)

        stateLock.lock()
        _isHardwareAccelerated = isHW
        stateLock.unlock()

        decompressionSession = created
    }

    private func decodeSliceBuffer(
        _ data: Data,
        formatDescription: CMVideoFormatDescription,
        ptsMs: UInt32,
        startTime: CFAbsoluteTime
    ) {
        guard let session = decompressionSession else { return }

        guard let rawMemory = Darwin.malloc(data.count) else { return }
        data.copyBytes(to: rawMemory.assumingMemoryBound(to: UInt8.self), count: data.count)

        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: rawMemory,
            blockLength: data.count,
            blockAllocator: kCFAllocatorMalloc,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard blockStatus == noErr, let buffer = blockBuffer else {
            Darwin.free(rawMemory)
            return
        }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: CMTimeValue(ptsMs), timescale: 1000),
            decodeTimeStamp: .invalid
        )
        var sampleSize = data.count
        var sampleBuffer: CMSampleBuffer?

        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: buffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )

        guard sampleStatus == noErr, let sBuffer = sampleBuffer else { return }

        var infoFlags: VTDecodeInfoFlags = []
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sBuffer,
            flags: [._EnableAsynchronousDecompression],
            infoFlagsOut: &infoFlags
        ) { [weak self] status, _, imageBuffer, _, _ in
            guard let self else { return }
            if status == noErr, let pixelBuffer = imageBuffer {
                let elapsedMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
                self.stateLock.lock()
                self._lastDecodeMs = elapsedMs
                self.stateLock.unlock()

                self.decodeQueue.async {
                    self.consecutiveErrors = 0
                }
                self.onDecodedFrame?(pixelBuffer)
            } else {
                self.decodeQueue.async {
                    self.handleDecodeError()
                }
            }
        }

        if decodeStatus != noErr {
            handleDecodeError()
        }
    }

    private func handleDecodeError() {
        consecutiveErrors += 1
        if consecutiveErrors >= 3 {
            consecutiveErrors = 0
            requestKeyframeIfNeeded()
        }
    }

    private func requestKeyframeIfNeeded() {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastKeyframeRequestTime >= 1.0 else { return }
        lastKeyframeRequestTime = now
        onRequestKeyframe?()
    }

    // MARK: - JPEG Fallback Decoding

    private func decodeJPEG(_ packet: VideoFramePacket, startTime: CFAbsoluteTime) {
        stateLock.lock()
        _isHardwareAccelerated = false
        stateLock.unlock()

        guard let source = CGImageSourceCreateWithData(packet.data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return
        }

        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return }

        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]
        ]

        var pixelBufferOut: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBufferOut
        )
        guard status == kCVReturnSuccess, let pixelBuffer = pixelBufferOut else { return }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue

        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let elapsedMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
        stateLock.lock()
        _lastDecodeMs = elapsedMs
        stateLock.unlock()

        onDecodedFrame?(pixelBuffer)
    }

    // MARK: - Annex-B Start Code Parser

    private func splitAnnexBNALUs(_ data: Data) -> [Data] {
        let count = data.count
        guard count >= 4 else { return [] }

        return data.withUnsafeBytes { raw -> [Data] in
            guard let ptr = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return [] }

            var nalus: [Data] = []
            var starts: [(dataStart: Int, codeLen: Int)] = []
            var i = 0

            while i <= count - 3 {
                if ptr[i] == 0 && ptr[i + 1] == 0 {
                    if ptr[i + 2] == 1 {
                        starts.append((i + 3, 3))
                        i += 3
                        continue
                    } else if i <= count - 4 && ptr[i + 2] == 0 && ptr[i + 3] == 1 {
                        starts.append((i + 4, 4))
                        i += 4
                        continue
                    }
                }
                i += 1
            }

            guard !starts.isEmpty else { return [] }

            for idx in 0..<starts.count {
                let start = starts[idx].dataStart
                let end: Int
                if idx + 1 < starts.count {
                    end = starts[idx + 1].dataStart - starts[idx + 1].codeLen
                } else {
                    end = count
                }
                if end > start {
                    nalus.append(Data(bytes: ptr.advanced(by: start), count: end - start))
                }
            }

            return nalus
        }
    }
}
