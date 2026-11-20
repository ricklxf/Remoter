import Foundation
import AVFoundation
import CoreMedia

// System-audio PCM (from SCStream) → AAC-LC packets framed with ADTS
// headers. ADTS (rather than raw AAC + out-of-band AudioSpecificConfig)
// keeps the wire format self-describing: WebCodecs' AudioDecoder accepts
// 'mp4a.40.2' with no description and parses ADTS directly, so the client
// needs zero setup handshake and can join/leave the stream at any packet.
final class AudioEncoder {
    var onEncodedFrame: ((Data) -> Void)?

    private let queue = DispatchQueue(label: "remoter.audio.encode", qos: .userInitiated)
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?
    // AVAudioConverter pulls input on demand; SCStream pushes buffers at its
    // own cadence (not aligned to AAC's 1024-sample frames) — this FIFO
    // bridges the two. Only touched on `queue`.
    private var pending: [AVAudioPCMBuffer] = []

    func encode(_ sample: CMSampleBuffer) {
        queue.async { [weak self] in self?.encodeSync(sample) }
    }

    private func encodeSync(_ sample: CMSampleBuffer) {
        guard let fd = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd) else { return }

        if converter == nil {
            guard let inFmt = AVAudioFormat(streamDescription: asbd) else { return }
            var outDesc = AudioStreamBasicDescription(
                mSampleRate: asbd.pointee.mSampleRate,
                mFormatID: kAudioFormatMPEG4AAC,
                mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 1024,
                mBytesPerFrame: 0, mChannelsPerFrame: min(asbd.pointee.mChannelsPerFrame, 2),
                mBitsPerChannel: 0, mReserved: 0)
            guard let outFmt = AVAudioFormat(streamDescription: &outDesc),
                  let conv = AVAudioConverter(from: inFmt, to: outFmt) else {
                ConnectionLogger.shared.logStep(sessionId: "audio", step: "encoder_init_failed")
                return
            }
            conv.bitRate = 128_000
            inputFormat = inFmt
            outputFormat = outFmt
            converter = conv
            ConnectionLogger.shared.logStep(sessionId: "audio", step: "encoder_ready",
                detail: "aac \(Int(asbd.pointee.mSampleRate))Hz \(outDesc.mChannelsPerFrame)ch 128kbps")
        }
        guard let converter, let inputFormat, let outputFormat else { return }

        // CMSampleBuffer → AVAudioPCMBuffer
        let frames = CMSampleBufferGetNumSamples(sample)
        guard frames > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(frames)) else { return }
        pcm.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sample, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList)
        guard status == noErr else { return }
        pending.append(pcm)

        // Drain: pull as many complete AAC packets as the buffered PCM yields.
        while true {
            guard let out = AVAudioCompressedBuffer(format: outputFormat, packetCapacity: 1,
                    maximumPacketSize: converter.maximumOutputPacketSize) as AVAudioCompressedBuffer? else { return }
            var error: NSError?
            let result = converter.convert(to: out, error: &error) { [weak self] _, outStatus in
                guard let self, !self.pending.isEmpty else {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                outStatus.pointee = .haveData
                return self.pending.removeFirst()
            }
            if result == .error {
                ConnectionLogger.shared.logStep(sessionId: "audio", step: "encode_err",
                    detail: error.map { "\($0)" } ?? "unknown")
                return
            }
            guard result == .haveData, out.packetCount > 0 else { return } // ran dry — wait for more PCM

            let aacLen = Int(out.packetDescriptions?.pointee.mDataByteSize ?? out.byteLength)
            guard aacLen > 0 else { return }
            var packet = adtsHeader(aacLength: aacLen,
                                    sampleRate: Int(outputFormat.sampleRate),
                                    channels: Int(outputFormat.channelCount))
            packet.append(Data(bytes: out.data, count: aacLen))
            onEncodedFrame?(packet)
        }
    }

    // 7-byte ADTS header (MPEG-4 AAC-LC, no CRC)
    private func adtsHeader(aacLength: Int, sampleRate: Int, channels: Int) -> Data {
        let srIdx: Int = switch sampleRate {
        case 96000: 0; case 88200: 1; case 64000: 2; case 48000: 3
        case 44100: 4; case 32000: 5; case 24000: 6; case 22050: 7
        case 16000: 8; default: 3
        }
        let profile = 2       // AAC-LC
        let len = aacLength + 7
        var h = Data(count: 7)
        h[0] = 0xFF
        h[1] = 0xF1
        h[2] = UInt8(((profile - 1) << 6) | (srIdx << 2) | ((channels >> 2) & 0x1))
        h[3] = UInt8(((channels & 0x3) << 6) | ((len >> 11) & 0x3))
        h[4] = UInt8((len >> 3) & 0xFF)
        h[5] = UInt8(((len & 0x7) << 5) | 0x1F)
        h[6] = 0xFC
        return h
    }
}
