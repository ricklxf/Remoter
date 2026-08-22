import Foundation
import WebRTC
import CoreVideo

// Mac 端作为 WebRTC Answerer（客户端发 Offer）。
// 视频走真正的 RTP 媒体轨道：CVPixelBuffer 直接喂给 RTCVideoSource，
// libwebrtc 内部完成硬件编码、拥塞控制（GCC 主动带宽估计）、pacing、
// NACK/PLI 重传与关键帧请求、接收端抖动缓冲——这些此前全是在
// DataChannel 上手写的近似实现（分片重组/背压丢帧/关键帧风暴治理），
// 现在由协议栈原生接管。DataChannel 保留两个用途：control（输入事件）
// 和旧版客户端的 video 通道兜底。
final class WebRTCAgent: NSObject, @unchecked Sendable {

    // 信令回调（通过已有的 WebSocket 发出）
    var onLocalDescription: ((String, String) -> Void)?  // (type, sdp)
    var onICECandidate: ((String) -> Void)?              // JSON
    var onConnected: (() -> Void)?
    var onDisconnected: (() -> Void)?
    var onControlMessage: ((String) -> Void)?            // DataChannel 上的控制消息

    var isVideoChannelOpen: Bool { videoChannel?.readyState == .open }
    /// RTP 视频轨道可用：ICE 已连通且答复里协商出了 sendonly 视频 m-line。
    var isMediaReady: Bool { iceConnected && videoSender != nil }

    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory()
        )
    }()

    private var pc: RTCPeerConnection?
    private var videoChannel: RTCDataChannel?
    private var controlChannel: RTCDataChannel?
    private var videoSource: RTCVideoSource?
    private var videoCapturer: RTCVideoCapturer?
    private var videoSender: RTCRtpSender?
    private(set) var iceConnected = false

    // MARK: - 信令处理

    func handleOffer(_ sdp: String, turnServers: [RTCIceServer] = []) {
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually

        var servers = [
            RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"]),
            RTCIceServer(urlStrings: ["stun:stun1.l.google.com:19302"])
        ]
        servers.append(contentsOf: turnServers)
        config.iceServers = servers

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let p = WebRTCAgent.factory.peerConnection(with: config, constraints: constraints, delegate: self) else {
            print("[WebRTC] failed to create peer connection"); return
        }
        self.pc = p

        p.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: sdp)) { [weak self] error in
            if let e = error { print("[WebRTC] setRemoteDescription error: \(e)"); return }
            guard let self else { return }
            // Attach the video track after the remote offer is in place so
            // it pairs with the client's recvonly video transceiver (an
            // older client whose offer has no video m-line just ends up with
            // an unpaired transceiver — harmless, DataChannel path kicks in).
            self.setupVideoTrack(pc: p)
            self.createAnswer(pc: p)
        }
    }

    /// screencast-mode source: tells libwebrtc's encoder/adaptation this is
    /// desktop content (favor text legibility over smoothness when starved).
    private func setupVideoTrack(pc: RTCPeerConnection) {
        let source = WebRTCAgent.factory.videoSource(forScreenCast: true)
        let track  = WebRTCAgent.factory.videoTrack(with: source, trackId: "remoter-video")
        let sender = pc.add(track, streamIds: ["remoter"])
        videoSource = source
        videoCapturer = RTCVideoCapturer(delegate: source)
        videoSender = sender
        if sender == nil {
            ConnectionLogger.shared.logStep(sessionId: "webrtc", step: "video_track_add_failed")
        }
    }

    /// Feed one captured frame into the RTP pipeline. libwebrtc owns
    /// everything downstream (encode, pacing, congestion control) — this can
    /// be called at capture rate regardless of network conditions; the stack
    /// drops/adapts internally as needed.
    func sendVideoBuffer(_ pb: CVPixelBuffer) {
        guard let source = videoSource, let capturer = videoCapturer else { return }
        let buf = RTCCVPixelBuffer(pixelBuffer: pb)
        let ts  = Int64(CACurrentMediaTime() * 1_000_000_000)
        let frame = RTCVideoFrame(buffer: buf, rotation: ._0, timeStampNs: ts)
        source.capturer(capturer, didCapture: frame)
    }

    /// Cap the RTP encoder's bitrate (manual quality picks). GCC still
    /// adapts *below* the cap on congestion; this only sets the ceiling.
    func setMaxBitrate(_ bps: Int) {
        guard let sender = videoSender else { return }
        let params = sender.parameters
        for enc in params.encodings { enc.maxBitrateBps = NSNumber(value: bps) }
        sender.parameters = params
    }

    func handleRemoteICE(_ json: String) {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidateStr = dict["candidate"] as? String else { return }
        let sdpMid        = dict["sdpMid"] as? String
        let sdpMLineIndex = dict["sdpMLineIndex"] as? Int32 ?? 0
        pc?.add(RTCIceCandidate(sdp: candidateStr, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid))
    }

    // MARK: - 视频发送（分片 60KB，适配所有 SCTP 实现）

    /// Returns false if the frame was dropped (fully or partially) due to
    /// send-buffer backpressure — the caller must force the *next* frame to
    /// be a keyframe when this happens. Our H.264 has no B-frames, so every
    /// delta frame is decoded against the one before it; silently dropping a
    /// frame the client never sees breaks that reference chain and the
    /// decoder keeps producing corrupted/garbled output until the next
    /// keyframe arrives (up to 2s later on its own schedule) — invisible on
    /// a fast LAN where the buffer never backs up, but a real bandwidth-
    /// constrained link (VPN/WAN) hits this path often enough to matter.
    @discardableResult
    func sendVideoFrame(_ data: Data, isKeyframe: Bool, frameId: UInt32) -> Bool {
        guard let ch = videoChannel, ch.readyState == .open else { return false }

        // Threshold = ~4 frames worth of data at 350 KB/frame.
        if ch.bufferedAmount > 1_400_000 { return false }

        let CHUNK = 60 * 1024
        let flags: UInt8 = isKeyframe ? 0x01 : 0x00
        let totalChunks = UInt16((data.count + CHUNK - 1) / CHUNK)

        for i in 0..<Int(totalChunks) {
            // Re-check on every chunk, not just once before the loop — a
            // multi-chunk frame can fill the buffer mid-flight on a
            // bandwidth-constrained link (VPN/WAN), and dumping the rest of
            // it anyway turns one slow frame into a burst that delays
            // everything after it. Better to cut this frame short.
            if i > 0 && ch.bufferedAmount > 1_400_000 { return false }

            let start = i * CHUNK
            let end   = min(start + CHUNK, data.count)
            let payload = data[start..<end]

            var pkt = Data(capacity: 9 + payload.count)
            pkt.append(flags)
            var fid = frameId.bigEndian;       pkt.append(Data(bytes: &fid, count: 4))
            var ci  = UInt16(i).bigEndian;     pkt.append(Data(bytes: &ci,  count: 2))
            var tc  = totalChunks.bigEndian;   pkt.append(Data(bytes: &tc,  count: 2))
            pkt.append(Data(payload))

            ch.sendData(RTCDataBuffer(data: pkt, isBinary: true))
        }
        return true
    }

    func close() {
        pc?.close()
        pc = nil
        videoChannel = nil
        controlChannel = nil
        videoSource = nil
        videoCapturer = nil
        videoSender = nil
        iceConnected = false
    }

    // MARK: - Private

    private func createAnswer(pc: RTCPeerConnection) {
        let c = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        pc.answer(for: c) { [weak self] sdp, error in
            guard let sdp, error == nil else {
                print("[WebRTC] createAnswer error: \(String(describing: error))")
                return
            }
            pc.setLocalDescription(sdp) { _ in }
            self?.onLocalDescription?("answer", sdp.sdp)
        }
    }
}

