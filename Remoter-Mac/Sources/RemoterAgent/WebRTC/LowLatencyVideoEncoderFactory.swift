import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox
import QuartzCore
import WebRTC

/// Custom WebRTC video encoder factory wrapping `RTCDefaultVideoEncoderFactory`.
/// Intercepts ALL H.264 profiles (High `640c..`/`6400..`, Main `4d..`, Baseline `42..`)
/// to use `LowLatencyH264VideoEncoder` with VideoToolbox low-latency rate control,
/// 1.5x burst DataRateLimits, zero frame delay, and explicit BT.709 Full Range color metadata;
/// delegates all other codecs (VP9, AV1, etc.) to `RTCDefaultVideoEncoderFactory`.
final class LowLatencyVideoEncoderFactory: NSObject, RTCVideoEncoderFactory {
    private let defaultFactory = RTCDefaultVideoEncoderFactory()

    func createEncoder(_ info: RTCVideoCodecInfo) -> RTCVideoEncoder? {
        if info.name.uppercased() == "H264" {
            ConnectionLogger.shared.logStep(
                sessionId: "webrtc",
                step: "encoder_factory_create",
                detail: "custom=LowLatencyH264VideoEncoder profile=\(info.parameters["profile-level-id"] ?? "default")"
            )
            return LowLatencyH264VideoEncoder(codecInfo: info)
        }
        return defaultFactory.createEncoder(info)
    }

    func supportedCodecs() -> [RTCVideoCodecInfo] {
        let defaults = defaultFactory.supportedCodecs()
        var highH264: [RTCVideoCodecInfo] = []
        // Chrome offers H.264 High Profile (64001f/640032), whereas RTCDefaultVideoEncoderFactory
        // only advertises Constrained High (640c1f). libwebrtc treats kProfileHigh !=
        // kProfileConstrainedHigh and falls back to Constrained Baseline (42e01f, no CABAC).
        // Explicitly advertising 640032 first lets Chrome negotiate High Profile with CABAC.
        let hasHigh6400 = defaults.contains {
            $0.name.uppercased() == "H264"
                && ($0.parameters["profile-level-id"]?.lowercased().hasPrefix("6400") ?? false)
        }
        if !hasHigh6400 {
            highH264.append(RTCVideoCodecInfo(name: "H264", parameters: [
                "profile-level-id": "640032",
                "level-asymmetry-allowed": "1",
                "packetization-mode": "1"
            ]))
        }
        highH264.append(contentsOf: defaults.filter { Self.isH264HighProfile($0) })
        let otherH264 = defaults.filter { $0.name.uppercased() == "H264" && !Self.isH264HighProfile($0) }
        let others = defaults.filter { $0.name.uppercased() != "H264" }
        return highH264 + otherH264 + others
    }

    static func isH264HighProfile(_ info: RTCVideoCodecInfo) -> Bool {
        guard info.name.uppercased() == "H264" else { return false }
        guard let profile = info.parameters["profile-level-id"]?.lowercased() else { return false }
        return profile.hasPrefix("640c") || profile.hasPrefix("6400")
    }
}

/// VideoToolbox-backed H.264 High Profile encoder for WebRTC RTP with low-latency
/// anti-blur rate control (`EnableLowLatencyRateControl`, 1.5x burst `DataRateLimits`,
/// `MaxFrameDelayCount = 0`, `AllowFrameReordering = false`, BT.709 Full Range metadata).
final class LowLatencyH264VideoEncoder: NSObject, RTCVideoEncoder {
    private let codecInfo: RTCVideoCodecInfo
    private let stateLock = NSLock()

    private var session: VTCompressionSession?
    private var callback: RTCVideoEncoderCallback?
    private var width: Int32 = 0
    private var height: Int32 = 0
    private var currentBitrateBps: Int = 4_000_000
    private var currentFps: Int = 60
    private var codecMode: RTCVideoCodecMode = .screensharing
    private var isReleased = false

    // WebRTC video codec return codes
    private static let codecOK: Int = 0
    private static let codecError: Int = -1

    init(codecInfo: RTCVideoCodecInfo) {
        self.codecInfo = codecInfo
        super.init()
    }

    deinit {
        _ = release()
    }

    // MARK: - RTCVideoEncoder

    func setCallback(_ callback: RTCVideoEncoderCallback?) {
        stateLock.lock()
        self.callback = callback
        stateLock.unlock()
    }

