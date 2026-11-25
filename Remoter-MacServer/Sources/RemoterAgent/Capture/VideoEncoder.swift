import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox
import QuartzCore

enum StreamCodec: String {
    case h264
    case h265
}

// VTCompressionSession wrapper: CVPixelBuffer → H.264/HEVC Annex-B NAL units.
// Output fires on VT's internal queue; caller must be thread-safe.
final class VideoEncoder {
    var onEncodedFrame: ((Data, Bool) -> Void)?

    private let stateLock = NSLock()
    private var session: VTCompressionSession?
    private var codec: StreamCodec = .h264
    private var frameIndex: Int64 = 0
    private var lastPtsNs: Int64 = 0
    private var forceKeyframeNext = false
    private var currentBitrateBps: Int = 8_000_000
    private var maxFps: Int = 60

    // Cached VT properties to avoid redundant synchronous VTSessionSetProperty calls
    private var appliedBitrateBps: Int = 0
    private var appliedExpectedFps: Int = 0
    private var appliedPrioritizeSpeed: Bool = true
    private var lastRateControlApplyTime: CFTimeInterval = 0
    private var recentFrameTimes: [CFTimeInterval] = []
    private var lastFrameTime: CFTimeInterval = 0

    // UU-style dynamic ExpectedFrameRate rate-control constants
    private static let fpsWindowSeconds: CFTimeInterval = 0.6
    private static let rapidUpshiftWindowSeconds: CFTimeInterval = 0.06
    private static let rapidUpshiftFrameCount: Int = 3
    private static let idleWakeupIntervalSeconds: CFTimeInterval = 0.10
    private static let minDynamicExpectedFps: Int = 10
    private static let rateControlThrottleSeconds: CFTimeInterval = 0.10

    // True per-frame encode latency (submit → VT completion callback), for
    // the client's latency-breakdown panel. The perf_5s "enc=" figure only
    // times the submission call, which is ~0 — the actual encode happens on
    // VT's own thread. Multiple frames can be in flight, so submit times are
    // keyed by pts under a lock (both sides touch it from different threads).
    private(set) var lastEncodeMs: Double = 0
    private var submitTimes: [Int64: CFAbsoluteTime] = [:]
    private let submitLock = NSLock()

    // VTCompressionSessionEncodeFrame blocks the *next* submission until its
    // internal queue has a free slot, which only happens once the previous
    // frame's completion callback returns. If onEncodedFrame (network send,
    // chunking, etc.) ran directly on that callback, any slowness downstream
    // (e.g. WebRTC data channel backpressure) would propagate straight back
    // into encode submission — exactly the kind of stall that made fps dip
    // in bursts. Hop off VT's callback thread immediately so it can always
    // free its queue slot right away, regardless of how long sending takes.
    // .userInteractive — same reasoning as ScreenCapturer's captureQueue:
    // this is on the same synchronous per-frame real-time path, so it needs
    // to stay resistant to getting deprioritized under background system
    // load just as much as the capture callback does.
    private let outputQueue = DispatchQueue(label: "remoter.encode.output", qos: .userInteractive)

    /// Forces the *next* encode() call to emit a keyframe immediately,
    /// instead of waiting for the next scheduled one — used when a client
    /// (re)attaches a fresh decoder, e.g. switching back to a tab, and would
    /// otherwise show a black screen until the next interval.
    func forceKeyframe() {
        stateLock.lock()
        forceKeyframeNext = true
        stateLock.unlock()
    }

    /// Adjusts the live session's target bitrate without tearing it down —
    /// VideoToolbox supports changing this property mid-stream. Lets the
    /// client's quality picker actually take effect instead of being
    /// silently inert, which matters most exactly when it's needed:
    /// a client whose decode can't keep up with the fixed default bitrate.
    func setBitrate(_ bitrateBps: Int) {
        stateLock.lock()
        defer { stateLock.unlock() }
        currentBitrateBps = bitrateBps
        guard let session else { return }
        guard bitrateBps != appliedBitrateBps else { return }
        applyBitrateProperties(session, bitrateBps: bitrateBps)
    }