// MARK: - RTCPeerConnectionDelegate

extension WebRTCAgent: RTCPeerConnectionDelegate {
    func peerConnection(_ pc: RTCPeerConnection, didChange _: RTCSignalingState) {}
    func peerConnection(_ pc: RTCPeerConnection, didAdd _: RTCMediaStream) {}
    func peerConnection(_ pc: RTCPeerConnection, didRemove _: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ pc: RTCPeerConnection) {}

    func peerConnection(_ pc: RTCPeerConnection, didChange state: RTCIceConnectionState) {
        switch state {
        case .connected, .completed:
            ConnectionLogger.shared.logStep(sessionId: "webrtc", step: "ice_connected")
            iceConnected = true
            onConnected?()
            logSelectedCandidatePair(pc)
        case .failed, .disconnected, .closed:
            ConnectionLogger.shared.logStep(sessionId: "webrtc", step: "ice_disconnected", detail: "\(state)")
            iceConnected = false
            onDisconnected?()
        default: break
        }
    }

    // Same-LAN peers going through a TURN relay instead of a direct P2P
    // (host/srflx) candidate pair adds a real extra hop's worth of latency
    // and jitter — enough for libwebrtc's own GCC bandwidth estimator to
    // misjudge available bandwidth and throttle the send rate, which shows
    // up as low fps in sent_5s with nothing else pointing to why. Previously
    // had zero visibility into which kind of pair actually got selected
    // (the old P2P/relay distinction was only ever printed, never logged to
    // connections.log — see feedback_build_mac memory's note on print()
    // being unobservable for this process). Query once right after ICE
    // connects.
    private func logSelectedCandidatePair(_ pc: RTCPeerConnection) {
        pc.statistics { report in
            for stat in report.statistics.values where stat.type == "candidate-pair" {
                guard (stat.values["state"] as? String) == "succeeded",
                      (stat.values["nominated"] as? Bool) == true else { continue }
                let localId  = stat.values["localCandidateId"]  as? String
                let remoteId = stat.values["remoteCandidateId"] as? String
                let localType  = localId.flatMap  { report.statistics[$0]?.values["candidateType"] as? String } ?? "?"
                let remoteType = remoteId.flatMap { report.statistics[$0]?.values["candidateType"] as? String } ?? "?"
                ConnectionLogger.shared.logStep(sessionId: "webrtc", step: "candidate_pair",
                    detail: "local=\(localType) remote=\(remoteType)")
            }
        }
    }