    func startEncode(with settings: RTCVideoEncoderSettings, numberOfCores: Int32) -> Int {
        stateLock.lock()
        isReleased = false
        let w = Int32(settings.width)
        let h = Int32(settings.height)
        let startBps = settings.startBitrate > 0 ? Int(settings.startBitrate) * 1000 : 4_000_000
        let fps = max(1, Int(settings.maxFramerate > 0 ? settings.maxFramerate : 60))
        codecMode = settings.mode
        currentBitrateBps = startBps
        currentFps = fps
        let oldSession = session
        session = nil
        stateLock.unlock()

        if let oldSession {
            VTCompressionSessionInvalidate(oldSession)
        }

        return recreateSession(width: w, height: h, bitrateBps: startBps, fps: fps) ? Self.codecOK : Self.codecError
    }

    func release() -> Int {
        stateLock.lock()
        isReleased = true
        let s = session
        session = nil
        callback = nil
        stateLock.unlock()

        if let s {
            VTCompressionSessionInvalidate(s)
        }
        return Self.codecOK
    }

    func encode(
        _ frame: RTCVideoFrame,
        codecSpecificInfo info: RTCCodecSpecificInfo?,
        frameTypes: [NSNumber]
    ) -> Int {
        let frameW = frame.width
        let frameH = frame.height
        guard frameW > 0, frameH > 0 else { return Self.codecError }

        stateLock.lock()
        if isReleased {
            stateLock.unlock()
            return Self.codecError
        }
        let needsRecreate = (session == nil || width != frameW || height != frameH)
        let targetBps = currentBitrateBps
        let targetFps = currentFps
        stateLock.unlock()

        if needsRecreate {
            guard recreateSession(width: frameW, height: frameH, bitrateBps: targetBps, fps: targetFps) else {
                return Self.codecError
            }
        }

        stateLock.lock()
        guard let activeSession = session, !isReleased else {
            stateLock.unlock()
            return Self.codecError
        }
        let activeMode = codecMode
        stateLock.unlock()

        guard let pixelBuffer = extractPixelBuffer(from: frame, targetWidth: frameW, targetHeight: frameH) else {
            return Self.codecError
        }

        let forceKeyframe = frameTypes.contains { $0.uintValue == RTCFrameType.videoFrameKey.rawValue }
        let frameProperties: CFDictionary? = forceKeyframe
            ? ([kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary)
            : nil

        let rtpTimestamp = frame.timeStamp
        let timestampNs = frame.timeStampNs
        let rotation = frame.rotation
        let pts = CMTime(value: timestampNs, timescale: 1_000_000_000)
        let encodeStartMs = Int64(CACurrentMediaTime() * 1000)

        let status = VTCompressionSessionEncodeFrame(
            activeSession,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: frameProperties,
            infoFlagsOut: nil
        ) { [weak self] encodeStatus, _, sampleBuffer in
            guard let self, encodeStatus == noErr, let sampleBuffer else { return }
            self.handleEncodedSample(
                sampleBuffer,
                width: frameW,
                height: frameH,
                rtpTimestamp: rtpTimestamp,
                timestampNs: timestampNs,
                rotation: rotation,
                encodeStartMs: encodeStartMs,
                mode: activeMode
            )
        }

        return status == noErr ? Self.codecOK : Self.codecError
    }

    func setBitrate(_ bitrateKbit: UInt32, framerate: UInt32) -> Int32 {
        let bps = max(100_000, Int(bitrateKbit) * 1000)
        let fps = max(1, Int(framerate))

        stateLock.lock()
        currentBitrateBps = bps
        currentFps = fps
        let activeSession = session
        stateLock.unlock()

        if let activeSession {
            applyRateControl(activeSession, bitrateBps: bps, fps: fps)
        }
        return Int32(Self.codecOK)
    }

    func implementationName() -> String {
        "LowLatencyVideoToolboxH264"
    }

    func scalingSettings() -> RTCVideoEncoderQpThresholds? {
        // Disable QP-driven resolution downscaling so desktop text stays crisp at native resolution.
        nil
    }

    var resolutionAlignment: Int { 1 }
    var applyAlignmentToAllSimulcastLayers: Bool { false }
    var supportsNativeHandle: Bool { true }

    // MARK: - Private: VideoToolbox Session

    private func recreateSession(width w: Int32, height h: Int32, bitrateBps: Int, fps: Int) -> Bool {
        var newSession: VTCompressionSession?
        let encoderSpec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: kCFBooleanTrue!,
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue!
        ]

        let err = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: w,
            height: h,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: encoderSpec as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &newSession
        )
        guard err == noErr, let s = newSession else {
            ConnectionLogger.shared.logStep(
                sessionId: "webrtc",
                step: "vt_rtp_encoder_err",
                detail: "create failed \(w)x\(h) err=\(err)"
            )
            return false
        }

