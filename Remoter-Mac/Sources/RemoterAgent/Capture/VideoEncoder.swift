import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

enum StreamCodec: String {
    case h264
    case h265
}

// VTCompressionSession wrapper: CVPixelBuffer → H.264/HEVC Annex-B NAL units.
// Output fires on VT's internal queue; caller must be thread-safe.
final class VideoEncoder {
    var onEncodedFrame: ((Data, Bool) -> Void)?

    private var session: VTCompressionSession?
    private var codec: StreamCodec = .h264
    private var frameIndex: Int64 = 0
    private var forceKeyframeNext = false
    private var currentBitrateBps: Int = 8_000_000
    private var isRefinementBoostActive = false

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
        forceKeyframeNext = true
    }

    /// Adjusts the live session's target bitrate without tearing it down —
    /// VideoToolbox supports changing this property mid-stream. Lets the
    /// client's quality picker actually take effect instead of being
    /// silently inert, which matters most exactly when it's needed:
    /// a client whose decode can't keep up with the fixed default bitrate.
    func setBitrate(_ bitrateBps: Int) {
        currentBitrateBps = bitrateBps
        isRefinementBoostActive = false
        guard let session else { return }
        applyBitrateProperties(session, bitrateBps: bitrateBps, burstMultiplier: 1.5, prioritizeSpeed: true)
    }

    private func applyBitrateProperties(_ session: VTCompressionSession, bitrateBps: Int, burstMultiplier: Double, prioritizeSpeed: Bool) {
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                             value: NSNumber(value: bitrateBps))
        let burstByteLimit = Int64(Double(bitrateBps) * burstMultiplier / 8.0)
        let dataRateLimits: [Any] = [burstByteLimit, 1.0]
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: dataRateLimits as CFArray)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality,
                             value: prioritizeSpeed ? kCFBooleanTrue : kCFBooleanFalse)
    }

    /// Adjusts the live session's expected frame rate without tearing it down.
    func setFps(_ fps: Int) {
        guard let session else { return }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate,
                             value: NSNumber(value: fps))
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
        self.codec = codec
        self.currentBitrateBps = bitrateBps
        self.isRefinementBoostActive = false
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

        applyBitrateProperties(s, bitrateBps: bitrateBps, burstMultiplier: 1.5, prioritizeSpeed: true)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate,
                             value: NSNumber(value: fps))
        // A keyframe is ~10-20x the size of a delta frame; at the old 2s
        // interval keyframes alone ate ~20% of a 2Mbps budget. On-demand
        // request_keyframe covers every recovery case (drops, tab switches,
        // decoder overload), so the periodic one is just a slow safety net.
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
                             value: NSNumber(value: 10.0))

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
        if hdr {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ColorPrimaries,
                                 value: kCVImageBufferColorPrimaries_ITU_R_2020)
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_TransferFunction,
                                 value: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ)
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_YCbCrMatrix,
                                 value: kCVImageBufferYCbCrMatrix_ITU_R_2020)
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_HDRMetadataInsertionMode,
                                 value: kVTHDRMetadataInsertionMode_Auto)
        } else {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ColorPrimaries,
                                 value: kCVImageBufferColorPrimaries_ITU_R_709_2)
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_TransferFunction,
                                 value: kCVImageBufferTransferFunction_ITU_R_709_2)
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_YCbCrMatrix,
                                 value: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        }
    }

    /// Encodes a clean, high-quality refinement frame for static-frame sharpening
    /// (temporarily lifting bitrate limit and prioritizing quality over speed).
    func encodeRefinementFrame(_ pb: CVPixelBuffer) {
        guard let session else { return }
        let boostedBitrate = min(max(currentBitrateBps * 2, 20_000_000), 60_000_000)
        applyBitrateProperties(session, bitrateBps: boostedBitrate, burstMultiplier: 2.5, prioritizeSpeed: false)
        isRefinementBoostActive = true
        submitFrame(pb, session: session)
    }

    func encode(_ pb: CVPixelBuffer) {
        guard let session else { return }
        if isRefinementBoostActive {
            applyBitrateProperties(session, bitrateBps: currentBitrateBps, burstMultiplier: 1.5, prioritizeSpeed: true)
            isRefinementBoostActive = false
        }
        submitFrame(pb, session: session)
    }

    private func submitFrame(_ pb: CVPixelBuffer, session: VTCompressionSession) {

        let idx  = frameIndex
        frameIndex += 1
        let pts  = CMTime(value: idx, timescale: 60)

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
        if let s = session {
            VTCompressionSessionInvalidate(s)
            session = nil
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