    func peerConnection(_ pc: RTCPeerConnection, didChange _: RTCIceGatheringState) {}

    func peerConnection(_ pc: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        let dict: [String: Any] = [
            "candidate":     candidate.sdp,
            "sdpMid":        candidate.sdpMid ?? "",
            "sdpMLineIndex": candidate.sdpMLineIndex
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let json = String(data: data, encoding: .utf8) else { return }
        onICECandidate?(json)
    }

    func peerConnection(_ pc: RTCPeerConnection, didRemove _: [RTCIceCandidate]) {}

    // DataChannel 由 Windows（Offerer）创建，Mac（Answerer）在此接收
    func peerConnection(_ pc: RTCPeerConnection, didOpen channel: RTCDataChannel) {
        switch channel.label {
        case "video":
            videoChannel = channel
            channel.delegate = self
            print("[WebRTC] Video DataChannel open")
        case "control":
            controlChannel = channel
            channel.delegate = self
            print("[WebRTC] Control DataChannel open")
        default:
            break
        }
    }
}

// MARK: - RTCDataChannelDelegate

extension WebRTCAgent: RTCDataChannelDelegate {
    func dataChannelDidChangeState(_ channel: RTCDataChannel) {}

    func dataChannel(_ channel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        // 控制消息从 DataChannel 收到，路由给 Session 处理（与 WebSocket 路径相同）
        if channel.label == "control",
           let text = String(data: buffer.data, encoding: .utf8) {
            onControlMessage?(text)
        }
    }
}