        // Core low-latency anti-blur properties
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanTrue)

        let profileTag = configureProfileLevel(s)

        // Explicit BT.709 color metadata (preserves Full Range from input CVPixelBuffer)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ColorPrimaries, value: kCVImageBufferColorPrimaries_ITU_R_709_2)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_TransferFunction, value: kCVImageBufferTransferFunction_ITU_R_709_2)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_YCbCrMatrix, value: kCVImageBufferYCbCrMatrix_ITU_R_709_2)

        applyRateControl(s, bitrateBps: bitrateBps, fps: fps)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: NSNumber(value: 10.0))

        guard VTCompressionSessionPrepareToEncodeFrames(s) == noErr else {
            VTCompressionSessionInvalidate(s)
            return false
        }

        stateLock.lock()
        if isReleased {
            stateLock.unlock()
            VTCompressionSessionInvalidate(s)
            return false
        }
        let oldSession = session
        session = s
        width = w
        height = h
        stateLock.unlock()

        if let oldSession {
            VTCompressionSessionInvalidate(oldSession)
        }

        var usingHW: CFTypeRef?
        VTSessionCopyProperty(
            s,
            key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
            allocator: kCFAllocatorDefault,
            valueOut: &usingHW
        )
        ConnectionLogger.shared.logStep(
            sessionId: "webrtc",
            step: "vt_rtp_encoder_ready",
            detail: "\(profileTag) \(w)x\(h) \(fps)fps \(bitrateBps/1000)kbps hw=\((usingHW as? Bool) ?? false)"
        )
        return true
    }

    private func configureProfileLevel(_ session: VTCompressionSession) -> String {
        let id = codecInfo.parameters["profile-level-id"]?.lowercased() ?? ""
        if id.hasPrefix("42e0") {
            let status = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                                              value: kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel)
            if status == noErr { return "h264_constrained_baseline" }
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                                 value: kVTProfileLevel_H264_Baseline_AutoLevel)
            return "h264_baseline"
        } else if id.hasPrefix("42") {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                                 value: kVTProfileLevel_H264_Baseline_AutoLevel)
            return "h264_baseline"
        } else if id.hasPrefix("4d") {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                                 value: kVTProfileLevel_H264_Main_AutoLevel)
            return "h264_main"
        } else {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                                 value: kVTProfileLevel_H264_High_AutoLevel)
            return "h264_high"
        }
    }

    private func applyRateControl(_ session: VTCompressionSession, bitrateBps: Int, fps: Int) {
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: bitrateBps))
        // 2.0x burst headroom over a 0.5s window so sudden full-screen scrolling gets instant
        // burst bits without QP spiking into blurry text.
        let burstByteLimit = Int64(Double(bitrateBps) * 2.0 * 0.5 / 8.0)
        let dataRateLimits: [Any] = [burstByteLimit, 0.5]
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: dataRateLimits as CFArray)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: fps))
    }

    // MARK: - Private: PixelBuffer Extraction

    private func extractPixelBuffer(from frame: RTCVideoFrame, targetWidth: Int32, targetHeight: Int32) -> CVPixelBuffer? {
        if let cvBuf = frame.buffer as? RTCCVPixelBuffer {
            if !cvBuf.requiresCropping() && !cvBuf.requiresScaling(toWidth: targetWidth, height: targetHeight) {
                return cvBuf.pixelBuffer
            }
            var dst: CVPixelBuffer?
            let srcFormat = CVPixelBufferGetPixelFormatType(cvBuf.pixelBuffer)
            let attrs: [CFString: Any] = [
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
            ]
            let status = CVPixelBufferCreate(
                kCFAllocatorDefault,
                Int(targetWidth),
                Int(targetHeight),
                srcFormat,
                attrs as CFDictionary,
                &dst
            )
            guard status == kCVReturnSuccess, let dst else { return nil }
            let tmpSize = Int(cvBuf.bufferSizeForCroppingAndScaling(toWidth: targetWidth, height: targetHeight))
            if tmpSize > 0 {
                var tmp = [UInt8](repeating: 0, count: tmpSize)
                let ok = tmp.withUnsafeMutableBufferPointer { ptr in
                    cvBuf.cropAndScale(to: dst, withTempBuffer: ptr.baseAddress)
                }
                return ok ? dst : nil
            } else {
                return cvBuf.cropAndScale(to: dst, withTempBuffer: nil) ? dst : nil
            }
        }

        // Software I420 fallback
        let i420 = frame.buffer.toI420()
        var dst: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(i420.width),
            Int(i420.height),
            kCVPixelFormatType_420YpCbCr8PlanarFullRange,
            attrs as CFDictionary,
            &dst
        )
        guard status == kCVReturnSuccess, let dst else { return nil }
        CVPixelBufferLockBaseAddress(dst, [])
        defer { CVPixelBufferUnlockBaseAddress(dst, []) }

        copyPlane(src: i420.dataY, srcStride: Int(i420.strideY), dst: dst, planeIndex: 0, width: Int(i420.width), height: Int(i420.height))
        copyPlane(src: i420.dataU, srcStride: Int(i420.strideU), dst: dst, planeIndex: 1, width: Int(i420.chromaWidth), height: Int(i420.chromaHeight))
        copyPlane(src: i420.dataV, srcStride: Int(i420.strideV), dst: dst, planeIndex: 2, width: Int(i420.chromaWidth), height: Int(i420.chromaHeight))
        return dst
    }

    private func copyPlane(src: UnsafePointer<UInt8>, srcStride: Int, dst: CVPixelBuffer, planeIndex: Int, width: Int, height: Int) {
        guard let dstBase = CVPixelBufferGetBaseAddressOfPlane(dst, planeIndex) else { return }
        let dstStride = CVPixelBufferGetBytesPerRowOfPlane(dst, planeIndex)
        let copyBytes = min(width, min(srcStride, dstStride))
        for row in 0..<height {
            memcpy(dstBase.advanced(by: row * dstStride), src.advanced(by: row * srcStride), copyBytes)
        }
    }

    // MARK: - Private: Sample Output → RTCEncodedImage

    private func handleEncodedSample(
        _ sample: CMSampleBuffer,
        width: Int32,
        height: Int32,
        rtpTimestamp: Int32,
        timestampNs: Int64,
        rotation: RTCVideoRotation,
        encodeStartMs: Int64,
        mode: RTCVideoCodecMode
    ) {
        stateLock.lock()
        let cb = isReleased ? nil : callback
        stateLock.unlock()
        guard let cb else { return }

        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        let isKeyframe = !notSync

        guard let annexB = Self.avccToAnnexB(sample, includeParamSets: isKeyframe) else { return }

        let image = RTCEncodedImage()
        image.buffer = annexB
        image.encodedWidth = width
        image.encodedHeight = height
        image.timeStamp = UInt32(bitPattern: rtpTimestamp)
        image.captureTimeMs = timestampNs / 1_000_000
        image.ntpTimeMs = 0
        image.encodeStartMs = encodeStartMs
        image.encodeFinishMs = Int64(CACurrentMediaTime() * 1000)
        image.frameType = isKeyframe ? .videoFrameKey : .videoFrameDelta
        image.rotation = rotation
        image.contentType = (mode == .screensharing) ? .screenshare : .unspecified

        let h264Info = RTCCodecSpecificInfoH264()
        h264Info.packetizationMode = .nonInterleaved

        _ = cb(image, h264Info)
    }

    private static func avccToAnnexB(_ sample: CMSampleBuffer, includeParamSets: Bool) -> Data? {
        var result = Data()

        if includeParamSets, let desc = CMSampleBufferGetFormatDescription(sample) {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                desc,
                parameterSetIndex: 0,
                parameterSetPointerOut: nil,
                parameterSetSizeOut: nil,
                parameterSetCountOut: &count,
                nalUnitHeaderLengthOut: nil
            )
            for i in 0..<count {
                var ptr: UnsafePointer<UInt8>?
                var sz = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    desc,
                    parameterSetIndex: i,
                    parameterSetPointerOut: &ptr,
                    parameterSetSizeOut: &sz,
                    parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: nil
                )
                if let ptr, sz > 0 {
                    result.append(contentsOf: [0, 0, 0, 1])
                    result.append(Data(bytes: ptr, count: sz))
                }
            }
        }

        guard let bb = CMSampleBufferGetDataBuffer(sample) else { return nil }
        var total = 0
        var raw: UnsafeMutablePointer<CChar>?
        CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &total, dataPointerOut: &raw)
        guard let raw else { return nil }

        var off = 0
        while off + 4 <= total {
            let nalLen = Int(UInt8(bitPattern: raw[off])) << 24
                | Int(UInt8(bitPattern: raw[off + 1])) << 16
                | Int(UInt8(bitPattern: raw[off + 2])) << 8
                | Int(UInt8(bitPattern: raw[off + 3]))
            off += 4
            guard off + nalLen <= total, nalLen > 0 else { break }
            result.append(contentsOf: [0, 0, 0, 1])
            result.append(Data(bytes: raw.advanced(by: off), count: nalLen))
            off += nalLen
        }

        return result.isEmpty ? nil : result
    }
}
