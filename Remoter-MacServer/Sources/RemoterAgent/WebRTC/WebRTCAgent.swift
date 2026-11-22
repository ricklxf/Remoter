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
    /// Preferred RTP video codec for SDP answer ordering (default `"h264"`, preferring H.264 High Profile).
    var preferredCodec: String = "h264"

    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(
            encoderFactory: LowLatencyVideoEncoderFactory(),
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
    // Unconditional floor, independent of the RTT gate above. connections.log
    // (08-31, 13 sessions) showed 128 GCC estimate crashes, every one with
    // the LAN floor off (same-subnet Wi-Fi sits at 20-80ms RTT, so it never
    // arms): target fell from ~5Mbps to 35-90Kbps while capture kept
    // delivering 57fps, the encoder emitted 1-3fps, and the climb back took
    // up to 125s. Same trace: at target >= 0.6Mbps the encoder still holds a
    // median 52-57fps, below 300Kbps it stalls. 1Mbps keeps a crash above
    // that cliff, and sits under the lowest quality tier (2Mbps) so it
    // never fights a manual cap. A path that can't carry 1Mbps can't carry
    // a 1080p desktop either.
    private static let baseFloorBps: Int = 1_000_000
    // UU-style severe congestion relief floor (UU 1080p lowest tier 40% = 400kbps):
    // when RTT spikes (e.g. >250ms) or loss >= 8%, temporarily release the 1Mbps floor
    // down to 350kbps AND cap RTP fps to 24fps so GCC can drain the congested queue
    // instead of pumping 57fps into a 1.5s tunnel and triggering a 7.5s PLI freeze storm.
    private static let congestionFloorBps: Int = 350_000
    private static let congestionMaxFps: Int = 24
    private static let congestionImmediateRttMs: Double = 250.0
    private static let congestionSustainedRttMs: Double = 150.0
    private static let congestionSustainedLoss: Double = 0.05
    private static let congestionEnterStreakRequired: Int = 2   // 1.0s at 0.5s poll (fast enter)
    private static let congestionClearRttMs: Double = 60.0
    private static let congestionClearLoss: Double = 0.02
    private static let congestionClearStreakRequired: Int = 6   // 3.0s at 0.5s poll (slow exit)
    private var congestionGuardActive = false
    private var congestionEnterStreak = 0
    private var congestionClearStreak = 0
    // Raised from 3.0/8.0 after a confirmed same-switch wired LAN (user
    // verified both machines wired, same network, repeatedly) showed a
    // live session sitting at a *steady* 8.0ms RTT for its whole duration —
    // exactly at the old wanRttThresholdMs, so the floor never armed at all
    // for that session despite it being real LAN traffic. 1-8ms is real,
    // observed LAN variance here, not a sign of a WAN/VPN hop.
    // Re-tuned 10-10 from a WireGuard session's own numbers (company laptop
    // → gateway → this LAN), which the 10/20ms pair handled badly both ways:
    //  - idle RTT there is 8-15ms; at 15 the floor never armed, GCC sat at
    //    ~5Mbps and the encoder dropped a scroll to ~18fps (capture: 47fps),
    //  - when it did arm, the same path carried 12Mbps at a flat 12ms RTT
    //    for two minutes — then one 49ms sample with zero packet loss
    //    revoked it, GCC restarted from 1.4Mbps, and the next scroll was mush.
    // So: arm up to 20ms, and revoke on evidence the path is actually
    // overloaded — receiver-reported loss, one very high RTT sample, or two
    // *new* samples in a row above wanRttThresholdMs — not on a single blip.
    private static let wiredLanRttThresholdMs = 3.5
    private static let lanRttThresholdMs = 18.0
    private static let wanRttThresholdMs = 40.0
    private static let hardRttThresholdMs = 150.0
    private static let lossRevokeFraction = 0.06
    // After a revoke, don't re-arm for a while: the same session later showed
    // this path at ~1.5Mbps with real loss and ~1s receiver jitter, where
    // idle RTT still reads 8-15ms — without a hold-off the floor would re-arm
    // every 2s and flood a link that just proved it can't take it.
    private static let rearmCooldownSec = 30.0
    private var floorRevokedAt: CFAbsoluteTime = 0
    private var highRttStreak = 0
    private var lastRttSampleCount = -1.0
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
    /// false = the client told us it isn't on this LAN (see Session's
    /// clientNotOnLan): never arm the LAN floor, and drop it if armed.
    var lanFloorAllowed = true {
        didSet {
            applyMaxBitrate()
            if minBitrateFloorActive { setMinBitrate(floorBps) }
        }
    }
    // Not-on-LAN (tunnel) band. With no floor at all, GCC idled at 2.7-5.9Mbps
    // on the WireGuard path: a scroll's full-screen frames then take hundreds
    // of ms each to drain through the pacer — encoder output fell to 6-22fps,
    // the receiver's jitter buffer reached 1.3s (zero packet loss), i.e. both
    // the blur and the "inertia". The same path has carried 12-25Mbps cleanly
    // and 12Mbps with loss, so hold it in a 6-10Mbps band instead: enough for
    // a 30fps scroll, and no climbing to 25-30Mbps until it breaks. Loss
    // still revokes the floor and lowers the cap (evaluateLossCap).
    private static let wifiFloorBps: Int = 6_000_000
    private static let wifiElevatedFloorBps: Int = 9_000_000
    private static let wifiElevationRttThresholdMs = 15.0
    private static let wifiElevationStreakRequired = 10  // 5s of clean link at 0.5s poll
    private static let wifiDemoteRttThresholdMs = 25.0
    private static let wifiDemoteLossFraction = 0.02
    private static let tunnelFloorBps: Int = 6_000_000
    private static let tunnelCapBps: Int = 10_000_000
    /// Set by Session: true when the client is off-LAN AND bitrate is on auto.
    /// The auto ladder asks for its top tier (25M) as soon as RTP is up, which
    /// is exactly the overshoot a tunnel can't carry — so in that case the
    /// ceiling is held at tunnelCapBps. A manual bitrate pick is the user's
    /// explicit choice and is not capped.
    var tunnelCapActive = false {
        didSet { if oldValue != tunnelCapActive { applyMaxBitrate() } }
    }
    /// Detected from the nominated ICE candidate pair (`local=host`, `remote!=relay`) with either
    /// a private RFC1918 remote IP or sustained sub-15ms zero-loss direct P2P RTT:
    /// Web browsers hide their local IP from JS via mDNS (and libwebrtc omits IP on `prflx`),
    /// so `lanFloorAllowed` can be false even on the same physical LAN.
    private var isDirectP2P = false
    private var isDirectPrivateLan = false
    /// The client's own `net_hint lan=false` (it compared its interface subnets
    /// with our address) beats anything inferred here: a WireGuard/VPN path is
    /// direct P2P with private IPs, ~5ms RTT and often 0% loss, so it passes
    /// every `isDirectPrivateLan` test while still being a tunnel.
    var offLanHinted = false {
        didSet { if oldValue != offLanHinted { applyMaxBitrate() } }
    }
    private var directLanTrusted: Bool { isDirectPrivateLan && !offLanHinted }
    private var effectiveLanAllowed: Bool { lanFloorAllowed || directLanTrusted }
    /// Only arm the 12 Mbps wired LAN floor when RTT <= 3.5ms (true wired Ethernet);
    /// for Wi-Fi / P2P (3.5 < RTT <= 18ms), start at the safe 6 Mbps `wifiFloorBps` and
    /// elevate to 9 Mbps (`wifiElevatedFloorBps`) after 5s of 0% loss + RTT <= 15ms.
    private var lastObservedRttMs: Double = 999.0
    private var wifiCleanStreak = 0
    private var wifiFloorElevated = false
    private var floorBps: Int {
        if effectiveLanAllowed && lastObservedRttMs <= Self.wiredLanRttThresholdMs {
            return Self.lanFloorBps
        }
        if effectiveLanAllowed {
            return wifiFloorElevated ? Self.wifiElevatedFloorBps : Self.wifiFloorBps
        }
        return Self.tunnelFloorBps
    }
    private var activeFloorBps: Int = 0
    private var minBitrateFloorActive = false

    private static let playoutDelayExtURI = "http://www.webrtc.org/experiments/rtp-hdrext/playout-delay"
    private var offerPlayoutDelayExtId: Int?

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

        // Inspect Offer for RFC5285 playout-delay RTP header extension so Answer preserves it.
        let playoutExtId = Self.extractPlayoutDelayExtId(from: sdp)
        offerPlayoutDelayExtId = playoutExtId
        ConnectionLogger.shared.logStep(
            sessionId: "webrtc",
            step: "playout_delay_extmap",
            detail: playoutExtId.map { "offer id=\($0)" } ?? "offer absent"
        )

        // libwebrtc selects the *sender* encode codec from the remote Offer's m=video
        // payload order, not just the local Answer. Reorder the incoming Offer so even
        // older/unpatched clients immediately negotiate hardware H.264.
        let reorderedOffer = preferCodecInSDP(sdp, preferred: preferredCodec, logStep: "offer_codec_order")
        let proceedAfterOffer: () -> Void = { [weak self] in
            guard let self else { return }
            // Attach the video track after the remote offer is in place so
            // it pairs with the client's recvonly video transceiver (an
            // older client whose offer has no video m-line just ends up with
            // an unpaired transceiver — harmless, DataChannel path kicks in).
            self.setupVideoTrack(pc: p)
            self.createAnswer(pc: p)
        }
        p.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: reorderedOffer)) { error in
            if let e = error {
                ConnectionLogger.shared.logStep(
                    sessionId: "webrtc",
                    step: "set_remote_desc_fallback",
                    detail: "err=\(e.localizedDescription)"
                )
                p.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: sdp)) { fallbackErr in
                    if let fe = fallbackErr { print("[WebRTC] setRemoteDescription error: \(fe)"); return }
                    proceedAfterOffer()
                }
                return
            }
            proceedAfterOffer()
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

    private var lastFrameTimestampNs: Int64 = 0

    /// Feed one captured frame into the RTP pipeline. libwebrtc owns
    /// everything downstream (encode, pacing, congestion control) — this can
    /// be called at capture rate regardless of network conditions; the stack
    /// drops/adapts internally as needed.
    func sendVideoBuffer(_ pb: CVPixelBuffer) {
        guard let source = videoSource, let capturer = videoCapturer else { return }
        let buf = RTCCVPixelBuffer(pixelBuffer: pb)
        let nowNs = Int64(CACurrentMediaTime() * 1_000_000_000)
        let ts = max(nowNs, lastFrameTimestampNs + 1_000_000)
        lastFrameTimestampNs = ts
        let frame = RTCVideoFrame(buffer: buf, rotation: ._0, timeStampNs: ts)
        source.capturer(capturer, didCapture: frame)
    }

    /// Feed a static-frame refinement pixel buffer into the RTP pipeline so
    /// the WebRTC encoder emits a crisp update after motion settles.
    func sendRefinementFrame(_ pb: CVPixelBuffer) {
        sendVideoBuffer(pb)
    }

    /// Cap the RTP encoder's framerate.
    func setMaxFps(_ fps: Int) {
        requestedMaxFps = fps
        applyEncodingParams()
    }

    /// Cap the RTP encoder's bitrate (manual quality picks). GCC still
    /// adapts *below* the cap on congestion; this only sets the ceiling.
    func setMaxBitrate(_ bps: Int) {
        requestedMaxBps = bps
        applyEncodingParams()
    }

    private func applyEncodingParams() {
        guard let sender = videoSender else { return }
        let applyTunnelCap = tunnelCapActive && !directLanTrusted
        let bps = min(requestedMaxBps, lossCapBps ?? Int.max, applyTunnelCap ? Self.tunnelCapBps : Int.max)
        let effectiveFps = congestionGuardActive ? min(requestedMaxFps, Self.congestionMaxFps) : requestedMaxFps
        let params = sender.parameters
        for enc in params.encodings {
            if bps != Int.max {
                enc.maxBitrateBps = NSNumber(value: bps)
                if let m = enc.minBitrateBps?.intValue, m > bps { enc.minBitrateBps = NSNumber(value: bps) }
            }
            enc.maxFramerate = NSNumber(value: effectiveFps)
        }
        sender.parameters = params
    }

    private func applyMaxBitrate() {
        applyEncodingParams()
    }

    // Ceiling learned from loss. 10-10 WireGuard trace: the 12Mbps floor
    // armed (idle RTT 5-14ms looks exactly like LAN), the receiver started
    // losing 35-87 packets per 2s within seconds, and after the floor was
    // revoked GCC itself climbed on to 25Mbps through 1-4% loss before
    // crashing to 0.5Mbps — meanwhile the receiver's jitter buffer sat at
    // 0.4-1.2s, which is the ">1s inertia when reversing a scroll". GCC's
    // loss controller tolerates a few percent, so on a path like this it
    // keeps overshooting. Each time the receiver reports real loss, cap the
    // encoder at a fraction of the rate that produced it, for the rest of
    // this connection (a renegotiation starts clean).
    private static let lossCapTrigger = 0.06
    private static let lossCapFactor = 0.6
    private static let lossCapMinBps = 1_500_000
    private static let lossCapHoldSec = 10.0
    private static let lossCapRecoveryLossThreshold = 0.02
    private static let lossCapRecoveryRttThresholdMs = 30.0
    private static let lossCapRecoveryStreakRequired = 6   // 3s at 0.5s poll
    private static let lossCapRecoveryFactor = 1.35
    private static let lossCapClearBps = 10_000_000
    private var requestedMaxBps = Int.max
    private var requestedMaxFps = 120
    private var lossCapBps: Int?
    private var lossCapSetAt: CFAbsoluteTime = 0
    private var zeroLossStreak = 0

    private func evaluateLossCap(lossFraction: Double, targetBps: Int?, rttMs: Double?) {
        if lossFraction < Self.lossCapTrigger {
            if let currentCap = lossCapBps {
                if lossFraction < Self.lossCapRecoveryLossThreshold,
                   let rttMs, rttMs <= Self.lossCapRecoveryRttThresholdMs {
                    zeroLossStreak += 1
                    if zeroLossStreak >= Self.lossCapRecoveryStreakRequired {
                        zeroLossStreak = 0
                        let nextCap = Int(Double(currentCap) * Self.lossCapRecoveryFactor)
                        let clearLimit = min(Self.lossCapClearBps, requestedMaxBps)
                        if nextCap >= clearLimit {
                            lossCapBps = nil
                            applyMaxBitrate()
                            ConnectionLogger.shared.logStep(sessionId: "webrtc", step: "loss_cap",
                                detail: "cleared rttMs=\(String(format: "%.1f", rttMs))")
                        } else {
                            lossCapBps = nextCap
                            applyMaxBitrate()
                            ConnectionLogger.shared.logStep(sessionId: "webrtc", step: "loss_cap",
                                detail: "step_up cap=\(nextCap) rttMs=\(String(format: "%.1f", rttMs))")
                        }
                    }
                } else {
                    zeroLossStreak = 0
                }
            }
            return
        }
        zeroLossStreak = 0
        guard let targetBps else { return }
        let now = CFAbsoluteTimeGetCurrent()
        // One step per congestion episode — let the new cap take effect and
        // the loss reports catch up before judging again.
        guard now - lossCapSetAt >= Self.lossCapHoldSec else { return }
        let base = min(targetBps, lossCapBps ?? Int.max, requestedMaxBps)
        let cap = max(Self.lossCapMinBps, Int(Double(base) * Self.lossCapFactor))
        guard cap < (lossCapBps ?? Int.max) else { return }
        lossCapBps = cap
        lossCapSetAt = now
        applyMaxBitrate()
        ConnectionLogger.shared.logStep(sessionId: "webrtc", step: "loss_cap",
            detail: "cap=\(cap) from=\(base) loss=\(String(format: "%.3f", lossFraction))")
    }

    /// Floor GCC's own bandwidth estimate — see the gcc_stats diagnostic
    /// this pairs with: on a real same-switch LAN link (RTT ~0-1ms) GCC's
    /// delay-based congestion detector has been observed misreading tiny
    /// scheduling jitter as severe congestion and crashing its estimate to
    /// ~100Kbps, then taking 20-90s to climb back — a link that can
    /// trivially sustain many Mbps gets rate-limited to single-digit fps in
    /// the meantime. nil falls back to baseFloorBps, never to no floor at all.
    func setMinBitrate(_ bps: Int?) {
        guard let sender = videoSender else { return }
        let defaultFloor = congestionGuardActive ? Self.congestionFloorBps : Self.baseFloorBps
        let params = sender.parameters
        for enc in params.encodings {
            // Never above the encoding's own cap — min > max is rejected.
            let cap = enc.maxBitrateBps?.intValue ?? Int.max
            enc.minBitrateBps = NSNumber(value: min(bps ?? defaultFloor, cap))
        }
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
        highRttStreak = 0
        lowRttStreak = 0
        zeroLossStreak = 0
        lossCapBps = nil
        isDirectP2P = false
        isDirectPrivateLan = false
        lastObservedRttMs = 999.0
        wifiCleanStreak = 0
        wifiFloorElevated = false
        activeFloorBps = 0
        minBitrateFloorActive = false
        congestionGuardActive = false
        congestionEnterStreak = 0
        congestionClearStreak = 0
        offerPlayoutDelayExtId = nil
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
        // Sender encodings exist by now (ICE is up) — arm the base floor.
        setMinBitrate(nil)
        applyMaxBitrate()
        // forScreenCast sources default to keeping resolution/sharpness and
        // shedding frames: measured during a scroll at a ~5Mbps target,
        // capture delivered 47fps and the encoder emitted ~18. For remote
        // control a scroll has to stay fluid, so prefer framerate.
        if let sender = videoSender {
            let params = sender.parameters
            params.degradationPreference = NSNumber(value: RTCDegradationPreference.maintainFramerate.rawValue)
            sender.parameters = params
            if let ext = params.headerExtensions.first(where: { $0.uri == Self.playoutDelayExtURI }) {
                ConnectionLogger.shared.logStep(
                    sessionId: "webrtc",
                    step: "playout_delay_extmap",
                    detail: "sender_active id=\(ext.id) encrypted=\(ext.isEncrypted)"
                )
            } else {
                ConnectionLogger.shared.logStep(
                    sessionId: "webrtc",
                    step: "playout_delay_extmap",
                    detail: "sender_inactive extCount=\(params.headerExtensions.count)"
                )
            }
        }
    }

    private func logGCCStats() {
        pc?.statistics { [weak self] report in
            guard let self else { return }
            var outboundDetail = "n/a"
            var pairDetail = "n/a"
            var rttMs: Double?
            var rttSamples = -1.0
            var targetBps: Int?
            var lossFraction = 0.0
            for stat in report.statistics.values {
                if stat.type == "remote-inbound-rtp", (stat.values["kind"] as? String) == "video" {
                    lossFraction = stat.values["fractionLost"] as? Double ?? 0
                }
                if stat.type == "outbound-rtp", (stat.values["kind"] as? String) == "video" {
                    let reason  = stat.values["qualityLimitationReason"] as? String ?? "?"
                    let fps     = stat.values["framesPerSecond"] as? Double ?? -1
                    let target  = (stat.values["targetBitrate"] as? Double).map { Int($0) }
                    let encoded = stat.values["framesEncoded"] as? Double ?? -1
                    targetBps = target
                    outboundDetail = "qlr=\(reason) fps=\(fps) target=\(target.map(String.init) ?? "?") encoded=\(Int(encoded))"
                }
                if stat.type == "candidate-pair",
                   (stat.values["state"] as? String) == "succeeded",
                   (stat.values["nominated"] as? Bool) == true {
                    let rtt   = stat.values["currentRoundTripTime"] as? Double ?? -1
                    let avail = (stat.values["availableOutgoingBitrate"] as? Double).map { Int($0) }
                    rttMs = rtt * 1000
                    // currentRoundTripTime only changes per STUN check (every
                    // few seconds); this counter tells a fresh sample apart
                    // from the same one being re-read on each 0.5s poll.
                    rttSamples = stat.values["responsesReceived"] as? Double ?? -1
                    pairDetail = "rttMs=\(String(format: "%.1f", rttMs ?? -1)) availBps=\(avail.map(String.init) ?? "?")"
                }
            }
            ConnectionLogger.shared.logStep(sessionId: "webrtc", step: "gcc_stats",
                detail: "\(outboundDetail) | \(pairDetail) floor=\(self.minBitrateFloorActive ? "on" : "off") loss=\(String(format: "%.3f", lossFraction))")
            self.evaluateMinBitrateFloor(rttMs: rttMs, rttSamples: rttSamples, lossFraction: lossFraction)
            self.evaluateCongestionGuard(rttMs: rttMs, lossFraction: lossFraction)
            self.evaluateLossCap(lossFraction: lossFraction, targetBps: targetBps, rttMs: rttMs)
        }
    }

    /// UU-style asymmetric hysteresis congestion guard (enter fast, exit slow):
    /// when a tunnel/Wi-Fi hop spikes into severe loss or queueing delay, cap RTP fps to 24
    /// and relax the base bitrate floor to 350kbps so GCC can drain the queue and prevent
    /// multi-second PLI freeze storms; restore full fps once the link is clean for 3 seconds.
    private func evaluateCongestionGuard(rttMs: Double?, lossFraction: Double) {
        let rtt = rttMs ?? -1
        // Loss alone is not "immediate": on the WireGuard path one 0.5s poll of
        // 16-25% loss at 6ms RTT was followed by 0% a moment later (307 on/off
        // pairs, median 4s, ~30min of 24fps). It has to persist across the
        // sustained streak (loss >= 5% for 2 polls) before fps is cut.
        let immediateHit = rtt >= Self.congestionImmediateRttMs
        let sustainedHit = (rtt >= Self.congestionSustainedRttMs) || (lossFraction >= Self.congestionSustainedLoss)

        if !congestionGuardActive {
            if immediateHit {
                congestionEnterStreak = 0
                congestionClearStreak = 0
                congestionGuardActive = true
                applyEncodingParams()
                if !minBitrateFloorActive { setMinBitrate(nil) }
                ConnectionLogger.shared.logStep(sessionId: "webrtc", step: "congestion_guard",
                    detail: "on reason=immediate fps=\(min(requestedMaxFps, Self.congestionMaxFps)) floor=\(Self.congestionFloorBps) rttMs=\(String(format: "%.1f", rtt)) loss=\(String(format: "%.3f", lossFraction))")
            } else if sustainedHit {
                congestionEnterStreak += 1
                if congestionEnterStreak >= Self.congestionEnterStreakRequired {
                    congestionEnterStreak = 0
                    congestionClearStreak = 0
                    congestionGuardActive = true
                    applyEncodingParams()
                    if !minBitrateFloorActive { setMinBitrate(nil) }
                    ConnectionLogger.shared.logStep(sessionId: "webrtc", step: "congestion_guard",
                        detail: "on reason=sustained fps=\(min(requestedMaxFps, Self.congestionMaxFps)) floor=\(Self.congestionFloorBps) rttMs=\(String(format: "%.1f", rtt)) loss=\(String(format: "%.3f", lossFraction))")
                }
            } else {
                congestionEnterStreak = 0
            }
        } else {
            let clean = (rtt >= 0 && rtt <= Self.congestionClearRttMs) && (lossFraction < Self.congestionClearLoss)
            if clean {
                congestionClearStreak += 1
                if congestionClearStreak >= Self.congestionClearStreakRequired {
                    congestionClearStreak = 0
                    congestionEnterStreak = 0
                    congestionGuardActive = false
                    applyEncodingParams()
                    if !minBitrateFloorActive { setMinBitrate(nil) }
                    ConnectionLogger.shared.logStep(sessionId: "webrtc", step: "congestion_guard",
                        detail: "off fps=\(requestedMaxFps) floor=\(Self.baseFloorBps) rttMs=\(String(format: "%.1f", rtt)) loss=\(String(format: "%.3f", lossFraction))")
                }
            } else {
                congestionClearStreak = 0
            }
        }
    }

    /// Arms after several consecutive low-RTT polls; revokes on evidence of
    /// real overload (loss, a very high RTT, or sustained high RTT) and then
    /// holds off re-arming — see the comments on the thresholds above.
    private func evaluateMinBitrateFloor(rttMs: Double?, rttSamples: Double, lossFraction: Double) {
        guard let rttMs, rttMs >= 0 else { return }
        lastObservedRttMs = rttMs
        let isNewSample = rttSamples != lastRttSampleCount
        lastRttSampleCount = rttSamples
        if isNewSample { highRttStreak = rttMs >= Self.wanRttThresholdMs ? highRttStreak + 1 : 0 }

        var revokeReason: String?
        if lossFraction >= Self.lossRevokeFraction { revokeReason = "loss" }
        else if rttMs >= Self.hardRttThresholdMs { revokeReason = "rtt_hard" }
        else if highRttStreak >= 2 { revokeReason = "rtt_sustained" }

        if let revokeReason {
            lowRttStreak = 0
            wifiCleanStreak = 0
            wifiFloorElevated = false
            floorRevokedAt = CFAbsoluteTimeGetCurrent()
            if minBitrateFloorActive {
                minBitrateFloorActive = false
                activeFloorBps = 0
                setMinBitrate(nil)
                ConnectionLogger.shared.logStep(sessionId: "webrtc", step: "min_bitrate_floor",
                    detail: "off reason=\(revokeReason) rttMs=\(String(format: "%.1f", rttMs)) loss=\(String(format: "%.3f", lossFraction))")
            }
        } else {
            // If Wi-Fi floor was elevated to 9 Mbps and mild congestion appears
            // (rttMs > 25 or loss >= 2%), immediately drop back to the safe 6 Mbps floor.
            if minBitrateFloorActive, wifiFloorElevated,
               (rttMs > Self.wifiDemoteRttThresholdMs || lossFraction >= Self.wifiDemoteLossFraction) {
                wifiFloorElevated = false
                wifiCleanStreak = 0
                let demotedFloor = min(floorBps, requestedMaxBps, lossCapBps ?? Int.max)
                activeFloorBps = demotedFloor
                setMinBitrate(demotedFloor)
                ConnectionLogger.shared.logStep(sessionId: "webrtc", step: "min_bitrate_floor",
                    detail: "demote bps=\(demotedFloor) rttMs=\(String(format: "%.1f", rttMs)) loss=\(String(format: "%.3f", lossFraction))")
            }

            if rttMs <= Self.lanRttThresholdMs, lossCapBps == nil,
               CFAbsoluteTimeGetCurrent() - floorRevokedAt >= Self.rearmCooldownSec {
                lowRttStreak += 1
                if lowRttStreak >= Self.lanRttStreakRequired {
                    // Direct P2P (local=host, remote!=relay) with sustained <=15ms RTT and 0% loss
                    // is a real LAN link even when browser mDNS / prflx hides the remote IP.
                    if isDirectP2P, !isDirectPrivateLan, rttMs <= 15.0, lossFraction == 0 {
                        isDirectPrivateLan = true
                        applyMaxBitrate()
                        ConnectionLogger.shared.logStep(sessionId: "webrtc", step: "direct_lan_promoted",
                            detail: "bps=\(floorBps) rttMs=\(String(format: "%.1f", rttMs))")
                    }

                    // UU-style post-recovery ramp-up: once Wi-Fi 6 Mbps floor is active and proves
                    // completely clean (0% loss & RTT <= 15ms) for 10 consecutive polls (5s),
                    // elevate floor smoothly to 9 Mbps (capped by requestedMaxBps / lossCapBps).
                    var justElevated = false
                    if minBitrateFloorActive, effectiveLanAllowed, !wifiFloorElevated,
                       rttMs > Self.wiredLanRttThresholdMs {
                        if lossFraction == 0.0, rttMs <= Self.wifiElevationRttThresholdMs {
                            wifiCleanStreak += 1
                            if wifiCleanStreak >= Self.wifiElevationStreakRequired {
                                wifiFloorElevated = true
                                wifiCleanStreak = 0
                                justElevated = true
                            }
                        } else {
                            wifiCleanStreak = 0
                        }
                    } else if !wifiFloorElevated {
                        wifiCleanStreak = 0
                    }

                    let desiredFloor = min(floorBps, requestedMaxBps, lossCapBps ?? Int.max)
                    if !minBitrateFloorActive || activeFloorBps != desiredFloor {
                        minBitrateFloorActive = true
                        activeFloorBps = desiredFloor
                        setMinBitrate(desiredFloor)
                        let action = justElevated ? "elevate" : "on"
                        ConnectionLogger.shared.logStep(sessionId: "webrtc", step: "min_bitrate_floor",
                            detail: "\(action) bps=\(desiredFloor) rttMs=\(String(format: "%.1f", rttMs))")
                    }
                }
            } else {
                lowRttStreak = 0
                wifiCleanStreak = 0
            }
        }
    }

    // MARK: - Private

    private func createAnswer(pc: RTCPeerConnection) {
        let c = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        pc.answer(for: c) { [weak self] sdp, error in
            guard let self, let sdp, error == nil else {
                print("[WebRTC] createAnswer error: \(String(describing: error))")
                return
            }
            let reorderedSdpStr = self.preferCodecInSDP(sdp.sdp, preferred: self.preferredCodec)
            let finalSdpStr = Self.ensurePlayoutDelayInAnswer(reorderedSdpStr, offerExtId: self.offerPlayoutDelayExtId)
            let finalSdp = RTCSessionDescription(type: sdp.type, sdp: finalSdpStr)
            pc.setLocalDescription(finalSdp) { err in
                if let err {
                    ConnectionLogger.shared.logStep(
                        sessionId: "webrtc",
                        step: "set_local_desc_fallback",
                        detail: "err=\(err.localizedDescription)"
                    )
                    pc.setLocalDescription(sdp) { _ in }
                    self.onLocalDescription?("answer", sdp.sdp)
                    return
                }
                self.onLocalDescription?("answer", finalSdp.sdp)
            }
        }
    }

    /// Extracts the RFC5285 extension ID for `playout-delay` from the `m=video` section of an SDP.
    /// Supports both `a=extmap:<id> <uri>` and `a=extmap:<id>/<dir> ... <uri>`.
    private static func extractPlayoutDelayExtId(from sdp: String) -> Int? {
        let lineSep = sdp.contains("\r\n") ? "\r\n" : "\n"
        let lines = sdp.components(separatedBy: lineSep)
        guard let videoMLineIdx = lines.firstIndex(where: { $0.hasPrefix("m=video ") }) else {
            return nil
        }
        let nextMLineIdx = lines[(videoMLineIdx + 1)...].firstIndex(where: { $0.hasPrefix("m=") }) ?? lines.endIndex
        for i in (videoMLineIdx + 1)..<nextMLineIdx {
            let line = lines[i]
            guard line.hasPrefix("a=extmap:"), line.contains(playoutDelayExtURI) else { continue }
            let body = line.dropFirst("a=extmap:".count)
            guard let idToken = body.split(separator: " ").first else { continue }
            let idStr = idToken.split(separator: "/").first ?? idToken
            if let id = Int(idStr), id >= 1 {
                return id
            }
        }
        return nil
    }

    /// Ensures the Answer's `m=video` section preserves the exact `a=extmap:<id> playout-delay`
    /// offered by the remote peer (per RFC 5285, never injects one if absent from Offer).
    private static func ensurePlayoutDelayInAnswer(_ sdp: String, offerExtId: Int?) -> String {
        guard let offerExtId else { return sdp }
        let lineSep = sdp.contains("\r\n") ? "\r\n" : "\n"
        var lines = sdp.components(separatedBy: lineSep)
        guard let videoMLineIdx = lines.firstIndex(where: { $0.hasPrefix("m=video ") }) else {
            return sdp
        }
        let nextMLineIdx = lines[(videoMLineIdx + 1)...].firstIndex(where: { $0.hasPrefix("m=") }) ?? lines.endIndex
        let targetLine = "a=extmap:\(offerExtId) \(playoutDelayExtURI)"

        var existingIdx: Int?
        var lastExtmapIdx: Int?
        for i in (videoMLineIdx + 1)..<nextMLineIdx {
            let line = lines[i]
            if line.hasPrefix("a=extmap:") {
                lastExtmapIdx = i
                if line.contains(playoutDelayExtURI) {
                    existingIdx = i
                }
            }
        }

        if let idx = existingIdx {
            let existingId = extractPlayoutDelayExtId(from: sdp)
            if existingId == offerExtId {
                ConnectionLogger.shared.logStep(
                    sessionId: "webrtc",
                    step: "playout_delay_extmap",
                    detail: "answer_preserved id=\(offerExtId)"
                )
                return sdp
            }
            lines[idx] = targetLine
            ConnectionLogger.shared.logStep(
                sessionId: "webrtc",
                step: "playout_delay_extmap",
                detail: "answer_aligned id=\(offerExtId) prev=\(existingId.map(String.init) ?? "?")"
            )
            return lines.joined(separator: lineSep)
        }

        // Insert right after the last a=extmap: line in m=video (or right after m=video).
        let insertIdx = (lastExtmapIdx ?? videoMLineIdx) + 1
        lines.insert(targetLine, at: insertIdx)
        ConnectionLogger.shared.logStep(
            sessionId: "webrtc",
            step: "playout_delay_extmap",
            detail: "answer_injected id=\(offerExtId)"
        )
        return lines.joined(separator: lineSep)
    }

    /// Reorders `m=video` payload types to prioritize `preferred` codec (defaulting to
    /// H.264 High Profile `640c..`/`6400..`, then other H.264 profiles ahead of software
    /// VP9/AV1/VP8).
    private func preferCodecInSDP(_ sdp: String, preferred: String, logStep: String = "answer_codec_order") -> String {
        let lineSep = sdp.contains("\r\n") ? "\r\n" : "\n"
        var lines = sdp.components(separatedBy: lineSep)

        guard let videoMLineIdx = lines.firstIndex(where: { $0.hasPrefix("m=video ") }) else {
            return sdp
        }
        let nextMLineIdx = lines[(videoMLineIdx + 1)...].firstIndex(where: { $0.hasPrefix("m=") }) ?? lines.endIndex

        let mParts = lines[videoMLineIdx].split(separator: " ").map(String.init)
        guard mParts.count > 3 else { return sdp }
        let header = mParts[0..<3]
        let payloadTypes = Array(mParts[3...])

        var rtpmap: [String: String] = [:]   // pt -> lowercased codec name
        var fmtp: [String: String] = [:]     // pt -> lowercased fmtp params
        for i in (videoMLineIdx + 1)..<nextMLineIdx {
            let line = lines[i]
            if line.hasPrefix("a=rtpmap:") {
                let body = line.dropFirst("a=rtpmap:".count)
                let comps = body.split(separator: " ", maxSplits: 1)
                if comps.count == 2 {
                    let pt = String(comps[0])
                    let codec = comps[1].split(separator: "/").first.map { String($0).lowercased() } ?? ""
                    rtpmap[pt] = codec
                }
            } else if line.hasPrefix("a=fmtp:") {
                let body = line.dropFirst("a=fmtp:".count)
                let comps = body.split(separator: " ", maxSplits: 1)
                if comps.count == 2 {
                    fmtp[String(comps[0])] = String(comps[1]).lowercased()
                }
            }
        }

        // Map primary PT -> associated RTX PT(s) via `apt=<pt>`
        var rtxForApt: [String: [String]] = [:]
        var rtxSet: Set<String> = []
        for pt in payloadTypes where rtpmap[pt] == "rtx" {
            if let params = fmtp[pt],
               let aptRange = params.range(of: "apt=") {
                let rest = params[aptRange.upperBound...]
                let apt = String(rest.prefix { $0.isNumber })
                if !apt.isEmpty {
                    rtxForApt[apt, default: []].append(pt)
                    rtxSet.insert(pt)
                }
            }
        }

        let pref = preferred.lowercased()
        let isH264High: (String) -> Bool = { pt in
            guard rtpmap[pt] == "h264", let p = fmtp[pt] else { return false }
            return p.contains("profile-level-id=640c") || p.contains("profile-level-id=6400")
        }
        let isH264Main: (String) -> Bool = { pt in
            guard rtpmap[pt] == "h264", let p = fmtp[pt] else { return false }
            return p.contains("profile-level-id=4d")
        }

        func priority(for pt: String) -> Int {
            let codec = rtpmap[pt] ?? ""
            if codec == "red" || codec == "ulpfec" || codec == "flexfec-03" || codec == "rtx" {
                return 90
            }
            if codec == "vp8" { return 80 }

            switch pref {
            case "h265", "hevc":
                if codec == "h265" || codec == "hevc" { return 0 }
                if isH264High(pt) { return 10 }
                if isH264Main(pt) { return 14 }
                if codec == "h264" { return 15 }
                if codec == "vp9" { return 30 }
                if codec == "av1" { return 40 }
                return 50
            case "av1":
                if codec == "av1" { return 0 }
                if isH264High(pt) { return 10 }
                if isH264Main(pt) { return 14 }
                if codec == "h264" { return 15 }
                if codec == "vp9" || codec == "h265" || codec == "hevc" { return 25 }
                return 50
            case "vp9":
                if codec == "vp9" { return 0 }
                if isH264High(pt) { return 10 }
                if isH264Main(pt) { return 14 }
                if codec == "h264" { return 15 }
                if codec == "h265" || codec == "hevc" { return 25 }
                if codec == "av1" { return 35 }
                return 50
            case "h264":
                // ALL hardware H.264 profiles (High -> Main -> Constrained Baseline)
                // MUST rank ahead of software AV1/VP9/VP8 so clients that only offer
                // Baseline (e.g. Windows Chrome 42e01f) never fall back to CPU AV1.
                if isH264High(pt) { return 0 }
                if isH264Main(pt) { return 4 }
                if codec == "h264" { return 5 }
                if codec == "h265" || codec == "hevc" { return 15 }
                if codec == "vp9" { return 30 }
                if codec == "av1" { return 40 }
                return 50
            default:
                if codec == pref { return 0 }
                if isH264High(pt) { return 10 }
                if isH264Main(pt) { return 14 }
                if codec == "h264" { return 15 }
                if codec == "vp9" { return 30 }
                if codec == "av1" { return 40 }
                return 50
            }
        }

        let primaryPTs = payloadTypes.filter { !rtxSet.contains($0) }
        let sortedPrimary = primaryPTs.enumerated().sorted { a, b in
            let pa = priority(for: a.element)
            let pb = priority(for: b.element)
            return pa != pb ? pa < pb : a.offset < b.offset
        }.map(\.element)

        var ordered: [String] = []
        ordered.reserveCapacity(payloadTypes.count)
        for pt in sortedPrimary {
            ordered.append(pt)
            if let rtxList = rtxForApt[pt] {
                ordered.append(contentsOf: rtxList)
            }
        }
        // Append any unassociated RTX payload types if present
        let orderedSet = Set(ordered)
        for pt in payloadTypes where !orderedSet.contains(pt) {
            ordered.append(pt)
        }

        lines[videoMLineIdx] = (Array(header) + ordered).joined(separator: " ")
        if let firstPT = ordered.first {
            ConnectionLogger.shared.logStep(
                sessionId: "webrtc",
                step: logStep,
                detail: "preferred=\(pref) top=\(rtpmap[firstPT] ?? "?")(pt=\(firstPT)) fmtp=\(fmtp[firstPT] ?? "")"
            )
        }
        return lines.joined(separator: lineSep)
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
            highRttStreak = 0
            lowRttStreak = 0
            zeroLossStreak = 0
            lossCapBps = nil
            isDirectP2P = false
            isDirectPrivateLan = false
            lastObservedRttMs = 999.0
            wifiCleanStreak = 0
            wifiFloorElevated = false
            activeFloorBps = 0
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
        pc.statistics { [weak self] report in
            guard let self else { return }
            for stat in report.statistics.values where stat.type == "candidate-pair" {
                guard (stat.values["state"] as? String) == "succeeded",
                      (stat.values["nominated"] as? Bool) == true else { continue }
                let localId  = stat.values["localCandidateId"]  as? String
                let remoteId = stat.values["remoteCandidateId"] as? String
                let localStat  = localId.flatMap { report.statistics[$0] }
                let remoteStat = remoteId.flatMap { report.statistics[$0] }
                let localType  = localStat?.values["candidateType"] as? String ?? "?"
                let remoteType = remoteStat?.values["candidateType"] as? String ?? "?"
                let remoteIP   = (remoteStat?.values["ip"] as? String)
                    ?? (remoteStat?.values["address"] as? String)
                    ?? (remoteStat?.values["ipAddress"] as? String)
                    ?? ""
                let directP2P = (localType == "host" && remoteType != "relay")
                let directPrivate = directP2P && Self.isPrivateLanIP(remoteIP)
                self.isDirectP2P = directP2P
                if directPrivate != self.isDirectPrivateLan {
                    self.isDirectPrivateLan = directPrivate
                    self.applyMaxBitrate()
                    if self.minBitrateFloorActive {
                        self.setMinBitrate(self.floorBps)
                    }
                }
                ConnectionLogger.shared.logStep(sessionId: "webrtc", step: "candidate_pair",
                    detail: "local=\(localType) remote=\(remoteType) remoteIP=\(remoteIP.isEmpty ? "?" : remoteIP) directP2P=\(directP2P) directLan=\(directPrivate)")
            }
        }
    }

    private static func isPrivateLanIP(_ ip: String) -> Bool {
        if ip.hasPrefix("192.168.") || ip.hasPrefix("10.") || ip.hasPrefix("127.") { return true }
        if ip.hasPrefix("172.") {
            let parts = ip.split(separator: ".")
            if parts.count >= 2, let second = Int(parts[1]), (16...31).contains(second) {
                return true
            }
        }
        let lower = ip.lowercased()
        if lower.hasPrefix("fe80:") || lower.hasPrefix("fc") || lower.hasPrefix("fd") { return true }
        return false
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
