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
    // TEMP DIAGNOSTIC — RTP fps has been observed collapsing to single
    // digits while synthetic input is active and recovering ~60-90s after
    // it stops, with our own backpressure/decode-overload counters staying
    // at zero throughout (they're wired to the WS/DataChannel fallback path
    // only, dead on RTP). qualityLimitationReason is libwebrtc's own answer
    // to "why isn't the encoder running faster" (cpu/bandwidth/other/none)
    // — polling it alongside GCC's target bitrate and the link's measured
    // RTT settles whether this is GCC misreading local scheduling jitter as
    // congestion, or the encoder itself being CPU-starved by the same
    // contention. Remove once the cause is confirmed.
    private var statsTimer: DispatchSourceTimer?
    // RTT-gated minimum-bitrate floor (see setMinBitrate) — only trusted on
    // a link that looks like a real same-switch LAN, never a blanket floor.
    // WireGuard-tunneled access (company laptop → gateway → this LAN) is a
    // real bottleneck (gateway uplink/CPU for encryption), not a LAN, and
    // must NOT get the floor even though its RTT can also be quite low —
    // the asymmetry below (slow to commit, instant to revoke) is the
    // actual safety net for that case: if the floor turns out to be more
    // than that path can sustain, the resulting real queueing delay pushes
    // RTT past wanRttThresholdMs on the very next poll and the floor comes
    // back off automatically, no manual LAN/VPN detection required.
    // Raised from 1.5Mbps after confirming via gcc_stats that GCC's own
    // target was bouncing around 3-5Mbps on a proven ~1ms-RTT LAN — nowhere
    // near the 15Mbps ceiling, so the ceiling wasn't the constraint anymore,
    // GCC's own conservative bandwidth probing was. 5Mbps visibly blurs text
    // (high-frequency detail is the first thing H.264 sacrifices under a
    // tight bitrate budget). This floor only ever activates after the
    // RTT-streak gate above proves it's a real same-switch LAN, so pushing
    // it this high is safe — the same "instant to revoke" asymmetry still
    // applies if it turns out the link can't actually sustain it.
    private static let lanFloorBps: Int = 12_000_000
    // Raised from 3.0/8.0 after a confirmed same-switch wired LAN (user
    // verified both machines wired, same network, repeatedly) showed a
    // live session sitting at a *steady* 8.0ms RTT for its whole duration —
    // exactly at the old wanRttThresholdMs, so the floor never armed at all
    // for that session despite it being real LAN traffic. 1-8ms is real,
    // observed LAN variance here, not a sign of a WAN/VPN hop.
    private static let lanRttThresholdMs = 10.0
    private static let wanRttThresholdMs = 20.0
    // 4 consecutive polls at the new 0.5s poll interval (see
    // startStatsPolling) = ~2s to re-arm, down from ~6s at the old 2s×3
    // pacing — confirmed via a live gcc_stats trace that a single brief RTT
    // blip (a real one, not misdetection) revokes the floor instantly (by
    // design), but then took ~6s just waiting on this streak before even
    // starting to recover, on top of however long GCC's own crashed
    // estimate takes to ramp back up afterward — measured total stall was
    // ~12s for one transient spike. Keeping 4 samples (not fewer) instead
    // of just shortening the interval preserves the same confirmation
    // count, just gathered faster.
    private static let lanRttStreakRequired = 4
    private var lowRttStreak = 0
    private var minBitrateFloorActive = false

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

    /// Floor GCC's own bandwidth estimate — see the gcc_stats diagnostic
    /// this pairs with: on a real same-switch LAN link (RTT ~0-1ms) GCC's
    /// delay-based congestion detector has been observed misreading tiny
    /// scheduling jitter as severe congestion and crashing its estimate to
    /// ~100Kbps, then taking 20-90s to climb back — a link that can
    /// trivially sustain many Mbps gets rate-limited to single-digit fps in
    /// the meantime. nil clears the floor (back to GCC's own judgment).
    func setMinBitrate(_ bps: Int?) {
        guard let sender = videoSender else { return }
        let params = sender.parameters
        for enc in params.encodings { enc.minBitrateBps = bps.map { NSNumber(value: $0) } }
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
        statsTimer?.cancel()
        statsTimer = nil
        lowRttStreak = 0
        minBitrateFloorActive = false
        pc?.close()
        pc = nil
        videoChannel = nil
        controlChannel = nil
        videoSource = nil
        videoCapturer = nil
        videoSender = nil
        iceConnected = false
    }

    // MARK: - TEMP DIAGNOSTIC — GCC stats polling

    private func startStatsPolling() {
        statsTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        // 0.5s, not 2s — see lanRttStreakRequired's comment for why: this is
        // what actually determines how fast the floor can re-arm after a
        // transient RTT blip clears.
        t.schedule(deadline: .now() + 0.5, repeating: 0.5)
        t.setEventHandler { [weak self] in self?.logGCCStats() }
        t.resume()
        statsTimer = t
    }

    private func logGCCStats() {
        pc?.statistics { [weak self] report in
            guard let self else { return }
            var outboundDetail = "n/a"
            var pairDetail = "n/a"
            var rttMs: Double?
            for stat in report.statistics.values {
                if stat.type == "outbound-rtp", (stat.values["kind"] as? String) == "video" {
                    let reason  = stat.values["qualityLimitationReason"] as? String ?? "?"
                    let fps     = stat.values["framesPerSecond"] as? Double ?? -1
                    let target  = (stat.values["targetBitrate"] as? Double).map { Int($0) }
                    let encoded = stat.values["framesEncoded"] as? Double ?? -1
                    outboundDetail = "qlr=\(reason) fps=\(fps) target=\(target.map(String.init) ?? "?") encoded=\(Int(encoded))"
                }
                if stat.type == "candidate-pair",
                   (stat.values["state"] as? String) == "succeeded",
                   (stat.values["nominated"] as? Bool) == true {
                    let rtt   = stat.values["currentRoundTripTime"] as? Double ?? -1
                    let avail = (stat.values["availableOutgoingBitrate"] as? Double).map { Int($0) }
                    rttMs = rtt * 1000
                    pairDetail = "rttMs=\(String(format: "%.1f", rttMs ?? -1)) availBps=\(avail.map(String.init) ?? "?")"
                }
            }
            ConnectionLogger.shared.logStep(sessionId: "webrtc", step: "gcc_stats",
                detail: "\(outboundDetail) | \(pairDetail) floor=\(self.minBitrateFloorActive ? "on" : "off")")
            self.evaluateMinBitrateFloor(rttMs: rttMs)
        }
    }

    /// Slow to commit (needs several consecutive low-RTT polls before
    /// trusting the link is a real LAN), instant to revoke (any one poll
    /// at/above wanRttThresholdMs drops it immediately) — see the property
    /// comment on minBitrateFloorActive for why that asymmetry is what
    /// makes this safe on a WireGuard-tunneled path too, without needing to
    /// actually distinguish "LAN" from "tunnel" up front.
    private func evaluateMinBitrateFloor(rttMs: Double?) {
        guard let rttMs, rttMs >= 0 else { return }
        if rttMs >= Self.wanRttThresholdMs {
            lowRttStreak = 0
            if minBitrateFloorActive {
                minBitrateFloorActive = false
                setMinBitrate(nil)
                ConnectionLogger.shared.logStep(sessionId: "webrtc", step: "min_bitrate_floor",
                    detail: "off rttMs=\(String(format: "%.1f", rttMs))")
            }
        } else if rttMs <= Self.lanRttThresholdMs {
            lowRttStreak += 1
            if lowRttStreak >= Self.lanRttStreakRequired, !minBitrateFloorActive {
                minBitrateFloorActive = true
                setMinBitrate(Self.lanFloorBps)
                ConnectionLogger.shared.logStep(sessionId: "webrtc", step: "min_bitrate_floor",
                    detail: "on rttMs=\(String(format: "%.1f", rttMs))")
            }
        }
        // Between the two thresholds: ambiguous, leave current state as-is.
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
            startStatsPolling()
        case .failed, .disconnected, .closed:
            ConnectionLogger.shared.logStep(sessionId: "webrtc", step: "ice_disconnected", detail: "\(state)")
            iceConnected = false
            statsTimer?.cancel()
            statsTimer = nil
            lowRttStreak = 0
            minBitrateFloorActive = false
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