    private func applyBitrateProperties(_ session: VTCompressionSession, bitrateBps: Int) {
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                             value: NSNumber(value: bitrateBps))
        // Keep >= 500 KB/s burst headroom so VideoToolbox never silently drops
        // frames after a 2K keyframe when AverageBitRate adapts down to 1.2-2 Mbps.
        let burstByteLimit = Int64(max(Double(bitrateBps) * 2.0 / 8.0, 500_000.0))
        let dataRateLimits: [Any] = [burstByteLimit, 1.0]
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: dataRateLimits as CFArray)
        appliedBitrateBps = bitrateBps
    }

    private func applyPrioritizeSpeed(_ session: VTCompressionSession, prioritizeSpeed: Bool) {
        guard prioritizeSpeed != appliedPrioritizeSpeed else { return }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality,
                             value: prioritizeSpeed ? kCFBooleanTrue : kCFBooleanFalse)
        appliedPrioritizeSpeed = prioritizeSpeed
    }

    private func applyExpectedFps(_ session: VTCompressionSession, fps: Int) {
        guard fps != appliedExpectedFps else { return }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate,
                             value: NSNumber(value: fps))
        appliedExpectedFps = fps
    }

    /// Adjusts the live session's expected frame rate ceiling without tearing it down.
    func setFps(_ fps: Int) {
        stateLock.lock()
        defer { stateLock.unlock() }
        let clamped = max(1, fps)
        maxFps = clamped
        guard let session else { return }
        let desired = appliedExpectedFps > 0 ? min(appliedExpectedFps, clamped) : clamped
        applyExpectedFps(session, fps: desired)
    }

    func setup(
        width: Int,
        height: Int,
        fps: Int,
        bitrateBps: Int,
        codec: StreamCodec = .h264,
        chroma444: Bool = false,
        hdr: Bool = false
    ) throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        self.codec = codec
        self.currentBitrateBps = bitrateBps
        self.maxFps = max(1, fps)
        self.recentFrameTimes.removeAll(keepingCapacity: true)
        self.lastFrameTime = 0
        self.lastPtsNs = 0
        var s: VTCompressionSession?
        let encoderSpec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: kCFBooleanTrue!,
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue!
        ]
        let err = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width:  Int32(width),
            height: Int32(height),
            codecType: codec == .h265 ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
            encoderSpecification: encoderSpec as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &s
        )
        guard err == noErr, let s else {
            throw NSError(domain: "VideoEncoder", code: Int(err),
                          userInfo: [NSLocalizedDescriptionKey: "VTCompressionSessionCreate(\(codec.rawValue)) failed err=\(err)"])
        }

        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime,             value: kCFBooleanTrue)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxFrameDelayCount,   value: 0 as CFNumber)

        let selectedProfile = configureProfileLevel(s, codec: codec, chroma444: chroma444, hdr: hdr)
        configureColorMetadata(s, hdr: hdr)

        appliedBitrateBps = 0
        appliedExpectedFps = 0
        appliedPrioritizeSpeed = false // force initial true set below
        applyBitrateProperties(s, bitrateBps: bitrateBps)
        applyPrioritizeSpeed(s, prioritizeSpeed: true)
        applyExpectedFps(s, fps: self.maxFps)
        lastRateControlApplyTime = CACurrentMediaTime()
        // Disable unsolicited periodic keyframes (0 = infinite GOP, matching Parsec/Moonlight/UU):
        // remote desktop has no mid-stream joiners or seeking, and on-demand forceKeyframe() +
        // NACK/FEC cover every real recovery case. Periodic ~180KB keyframes while idle only
        // inject burst tail-drops into WAN tunnels and crush bitrate down to the floor.
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
                             value: NSNumber(value: 0.0))

        guard VTCompressionSessionPrepareToEncodeFrames(s) == noErr else {
            VTCompressionSessionInvalidate(s)
            throw NSError(domain: "VideoEncoder", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "PrepareToEncodeFrames failed"])
        }

        session = s
        frameIndex = 0
        var usingHW: CFTypeRef?
        VTSessionCopyProperty(s, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                              allocator: kCFAllocatorDefault, valueOut: &usingHW)
        ConnectionLogger.shared.logStep(sessionId: "encoder", step: "encoder_ready",
            detail: "\(codec.rawValue) \(width)x\(height) \(fps)fps \(bitrateBps/1000)kbps profile=\(selectedProfile) chroma444=\(chroma444) hdr=\(hdr) hw=\((usingHW as? Bool) ?? false)")
    }

    private func configureProfileLevel(
        _ session: VTCompressionSession,
        codec: StreamCodec,
        chroma444: Bool,
        hdr: Bool
    ) -> String {
        if codec == .h265 {
            if chroma444 {
                // Try HEVC Main 4:4:4 (10-bit first if HDR) and fall back gracefully if unsupported.
                let candidates: [(CFString, String)] = hdr
                    ? [
                        ("HEVC_Main44410_AutoLevel" as CFString, "HEVC_Main44410"),
                        ("HEVC_Main444_AutoLevel" as CFString, "HEVC_Main444"),
                        (kVTProfileLevel_HEVC_Main42210_AutoLevel, "HEVC_Main42210"),
                        (kVTProfileLevel_HEVC_Main10_AutoLevel, "HEVC_Main10")
                    ]
                    : [
                        ("HEVC_Main444_AutoLevel" as CFString, "HEVC_Main444"),
                        (kVTProfileLevel_HEVC_Main42210_AutoLevel, "HEVC_Main42210"),
                        (kVTProfileLevel_HEVC_Main_AutoLevel, "HEVC_Main")
                    ]
                for (index, candidate) in candidates.enumerated() {
                    let status = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: candidate.0)
                    if status == noErr {
                        if index > 0 {
                            ConnectionLogger.shared.logStep(sessionId: "encoder", step: "profile_fallback",
                                detail: "requested=HEVC_444 selected=\(candidate.1)")
                        }
                        return candidate.1
                    }
                }
            }
            if hdr {
                let status = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                                                  value: kVTProfileLevel_HEVC_Main10_AutoLevel)
                if status == noErr {
                    return "HEVC_Main10"
                }
                ConnectionLogger.shared.logStep(sessionId: "encoder", step: "profile_fallback",
                    detail: "requested=HEVC_Main10 err=\(status) selected=HEVC_Main")
            }
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                                 value: kVTProfileLevel_HEVC_Main_AutoLevel)
            return "HEVC_Main"
        } else {
            if chroma444 {
                let status = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                                                  value: "H264_High444_AutoLevel" as CFString)
                if status == noErr {
                    return "H264_High444"
                }
                ConnectionLogger.shared.logStep(sessionId: "encoder", step: "profile_fallback",
                    detail: "requested=H264_High444 err=\(status) selected=H264_High")
            }
            // High profile, not Baseline: B-frames are already disabled by
            // AllowFrameReordering=false above (that's the only Baseline
            // property latency actually needs), while Baseline additionally
            // forfeits CABAC entropy coding and 8x8 transforms — a free
            // 10-20% compression loss. WebCodecs decodes High everywhere;
            // the client's codec string declares High to match.
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                                 value: kVTProfileLevel_H264_High_AutoLevel)
            return "H264_High"
        }
    }

    private func configureColorMetadata(_ session: VTCompressionSession, hdr: Bool) {
        // Match UU Remote (libstreamer.dylib): do NOT override ColorPrimaries/TransferFunction/YCbCrMatrix
        // on VTCompressionSession in SDR mode. Setting TransferFunction=sRGB when ScreenCaptureKit tags
        // 420v frames as ITU_R_709_2 triggers an implicit VTPixelTransfer gamma lift (Y 64->71, 128->138)
        // that washes out / whitens the entire image across Electron and Windows clients.
        guard hdr else { return }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ColorPrimaries,
                             value: kCVImageBufferColorPrimaries_ITU_R_2020)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_TransferFunction,
                             value: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_YCbCrMatrix,
                             value: kCVImageBufferYCbCrMatrix_ITU_R_2020)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_HDRMetadataInsertionMode,
                             value: kVTHDRMetadataInsertionMode_Auto)
    }

    /// Encodes a clean, high-quality refinement frame for static-frame sharpening.
    /// Uses cached dynamic ExpectedFrameRate + quality-over-speed without thrashing
    /// AverageBitRate/DataRateLimits synchronously on every idle->motion transition.
    func encodeRefinementFrame(_ pb: CVPixelBuffer) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let session else { return }
        let now = CACurrentMediaTime()
        let floorFps = min(Self.minDynamicExpectedFps, maxFps)
        if appliedExpectedFps > floorFps {
            applyExpectedFps(session, fps: floorFps)
            lastRateControlApplyTime = now
        }
        applyPrioritizeSpeed(session, prioritizeSpeed: false)
        submitFrame(pb, session: session, now: now)
    }

    func encode(_ pb: CVPixelBuffer) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let session else { return }
        let now = CACurrentMediaTime()
        updateDynamicRateControl(session, now: now)
        submitFrame(pb, session: session, now: now)
    }

    private func updateDynamicRateControl(_ session: VTCompressionSession, now: CFTimeInterval) {
        let frameInterval = lastFrameTime > 0 ? (now - lastFrameTime) : 1.0
        lastFrameTime = now
        recentFrameTimes.append(now)
        let cutoff = now - Self.fpsWindowSeconds
        if let firstValidIdx = recentFrameTimes.firstIndex(where: { $0 >= cutoff }) {
            if firstValidIdx > 0 {
                recentFrameTimes.removeFirst(firstValidIdx)
            }
        } else {
            recentFrameTimes.removeAll(keepingCapacity: true)
        }

        let isRapidMotion = recentFrameTimes.count >= Self.rapidUpshiftFrameCount
            && (now - recentFrameTimes[recentFrameTimes.count - Self.rapidUpshiftFrameCount]) <= Self.rapidUpshiftWindowSeconds
        let isIdleWakeup = frameInterval > Self.idleWakeupIntervalSeconds

        let desiredExpectedFps: Int
        if isRapidMotion {
            desiredExpectedFps = maxFps
        } else {
            let observedFps = Double(recentFrameTimes.count) / Self.fpsWindowSeconds
            let floorFps = min(Self.minDynamicExpectedFps, maxFps)
            desiredExpectedFps = max(floorFps, min(maxFps, Int(ceil(observedFps * 1.25))))
        }

        let fpsDelta = abs(desiredExpectedFps - appliedExpectedFps)
        let fpsRatioChange = appliedExpectedFps > 0 ? (Double(fpsDelta) / Double(appliedExpectedFps)) : 1.0
        let significantFpsChange = (fpsDelta >= 5 || fpsRatioChange >= 0.20)
        let urgentFpsChange = (isRapidMotion && desiredExpectedFps > appliedExpectedFps)
            || (isIdleWakeup && desiredExpectedFps < appliedExpectedFps && significantFpsChange)

        if desiredExpectedFps != appliedExpectedFps &&
            (urgentFpsChange || (significantFpsChange && (now - lastRateControlApplyTime >= Self.rateControlThrottleSeconds))) {
            applyExpectedFps(session, fps: desiredExpectedFps)
            lastRateControlApplyTime = now
        }

        if isIdleWakeup {
            applyPrioritizeSpeed(session, prioritizeSpeed: false)
        } else if isRapidMotion {
            applyPrioritizeSpeed(session, prioritizeSpeed: true)
        }
    }

    private func submitFrame(_ pb: CVPixelBuffer, session: VTCompressionSession, now: CFTimeInterval) {
        let idx = frameIndex
        frameIndex += 1
        // Use real monotonic clock PTS so VideoToolbox perceives idle intervals
        // and accumulates VBV credit across static periods.
        let nowNs = Int64(now * 1_000_000_000)
        let ptsNs = max(nowNs, lastPtsNs + 1)
        lastPtsNs = ptsNs
        let pts = CMTime(value: ptsNs, timescale: 1_000_000_000)

        submitLock.lock()
        submitTimes[idx] = CFAbsoluteTimeGetCurrent()
        // Frames whose callback never fired (dropped by VT) would leak —
        // anything older than ~2s of frames is dead.
        if submitTimes.count > 200 {
            let cutoff = idx - 200
            submitTimes = submitTimes.filter { $0.key > cutoff }
        }
        submitLock.unlock()

        var frameProperties: CFDictionary?
        if forceKeyframeNext {
            forceKeyframeNext = false
            frameProperties = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
        }

        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pb,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: frameProperties,
            infoFlagsOut: nil
        ) { [weak self] status, _, sample in
            guard let self, status == noErr, let sample else {
                if status != noErr {
                    ConnectionLogger.shared.logStep(sessionId: "encoder", step: "encode_err",
                        detail: "status=\(status)")
                }
                return
            }
            self.submitLock.lock()
            if let t = self.submitTimes.removeValue(forKey: idx) {
                self.lastEncodeMs = (CFAbsoluteTimeGetCurrent() - t) * 1000
            }
            self.submitLock.unlock()
            self.outputQueue.async { self.handleOutput(sample) }
        }
    }

    func close() {
        stateLock.lock()
        let s = session
        session = nil
        stateLock.unlock()
        if let s {
            VTCompressionSessionInvalidate(s)
        }
    }

    // MARK: - Private

    private func handleOutput(_ sample: CMSampleBuffer) {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
            as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        let isKeyframe = !notSync

        guard let data = lengthPrefixedToAnnexB(sample, includeParamSets: isKeyframe) else { return }
        onEncodedFrame?(data, isKeyframe)
    }

    // AVCC/HVCC (4-byte length prefix) → Annex-B (0x00000001 start code).
    // H.264 keyframes carry SPS+PPS in-band; HEVC additionally carries VPS —
    // both come from the format description via their codec's accessor.
    private func lengthPrefixedToAnnexB(_ sample: CMSampleBuffer, includeParamSets: Bool) -> Data? {
        var result = Data()

        if includeParamSets,
           let desc = CMSampleBufferGetFormatDescription(sample) {
            var count = 0
            if codec == .h265 {
                CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    desc, parameterSetIndex: 0,
                    parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                    parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            } else {
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    desc, parameterSetIndex: 0,
                    parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                    parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            }
            for i in 0..<count {
                var ptr: UnsafePointer<UInt8>?
                var sz = 0
                if codec == .h265 {
                    CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                        desc, parameterSetIndex: i,
                        parameterSetPointerOut: &ptr, parameterSetSizeOut: &sz,
                        parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                } else {
                    CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                        desc, parameterSetIndex: i,
                        parameterSetPointerOut: &ptr, parameterSetSizeOut: &sz,
                        parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                }
                if let ptr, sz > 0 {
                    result.append(contentsOf: [0, 0, 0, 1])
                    result.append(Data(bytes: ptr, count: sz))
                }
            }
        }

        guard let bb = CMSampleBufferGetDataBuffer(sample) else { return nil }
        var total = 0
        var raw: UnsafeMutablePointer<CChar>?
        CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil,
                                    totalLengthOut: &total, dataPointerOut: &raw)
        guard let raw else { return nil }

        var off = 0
        while off + 4 <= total {
            let nalLen = Int(UInt8(bitPattern: raw[off    ])) << 24
                       | Int(UInt8(bitPattern: raw[off + 1])) << 16
                       | Int(UInt8(bitPattern: raw[off + 2])) <<  8
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
