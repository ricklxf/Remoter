import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

final class VideoEncoder {
    var onEncodedFrame: ((Data, Bool) -> Void)?

    private var session: VTCompressionSession?
    private var frameCount: Int = 0

    func setup(width: Int, height: Int, fps: Int, bitrate: Int) throws {
        var s: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: encodedFrameCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &s
        )
        guard status == noErr, let session = s else { throw RemoterError.encoderSetupFailed }

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_H264EntropyMode, value: kVTH264EntropyMode_CABAC)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFTypeRef)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: (fps * 2) as CFTypeRef)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFTypeRef)

        let dataRateLimits: [CFNumber] = [bitrate as CFNumber, 1 as CFNumber]
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: dataRateLimits as CFArray)

        VTCompressionSessionPrepareToEncodeFrames(session)
        self.session = session
        frameCount = 0
    }

    func encode(sampleBuffer: CMSampleBuffer) {
        guard let session,
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let dur = CMSampleBufferGetDuration(sampleBuffer)

        // Force keyframe every 5s as fallback
        var frameProps: CFDictionary?
        frameCount += 1
        if frameCount % 300 == 1 {
            frameProps = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
        }

        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: imageBuffer,
            presentationTimeStamp: pts,
            duration: dur,
            frameProperties: frameProps,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
    }

    func forceKeyframe() {
        frameCount = 0
    }

    /// 动态调整编码器码率（ABR 调用）
    func adjustBitrate(_ newBitrate: Int) {
        guard let session else { return }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: newBitrate as CFTypeRef)
        let limits: [CFNumber] = [newBitrate as CFNumber, 1 as CFNumber]
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limits as CFArray)
        print("[ABR] bitrate → \(newBitrate / 1_000) kbps")
    }

    func invalidate() {
        if let s = session {
            VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(s)
            session = nil
        }
    }
}

private func encodedFrameCallback(
    refcon: UnsafeMutableRawPointer?,
    _: UnsafeMutableRawPointer?,
    status: OSStatus,
    _: VTEncodeInfoFlags,
    sampleBuffer: CMSampleBuffer?
) {
    guard status == noErr, let sampleBuffer, let refcon else { return }

    let encoder = Unmanaged<VideoEncoder>.fromOpaque(refcon).takeUnretainedValue()

    let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
        as? [[CFString: Any]]
    let isKeyframe = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)

    guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

    var annexB = Data()

    // Prepend SPS + PPS for keyframes
    if isKeyframe, let fmtDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
        var paramCount = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            fmtDesc, parameterSetIndex: 0,
            parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &paramCount, nalUnitHeaderLengthOut: nil
        )
        for i in 0..<paramCount {
            var ptr: UnsafePointer<UInt8>?
            var size = 0
            let r = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                fmtDesc, parameterSetIndex: i,
                parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
            )
            if r == noErr, let p = ptr {
                annexB += [0x00, 0x00, 0x00, 0x01]
                annexB += Data(bytes: p, count: size)
            }
        }
    }

    // Convert AVCC → Annex B
    var totalLen = 0
    CMBlockBufferGetDataLength(dataBuffer, &totalLen)
    var raw: UnsafeMutablePointer<CChar>?
    CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil, dataPointerOut: &raw)
    guard let base = raw else { return }

    var offset = 0
    while offset + 4 <= totalLen {
        var naluLen: UInt32 = 0
        memcpy(&naluLen, base + offset, 4)
        naluLen = CFSwapInt32BigToHost(naluLen)
        offset += 4
        guard offset + Int(naluLen) <= totalLen else { break }
        annexB += [0x00, 0x00, 0x00, 0x01]
        annexB += Data(bytes: base + offset, count: Int(naluLen))
        offset += Int(naluLen)
    }

    encoder.onEncodedFrame?(annexB, isKeyframe)
}
