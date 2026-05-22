import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

enum VideoCodec: String {
    case h264 = "h264"
    case h265 = "h265"
}

final class VideoEncoder {
    var onEncodedFrame: ((Data, Bool) -> Void)?

    private(set) var currentCodec: VideoCodec = .h264
    private var session: VTCompressionSession?
    private var frameCount = 0

    // MARK: - Setup

    func setup(width: Int, height: Int, fps: Int, bitrate: Int, codec: VideoCodec = .h264) throws {
        self.currentCodec = codec
        let codecType: CMVideoCodecType = codec == .h265
            ? kCMVideoCodecType_HEVC
            : kCMVideoCodecType_H264

        var s: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width:  Int32(width),
            height: Int32(height),
            codecType: codecType,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: encodedFrameCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &s
        )
        guard status == noErr, let session = s else { throw RemoterError.encoderSetupFailed }

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime,             value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)

        if codec == .h265 {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                                 value: kVTProfileLevel_HEVC_Main_AutoLevel)
        } else {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                                 value: kVTProfileLevel_H264_High_AutoLevel)
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_H264EntropyMode,
                                 value: kVTH264EntropyMode_CABAC)
        }

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,    value: bitrate as CFTypeRef)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: (fps * 2) as CFTypeRef)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate,  value: fps as CFTypeRef)
        let limits: [CFNumber] = [bitrate as CFNumber, 1 as CFNumber]
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limits as CFArray)

        VTCompressionSessionPrepareToEncodeFrames(session)
        self.session = session
        frameCount   = 0
    }

    // MARK: - Encode

    func encode(sampleBuffer: CMSampleBuffer) {
        guard let session,
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let dur = CMSampleBufferGetDuration(sampleBuffer)

        var props: CFDictionary?
        frameCount += 1
        if frameCount % 300 == 1 {
            props = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
        }
        VTCompressionSessionEncodeFrame(session, imageBuffer: imageBuffer,
                                        presentationTimeStamp: pts, duration: dur,
                                        frameProperties: props, sourceFrameRefcon: nil, infoFlagsOut: nil)
    }

    func forceKeyframe() { frameCount = 0 }

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

    // MARK: - Static helpers

    /// 检查硬件是否支持 HEVC 编码
    static func isHEVCSupported() -> Bool {
        var dict: CFDictionary?
        return VTCopySupportedPropertyDictionaryForEncoder(
            width: 1920, height: 1080,
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: nil,
            encoderIDOut: nil,
            supportedPropertiesOut: &dict
        ) == noErr
    }
}

// MARK: - Output callback (free function)

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

    // 关键帧前插入参数集（H.264: SPS/PPS；H.265: VPS/SPS/PPS）
    if isKeyframe, let fmt = CMSampleBufferGetFormatDescription(sampleBuffer) {
        var count = 0
        let codec  = encoder.currentCodec

        if codec == .h265 {
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                fmt, parameterSetIndex: 0,
                parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil
            )
            for i in 0..<count {
                var ptr: UnsafePointer<UInt8>?; var sz = 0
                let r = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    fmt, parameterSetIndex: i,
                    parameterSetPointerOut: &ptr, parameterSetSizeOut: &sz,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
                )
                if r == noErr, let p = ptr {
                    annexB += [0x00, 0x00, 0x00, 0x01]
                    annexB += Data(bytes: p, count: sz)
                }
            }
        } else {
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                fmt, parameterSetIndex: 0,
                parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil
            )
            for i in 0..<count {
                var ptr: UnsafePointer<UInt8>?; var sz = 0
                let r = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    fmt, parameterSetIndex: i,
                    parameterSetPointerOut: &ptr, parameterSetSizeOut: &sz,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
                )
                if r == noErr, let p = ptr {
                    annexB += [0x00, 0x00, 0x00, 0x01]
                    annexB += Data(bytes: p, count: sz)
                }
            }
        }
    }

    // AVCC → Annex B（H.264 / H.265 格式相同：4B 长度前缀 → 起始码）
    let totalLen = CMBlockBufferGetDataLength(dataBuffer)
    var raw: UnsafeMutablePointer<CChar>?
    CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                totalLengthOut: nil, dataPointerOut: &raw)
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
