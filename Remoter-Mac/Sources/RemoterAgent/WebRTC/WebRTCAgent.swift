import Foundation
import WebRTC

// Mac 端作为 WebRTC Answerer（Windows 客户端发 Offer）
// 视频通过 DataChannel 发送（UDP，不重传），控制消息继续走 WebSocket
final class WebRTCAgent: NSObject, @unchecked Sendable {

    // 信令回调（通过已有的 WebSocket 发出）
    var onLocalDescription: ((String, String) -> Void)?  // (type, sdp)
    var onICECandidate: ((String) -> Void)?              // JSON
    var onConnected: (() -> Void)?
    var onDisconnected: (() -> Void)?
    var onControlMessage: ((String) -> Void)?            // DataChannel 上的控制消息

    var isVideoChannelOpen: Bool { videoChannel?.readyState == .open }

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
            self?.createAnswer(pc: p)
        }
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
            print("[WebRTC] P2P connected ✓")
            onConnected?()
        case .failed, .disconnected, .closed:
            print("[WebRTC] P2P disconnected")
            onDisconnected?()
        default: break
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
