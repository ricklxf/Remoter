import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

// VTCompressionSession wrapper: CVPixelBuffer → H.264 Annex-B NAL units.
// Output fires on VT's internal queue; caller must be thread-safe.
final class H264Encoder {
    var onEncodedFrame: ((Data, Bool) -> Void)?

    private var session: VTCompressionSession?
    private var frameIndex: Int64 = 0
    private var forceKeyframeNext = false

    // VTCompressionSessionEncodeFrame blocks the *next* submission until its
    // internal queue has a free slot, which only happens once the previous
    // frame's completion callback returns. If onEncodedFrame (network send,
    // chunking, etc.) ran directly on that callback, any slowness downstream
    // (e.g. WebRTC data channel backpressure) would propagate straight back
    // into encode submission — exactly the kind of stall that made fps dip
    // in bursts. Hop off VT's callback thread immediately so it can always
    // free its queue slot right away, regardless of how long sending takes.
    private let outputQueue = DispatchQueue(label: "remoter.h264.output", qos: .userInitiated)

    /// Forces the *next* encode() call to emit a keyframe immediately,
    /// instead of waiting for the next scheduled one (up to 2s away) — used
    /// when a client (re)attaches a fresh decoder, e.g. switching back to a
    /// tab, and would otherwise show a black screen until the next interval.
    func forceKeyframe() {
        forceKeyframeNext = true
    }

    /// Adjusts the live session's target bitrate without tearing it down —
    /// VideoToolbox supports changing this property mid-stream. Lets the
    /// client's quality picker (e.g. "流畅优先") actually take effect instead
    /// of being silently inert, which matters most exactly when it's needed:
    /// a client whose decode can't keep up with the fixed default bitrate.
    func setBitrate(_ bitrateBps: Int) {
        guard let session else { return }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                              value: NSNumber(value: bitrateBps))
    }

    func setup(width: Int, height: Int, fps: Int, bitrateBps: Int) throws {
        var s: VTCompressionSession?
        let encoderSpec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: kCFBooleanTrue!
        ]
        let err = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width:  Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: encoderSpec as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &s
        )
        guard err == noErr, let s else {
            throw NSError(domain: "H264Encoder", code: Int(err),
                          userInfo: [NSLocalizedDescriptionKey: "VTCompressionSessionCreate failed err=\(err)"])
        }

        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime,             value: kCFBooleanTrue)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        // Baseline profile: 最兼容 WebCodecs，无 B 帧，软件编码器稳定支持
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: kVTProfileLevel_H264_Baseline_AutoLevel)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate,
                             value: NSNumber(value: bitrateBps))
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate,
                             value: NSNumber(value: fps))
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
                             value: NSNumber(value: 2.0))

        guard VTCompressionSessionPrepareToEncodeFrames(s) == noErr else {
            VTCompressionSessionInvalidate(s)
            throw NSError(domain: "H264Encoder", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "PrepareToEncodeFrames failed"])
        }

        session = s
        frameIndex = 0
        var usingHW: CFTypeRef?
        VTSessionCopyProperty(s, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                               allocator: kCFAllocatorDefault, valueOut: &usingHW)
        ConnectionLogger.shared.logStep(sessionId: "h264", step: "encoder_ready",
            detail: "\(width)x\(height) \(fps)fps \(bitrateBps/1000)kbps hw=\((usingHW as? Bool) ?? false)")
    }

    func encode(_ pb: CVPixelBuffer) {
        guard let session else { return }

        let idx  = frameIndex
        frameIndex += 1
        let pts  = CMTime(value: idx, timescale: 60)

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
                    ConnectionLogger.shared.logStep(sessionId: "h264", step: "encode_err",
                        detail: "status=\(status)")
                }
                return
            }
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

        guard let data = avccToAnnexB(sample, includeParamSets: isKeyframe) else { return }
        onEncodedFrame?(data, isKeyframe)
    }

    // AVCC (4-byte length prefix) → Annex-B (0x00000001 start code)
    private func avccToAnnexB(_ sample: CMSampleBuffer, includeParamSets: Bool) -> Data? {
        var result = Data()

        if includeParamSets,
           let desc = CMSampleBufferGetFormatDescription(sample) {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                desc, parameterSetIndex: 0,
                parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            for i in 0..<count {
                var ptr: UnsafePointer<UInt8>?
                var sz = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    desc, parameterSetIndex: i,
                    parameterSetPointerOut: &ptr, parameterSetSizeOut: &sz,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
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
