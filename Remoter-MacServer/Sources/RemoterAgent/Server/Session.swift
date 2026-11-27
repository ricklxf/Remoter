import Foundation
import AppKit
import CoreGraphics
import CoreVideo
import VideoToolbox
import ImageIO
import UniformTypeIdentifiers
import ApplicationServices
import SystemConfiguration
import PamAuthHelper
import WebRTC

// Manages one connected client: auth → capture → encode → stream
// Video: JPEG over WebSocket (bypasses VideoToolbox which hangs on macOS 26)
// Security: P-256 ECDH + AES-256-GCM end-to-end encryption (0xE0 frame prefix)
final class Session {
    let id: UUID
    let connection: WSClient
    private let pin: String

    private var capturer: ScreenCapturer?
    private var encoder: VideoEncoder?
    private var audioEncoder: AudioEncoder?
    private var audioEnabled = false
    private var audioSeq: UInt32 = 0
    private var micPlayer: MicPlayer?
    private var micEnabled = false
    private var cursorMonitor: CursorMonitor?
    private let lastFrameLock = NSLock()
    private var _lastFrame: CVPixelBuffer?
    private var lastFrame: CVPixelBuffer? {
        get {
            lastFrameLock.lock()
            defer { lastFrameLock.unlock() }
            return _lastFrame
        }
        set {
            lastFrameLock.lock()
            _lastFrame = newValue
            lastFrameLock.unlock()
        }
    }
    private var input: InputController?
    private var fileReceiver: FileReceiver?
    private var webrtc: WebRTCAgent?
    private let crypto = E2ECrypto()

    private var authenticated = false
    private var isClosed = false
    private var displayAwakeHeld = false
    private var frameId: UInt32 = 0
    private var inputEnabled = true
    private var jpegQuality: Double = 0.75
    private var lastForcedKeyframeAt: Date = .distantPast

    // Resolution is capped (longer side), not stepped automatically like
    // fps/bitrate — changing it tears down and rebuilds the capture stream
    // and encoder (VTCompressionSession can't resize live), which is
    // disruptive enough that it should only happen on an explicit user
    // choice, never silently as part of auto-quality. Defaults to native
    // resolution (nil = no cap) — capping to a fixed size regardless of the
    // actual display blurs anything wider than that cap (e.g. a 2560-wide
    // screen forced down to 1920). 1080p/2K remain manual downscale options
    // for bandwidth-constrained links.
    private var resolutionMaxDimension: Int?
    // Off-LAN (e.g. WireGuard from the office) + resolution never picked by the user:
    // a 4K headless display was being sent at 1.5-3 Mbps (blurry and stuttering), so the
    // capture is held to wanMaxDimension. Home LAN and explicit picks are never capped.
    private var resolutionUserSet = false
    private var wanResCapApplied = false
    private let wanResCapLock = NSLock()
    private static let wanMaxDimension = 2560
    private var effectiveMaxDimension: Int? {
        resolutionUserSet ? resolutionMaxDimension : (wanResCapApplied ? Self.wanMaxDimension : nil)
    }
    /// net_hint can land while the first capture is still starting, so wait for it
    /// instead of tearing down a capturer that doesn't exist yet.
    private func reconcileWanResolutionCap() async {
        guard !resolutionUserSet else { return }
        for _ in 0..<50 where capturer == nil { try? await Task.sleep(nanoseconds: 100_000_000) }
        guard let c = capturer, !resolutionUserSet else { return }
        // Two tasks (net_hint + rebuild paths) can get here at once: decide under a lock so only one rebuilds.
        wanResCapLock.lock()
        let wantCap = clientNotOnLan && max(c.screenWidth, c.screenHeight) > Self.wanMaxDimension
        let turnOn = wantCap && !wanResCapApplied
        let turnOff = !clientNotOnLan && wanResCapApplied
        if turnOn { wanResCapApplied = true }
        if turnOff { wanResCapApplied = false }
        wanResCapLock.unlock()
        if turnOn {
            ConnectionLogger.shared.logStep(sessionId: id.uuidString, step: "wan_res_cap",
                detail: "on \(c.screenWidth)x\(c.screenHeight) -> max \(Self.wanMaxDimension)")
            await rebuildPipeline()
        } else if turnOff {
            ConnectionLogger.shared.logStep(sessionId: id.uuidString, step: "wan_res_cap", detail: "off (LAN)")
            await rebuildPipeline()
        }
    }
    // nil = main display; switching also requires a full pipeline rebuild.
    private var selectedDisplayID: UInt32?

    // Currently-applied fps/bitrate (mirrors whatever applyFps/applyBitrate
    // last set, whether from auto-stepping or a manual pick) — beginCapture() reads
    // these instead of a hardcoded default so a resolution switch (which
    // re-runs the whole capture/encoder setup) doesn't reset quality back
    // to the connection-time starting point.
    private var currentFps = 30
    private var currentBitrate = 2_000_000
    private var currentCodec: StreamCodec = .h264
    private var manualCodecSelected = false
    private var clientSupportsH265 = false
    private var currentChroma: ChromaMode = .yuv420
    private var currentHdr = false
    private var lowLatencyZeroBuffer = false
    private var usingJpeg = false  // re-applied after a resolution switch's beginCapture() rebuild, which defaults back to h264

    /// Standard WebRTC RTP only carries 8-bit 4:2:0 and adds browser jitter
    /// buffering; when 4:4:4, 10-bit HDR, or 0-buffer low-latency mode is active,
    /// route frames through VideoEncoder -> WebCodecs.
    private var forceCanvasMode: Bool {
        currentChroma == .yuv444 || currentHdr || lowLatencyZeroBuffer
    }

    // Video send semaphore: allow several small H.264 frames in flight so a
    // single high-RTT contentProcessed round-trip doesn't throttle throughput.
    // Frames are tiny (a few KB), so a small backlog adds negligible latency
    // while keeping the pipe full. Excess frames are dropped (backpressure).
    private let wsSendSem = DispatchSemaphore(value: 4)

    // Sent-frame diagnostics (shared across WebRTC/WebSocket video paths)
    private var sentFrames = 0
    private var sentTick = Date()
    private var backpressureDrops = 0     // frames dropped: WebRTC send buffer was full
    private var keyframesForced = 0       // times we actually forced a keyframe (post-cooldown)
    private var keyframeRequests = 0      // client request_keyframe messages received (pre-cooldown)
    private var usingWebRTCVideo = false  // legacy DataChannel video path active
    private var usingRtpVideo = false     // RTP media-track path active
    private var usingUdpVideo = false     // direct UDP video path active
    private var udpCleanBitrateStreak = 0 // consecutive 2s windows with lossRatio < 0.01
    private var udpLearnedCeilingBps: Int? // learned safe bitrate ceiling after UDP packet loss (anti-sawtooth)
    private var udpLossCapSetAt: CFAbsoluteTime = 0
    private var udpStableAtCapStreak = 0
    private var udpLastLossRatio: Double = 0
    private var udpSevereFpsGuard = UdpSevereFpsGuard()
    private var udpDelayOveruseStreak = 0
    private var udpDelayCleanStreak = 0
    private var udpLastGccAdjustAt: CFAbsoluteTime = 0
    private let udpSessionToken: Data = {
        var rng = SystemRandomNumberGenerator()
        return Data((0..<16).map { _ in UInt8.random(in: 0...255, using: &rng) })
    }()
    private var udpSessionTokenHex: String {
        udpSessionToken.map { String(format: "%02x", $0) }.joined()
    }
    // Client-reported: none of its network interfaces share a subnet with the
    // address it dialed (i.e. it's coming in through a tunnel/router, e.g.
    // WireGuard). RTT can't tell that apart from a real LAN — the tunnel
    // idles at 5-16ms — and arming the 12Mbps floor on it caused real loss.
    private var clientNotOnLan = false
    // Scroll bitrate boost: instead of crippling capture to 30fps (which ruins smoothness
    // and causes SCStream reconfiguration hitching), maintain 60fps/120fps and temporarily
    // boost encoder bitrate by 50% during scrolling so moving text stays crisp and clear.
    private let scrollBoostLock = NSLock()
    private var scrollBoostGen = 0
    private var scrollBoostActive = false
    // Auto quality: fps and bitrate step on separate ladders — collapsing
    // them into one combined tier meant any problem (network congestion OR
    // decode overload) dragged *both* down together, even when only one
    // lever was actually needed.
    //   - fps      ← keyframeRequests only (client's decode queue backed
    //                up; lowering fps directly relieves decode load)
    //   - bitrate  ← keyframeRequests *and* backpressureDrops. Bitrate
    //                isn't purely a network knob: a bigger bitrate means
    //                bigger, more expensive-to-decode frames, so it can't
    //                be allowed to climb (or should come down) whenever the
    //                client is decode-overloaded, even if the network side
    //                looks perfectly clean. Learned this the hard way —
    //                bitrate climbing to its max tier in lockstep with fps
    //                stepping down to fix a decode-overloaded client made
    //                "自动" hand it even bigger frames while already behind,
    //                and it never settled.
    // Both ordered safest-first so "自动" starts conservative and only
    // climbs after proving stable, rather than starting high and visibly
    // stuttering before settling.
    /// Off-LAN bitrate ceiling. 12 Mbps made 2560-wide keyframes ~160KB, whose burst queued up on
    /// Wi-Fi/tunnel paths; 8 Mbps keeps them ~100KB with little visible loss for desktop content.
    static let wanMaxBitrateBps = 8_000_000
    private static let autoFpsTiers:     [Int] = [30, 60, 90, 120]
    /// Highest auto tier the captured display can actually deliver — on a
    /// 60Hz panel, climbing to 90/120 only costs a deeper capture queue and a
    /// 120fps encoder cap for frames that never exist. Manual picks are not
    /// limited by this.
    private var autoFpsTopIndex: Int {
        let limit = max(60, capturer?.maxRefreshRate ?? 60)
        return Self.autoFpsTiers.lastIndex(where: { $0 <= limit }) ?? 0
    }
    // Top tier raised to 25M for pristine LAN bitrate — WebRTCAgent's lanFloorBps
    // (RTT-gated minimum) now sits at 12M, so the ceiling gives room for 25M
    // pristine stream quality.
    private static let autoBitrateTiers: [Int] = [2_000_000, 4_000_000, 8_000_000, 15_000_000, 25_000_000, 40_000_000]
    private static let lanStartupBitrateIndex: Int = autoBitrateTiers.firstIndex(of: 15_000_000) ?? max(0, autoBitrateTiers.count - 2)
    // Independent — the client can put either on auto while pinning the
    // other to a manual value, matching the fact they're genuinely two
    // separate knobs, not one bundled "quality" choice.
    private var autoFpsEnabled = false
    private var autoBitrateEnabled = false
    private var manualFpsSelected = false
    private var manualBitrateSelected = false
    private var autoFpsIndex = 0
    private var autoBitrateIndex = 0
    private var autoFpsCleanStreak = 0
    private var autoBitrateCleanStreak = 0

    // For disconnection logging
    private var connectTime: Date?
    private var bytesSent: Int64 = 0
    private var bytesRecv: Int64 = 0
    private var loggedFirstInput = false


    // Active authenticated session registry: when a client reconnects after a drop,
    // immediately reap any half-open zombie session idle >= 3s BEFORE starting the new
    // capture/encoder pipeline so the old zombie never overlaps and steals bandwidth!
    private static let activeSessionsLock = NSLock()
    private static var activeSessions: [UUID: Session] = [:]

    private static func registerAndReapStaleSessions(newSession: Session) {
        // One controller per machine: a newly authenticated session replaces every older one
        // (not only idle zombies). The old client is told why first (code=session_replaced) so it
        // stops auto-reconnecting instead of kicking the new one back out.
        var toClose: [(Session, Double)] = []
        let now = CFAbsoluteTimeGetCurrent()
        activeSessionsLock.lock()
        activeSessions[newSession.id] = newSession
        for (sid, existing) in activeSessions where sid != newSession.id {
            activeSessions.removeValue(forKey: sid)
            if existing.isClosed { continue }
            if existing.authenticated { toClose.append((existing, now - existing.lastClientActivityAt)) }
        }
        activeSessionsLock.unlock()

        for (old, idleSec) in toClose {
            ConnectionLogger.shared.logStep(
                sessionId: old.id.uuidString,
                step: "session_replaced",
                detail: "idleSec=\(String(format: "%.1f", idleSec)) replacedBy=\(newSession.id.uuidString.prefix(8))"
            )
            old.sendJson(["type": "error", "code": "session_replaced",
                          "message": "此被控端已被另一台电脑连接，当前连接已断开"])
            // Give the notice a moment to flush before the socket goes away.
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.4) {
                old.connection.close()
                old.close()
            }
        }
    }

    private static func unregisterActiveSession(id: UUID) {
        activeSessionsLock.lock()
        activeSessions.removeValue(forKey: id)
        activeSessionsLock.unlock()
    }

    // Keepalive: send a JSON message every 3s so the client's stale-timeout (6s)
    // doesn't fire when the screen is static and CGDisplayStream pushes no frames.
    // Also reaps half-open zombie TCP sessions after 15s of zero inbound client traffic.
    private var keepaliveTimer: DispatchSourceTimer?
    private var lastClientActivityAt: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    // WAN background-window bandwidth saver: if no mouse/keyboard/scroll input arrives for >= 12s
    // on a WAN UDP session, step down to 20fps / 1.5Mbps so an inactive background Mac never
    // steals 2.5-5 Mbps from the active Mac sharing the same WAN tunnel; restores instantly (<1ms)
    // on the first user input event.
    private var lastUserInputAt: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    private var wanBgSaverActive = false
    private var wanBgSaverArmedAt: CFAbsoluteTime? = nil
    private var lastUnreadableClipboardFilesSig = ""
    private var wanBgBestFps = 0
    private var scrollBurstGen = 0   // guarded by scrollBoostLock
    private var wanBgSavedFps: Int? = nil
    private var wanBgSavedBitrate: Int? = nil

    // Low-priority reverse sync: this agent's own clipboard → controller.
    // Deliberately much slower than the controller→agent path (which is
    // paste-triggered, effectively instant) — the controller's clipboard is
    // the side that matters for responsiveness; this direction only needs
    // to eventually catch up. Tracks what it last SENT (not what a
    // clipboard_set/clipboard_set_image just applied) so applying the
    // controller's own push right back doesn't get echoed straight back to
    // it as if it were a fresh local copy.
    private var clipboardTimer: DispatchSourceTimer?
    private var lastSentClipboardText = ""
    private var lastSentClipboardImageSize = -1
    private var lastSentClipboardFilesSig = ""
    private var lastAppliedPasteboardChangeCount = -1
    // Set once the first time startClipboardMonitor() ever captures a
    // baseline for this session — see there for why this must not happen
    // again on every restart.
    private var clipboardBaselineCaptured = false

    // Live-session count: the virtual display and the privacy curtain are
    // process-wide singletons, so one client disconnecting must not tear them
    // down while another client is still using them.
    private static let liveLock = NSLock()
    private static var liveCount = 0

    init(id: UUID, connection: WSClient, pin: String) {
        self.id = id
        self.connection = connection
        self.pin = pin
        Self.liveLock.lock(); Self.liveCount += 1; Self.liveLock.unlock()
    }

    func start() {
        let remote = "\(connection.endpoint)"
        ConnectionLogger.shared.logClientConnected(sessionId: id.uuidString, remoteAddr: remote)

        Task {
            var hello: [String: Any] = [
                "type": "hello", "version": "1.0", "os": "macOS",
                "pubkey": crypto.publicKeyBase64,
                "computerName": Self.computerName(),
                "modelId": Self.modelId(),
                "inputLocked": InputLocker.shared.isLocked
            ]
            // TURN info lets the client's WebRTC offer include a relay candidate —
            // without it, P2P only works when STUN/direct already succeeds (LAN,
            // or no symmetric NAT in the way). Omitted gracefully if the public IP
            // hasn't resolved yet; video just stays on the WebSocket fallback.
            if let ip = await PublicIPResolver.shared.current() {
                let cred = TurnCredentials.generate()
                let host = PublicIPResolver.shared.bracketedForURI(ip)
                // TURN 信令复用 WS 端口号（UDP，跟 TCP:port 的 WebSocket 不冲突，
                // 路由器只用转发一个端口号）。turnserver.conf 的 listening-port
                // 改了的话这里要跟着改——目前是手动保持一致，还没接到 config.port。
                hello["turn"] = [
                    "urls": ["turn:\(host):7788?transport=udp"],
                    "username": cred.username,
                    "credential": cred.password
                ]
            }
            // Include our E2E public key so client can initiate handshake
            sendJsonRaw(hello)
        }
    }

    private static func computerName() -> String {
        return (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? ""
    }

    private static func modelId() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "" }
        var chars = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &chars, &size, nil, 0)
        return String(cString: chars)
    }

    func handleText(_ text: String) {
        lastClientActivityAt = CFAbsoluteTimeGetCurrent()
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        routeMessage(json)
    }

    func handleBinary(_ data: Data) {
        lastClientActivityAt = CFAbsoluteTimeGetCurrent()
        guard data.count > 0 else { return }

        // 0xE0 = encrypted JSON frame (sent after E2E handshake)
        if data[0] == 0xE0 {
            guard data.count > 1 else { return }
            let ciphertext = Data(data[1...])
            do {
                let plain = try crypto.decrypt(ciphertext)
                guard let json = try? JSONSerialization.jsonObject(with: plain) as? [String: Any] else { return }
                routeMessage(json)
            } catch {
                ConnectionLogger.shared.logStep(sessionId: id.uuidString, step: "e2e_decrypt_failed",
                                                detail: "\(error)")
            }
            return
        }
        // 未加密文本消息兜底（E2E 握手前）
        print("[Session] binary non-E2E prefix=\(data[0]) len=\(data.count)")

        // Opt-in client microphone PCM passthrough (0x04) -> virtual audio device
        if authenticated && micEnabled && data.count > 1 && data[0] == FrameType.micAudio.rawValue {
            bytesRecv += Int64(data.count)
            micPlayer?.enqueuePcm(Data(data[1...]))
            return
        }

        // Regular binary (file chunk)
        guard authenticated, data.count > 1, data[0] == FrameType.fileChunk.rawValue else { return }
        guard data.count > 21 else { return }
        let idData = data[1..<17]
        let fid = String(data: idData, encoding: .utf8)?
            .trimmingCharacters(in: .init(charactersIn: "\0")) ?? ""
        var offsetBE: UInt32 = 0
        (data[17..<21] as NSData).getBytes(&offsetBE, length: 4)
        let offset = CFSwapInt32BigToHost(offsetBE)
        bytesRecv += Int64(data.count)
        fileReceiver?.receive(id: fid, offset: Int64(offset), chunk: Data(data[21...]))
    }

    func close() {
        Self.unregisterActiveSession(id: id)
        let alreadyClosed = isClosed
        isClosed = true
        // Log disconnection if we were streaming
        if let t = connectTime {
            let secs = Int(Date().timeIntervalSince(t))
            ConnectionLogger.shared.logDisconnected(
                sessionId: id.uuidString,
                durationSecs: secs,
                bytesSentMB: Double(bytesSent) / 1_048_576,
                bytesRecvMB: Double(bytesRecv) / 1_048_576
            )
            notifyUser(connected: false)
        }
        input?.releaseAllKeys()
        stopKeepalive()
        stopClipboardMonitor()
        var lastOne = false
        if !alreadyClosed {   // close() can run more than once per session
            Self.liveLock.lock(); Self.liveCount -= 1; lastOne = Self.liveCount <= 0; Self.liveLock.unlock()
        }
        if lastOne {
            Task { @MainActor in
                PrivacyScreenManager.shared.disable()
            }
            VirtualDisplayManager.shared.destroyVirtualDisplay()
        }
        cursorMonitor?.stop()
        cursorMonitor = nil
        micEnabled = false
        micPlayer?.stop()
        micPlayer = nil
        if displayAwakeHeld {
            displayAwakeHeld = false
            PowerManager.shared.setDisplayActive(false)
        }
        usingUdpVideo = false
        UdpVideoServer.shared.unregisterSession(token: udpSessionToken)
        encoder?.close()
        encoder = nil
        // Capture the current capturer locally before niling it out, so the
        // stop Task doesn't hold a strong ref to self (which would keep the
        // session alive and allow onStopped to fire and restart beginCapture).
        let cap = capturer
        capturer = nil
        cap?.onStopped = nil   // prevent stop() from triggering beginCapture restart
        Task { await cap?.stop() }
        webrtc?.close()
        webrtc = nil
    }

    // MARK: - Message routing

    private func routeMessage(_ json: [String: Any]) {
        let msg = ClientMessage.parse(json)

        // ── E2E 握手（无需认证）──────────────────────────────────
        if case .cryptoHello(let pubkey) = msg {
            do {
                try crypto.deriveSharedKey(peerBase64: pubkey)
                // Respond with our pubkey so client can verify (already sent in hello, but ack)
                sendJsonRaw(["type": "crypto_ok"])
            } catch {
                sendJsonRaw(["type": "error", "code": "crypto_failed", "message": "\(error)"])
            }
            return
        }

        // ── PIN 认证 ──────────────────────────────────────────
        if case .auth(_) = msg {
            let token = TokenStore.shared.generate(username: "__pin__")
            authenticated = true
            ConnectionLogger.shared.logAuthSuccess(sessionId: id.uuidString)
            notifyUser(connected: true)
            // 不再强制切换被控端输入法为 ABC：控制端普通可打印字符（含中英文与标点）
            // 统一通过 text_input (CGEventKeyboardSetUnicodeString) 注入，绕过被控端 IME。
            startClipboardMonitor()
            sendJsonRaw(["type": "auth_ok", "token": token, "username": "__pin__"])
            Task { await self.beginCapture() }
            return
        }

        // ── OS 账户认证 ────────────────────────────────────────
        if case .authCredentials(let username, let password) = msg {
            let u = username.lowercased()
            ConnectionLogger.shared.logStep(sessionId: id.uuidString,
                step: "cred_received", detail: "user=\(u) pwd_len=\(password.count)")
            if validateOsCredentials(username: u, password: password) {
                let token = TokenStore.shared.generate(username: username)
                authenticated = true
                ConnectionLogger.shared.logAuthSuccess(sessionId: id.uuidString)
                notifyUser(connected: true)
                startClipboardMonitor()
                sendJsonRaw(["type": "auth_ok", "token": token, "username": username])
                Task { await self.beginCapture() }
            } else {
                ConnectionLogger.shared.logStep(sessionId: id.uuidString,
                    step: "cred_failed", detail: "user=\(u)")
                sendJsonRaw(["type": "error", "code": "bad_credentials",
                             "message": "用户名或密码错误（请用 macOS 登录密码，用户名在系统偏好→用户与群组中确认）"])
            }
            return
        }

        // ── Token 认证 ────────────────────────────────────────
        if case .authToken(let token) = msg {
            if let username = TokenStore.shared.lookup(token) {
                authenticated = true
                ConnectionLogger.shared.logAuthSuccess(sessionId: id.uuidString)
                notifyUser(connected: true)
                startClipboardMonitor()
                sendJsonRaw(["type": "auth_ok"])
                NSLog("[Session] token auth as %@", username)
                Task { await self.beginCapture() }
            } else {
                sendJsonRaw(["type": "error", "code": "bad_token", "message": "Token 无效，请重新登录"])
            }
            return
        }

        guard authenticated else { return }

        switch msg {

        // ── 输入事件 ───────────────────────────────────────────
        case .mouseMove(let x, let y, let dragging):
            guard inputEnabled else { break }
            noteUserInputActivity()
            if !loggedFirstInput {
                loggedFirstInput = true
                ConnectionLogger.shared.logStep(sessionId: id.uuidString, step: "first_input",
                                                detail: "input=\(input != nil), ax=\(AXIsProcessTrusted())")
            }
            input?.mouseMove(x: x, y: y, dragging: dragging)

        case .mouseButton(let btn, let down, let x, let y):
            guard inputEnabled else { break }
            noteUserInputActivity()
            input?.mouseButton(button: btn, down: down, x: x, y: y)

        case .mouseDoubleClick(let btn, let x, let y):
            guard inputEnabled else { break }
            noteUserInputActivity()
            input?.mouseDoubleClick(button: btn, x: x, y: y)

        case .mouseScroll(let dx, let dy, let px, let py, let isPrecise):
            guard inputEnabled else { break }
            noteUserInputActivity()
            input?.mouseScroll(dx: dx, dy: dy, px: px, py: py, isPrecise: isPrecise)
            boostBitrateWhileScrolling()

        case .netHint(let lan):
            clientNotOnLan = !lan
            Task { await self.reconcileWanResolutionCap() }
            webrtc?.offLanHinted = clientNotOnLan
            webrtc?.lanFloorAllowed = lan
            webrtc?.tunnelCapActive = clientNotOnLan && autoBitrateEnabled
            UdpVideoServer.shared.setFecSuppressionAllowed(token: udpSessionToken, allowed: lan)
            if lan {
                if !manualBitrateSelected && currentBitrate < 15_000_000 {
                    autoBitrateIndex = Self.lanStartupBitrateIndex
                    autoBitrateCleanStreak = 0
                    applyBitrate(15_000_000, notify: true)
                }
                if !manualFpsSelected && currentFps < 60 {
                    if let idx60 = Self.autoFpsTiers.firstIndex(of: 60) {
                        autoFpsIndex = min(idx60, autoFpsTopIndex)
                    }
                    autoFpsCleanStreak = 0
                    applyFps(60, notify: true)
                }
            } else if usingUdpVideo && !manualBitrateSelected && currentBitrate > Self.wanMaxBitrateBps {
                applyBitrate(Self.wanMaxBitrateBps, notify: true)
            }
            ConnectionLogger.shared.logStep(sessionId: id.uuidString, step: "net_hint", detail: "lan=\(lan)")

        case .key(let code, let down, let mods):
            guard inputEnabled else { break }
            noteUserInputActivity()
            // Scoped to modifier combos only (not every keystroke) — this is
            // for diagnosing reports like "Ctrl+C sent from the client does
            // nothing on the target": confirms whether the key actually made
            // it to this agent at all, vs. being eaten locally on the target
            // (e.g. by a system-wide remapper such as Keybot) after CGEvent
            // injection. The old NSLog here logged every keystroke but
            // turned out to be unobservable — `log show`/`log stream`
            // returned zero matches for this process even over a 30-minute
            // window with an exact PID predicate — so this uses
            // ConnectionLogger (connections.log) instead, already confirmed
            // reliable for every other diagnostic in this file.
            if !mods.isEmpty {
                ConnectionLogger.shared.logStep(sessionId: id.uuidString, step: "key_modifier_combo",
                    detail: "code=\(code) down=\(down) mods=\(mods.joined(separator: "+"))")
            }
            input?.keyEvent(code: code, down: down, modifiers: mods)

        case .textInput(let text):
            guard inputEnabled else { break }
            input?.typeText(text)

        case .clipboardSet(let text):
            // The controller's push is the high-priority direction — apply
            // it immediately. Also mark it as "already sent" so the slow
            // reverse-sync poll below doesn't see this same content as a
            // fresh local copy a moment later and echo it straight back.
            // Dispatched onto main — routeMessage runs on a NIO event-loop
            // thread, and a real crash report confirmed NSPasteboard isn't
            // safe to touch off the main thread (see clipboardPlainText()).
            lastSentClipboardText = text
            DispatchQueue.main.async { [weak self] in
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
                self?.lastAppliedPasteboardChangeCount = pb.changeCount
            }
            ConnectionLogger.shared.logStep(sessionId: id.uuidString, step: "clipboard_set_applied", detail: "len=\(text.count)")

        case .clipboardSetImage(let data):
            guard !data.isEmpty, let imgData = Data(base64Encoded: data) else { break }
            lastSentClipboardImageSize = imgData.count
            DispatchQueue.main.async { [weak self] in
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.declareTypes([.png, .tiff], owner: nil)
                pb.setData(imgData, forType: .png)
                if let rep = NSBitmapImageRep(data: imgData),
                   let tiff = rep.representation(using: .tiff, properties: [:]) {
                    pb.setData(tiff, forType: .tiff)
                }
                self?.lastAppliedPasteboardChangeCount = pb.changeCount
            }
            ConnectionLogger.shared.logStep(sessionId: id.uuidString, step: "clipboard_set_image_applied", detail: "bytes=\(imgData.count)")

        case .clipboardSetFiles(let paths):
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let fm = FileManager.default
                let urls: [URL] = paths.compactMap { raw in
                    let expanded = (raw as NSString).expandingTildeInPath
                    return fm.fileExists(atPath: expanded) ? URL(fileURLWithPath: expanded) : nil
                }
                guard !urls.isEmpty else {
                    self.sendJson(["type": "clipboard_files_ready", "count": 0])
                    return
                }
                self.lastSentClipboardFilesSig = Self.clipboardFilesSignature(urls: urls)
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.writeObjects(urls as [NSURL])
                self.lastAppliedPasteboardChangeCount = pb.changeCount
                ConnectionLogger.shared.logStep(
                    sessionId: self.id.uuidString,
                    step: "clipboard_set_files_applied",
                    detail: "count=\(urls.count)"
                )
                self.sendJson(["type": "clipboard_files_ready", "count": urls.count])
            }

        case .fileStart(let fid, let name, let size, let relPath, let destDir, let resume, let purpose):
            fileReceiver?.start(
                id: fid,
                name: name,
                size: size,
                relPath: relPath,
                destDir: destDir,
                resume: resume,
                purpose: purpose
            ) { [weak self] offset, resumed in
                self?.sendJson([
                    "type": "file_ack",
                    "id": fid,
                    "offset": offset,
                    "resumed": resumed
                ])
            }

        case .fileEnd(let fid):
            fileReceiver?.finish(id: fid) { [weak self] finalPath in
                var resp: [String: Any] = ["type": "file_done", "id": fid]
                if let finalPath { resp["path"] = finalPath }
                self?.sendJson(resp)
            }

        case .fpsSet(let fps, let auto):
            autoFpsEnabled = auto
            manualFpsSelected = !auto
            if auto {
                if usingRtpVideo {
                    autoFpsIndex = autoFpsTopIndex
                    autoFpsCleanStreak = 0
                    applyFps(Self.autoFpsTiers[autoFpsIndex])
                } else if usingUdpVideo || !clientNotOnLan {
                    autoFpsIndex = min(1, autoFpsTopIndex) // 60fps floor for direct UDP & LAN
                    autoFpsCleanStreak = 0
                    applyFps(max(60, Self.autoFpsTiers[autoFpsIndex]))
                } else {
                    autoFpsIndex = 0
                    autoFpsCleanStreak = 0
                    applyFps(Self.autoFpsTiers[autoFpsIndex])
                }
            } else {
                applyFps(fps)
            }

        case .bitrateSet(let bitrate, let auto):
            autoBitrateEnabled = auto
            manualBitrateSelected = !auto
            webrtc?.tunnelCapActive = clientNotOnLan && auto
            if auto {
                if usingRtpVideo {
                    autoBitrateIndex = Self.autoBitrateTiers.count - 1
                    autoBitrateCleanStreak = 0
                    applyBitrate(Self.autoBitrateTiers[autoBitrateIndex])
                } else if usingUdpVideo {
                    autoBitrateCleanStreak = 0
                    if !clientNotOnLan {
                        autoBitrateIndex = Self.lanStartupBitrateIndex
                        applyBitrate(max(15_000_000, currentBitrate))
                    } else {
                        applyBitrate(max(6_000_000, currentBitrate))
                    }
                } else {
                    autoBitrateCleanStreak = 0
                    if !clientNotOnLan {
                        autoBitrateIndex = Self.lanStartupBitrateIndex
                    } else {
                        autoBitrateIndex = min(1, Self.autoBitrateTiers.count - 1)
                    }
                    applyBitrate(Self.autoBitrateTiers[autoBitrateIndex])
                }
            } else {
                applyBitrate(max(500_000, min(50_000_000, bitrate)))
            }

        case .resolutionSet(let tier, let customW, let customH, let scale):
            resolutionUserSet = true
            let effectiveScale = max(1.0, scale ?? 1.0)
            if tier == "native" {
                if VirtualDisplayManager.shared.activeDisplayID != nil {
                    VirtualDisplayManager.shared.destroyVirtualDisplay()
                    selectedDisplayID = nil
                    sendJson(["type": "virtual_display_active", "enabled": false])
                }
                resolutionMaxDimension = nil
                Task { await rebuildPipeline() }
                break
            }

            if tier == "match", let w = customW, let h = customH, w > 0, h > 0 {
                var logicalW = Double(min(max(w, 640), 5120))
                var logicalH = Double(min(max(h, 480), 2880))
                let physW = logicalW * effectiveScale
                let physH = logicalH * effectiveScale
                if physW > 3840.0 || physH > 2160.0 {
                    let factor = min(3840.0 / physW, 2160.0 / physH)
                    logicalW = max(640.0, logicalW * factor)
                    logicalH = max(480.0, logicalH * factor)
                }
                let targetW = UInt(logicalW.rounded()) & ~1
                let targetH = UInt(logicalH.rounded()) & ~1
                ConnectionLogger.shared.logStep(sessionId: id.uuidString, step: "match_resolution",
                                                detail: "\(targetW)x\(targetH)@\(effectiveScale)x")
                if let vId = VirtualDisplayManager.shared.createOrUpdateVirtualDisplay(
                    logicalWidth: targetW,
                    logicalHeight: targetH,
                    refreshRate: Double(currentFps),
                    scaleFactor: effectiveScale
                ) {
                    selectedDisplayID = vId
                    resolutionMaxDimension = nil
                    sendJson([
                        "type": "virtual_display_active",
                        "enabled": true,
                        "display_id": Int(vId)
                    ])
                    Task {
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        await rebuildPipeline()
                    }
                    break
                }
            }

            // If virtual display is currently active and user selected a standard tier, resize it
            if let activeVId = VirtualDisplayManager.shared.activeDisplayID, selectedDisplayID == activeVId {
                if tier == "1080" {
                    _ = VirtualDisplayManager.shared.createOrUpdateVirtualDisplay(
                        logicalWidth: 1920,
                        logicalHeight: 1080,
                        refreshRate: Double(currentFps),
                        scaleFactor: effectiveScale
                    )
                } else if tier == "2k" {
                    _ = VirtualDisplayManager.shared.createOrUpdateVirtualDisplay(
                        logicalWidth: 2560,
                        logicalHeight: 1440,
                        refreshRate: Double(currentFps),
                        scaleFactor: effectiveScale
                    )
                }
            }

            let newMax: Int? = tier == "2k" ? 2560 : (tier == "1080" ? 1920 : nil)
            guard newMax != resolutionMaxDimension else { break }
            resolutionMaxDimension = newMax
            Task { await rebuildPipeline() }

        case .chromaSet(let mode):
            let next = ChromaMode(rawValue: mode) ?? .yuv420
            let changed = next != currentChroma
            currentChroma = next
            ConnectionLogger.shared.logStep(sessionId: id.uuidString, step: "chroma_set",
                                            detail: "mode=\(next.rawValue) changed=\(changed)")
            if changed {
                applyColorConfig()
            } else {
                sendJson(["type": "chroma_active", "mode": currentChroma.rawValue])
                sendJson(["type": "force_canvas", "enabled": forceCanvasMode])
            }

        case .hdrSet(let enabled):
            let changed = enabled != currentHdr
            currentHdr = enabled
            ConnectionLogger.shared.logStep(sessionId: id.uuidString, step: "hdr_set",
                                            detail: "enabled=\(enabled) changed=\(changed)")
            if changed {
                applyColorConfig()
            } else {
                sendJson(["type": "hdr_active", "enabled": currentHdr])
                sendJson(["type": "force_canvas", "enabled": forceCanvasMode])
            }

        case .lowLatencySet(let enabled):
            let wasForceCanvas = forceCanvasMode
            lowLatencyZeroBuffer = enabled
            let nowForceCanvas = forceCanvasMode
            ConnectionLogger.shared.logStep(sessionId: id.uuidString, step: "low_latency_set",
                                            detail: "enabled=\(enabled) forceCanvas=\(nowForceCanvas)")
            if nowForceCanvas && usingRtpVideo {
                usingRtpVideo = false
                ConnectionLogger.shared.logStep(sessionId: id.uuidString,
                                                step: "video_transport",
                                                detail: "force_canvas(low_latency=\(enabled))")
            }
            if nowForceCanvas && !wasForceCanvas && !usingJpeg {
                if !autoUpgradeToH265IfEligible(reason: "force_canvas_low_latency") {
                    encoder?.forceKeyframe()
                }
            }
            sendJson(["type": "force_canvas", "enabled": nowForceCanvas])
            if nowForceCanvas && !wasForceCanvas && !usingJpeg, let last = lastFrame {
                encoder?.encode(last)
            }

        case .setAudioEnabled(let enabled):
            audioEnabled = enabled
            if enabled { startAudioStream() } else { stopAudioStream() }

        case .setMicEnabled(let enabled):
            if enabled {
                let player = micPlayer ?? MicPlayer()
                if player.start() {
                    micPlayer = player
                    micEnabled = true
                    sendJson([
                        "type": "mic_status",
                        "available": true,
                        "enabled": true,
                        "device": player.activeDeviceName
                    ])
                } else {
                    micEnabled = false
                    micPlayer = nil
                    sendJson([
                        "type": "mic_status",
                        "available": false,
                        "enabled": false,
                        "reason": "no_virtual_audio_device"
                    ])
                }
            } else {
                micEnabled = false
                micPlayer?.stop()
                micPlayer = nil
                sendJson(["type": "mic_status", "available": true, "enabled": false])
            }

        case .setPrivacyScreen(let enabled):
            Task { @MainActor in
                if enabled {
                    guard !PrivacyScreenManager.shared.isEnabled else { return }
                    PrivacyScreenManager.shared.enable()
                    // The overlay windows only exist now, but ScreenCapturer
                    // builds its SCContentFilter (which excludes them) once at
                    // stream start — without a rebuild the remote side would
                    // see the curtain instead of the desktop.
                    await rebuildPipeline()
                } else {
                    PrivacyScreenManager.shared.disable()
                }
            }

        case .displaySet(let did):
            guard did != selectedDisplayID else { break }
            selectedDisplayID = did
            Task { await rebuildPipeline() }

        case .virtualDisplay(let action, let w, let h, let fps):
            switch action.lowercased() {
            case "create":
                let targetW = UInt(min(max(w ?? 1920, 640), 5120)) & ~1
                let targetH = UInt(min(max(h ?? 1080, 480), 2880)) & ~1
                let targetFps = Double(max(fps ?? max(currentFps, 60), 30))
                if let vId = VirtualDisplayManager.shared.createOrUpdateVirtualDisplay(
                    logicalWidth: targetW,
                    logicalHeight: targetH,
                    refreshRate: targetFps,
                    scaleFactor: 2.0
                ) {
                    selectedDisplayID = vId
                    resolutionMaxDimension = nil
                    ConnectionLogger.shared.logStep(
                        sessionId: id.uuidString,
                        step: "virtual_display",
                        detail: "create id=\(vId) \(targetW)x\(targetH)@\(Int(targetFps))"
                    )
                    sendJson([
                        "type": "virtual_display_active",
                        "enabled": true,
                        "display_id": Int(vId)
                    ])
                    Task {
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        await rebuildPipeline()
                    }
                } else {
                    sendJson(["type": "virtual_display_active", "enabled": false])
                }

            case "destroy":
                let activeVId = VirtualDisplayManager.shared.activeDisplayID
                VirtualDisplayManager.shared.destroyVirtualDisplay()
                if let activeVId, selectedDisplayID == activeVId {
                    selectedDisplayID = nil
                }
                ConnectionLogger.shared.logStep(
                    sessionId: id.uuidString,
                    step: "virtual_display",
                    detail: "destroy"
                )
                sendJson(["type": "virtual_display_active", "enabled": false])
                Task {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    await rebuildPipeline()
                }

            default:
                break
            }

        case .ping:
            // encode_ms rides on the pong so the client's latency-breakdown
            // panel gets it with zero extra message traffic. On the RTP path
            // our VT encoder is idle (libwebrtc encodes internally) — its
            // last value is stale, report 0 rather than a lie.
            sendJson(["type": "pong",
                      "encode_ms": usingRtpVideo ? 0 : Int((encoder?.lastEncodeMs ?? 0).rounded())])

        case .requestKeyframe:
            // Shares the drop-triggered cooldown below: the client also sends
            // this when its own decode queue backs up (can't keep up in real
            // time, e.g. no hardware decoder). A keyframe is the biggest
            // possible frame — sending one immediately on every such signal
            // adds more work for a decoder that's already behind, which
            // triggers another overload signal right after, in a loop that
            // never lets it catch up. Debounce so at most one forced keyframe
            // goes out per second regardless of which path asked for it.
            keyframeRequests += 1
            let now = Date()
            let cooldown = Self.computeKeyframeCooldown(usingUdpVideo: usingUdpVideo, lossRatio: udpLastLossRatio, clientNotOnLan: clientNotOnLan)
            guard now.timeIntervalSince(lastForcedKeyframeAt) > cooldown else { break }
            lastForcedKeyframeAt = now
            keyframesForced += 1
            encoder?.forceKeyframe()
            // CGDisplayStream only calls onFrame when the screen content actually
            // changes — if it's static, forceKeyframe's flag would sit unused
            // indefinitely. Re-push the last captured frame right away so the
            // forced keyframe goes out immediately instead of waiting for the
            // next real screen change.
            if let last = lastFrame { encoder?.encode(last) }

        // ── WebRTC 信令 ────────────────────────────────────────
        case .webrtcOffer(let sdp):
            setupWebRTC(offerSDP: sdp)

        case .webrtcICE(let json):
            webrtc?.handleRemoteICE(json)

        case .udpPunch(let ip, let port):
            guard !ip.isEmpty, port > 0 else { break }
            ConnectionLogger.shared.logStep(sessionId: id.uuidString, step: "udp_punch", detail: "\(ip):\(port)")
            UdpVideoServer.shared.sendHolePunch(token: udpSessionToken, ip: ip, port: port)

        case .clientStats:
            break

        case .setCodec(let codec):
            manualCodecSelected = true
            if codec == "jpeg" {
                switchToJpeg()
            } else if let c = StreamCodec(rawValue: codec), c != currentCodec || usingJpeg {
                currentCodec = c
                usingJpeg = false
                webrtc?.preferredCodec = c.rawValue
                // On RTP, codec is negotiated by libwebrtc via SDP — remembering
                // preferredCodec ensures any subsequent renegotiation honors H.264/H.265.
                // Skip full pipeline rebuild while RTP is actively streaming (unless
                // forceCanvasMode is routing frames through VideoEncoder).
                guard !usingRtpVideo || forceCanvasMode else { break }
                // Codec is baked into the VTCompressionSession at creation, so
                // like a resolution change this needs the full pipeline rebuild.
                Task { await rebuildPipeline() }
            }

        case .codecCaps(let codecs):
            let supportsHevc = codecs.contains {
                let lower = $0.lowercased()
                return lower == "h265" || lower == "hevc"
            }
            clientSupportsH265 = supportsHevc
            ConnectionLogger.shared.logStep(
                sessionId: id.uuidString,
                step: "codec_caps",
                detail: "codecs=\(codecs.joined(separator: ",")) manual=\(manualCodecSelected) rtp=\(usingRtpVideo)"
            )
            if supportsHevc {
                _ = autoUpgradeToH265IfEligible(reason: "codec_caps")
            }

        case .listDir(let path):
            handleListDir(path)

        case .listDirRecursive(let path):
            handleListDirRecursive(path)

        case .requestFile(let path, let offset):
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            sendFile(url, offset: max(0, offset))

        case .setMuted(let muted):
            setSystemMuted(muted)

        case .ctrlAltDel:
            input?.keyEvent(code: "Delete", down: true,  modifiers: ["ctrl", "alt"])
            input?.keyEvent(code: "Delete", down: false, modifiers: ["ctrl", "alt"])

        case .setInputEnabled(let enabled):
            inputEnabled = enabled

        case .setReverseClipboardSync(let enabled):
            // Driven by the client's own tab-active state (DesktopPage's
            // isActive → Connection.setReverseClipboardActive), not just a
            // client-side filter on an always-on poll — see the field
            // comments on lastSentClipboardText for why: gating only on the
            // *receiving* end left a race where a background tab's target
            // could still push a message that lands and gets applied right
            // as the user switches away from (or into) a different tab,
            // clobbering the local clipboard with the wrong machine's
            // content. Actually stopping the poll on the inactive session's
            // agent — not merely ignoring what it sends — closes that
            // window instead of narrowing it.
            if enabled { startClipboardMonitor() } else { stopClipboardMonitor() }

        case .setInputLock(let locked):
            // Broadcasting the resulting state to every session (including
            // this one) happens via InputLocker.onLockChanged, wired once in
            // main.swift — not here, so it stays correct regardless of
            // whether the change came from a client request or the local
            // escape hatch.
            InputLocker.shared.setLocked(locked)

        case .lockScreen:
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession")
            task.arguments = ["-suspend"]
            try? task.run()

        case .logout:
            let script = "tell application \"System Events\" to log out"
            NSAppleScript(source: script)?.executeAndReturnError(nil)

        case .restart:
            let script = "tell application \"System Events\" to restart"
            NSAppleScript(source: script)?.executeAndReturnError(nil)

        case .powerAction(let action):
            ConnectionLogger.shared.logStep(sessionId: id.uuidString, step: "power_action", detail: action)
            PowerManager.shared.performAction(action)

        default:
            break
        }
    }

    // MARK: - OS 凭据验证（PAM checkpw → dscl 双保险，无需 root）

    private func validateOsCredentials(username: String, password: String) -> Bool {
        guard !username.isEmpty, !password.isEmpty else {
            ConnectionLogger.shared.logStep(sessionId: id.uuidString,
                step: "cred_empty", detail: "user=\(username) pwd_empty=\(password.isEmpty)")
            return false
        }

        // 1. PAM checkpw（最简配置：只有 pam_opendirectory.so，无需 root）
        let pamResult = pam_verify_password(username, password)
        ConnectionLogger.shared.logStep(sessionId: id.uuidString,
            step: "pam_result", detail: "user=\(username) code=\(pamResult)")
        if pamResult == 0 { return true }

        // 2. dscl 兜底（捕获 stderr 供调试）
        return dsclAuth(username: username, password: password)
    }

    private func dsclAuth(username: String, password: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/dscl")
        task.arguments = [".", "-authonly", username, password]
        task.standardOutput = Pipe()
        let stderrPipe = Pipe()
        task.standardError = stderrPipe
        do {
            try task.run()
            task.waitUntilExit()
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let ok = task.terminationStatus == 0
            ConnectionLogger.shared.logStep(sessionId: id.uuidString,
                step: "dscl_result", detail: "user=\(username) exit=\(task.terminationStatus) stderr=\(stderr)")
            return ok
        } catch {
            ConnectionLogger.shared.logStep(sessionId: id.uuidString,
                step: "dscl_error", detail: error.localizedDescription)
            return false
        }
    }

    // MARK: - WebRTC 信令设置

    private func setupWebRTC(offerSDP: String) {
        // A repeat offer on a live session is the client renegotiating after
        // an ICE failure (network roam / NAT rebind) — release the dead peer
        // connection before building its replacement.
        webrtc?.close()
        usingWebRTCVideo = false
        let agent = WebRTCAgent()
        agent.preferredCodec = currentCodec.rawValue
        agent.offLanHinted = clientNotOnLan
        agent.lanFloorAllowed = !clientNotOnLan
        agent.tunnelCapActive = clientNotOnLan && autoBitrateEnabled

        agent.onLocalDescription = { [weak self] type, sdp in
            self?.sendJson(["type": "webrtc_\(type)", "sdp": sdp])
        }
        agent.onICECandidate = { [weak self] json in
            self?.sendJson(["type": "webrtc_ice", "candidate": json])
        }
        agent.onConnected = {
            // JPEG 模式无需关键帧操作
        }
        agent.onDisconnected = { [weak self] in
            guard let self else { return }
            ConnectionLogger.shared.logStep(sessionId: self.id.uuidString, step: "webrtc_disconnected")
        }
        agent.onControlMessage = { [weak self] text in
            self?.handleText(text)
        }

        self.webrtc = agent

        Task {
            var turnServers: [RTCIceServer] = []
            if let ip = await PublicIPResolver.shared.current() {
                let cred = TurnCredentials.generate()
                let host = PublicIPResolver.shared.bracketedForURI(ip)
                turnServers = [RTCIceServer(
                    urlStrings: ["turn:\(host):7788?transport=udp"],
                    username: cred.username,
                    credential: cred.password
                )]
            }
            agent.handleOffer(offerSDP, turnServers: turnServers)
        }
    }

    // MARK: - 采集与 JPEG 编码

    /// Resolution and codec are both baked into a live SCStream /
    /// VTCompressionSession at creation — changing either stops the current
    /// capture and rebuilds everything from scratch via beginCapture(),
    /// which reads resolutionMaxDimension/currentFps/currentBitrate/
    /// currentCodec rather than hardcoded defaults so this preserves
    /// whatever was already active. Visible cost: a brief gap (fresh
    /// keyframe, decoder reset) while it rebuilds — acceptable since this
    /// only happens on an explicit, infrequent user choice, never
    /// automatically.
    private func rebuildPipeline() async {
        await capturer?.stop()
        await beginCapture()
        // beginCapture() always sets up the H.264/HEVC path — re-apply JPEG
        // if that's what this client actually needs (WebCodecs unavailable),
        // or it'd get silently switched back to a codec it can't decode.
        if usingJpeg { switchToJpeg() }
        // New ScreenCapturer instance → its onAudioSample is nil again.
        if audioEnabled { startAudioStream() }
    }

    // MARK: - 音频转发

    /// Idempotent: (re)wires the current capturer's audio callback into an
    /// AAC encoder whose output goes out as 0x03 binary frames. ~128kbps, so
    /// the plain fire-and-forget sendBinary path is plenty — no backpressure
    /// coupling with video.
    private func startAudioStream() {
        if audioEncoder == nil {
            let enc = AudioEncoder()
            enc.onEncodedFrame = { [weak self] data in
                guard let self, self.connection.isActive else { return }
                if self.usingUdpVideo {
                    let seq = self.audioSeq
                    self.audioSeq &+= 1
                    let nowMs = UInt32(Date().timeIntervalSince(self.connectTime ?? Date()) * 1000)
                    if UdpVideoServer.shared.sendAudioFrame(
                        token: self.udpSessionToken,
                        seq: seq,
                        ptsMs: nowMs,
                        data: data
                    ) {
                        self.bytesSent += Int64(data.count)
                        return
                    }
                }
                var pkt = Data(capacity: 1 + data.count)
                pkt.append(FrameType.audioFrame.rawValue)
                pkt.append(data)
                self.bytesSent += Int64(pkt.count)
                self.connection.sendBinary(pkt)
            }
            audioEncoder = enc
            ConnectionLogger.shared.logStep(sessionId: id.uuidString, step: "audio_stream", detail: "on")
        }
        capturer?.onAudioSample = { [weak self] sample in
            self?.audioEncoder?.encode(sample)
        }
    }

    private func stopAudioStream() {
        capturer?.onAudioSample = nil
        audioEncoder = nil
        ConnectionLogger.shared.logStep(sessionId: id.uuidString, step: "audio_stream", detail: "off")
    }

    // MARK: - 被控端连接通知

    /// Posts a macOS notification on this (the controlled) machine when a
    /// client connects/disconnects — whoever is sitting at it deserves to
    /// know it's being viewed. Via osascript rather than
    /// UNUserNotificationCenter: the latter requires a user-approved
    /// notification permission (an extra setup prompt on every machine this
    /// ad-hoc-signed app is dropped onto), osascript needs none.
    private func notifyUser(connected: Bool) {
        // endpoint looks like "[IPv4]1.2.3.4/1.2.3.4:56789" — keep just the ip:port
        let addr = connection.endpoint.split(separator: "/").last.map(String.init) ?? connection.endpoint
        let text = connected ? "远程控制已连接：\(addr)" : "远程控制已断开：\(addr)"
        // Escape for embedding in the AppleScript string literal.
        let safe = text.replacingOccurrences(of: "\\", with: "\\\\")
                       .replacingOccurrences(of: "\"", with: "\\\"")
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "display notification \"\(safe)\" with title \"Remoter\""]
            try? p.run()
        }
    }

    /// Broadcast target for InputLocker.onLockChanged (wired in main.swift) —
    /// lets every connected client's lock toggle stay accurate regardless of
    /// whether the state changed via a client request or the local escape
    /// hatch (Control+Option+Command+Escape).
    func notifyInputLockChanged(locked: Bool) {
        sendJson(["type": "input_lock_changed", "locked": locked])
    }

    // MARK: - 光标形状同步

    /// The client hides the captured cursor and draws its own local pointer
    /// (zero-latency position); this feeds it the *shape* the remote system
    /// is currently showing (text beam, resize arrows, hand, …) so the local
    /// pointer doesn't stay a plain arrow everywhere. Idempotent.
    private func startCursorMonitor() {
        guard cursorMonitor == nil else { return }
        let m = CursorMonitor()
        m.onCursorChanged = { [weak self] pngBase64, hotX, hotY, w, h in
            guard let self, self.connection.isActive else { return }
            self.sendJson([
                "type": "cursor_shape",
                "png":  pngBase64,
                "hot_x": hotX, "hot_y": hotY,
                "width": w, "height": h,
            ])
        }
        m.start()
        cursorMonitor = m
    }

    private func setupVideoEncoder(width: Int, height: Int) throws {
        encoder?.close()
        let enc = VideoEncoder()
        try enc.setup(
            width: width,
            height: height,
            fps: currentFps,
            bitrateBps: currentBitrate,
            codec: currentCodec,
            chroma444: currentChroma == .yuv444,
            hdr: currentHdr
        )
        enc.onEncodedFrame = { [weak self] data, isKeyframe in
            guard let self else { return }
            guard self.connection.isActive else { return }

            let fid = self.frameId
            self.frameId &+= 1
            self.bytesSent += Int64(data.count)
            let nowMs = UInt32(Date().timeIntervalSince(self.connectTime ?? Date()) * 1000)

            // 1. Direct low-latency UDP video channel (native clients / WebCodecs path)
            if !self.usingRtpVideo && self.usingUdpVideo,
               UdpVideoServer.shared.sendVideoFrame(
                   token: self.udpSessionToken,
                   frameId: fid,
                   ptsMs: nowMs,
                   data: data,
                   isKeyframe: isKeyframe,
                   isHEVC: self.currentCodec == .h265
               ) {
                self.recordSentFrame()
            } else if let webrtc = self.webrtc, webrtc.isVideoChannelOpen {
                // 2. WebRTC DataChannel fallback
                if !self.usingWebRTCVideo {
                    self.usingWebRTCVideo = true
                    ConnectionLogger.shared.logStep(sessionId: self.id.uuidString,
                        step: "video_transport", detail: "webrtc")
                }
                if webrtc.sendVideoFrame(data, isKeyframe: isKeyframe, frameId: fid) {
                    self.recordSentFrame()
                } else {
                    self.backpressureDrops += 1
                    let now = Date()
                    if now.timeIntervalSince(self.lastForcedKeyframeAt) > 1.0 {
                        self.lastForcedKeyframeAt = now
                        self.keyframesForced += 1
                        self.encoder?.forceKeyframe()
                    }
                }
            } else {
                // 3. WebSocket TCP fallback
                if self.usingWebRTCVideo {
                    self.usingWebRTCVideo = false
                    ConnectionLogger.shared.logStep(sessionId: self.id.uuidString,
                        step: "video_transport", detail: "websocket")
                }
                guard self.wsSendSem.wait(timeout: .now()) == .success else {
                    self.backpressureDrops += 1
                    let now = Date()
                    if now.timeIntervalSince(self.lastForcedKeyframeAt) > 1.0 {
                        self.lastForcedKeyframeAt = now
                        self.keyframesForced += 1
                        self.encoder?.forceKeyframe()
                    }
                    return
                }
                let pkt = buildVideoFramePacket(data: data, frameId: fid, ptsMs: nowMs, isKeyframe: isKeyframe)
                self.connection.sendBinaryVideo(pkt) {
                    self.wsSendSem.signal()
                    self.recordSentFrame()
                }
            }

            if fid == 0 {
                ConnectionLogger.shared.logStep(sessionId: self.id.uuidString,
                    step: "first_frame_h264", detail: "\(data.count)B keyframe=\(isKeyframe)")
            }
        }
        encoder = enc
    }

    /// Automatically upgrades the encoder to H.265 (HEVC) when the client
    /// advertised hardware HEVC decode support via `codec_caps`, no manual
    /// codec was pinned, and the session is on a non-RTP path (native UDP/WS
    /// or Web `forceCanvasMode`). Falls back safely to H.264 if HEVC init fails.
    /// Returns `true` if the encoder was rebuilt to H.265.
    @discardableResult
    private func autoUpgradeToH265IfEligible(reason: String) -> Bool {
        guard clientSupportsH265,
              !manualCodecSelected,
              !usingJpeg,
              (!usingRtpVideo || forceCanvasMode),
              currentCodec != .h265 else {
            return false
        }

        let previousCodec = currentCodec
        currentCodec = .h265
        guard let c = capturer else {
            // beginCapture() hasn't finished yet; it will read currentCodec == .h265.
            ConnectionLogger.shared.logStep(
                sessionId: id.uuidString,
                step: "codec_auto_negotiated",
                detail: "h265 reason=\(reason) deferred=true"
            )
            return true
        }

        do {
            try setupVideoEncoder(width: c.screenWidth, height: c.screenHeight)
            encoder?.forceKeyframe()
            webrtc?.preferredCodec = StreamCodec.h265.rawValue
            ConnectionLogger.shared.logStep(
                sessionId: id.uuidString,
                step: "codec_auto_negotiated",
                detail: "h265 reason=\(reason)"
            )
            sendJson(["type": "codec_changed", "codec": StreamCodec.h265.rawValue])
            if let last = lastFrame {
                encoder?.encode(last)
            }
            return true
        } catch {
            currentCodec = previousCodec
            ConnectionLogger.shared.logStep(
                sessionId: id.uuidString,
                step: "codec_auto_negotiated_fallback",
                detail: "codec=\(previousCodec.rawValue) err=\(error)"
            )
            try? setupVideoEncoder(width: c.screenWidth, height: c.screenHeight)
            return false
        }
    }

    private func applyColorConfig() {
        let forceCanvas = forceCanvasMode
        capturer?.updateColorConfig(chroma: currentChroma, hdr: currentHdr)

        var autoUpgradedHevc = false
        if forceCanvas && clientSupportsH265 && !manualCodecSelected && !usingJpeg && currentCodec != .h265 {
            currentCodec = .h265
            autoUpgradedHevc = true
        }

        if !usingJpeg, let c = capturer {
            do {
                try setupVideoEncoder(width: c.screenWidth, height: c.screenHeight)
                encoder?.forceKeyframe()
                if autoUpgradedHevc {
                    webrtc?.preferredCodec = StreamCodec.h265.rawValue
                    ConnectionLogger.shared.logStep(
                        sessionId: id.uuidString,
                        step: "codec_auto_negotiated",
                        detail: "h265 reason=force_canvas_color"
                    )
                    sendJson(["type": "codec_changed", "codec": StreamCodec.h265.rawValue])
                }
            } catch {
                if autoUpgradedHevc {
                    currentCodec = .h264
                    ConnectionLogger.shared.logStep(
                        sessionId: id.uuidString,
                        step: "codec_auto_negotiated_fallback",
                        detail: "codec=h264 err=\(error)"
                    )
                    try? setupVideoEncoder(width: c.screenWidth, height: c.screenHeight)
                    encoder?.forceKeyframe()
                } else {
                    ConnectionLogger.shared.logStep(
                        sessionId: id.uuidString,
                        step: "color_encoder_rebuild_failed",
                        detail: "\(error)"
                    )
                }
            }
        }

        if forceCanvas && usingRtpVideo {
            usingRtpVideo = false
            ConnectionLogger.shared.logStep(
                sessionId: id.uuidString,
                step: "video_transport",
                detail: "force_canvas(chroma=\(currentChroma.rawValue),hdr=\(currentHdr))"
            )
        }

        sendJson(["type": "chroma_active", "mode": currentChroma.rawValue])
        sendJson(["type": "hdr_active", "enabled": currentHdr])
        sendJson(["type": "force_canvas", "enabled": forceCanvas])

        // If switching into forceCanvas on a static screen, push the last frame
        // so the WebCodecs decoder immediately receives a fresh keyframe.
        if forceCanvas, !usingJpeg, let last = lastFrame {
            encoder?.encode(last)
        }
    }

    private func sendCurrentUdpOffer() {
        let udpPort = UdpVideoServer.shared.listeningPort
        guard udpPort > 0, !isClosed else { return }
        var udpOffer: [String: Any] = [
            "type": "udp_offer",
            "port": Int(udpPort),
            "session_token": udpSessionTokenHex,
            "encrypted": (crypto.rawKeyData != nil)
        ]
        if let pub = UdpVideoServer.shared.publicEndpoint {
            udpOffer["publicIp"] = pub.ip
            udpOffer["publicPort"] = Int(pub.port)
        }
        sendJson(udpOffer)
    }

    /// Automatically re-offers UDP after a transient network blip causes `ws_fallback`,
    /// so sessions never get permanently trapped on WebSocket TCP!
    private func scheduleUdpReoffer(delaySeconds: TimeInterval) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delaySeconds) { [weak self] in
            guard let self, !self.isClosed, self.authenticated, !self.usingUdpVideo, !self.usingRtpVideo else { return }
            ConnectionLogger.shared.logStep(sessionId: self.id.uuidString, step: "udp_reoffer_sent", detail: "delay=\(Int(delaySeconds))s")
            self.sendCurrentUdpOffer()
            self.scheduleUdpReoffer(delaySeconds: 20.0)
        }
    }

    private func beginCapture() async {
        Self.registerAndReapStaleSessions(newSession: self)
        let c   = ScreenCapturer()
        let sid = id.uuidString
        ConnectionLogger.shared.logStep(sessionId: sid, step: "capture_begin", detail: "jpeg")
        do {
            ConnectionLogger.shared.logStep(sessionId: sid, step: "capturer_start")
            // currentFps defaults to 30 (matches the client's default "自动"
            // preset) on a fresh session, or carries over whatever was
            // already active when this is a resolution-switch re-run.
            try await c.start(fps: currentFps, maxDimension: effectiveMaxDimension,
                              displayID: selectedDisplayID,
                              chroma: currentChroma, hdr: currentHdr)
            ConnectionLogger.shared.logStep(sessionId: sid, step: "capturer_ready",
                                            detail: "\(c.screenWidth)x\(c.screenHeight)")
            capturer     = c
            input        = InputController(screenWidth: Int(c.pointWidth.rounded()),
                                           screenHeight: Int(c.pointHeight.rounded()),
                                           originX: c.originX, originY: c.originY)
            fileReceiver = FileReceiver()
            connectTime  = Date()

            // Set up the video encoder (H.264 default, HEVC if the client
            // opted in) — same currentFps/currentBitrate/chroma/hdr carry-over as above.
            try setupVideoEncoder(width: c.screenWidth, height: c.screenHeight)

            ConnectionLogger.shared.logConnected(sessionId: sid, codec: currentCodec.rawValue, encrypted: crypto.isReady)
            if !displayAwakeHeld {
                displayAwakeHeld = true
                PowerManager.shared.setDisplayActive(true)
            }
            startKeepalive()
            // Remote cursor shape sync intentionally disabled so clients keep their native local cursor.
            sendJson([
                "type":   "stream_started",
                "width":  c.screenWidth,
                "height": c.screenHeight,
                "codec":  currentCodec.rawValue,
                "displays": c.displays.map { ["id": Int($0.id), "name": $0.name,
                                              "width": $0.width, "height": $0.height] },
                "display": Int(selectedDisplayID ?? CGMainDisplayID())
            ])

            if let activeVId = VirtualDisplayManager.shared.activeDisplayID {
                sendJson([
                    "type": "virtual_display_active",
                    "enabled": true,
                    "display_id": Int(activeVId)
                ])
            }

            let udpPort = UdpVideoServer.shared.listeningPort
            if udpPort > 0 {
                let cryptoKey = crypto.rawKeyData
                UdpVideoServer.shared.registerSession(
                    token: udpSessionToken,
                    aesKey: cryptoKey,
                    allowFecSuppression: !clientNotOnLan,
                    onActivated: { [weak self] active in
                        guard let self, !self.isClosed else { return }
                        self.usingUdpVideo = active
                        if !active {
                            self.udpCleanBitrateStreak = 0
                            self.udpLearnedCeilingBps = nil
                            self.udpStableAtCapStreak = 0
                            self.udpLastLossRatio = 0
                            self.scheduleUdpReoffer(delaySeconds: 8.0)
                        }
                        ConnectionLogger.shared.logStep(
                            sessionId: self.id.uuidString,
                            step: "video_transport",
                            detail: active ? "udp" : "ws_fallback"
                        )
                        self.sendJson(["type": "udp_active", "enabled": active])
                        if active {
                            var qualityBumped = false
                            if !self.manualFpsSelected && self.currentFps < 60 {
                                self.applyFps(60, notify: false)
                                qualityBumped = true
                            }
                            if !self.manualBitrateSelected && self.currentBitrate < 6_000_000 {
                                self.applyBitrate(6_000_000, notify: false)
                                qualityBumped = true
                            }
                            if qualityBumped {
                                self.notifyQualityActive()
                            }
                            self.encoder?.forceKeyframe()
                        }
                    },
                    onLossFeedback: { [weak self] lossRatio, sentPackets in
                        guard let self, !self.isClosed else { return }
                        self.handleUdpLossFeedback(lossRatio, sentPackets: sentPackets)
                    },
                    onTransportFeedback: { [weak self] delayGradMs, lossRatio, jitterMs, recvBps in
                        guard let self, !self.isClosed else { return }
                        self.handleUdpTransportFeedback(
                            delayGradientMs: delayGradMs,
                            lossRatio: lossRatio,
                            jitterMs: jitterMs,
                            recvBps: recvBps
                        )
                    },
                    onInputMessage: { [weak self] jsonText in
                        guard let self, !self.isClosed else { return }
                        self.handleText(jsonText)
                    }
                )
                UdpVideoServer.shared.refreshPublicEndpointAsync()
                UdpVideoServer.shared.updatePacingBitrate(token: udpSessionToken, bitrateBps: currentBitrate)
                sendCurrentUdpOffer()
            }

            c.onFrame = { [weak self] pixelBuffer, _, _ in
                guard let self else { return }
                self.lastFrame = pixelBuffer
                // RTP media track first: raw buffer straight into libwebrtc
                // (it encodes + paces + congestion-controls internally). Our
                // own VT encoder + WS/DataChannel path stays as the fallback
                // whenever the media track isn't up OR when 4:4:4 / 10-bit HDR
                // requires forceCanvasMode (standard WebRTC RTP only carries
                // 8-bit 4:2:0).
                if !self.forceCanvasMode, let webrtc = self.webrtc, webrtc.isMediaReady {
                    if !self.usingRtpVideo {
                        self.usingRtpVideo = true
                        ConnectionLogger.shared.logStep(sessionId: self.id.uuidString,
                            step: "video_transport", detail: "rtp")
                        var qualityBumped = false
                        if self.autoBitrateEnabled {
                            self.applyBitrate(Self.autoBitrateTiers.last!, notify: false)
                            qualityBumped = true
                        } else {
                            webrtc.setMaxBitrate(self.currentBitrate)
                        }
                        if self.autoFpsEnabled {
                            self.autoFpsIndex = self.autoFpsTopIndex
                            self.applyFps(Self.autoFpsTiers[self.autoFpsIndex], notify: false)
                            qualityBumped = true
                        }
                        if qualityBumped { self.notifyQualityActive() }
                    }
                    webrtc.sendVideoBuffer(pixelBuffer)
                    self.recordSentFrame()
                } else {
                    if self.usingRtpVideo {
                        self.usingRtpVideo = false
                        ConnectionLogger.shared.logStep(sessionId: self.id.uuidString,
                            step: "video_transport", detail: self.forceCanvasMode ? "force_canvas" : "fallback")
                    }
                    self.encoder?.encode(pixelBuffer)
                }
            }

            c.onStaticFrameReady = { [weak self] pixelBuffer in
                guard let self, !self.isClosed, !self.usingJpeg else { return }
                if !self.forceCanvasMode, let webrtc = self.webrtc, webrtc.isMediaReady {
                    webrtc.sendRefinementFrame(pixelBuffer)
                } else {
                    self.encoder?.encodeRefinementFrame(pixelBuffer)
                }
            }

            // CGDisplayStream stops when macOS locks the screen, goes to sleep,
            // or revokes screen recording permission. Restart the stream so the
            // client resumes automatically when the display comes back.
            c.onStopped = { [weak self] in
                guard let self, !self.isClosed else { return }
                Task {
                    try? await Task.sleep(nanoseconds: 1_000_000_000) // wait 1s for display to wake
                    await self.beginCapture()
                }
            }
        } catch {
            let msg = "\(error)"
            ConnectionLogger.shared.logCaptureError(sessionId: sid, error: msg)
            sendJsonRaw(["type": "error", "code": "capture_failed", "message": msg])
        }
    }

    // Client requested fallback to JPEG (e.g. WebCodecs unavailable on this platform)
    private func switchToJpeg() {
        guard let c = capturer else { return }
        usingJpeg = true
        encoder?.close()
        encoder = nil
        ConnectionLogger.shared.logStep(sessionId: id.uuidString, step: "codec_switch", detail: "h264→jpeg")
        sendJson([
            "type":   "stream_started",
            "width":  c.screenWidth,
            "height": c.screenHeight,
            "codec":  "jpeg"
        ])
        c.onFrame = { [weak self] pixelBuffer, _, _ in
            guard let self else { return }
            var cgImage: CGImage?
            VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cgImage)
            guard let cgImage, let jpeg = Self.encodeJPEG(cgImage, quality: self.jpegQuality) else { return }
            guard self.connection.isActive else { return }
            guard self.wsSendSem.wait(timeout: .now()) == .success else { return }
            let fid = self.frameId
            self.frameId &+= 1
            self.bytesSent += Int64(jpeg.count)
            let now = UInt32(Date().timeIntervalSince(self.connectTime ?? Date()) * 1000)
            let pkt = buildVideoFramePacket(data: jpeg, frameId: fid, ptsMs: now, isKeyframe: true)
            self.connection.sendBinaryVideo(pkt) {
                self.wsSendSem.signal()
            }
        }
    }

    /// 统一的发送计数/FPS 日志，WebRTC 和 WebSocket 两条视频路径共用。
    private func recordSentFrame() {
        sentFrames += 1
        let dt = Date().timeIntervalSince(sentTick)
        if dt >= 5 {
            let transportLabel = usingRtpVideo ? "rtp" : (usingUdpVideo ? "udp" : (usingWebRTCVideo ? "webrtc" : "ws"))
            let capKbps = (udpLearnedCeilingBps ?? (clientNotOnLan ? Self.wanMaxBitrateBps : (Self.autoBitrateTiers.last ?? 40_000_000))) / 1000
            let lossPct = String(format: "%.1f%%", udpLastLossRatio * 100.0)
            ConnectionLogger.shared.logStep(sessionId: id.uuidString,
                step: "sent_5s", detail: "sent=\(sentFrames) fps=\(String(format: "%.0f", Double(sentFrames)/dt)) transport=\(transportLabel) br=\(currentBitrate/1000)k cap=\(capKbps)k loss=\(lossPct) bpDrops=\(backpressureDrops) kfForced=\(keyframesForced) kfReq=\(keyframeRequests)")
            // On RTP, libwebrtc's GCC owns adaptation; on direct UDP,
            // handleUdpLossFeedback owns bitrate adaptation and a single lost
            // UDP packet's kfReq must NEVER slash 60fps -> 30fps. Only run
            // evaluateAutoQuality() on the WS/DataChannel fallback transport.
            if !usingRtpVideo && !usingUdpVideo && (autoFpsEnabled || autoBitrateEnabled) { evaluateAutoQuality() }
            sentFrames = 0
            backpressureDrops = 0
            keyframesForced = 0
            keyframeRequests = 0
            sentTick = Date()
        }
    }

    /// Steps fps and bitrate with separate tier ladders, but not fully
    /// independent signals: fps only cares about decode overload (kfReq),
    /// while bitrate cares about *both* decode overload and network
    /// backpressure (bpDrops) — a bigger bitrate means bigger frames, which
    /// cost more to decode regardless of fps, so bitrate can't be allowed
    /// to climb while the client is already struggling to decode. Steps
    /// down immediately on any sign of trouble; steps up only after several
    /// consecutive clean windows, so it settles instead of oscillating
    /// right at the edge of what the client/link can sustain.
    private func evaluateAutoQuality() {
        guard !usingRtpVideo && !usingUdpVideo else { return }
        var fpsChanged = false
        var bitrateChanged = false

        let decodeOverloaded = keyframeRequests > 0

        if autoFpsEnabled {
            if decodeOverloaded {
                autoFpsCleanStreak = 0
                if autoFpsIndex > 0 { autoFpsIndex -= 1; fpsChanged = true }
            } else {
                autoFpsCleanStreak += 1
                if autoFpsCleanStreak >= 3 && autoFpsIndex < autoFpsTopIndex {
                    autoFpsCleanStreak = 0
                    autoFpsIndex += 1
                    fpsChanged = true
                }
            }
        }

        if autoBitrateEnabled {
            // A bigger bitrate means bigger, more expensive-to-decode frames
            // — decode cost isn't just a function of fps. Ignoring
            // decodeOverloaded here (treating bitrate as purely a network
            // concern) let bitrate climb to its max tier in the same breath
            // fps was stepping down to *fix* a decode-overloaded client,
            // handing it even bigger frames while it was already behind —
            // a real regression that made "auto" oscillate and never
            // settle. Both signals now gate both directions.
            if backpressureDrops > 0 || decodeOverloaded {
                autoBitrateCleanStreak = 0
                if autoBitrateIndex > 0 { autoBitrateIndex -= 1; bitrateChanged = true }
            } else {
                autoBitrateCleanStreak += 1
                let requiredClean = clientNotOnLan ? 3 : 1
                if autoBitrateCleanStreak >= requiredClean && autoBitrateIndex < Self.autoBitrateTiers.count - 1 {
                    autoBitrateCleanStreak = 0
                    autoBitrateIndex += 1
                    bitrateChanged = true
                }
            }
        }

        guard fpsChanged || bitrateChanged else { return }
        if fpsChanged { applyFps(Self.autoFpsTiers[autoFpsIndex], notify: false) }
        if bitrateChanged { applyBitrate(Self.autoBitrateTiers[autoBitrateIndex], notify: false) }
        ConnectionLogger.shared.logStep(sessionId: id.uuidString, step: "auto_quality_step",
            detail: "fps=\(currentFps) bitrate=\(currentBitrate)")
        notifyQualityActive()
    }

    /// Applies fps (used by both manual selection and auto stepping).
    /// notify=false lets evaluateAutoQuality() batch a single combined
    /// notice when it changes fps and bitrate in the same step, instead of
    /// sending two back-to-back messages for one logical update.
    /// Holds boosted encoder bitrate until 1.2s after the last scroll event,
    /// ensuring moving text remains crisp without pausing/reconfiguring SCStream.
    private func cancelScrollBoost() {
        scrollBoostLock.lock()
        scrollBoostGen += 1
        scrollBoostActive = false
        scrollBoostLock.unlock()
    }

    private func boostBitrateWhileScrolling() {
        // RTP: only the ceiling would move (GCC picks the real rate), and each
        // start/end rewrites the sender's encoding parameters — churn for no
        // effect. The boost only means something for the local VT encoder.
        guard !usingRtpVideo else { return }
        // Scroll burst allowance: independent of the bitrate boost below (which is skipped on a
        // capped WAN link). Without it VideoToolbox drops frames while scrolling at low bitrate
        // (fps tracks bitrate), which is what makes WAN scrolling look janky.
        if udpLastLossRatio < 0.05 {
            scrollBoostLock.lock()
            scrollBurstGen += 1
            let burstGen = scrollBurstGen
            scrollBoostLock.unlock()
            encoder?.setScrollBoost(true)
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self else { return }
                self.scrollBoostLock.lock()
                let latest = burstGen == self.scrollBurstGen
                self.scrollBoostLock.unlock()
                if latest { self.encoder?.setScrollBoost(false) }
            }
        }
        // Never boost above a congested or loss-capped WAN/tunnel link: doing
        // 1.5x bitrate on top of FEC during active scrolling blows past the
        // tunnel ceiling and causes 10-40% packet loss + keyframe freezes.
        if udpLastLossRatio >= 0.02 { return }
        if clientNotOnLan && udpLearnedCeilingBps != nil { return }

        scrollBoostLock.lock()
        scrollBoostGen += 1
        let gen = scrollBoostGen
        let starting = !scrollBoostActive
        scrollBoostActive = true
        scrollBoostLock.unlock()

        if starting {
            let cap = udpLearnedCeilingBps ?? (clientNotOnLan ? Self.wanMaxBitrateBps : 50_000_000)
            let boosted = min(Int(Double(currentBitrate) * 1.5), cap)
            if boosted > currentBitrate {
                encoder?.setBitrate(boosted)
                webrtc?.setMaxBitrate(boosted)
                UdpVideoServer.shared.updatePacingBitrate(token: udpSessionToken, bitrateBps: boosted)
            }
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            self.scrollBoostLock.lock()
            guard gen == self.scrollBoostGen else { self.scrollBoostLock.unlock(); return }
            self.scrollBoostActive = false
            self.scrollBoostLock.unlock()
            self.encoder?.setBitrate(self.currentBitrate)
            self.webrtc?.setMaxBitrate(self.currentBitrate)
            UdpVideoServer.shared.updatePacingBitrate(token: self.udpSessionToken, bitrateBps: self.currentBitrate)
        }
    }

    /// Dynamic UDP bitrate adaptation driven by UdpVideoServer's 2s loss feedback:
    /// - Resolution-aware quality floor (LAN: 5M/4M, WAN/tunnel: 1.5M/1.2M so FEC overhead
    ///   never pushes total wire rate back over the bottleneck ceiling).
    /// - Never suppressed during scrollBoost on loss: congestion immediately cancels scrollBoost
    ///   and steps bitrate down.
    /// - Below learned ceiling: step up +15% after 3 clean active windows (6s).
    /// - At learned ceiling: hold for 15s cooldown + 5 clean active windows (10s), then probe +15%.
    /// Pure keyframe throttle shared by `requestKeyframe` and regression self-tests:
    /// 0.4s when clean, 0.8s under moderate loss (>=3%), 1.5s under heavy loss (>=15%)
    /// so a 20-40% WAN burst never triggers a self-inflicted keyframe storm.
    static func computeKeyframeCooldown(usingUdpVideo: Bool, lossRatio: Double, clientNotOnLan: Bool = false) -> TimeInterval {
        guard usingUdpVideo else { return 1.0 }
        if lossRatio >= 0.15 { return 1.5 }
        if lossRatio >= 0.03 { return 0.8 }
        // Off-LAN: a keyframe needs ~0.2-0.3s to drain and the client re-requests every 450ms
        // while it waits, so a 0.4s cooldown let requests stack up into back-to-back keyframes.
        return clientNotOnLan ? 0.8 : 0.4
    }

    /// Extreme-congestion survival guard: never let the user freeze under severe WAN loss.
    /// - Instant trigger: >= 20% loss in a single 2s window -> immediately drop to 30fps.
    /// - Sustained trigger: >= 10% loss for 2 consecutive 2s windows (4s) -> drop to 30fps.
    /// - Fast restore: < 2.5% loss for 2 consecutive 2s windows (4s) -> restore original FPS.
    struct UdpSevereFpsGuard {
        var severeLossStreak: Int = 0
        var cleanRestoreStreak: Int = 0
        var savedFps: Int? = nil

        mutating func step(
            lossRatio: Double,
            sentPackets: UInt64,
            currentFps: Int,
            manualFpsSelected: Bool
        ) -> Int? {
            guard !manualFpsSelected else {
                severeLossStreak = 0
                cleanRestoreStreak = 0
                savedFps = nil
                return nil
            }
            if lossRatio >= 0.20 && sentPackets >= 80 {
                cleanRestoreStreak = 0
                severeLossStreak = 0
                if currentFps > 30 && savedFps == nil {
                    savedFps = currentFps
                    return 30
                }
            } else if lossRatio >= 0.10 && sentPackets >= 100 {
                cleanRestoreStreak = 0
                severeLossStreak += 1
                if severeLossStreak >= 2 && currentFps > 30 && savedFps == nil {
                    severeLossStreak = 0
                    savedFps = currentFps
                    return 30
                }
            } else if lossRatio < 0.025 {
                severeLossStreak = 0
                if let target = savedFps {
                    cleanRestoreStreak += 1
                    if cleanRestoreStreak >= 2 {
                        cleanRestoreStreak = 0
                        savedFps = nil
                        return target
                    }
                }
            } else {
                severeLossStreak = 0
                cleanRestoreStreak = 0
            }
            return nil
        }
    }

    /// Pure UDP bitrate adaptation state machine shared by `handleUdpLossFeedback` and regression tests.
    /// Weak-network anti-freeze design: allow bitrate to drop as low as 800k (2K) / 600k (1080p)
    /// with severity-proportional backoff so the stream stays fluid instead of stalling, then
    /// rapidly ramp back up once loss clears (< 1.5%).
    struct UdpBitrateState {
        var currentBitrate: Int
        var learnedCeilingBps: Int? = nil
        var lossCapSetAt: Double = 0
        var cleanStreak: Int = 0
        var stableAtCapStreak: Int = 0

        enum StepAction: Equatable {
            case hold
            case down(Int)
            case up(Int)
            case probeUp(Int)
        }

        mutating func step(
            lossRatio: Double,
            sentPackets: UInt64,
            now: Double,
            clientNotOnLan: Bool,
            screenWidth: Int,
            scrollBoostActive: Bool
        ) -> StepAction {
            let hardCeilingBps = clientNotOnLan ? Session.wanMaxBitrateBps : 40_000_000
            // Keep WAN floor readable (1.5M 2K / 1.2M 1080p) so text stays legible and
            // VideoToolbox never starves, while still cutting WAN traffic 4-5x under congestion.
            let floorBps = clientNotOnLan
                ? ((screenWidth >= 2560) ? 1_500_000 : 1_200_000)
                : ((screenWidth >= 2560) ? 5_000_000 : 4_000_000)
            let minLossPackets: UInt64 = clientNotOnLan ? 80 : 400
            // WireGuard here sits at a steady 0.5-5% loss that FEC already absorbs; 5% kept re-triggering
            // cuts and the ceiling stayed pinned near the 1.5 Mbps floor (42 of 68 adapts on 11-26).
            let lossThreshold: Double = clientNotOnLan ? 0.07 : 0.08
            // At low bitrate (< 3 Mbps), a single NACK out of ~60 packets is 1.67%, so allow
            // recovery whenever loss < 3% instead of locking the user at the blurry floor!
            let cleanLossThreshold: Double = (currentBitrate < 3_000_000) ? 0.03 : 0.015

            if lossRatio >= lossThreshold && sentPackets >= minLossPackets {
                cleanStreak = 0
                stableAtCapStreak = 0
                let dropFactor: Double
                let capFactor: Double
                if lossRatio >= 0.25 {
                    dropFactor = 0.50
                    capFactor = 0.58
                } else if lossRatio >= 0.12 {
                    dropFactor = 0.65
                    capFactor = 0.72
                } else {
                    dropFactor = 0.75
                    capFactor = 0.80
                }
                let nextBps = max(floorBps, min(hardCeilingBps, Int((Double(currentBitrate) * dropFactor).rounded())))
                let learnedCap = max(floorBps, min(hardCeilingBps, Int((Double(currentBitrate) * capFactor).rounded())))
                learnedCeilingBps = max(floorBps, min(learnedCeilingBps ?? hardCeilingBps, learnedCap))
                lossCapSetAt = now
                currentBitrate = nextBps
                return .down(nextBps)
            } else if lossRatio < cleanLossThreshold {
                guard !scrollBoostActive else { return .hold }
                let effectiveCeiling = max(floorBps, min(hardCeilingBps, learnedCeilingBps ?? hardCeilingBps))

                if currentBitrate < effectiveCeiling {
                    // Below the already-proven ceiling, allow quick recovery even while idle
                    let minRampPackets: UInt64 = (currentBitrate < 2_500_000) ? 10 : 60
                    guard sentPackets >= minRampPackets else { return .hold }
                    stableAtCapStreak = 0
                    cleanStreak += 1
                    let requiredClean = (currentBitrate < 2_500_000) ? 1 : 2
                    if cleanStreak >= requiredClean {
                        cleanStreak = 0
                        let stepFactor: Double = (currentBitrate < 2_500_000) ? 1.40 : 1.20
                        let nextBps = max(floorBps, min(effectiveCeiling, Int((Double(currentBitrate) * stepFactor).rounded())))
                        if nextBps != currentBitrate {
                            currentBitrate = nextBps
                            return .up(nextBps)
                        }
                    }
                } else if let cap = learnedCeilingBps {
                    cleanStreak = 0
                    // Anti-sawtooth & app-limited probing guard:
                    // - Below 1.8 Mbps (recovering from severe drop), allow quick 4s recovery
                    //   so text never stays blurry after a brief burst.
                    // - Between 1.8M and 2.5M, HOLD the learned ceiling for 12s + 3 clean windows
                    //   and probe gently (+12%) so we NEVER sawtooth 2.0M -> 2.5M -> loss every 4s!
                    // - Above 2.5M, additionally require real active load (>=320 pkts/2s) so idle
                    //   sessions never hallucinate 5-8M ceilings.
                    let blurryFloorRecoveryBps = clientNotOnLan ? 1_800_000 : 5_000_000
                    let activeProbeThresholdBps = clientNotOnLan ? 2_500_000 : 5_000_000
                    if cap < blurryFloorRecoveryBps {
                        guard sentPackets >= 10 else { return .hold }
                        guard now - lossCapSetAt >= 4.0 else { return .hold }
                        stableAtCapStreak += 1
                        if stableAtCapStreak >= 2 {
                            stableAtCapStreak = 0
                            let probedCap = min(blurryFloorRecoveryBps, Int((Double(cap) * 1.25).rounded()))
                            learnedCeilingBps = probedCap >= hardCeilingBps ? nil : probedCap
                            if probedCap > currentBitrate {
                                currentBitrate = probedCap
                                return .probeUp(probedCap)
                            }
                        }
                    } else {
                        let minProbePackets: UInt64 = (cap >= activeProbeThresholdBps) ? 320 : 60
                        guard lossRatio < (clientNotOnLan ? 0.02 : 0.01), sentPackets >= minProbePackets else {
                            stableAtCapStreak = 0
                            return .hold
                        }
                        guard now - lossCapSetAt >= (clientNotOnLan ? 8.0 : 12.0) else { return .hold }
                        stableAtCapStreak += 1
                        if stableAtCapStreak >= 3 {
                            stableAtCapStreak = 0
                            let probedCap = min(hardCeilingBps, Int((Double(cap) * 1.12).rounded()))
                            learnedCeilingBps = probedCap >= hardCeilingBps ? nil : probedCap
                            if probedCap > currentBitrate {
                                currentBitrate = probedCap
                                return .probeUp(probedCap)
                            }
                        }
                    }
                }
                return .hold
            } else {
                cleanStreak = 0
                stableAtCapStreak = 0
                return .hold
            }
        }
    }

    private func noteUserInputActivity() {
        lastUserInputAt = CFAbsoluteTimeGetCurrent()
        guard wanBgSaverActive else { return }
        wanBgSaverActive = false
        let restoreFps = wanBgSavedFps
        let restoreBr = wanBgSavedBitrate
        wanBgSavedFps = nil
        wanBgSavedBitrate = nil
        // Gentle restore: jumping straight back to 60fps right after idle made the first seconds
        // burst into the tunnel and trigger loss. Come back at 30fps, then step up if clean.
        if let fps = restoreFps, !manualFpsSelected, fps != currentFps {
            let first = clientNotOnLan ? min(fps, 30) : fps
            applyFps(first, notify: false)
            if first < fps {
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 4.0) { [weak self] in
                    // udpLastLossRatio can be stale while idle, so only the severe-fps guard holding
                    // 30 on purpose (or a clearly lossy last window) blocks the step-up.
                    guard let self, !self.wanBgSaverActive, !self.manualFpsSelected,
                          self.udpSevereFpsGuard.savedFps == nil,
                          self.udpLastLossRatio < 0.08, self.currentFps == first else { return }
                    self.applyFps(fps, notify: true)
                }
            }
        }
        // Restore to the last good rate, but at least 2.5Mbps (still under the learned ceiling)
        // so the first scroll after idle doesn't start from the 1.2-1.5Mbps floor.
        if let br = restoreBr, !manualBitrateSelected {
            let cap = udpLearnedCeilingBps ?? (clientNotOnLan ? Self.wanMaxBitrateBps : 40_000_000)
            let target = min(max(br, 2_500_000), cap)
            if target > currentBitrate { applyBitrate(target, notify: false) }
        }
        notifyQualityActive()
        ConnectionLogger.shared.logStep(
            sessionId: id.uuidString,
            step: "wan_bg_saver",
            detail: "active=false fps=\(currentFps) br=\(currentBitrate/1000)k"
        )
    }

    private func handleUdpLossFeedback(_ lossRatio: Double, sentPackets: UInt64) {
        udpLastLossRatio = lossRatio
        guard usingUdpVideo else { return }

        // WAN background-window bandwidth saver: if this Mac has had zero user input for >= 12s,
        // cap it to 20fps / 1.5Mbps so it stops hogging the shared WAN tunnel from the active Mac.
        let now = CFAbsoluteTimeGetCurrent()
        if clientNotOnLan && !manualFpsSelected && !manualBitrateSelected {
            // Debounce: arm on the first idle tick and only activate on a later tick that is still
            // idle. Input landing right on the activation tick used to switch the saver on and off
            // within the same second (fps/bitrate reconfig + keyframe for nothing).
            if (now - lastUserInputAt) < 12.0 {
                wanBgSaverArmedAt = nil
            } else if !wanBgSaverActive, wanBgSaverArmedAt == nil {
                wanBgSaverArmedAt = now
            }
            if !wanBgSaverActive, let armed = wanBgSaverArmedAt, now - armed >= 1.5,
               (now - lastUserInputAt) >= 12.0 {
                wanBgSaverArmedAt = nil
                wanBgSaverActive = true
                // Remember the best fps seen across saver cycles: after a gentle restore the live
                // fps is 30 until the step-up fires, and saving that would pin the session at 30.
                wanBgSavedFps = udpSevereFpsGuard.savedFps ?? max(currentFps, wanBgBestFps)
                wanBgBestFps = wanBgSavedFps ?? currentFps
                wanBgSavedBitrate = currentBitrate
                if currentFps > 20 { applyFps(20, notify: false) }
                if currentBitrate > 1_500_000 { applyBitrate(1_500_000, notify: false) }
                notifyQualityActive()
                ConnectionLogger.shared.logStep(
                    sessionId: id.uuidString,
                    step: "wan_bg_saver",
                    detail: "active=true fps=\(currentFps) br=\(currentBitrate/1000)k"
                )
            }
        }
        if wanBgSaverActive { return }

        // Extreme-congestion FPS survival mode (6s of >=15% loss -> 30fps; 6s clean -> restore)
        if let nextFps = udpSevereFpsGuard.step(
            lossRatio: lossRatio,
            sentPackets: sentPackets,
            currentFps: currentFps,
            manualFpsSelected: manualFpsSelected
        ) {
            let dir = nextFps < currentFps ? "down" : "up"
            let prevFps = currentFps
            applyFps(nextFps, notify: true)
            ConnectionLogger.shared.logStep(
                sessionId: id.uuidString,
                step: "udp_severe_fps",
                detail: "dir=\(dir) fps=\(nextFps) prevFps=\(prevFps) loss=\(String(format: "%.3f", lossRatio)) sent=\(sentPackets)"
            )
        }

        guard (autoBitrateEnabled || !manualBitrateSelected) else { return }

        scrollBoostLock.lock()
        let boosting = scrollBoostActive
        scrollBoostLock.unlock()

        var state = UdpBitrateState(
            currentBitrate: currentBitrate,
            learnedCeilingBps: udpLearnedCeilingBps,
            lossCapSetAt: udpLossCapSetAt,
            cleanStreak: udpCleanBitrateStreak,
            stableAtCapStreak: udpStableAtCapStreak
        )
        let action = state.step(
            lossRatio: lossRatio,
            sentPackets: sentPackets,
            now: CFAbsoluteTimeGetCurrent(),
            clientNotOnLan: clientNotOnLan,
            screenWidth: capturer?.screenWidth ?? 1920,
            scrollBoostActive: boosting
        )
        udpLearnedCeilingBps = state.learnedCeilingBps
        udpLossCapSetAt = state.lossCapSetAt
        udpCleanBitrateStreak = state.cleanStreak
        udpStableAtCapStreak = state.stableAtCapStreak

        let hardCeilingBps = clientNotOnLan ? Self.wanMaxBitrateBps : (Self.autoBitrateTiers.last ?? 40_000_000)
        switch action {
        case .down(let nextBps):
            cancelScrollBoost()
            if nextBps != currentBitrate {
                applyBitrate(nextBps, notify: true)
            } else {
                encoder?.setBitrate(currentBitrate)
                UdpVideoServer.shared.updatePacingBitrate(token: udpSessionToken, bitrateBps: currentBitrate)
            }
            ConnectionLogger.shared.logStep(
                sessionId: id.uuidString,
                step: "udp_bitrate_adapt",
                detail: "dir=down loss=\(String(format: "%.3f", lossRatio)) sent=\(sentPackets) bitrate=\(nextBps) cap=\(udpLearnedCeilingBps ?? hardCeilingBps)"
            )
        case .up(let nextBps):
            applyBitrate(nextBps, notify: true)
            ConnectionLogger.shared.logStep(
                sessionId: id.uuidString,
                step: "udp_bitrate_adapt",
                detail: "dir=up loss=\(String(format: "%.3f", lossRatio)) sent=\(sentPackets) bitrate=\(nextBps) cap=\(udpLearnedCeilingBps ?? hardCeilingBps)"
            )
        case .probeUp(let probedCap):
            applyBitrate(probedCap, notify: true)
            ConnectionLogger.shared.logStep(
                sessionId: id.uuidString,
                step: "udp_bitrate_adapt",
                detail: "dir=probe_up loss=\(String(format: "%.3f", lossRatio)) sent=\(sentPackets) bitrate=\(probedCap) cap=\(udpLearnedCeilingBps ?? hardCeilingBps)"
            )
        case .hold:
            break
        }
    }

    private func applyFps(_ fps: Int, notify: Bool = true) {
        currentFps = fps
        capturer?.updateFps(fps)
        encoder?.setFps(fps)
        webrtc?.setMaxFps(fps)
        if notify { notifyQualityActive() }
    }

    /// Pre-loss Delay-Gradient GCC (UU/WebRTC-style) driven by 200ms UDP FEEDBACK (0x13) packets:
    /// reacts to queuing delay buildup (+12ms gradient) BEFORE packets start dropping, trimming
    /// bitrate smoothly by 10% instead of waiting for a 2s loss spike.
    private func handleUdpTransportFeedback(
        delayGradientMs: Double,
        lossRatio: Double,
        jitterMs: Double,
        recvBps: Int
    ) {
        guard usingUdpVideo, (autoBitrateEnabled || !manualBitrateSelected) else { return }

        let hardCeilingBps = clientNotOnLan ? Self.wanMaxBitrateBps : (Self.autoBitrateTiers.last ?? 40_000_000)
        let floorBps = clientNotOnLan
            ? (((capturer?.screenWidth ?? 1920) >= 2560) ? 1_500_000 : 1_200_000)
            : (((capturer?.screenWidth ?? 1920) >= 2560) ? 5_000_000 : 4_000_000)
        let now = CFAbsoluteTimeGetCurrent()

        if delayGradientMs >= 12.0 && recvBps >= 1_000_000 {
            cancelScrollBoost()
            udpDelayCleanStreak = 0
            udpDelayOveruseStreak += 1
            if udpDelayOveruseStreak >= 2 && (now - udpLastGccAdjustAt) >= 1.2 {
                udpDelayOveruseStreak = 0
                udpLastGccAdjustAt = now
                let dropFactor = delayGradientMs >= 25.0 ? 0.85 : 0.90
                let nextBps = max(floorBps, min(hardCeilingBps, Int((Double(currentBitrate) * dropFactor).rounded())))
                if delayGradientMs >= 25.0 {
                    // Sync severe bufferbloat (+25ms queue buildup) with learnedCeilingBps so
                    // handleUdpLossFeedback does not immediately undo GCC's cut 2 seconds later!
                    udpLearnedCeilingBps = max(floorBps, min(udpLearnedCeilingBps ?? hardCeilingBps, nextBps))
                    udpLossCapSetAt = now
                    udpCleanBitrateStreak = 0
                    udpStableAtCapStreak = 0
                }
                if nextBps != currentBitrate {
                    applyBitrate(nextBps, notify: true)
                    ConnectionLogger.shared.logStep(
                        sessionId: id.uuidString,
                        step: "udp_gcc_delay",
                        detail: "dir=down gradMs=\(String(format: "%.1f", delayGradientMs)) jitterMs=\(String(format: "%.1f", jitterMs)) recvKbps=\(recvBps/1000) bitrate=\(nextBps) cap=\(udpLearnedCeilingBps ?? hardCeilingBps)"
                    )
                }
            }
        } else if delayGradientMs < 4.0 && lossRatio < 0.005 {
            scrollBoostLock.lock()
            let boosting = scrollBoostActive
            scrollBoostLock.unlock()
            guard !boosting else { return }
            udpDelayOveruseStreak = 0
            guard recvBps >= 800_000 else { return }
            udpDelayCleanStreak += 1
            let effectiveCeiling = max(floorBps, min(hardCeilingBps, udpLearnedCeilingBps ?? hardCeilingBps))
            if udpDelayCleanStreak >= 8 && currentBitrate < effectiveCeiling && (now - udpLastGccAdjustAt) >= 1.5 {
                udpDelayCleanStreak = 0
                udpLastGccAdjustAt = now
                let nextBps = max(floorBps, min(effectiveCeiling, Int((Double(currentBitrate) * 1.08).rounded())))
                if nextBps != currentBitrate {
                    applyBitrate(nextBps, notify: true)
                    ConnectionLogger.shared.logStep(
                        sessionId: id.uuidString,
                        step: "udp_gcc_delay",
                        detail: "dir=up gradMs=\(String(format: "%.1f", delayGradientMs)) jitterMs=\(String(format: "%.1f", jitterMs)) recvKbps=\(recvBps/1000) bitrate=\(nextBps)"
                    )
                }
            }
        } else {
            udpDelayOveruseStreak = 0
            udpDelayCleanStreak = 0
        }
    }

    private func applyBitrate(_ bitrate: Int, notify: Bool = true) {
        currentBitrate = bitrate
        jpegQuality = bitrateToJpegQuality(bitrate)
        encoder?.setBitrate(bitrate)
        webrtc?.setMaxBitrate(bitrate)   // RTP path: sets the GCC ceiling
        UdpVideoServer.shared.updatePacingBitrate(token: udpSessionToken, bitrateBps: bitrate)
        if notify { notifyQualityActive() }
    }

    /// Tells the client what's actually active — needed for auto mode,
    /// where it doesn't otherwise know which tier the server landed on.
    private func notifyQualityActive() {
        sendJson(["type": "quality_active", "fps": currentFps, "bitrate": currentBitrate])
    }

    /// 码率（bps）→ JPEG 质量，匹配客户端 Toolbar 预设
    private func bitrateToJpegQuality(_ bps: Int) -> Double {
        switch bps {
        case 10_000_000...: return 0.92
        case  6_000_000...: return 0.85
        case  3_000_000...: return 0.75
        default:            return 0.60
        }
    }

    /// CGImage → JPEG Data（完全不依赖 VideoToolbox）
    private static func encodeJPEG(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    // MARK: - JSON 发送

    /// 加密发送（E2E 握手完成后）；握手前或握手消息本身走明文
    private func sendJson(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        if crypto.isReady, let encrypted = try? crypto.encrypt(data) {
            // 0xE0 前缀 + AES-GCM 密文
            var frame = Data([0xE0])
            frame.append(encrypted)
            connection.sendBinary(frame)
        } else {
            guard let text = String(data: data, encoding: .utf8) else { return }
            connection.sendText(text)
        }
    }

    /// 无条件明文发送（hello / crypto_ok 等握手消息）
    private func sendJsonRaw(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else { return }
        connection.sendText(text)
    }

    // MARK: - 目录列表

    private func handleListDir(_ path: String) {
        let expandedPath = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expandedPath)
        let fm  = FileManager.default

        let keys: [URLResourceKey] = [.fileSizeKey, .isDirectoryKey, .contentModificationDateKey]
        guard let contents = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: []) else {
            sendJson(["type": "dir_listing", "path": expandedPath, "entries": [] as [[String: Any]]])
            return
        }

        var entries: [[String: Any]] = contents.compactMap { item in
            guard let res = try? item.resourceValues(forKeys: Set(keys)) else { return nil }
            let isDir = res.isDirectory ?? false
            return [
                "name":     item.lastPathComponent,
                "size":     isDir ? 0 : (res.fileSize ?? 0),
                "isDir":    isDir,
                "modified": (res.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000
            ]
        }

        entries.sort {
            let ad = $0["isDir"] as? Bool ?? false
            let bd = $1["isDir"] as? Bool ?? false
            if ad != bd { return ad }
            return ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "")
        }

        sendJson(["type": "dir_listing", "path": expandedPath, "entries": entries])
    }

    private func handleListDirRecursive(_ path: String) {
        let expandedPath = (path as NSString).expandingTildeInPath
        let rootURL = URL(fileURLWithPath: expandedPath).standardizedFileURL
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: rootURL.path, isDirectory: &isDir), isDir.boolValue else {
            sendJson(["type": "dir_tree", "root": rootURL.path, "files": [] as [[String: Any]]])
            return
        }

        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        let rootPrefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        var files: [[String: Any]] = []
        let maxEntries = 2000

        if let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants]
        ) {
            for case let itemURL as URL in enumerator {
                if files.count >= maxEntries { break }
                guard let res = try? itemURL.resourceValues(forKeys: Set(keys)) else { continue }
                if res.isSymbolicLink == true {
                    enumerator.skipDescendants()
                    continue
                }
                guard res.isRegularFile == true else { continue }
                let fullPath = itemURL.standardizedFileURL.path
                let relPath: String
                if fullPath.hasPrefix(rootPrefix) {
                    relPath = String(fullPath.dropFirst(rootPrefix.count))
                } else {
                    relPath = itemURL.lastPathComponent
                }
                files.append([
                    "relPath": relPath,
                    "path": fullPath,
                    "size": res.fileSize ?? 0
                ])
            }
        }

        sendJson(["type": "dir_tree", "root": rootURL.path, "files": files])
    }

    // MARK: - 保活定时器

    private func startKeepalive() {
        stopKeepalive()
        lastClientActivityAt = CFAbsoluteTimeGetCurrent()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + .seconds(3), repeating: .seconds(3))
        timer.setEventHandler { [weak self] in
            guard let self, !self.isClosed else { return }
            let idleSec = CFAbsoluteTimeGetCurrent() - self.lastClientActivityAt
            if self.authenticated && idleSec > 15.0 {
                ConnectionLogger.shared.logStep(
                    sessionId: self.id.uuidString,
                    step: "session_zombie_reaped",
                    detail: "idleSec=\(String(format: "%.1f", idleSec))"
                )
                self.connection.close()
                self.close()
                return
            }
            self.sendJson(["type": "keepalive"])
        }
        timer.resume()
        keepaliveTimer = timer
    }

    private func stopKeepalive() {
        keepaliveTimer?.cancel()
        keepaliveTimer = nil
    }

    // MARK: - 剪贴板反向同步（低优先级：被控端 → 控制端）

    // Much slower than the controller→agent path on purpose — see the field
    // comments on lastSentClipboardText/lastSentClipboardImageSize. The
    // client only actually applies this to its local OS clipboard while its
    // tab is the active one (see Connection.ts), so a background session
    // controlling a different machine can't clobber what the user is
    // currently working with — but that gating lives entirely on the client
    // side; this agent just reports its own clipboard changes unconditionally.
    private func startClipboardMonitor() {
        guard clipboardTimer == nil else { return }   // already running — don't recreate the timer

        // Capture the "don't push what was already there before reverse
        // sync ever turned on" baseline exactly once per session, not on
        // every (re)start. The client resends set_reverse_clipboard_sync
        // far more often than "once at connect" — every isActive transition
        // (tab switch, window focus/blur) triggers a real stop→start cycle,
        // confirmed via connections.log showing clipboard_monitor_started
        // firing many times a minute within a single session. Resetting the
        // baseline on each of those restarts silently adopts whatever's on
        // the pasteboard *at that instant* as "already sent" — if the user
        // had just copied something on the target and the 3s poll hadn't
        // caught it yet, a restart landing in that window swallows it
        // forever, with no error and no way to tell anything went wrong.
        if !clipboardBaselineCaptured {
            clipboardBaselineCaptured = true
            let baseFiles = Self.clipboardFileURLs()
            lastSentClipboardFilesSig = baseFiles.isEmpty ? "" : Self.clipboardFilesSignature(urls: baseFiles)
            lastSentClipboardText = Self.clipboardPlainText() ?? ""
            lastSentClipboardImageSize = clipboardImagePNG()?.count ?? -1
        }
        ConnectionLogger.shared.logStep(sessionId: id.uuidString, step: "clipboard_monitor_started")

        // 150ms, not 10ms — confirmed crash (EXC_BAD_ACCESS in AppKit's
        // NSPasteboard _updateTypeCacheIfNeeded, from a real .ips crash
        // report) from hammering NSPasteboard at 100 reads/sec from a
        // background thread. 150ms is still ~20x faster than the original
        // 3s poll — plenty for "instant" copy/paste — while giving AppKit's
        // internal pasteboard cache enough breathing room not to corrupt
        // itself. See clipboardPlainText()/clipboardImagePNG() for the
        // other half of this fix (moving the actual NSPasteboard calls onto
        // the main thread, same pattern as InputSourceForcer's fix for the
        // same class of AppKit-off-main-thread crash).
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + .milliseconds(150), repeating: .milliseconds(150))
        timer.setEventHandler { [weak self] in self?.checkAndSendClipboardChanges() }
        timer.resume()
        clipboardTimer = timer
    }

    // Shared by the 3s poll tick and by stopClipboardMonitor()'s final
    // flush — see there for why a copy-then-immediately-switch-tabs
    // workflow needs this to run one extra time right as the monitor stops,
    // not just on the regular interval.
    private func checkAndSendClipboardChanges() {
        let currentChangeCount = DispatchQueue.main.sync { NSPasteboard.general.changeCount }
        if lastAppliedPasteboardChangeCount >= 0 && currentChangeCount == lastAppliedPasteboardChangeCount {
            return
        }

        // Check Finder file URLs first: skip text/image broadcast when files are on the
        // pasteboard so copying a file in Finder doesn't send its filename as plain text!
        // Files the agent cannot actually open (another app's sandbox container, e.g. an image
        // copied from WeChat's viewer, or a TCC-protected folder) can never be downloaded by the
        // client: the request used to hang silently on the Windows side. Skip them so the image
        // data on the pasteboard is sent instead.
        let allFileURLs = Self.clipboardFileURLs()
        let fileURLs = allFileURLs.filter { Self.canReadFile($0) }
        if fileURLs.isEmpty && !allFileURLs.isEmpty {
            let sig = Self.clipboardFilesSignature(urls: allFileURLs)
            if sig != lastUnreadableClipboardFilesSig {
                lastUnreadableClipboardFilesSig = sig
                ConnectionLogger.shared.logStep(
                    sessionId: id.uuidString,
                    step: "clipboard_files_unreadable",
                    detail: "count=\(allFileURLs.count) path=\(allFileURLs[0].path)"
                )
            }
        }
        if !fileURLs.isEmpty {
            let sig = Self.clipboardFilesSignature(urls: fileURLs)
            if sig != lastSentClipboardFilesSig {
                lastSentClipboardFilesSig = sig
                let fm = FileManager.default
                let filesPayload: [[String: Any]] = fileURLs.compactMap { url in
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
                    let attrs = try? fm.attributesOfItem(atPath: url.path)
                    let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                    return [
                        "name": url.lastPathComponent,
                        "path": url.path,
                        "size": isDir.boolValue ? 0 : size,
                        "isDir": isDir.boolValue
                    ]
                }
                if !filesPayload.isEmpty {
                    ConnectionLogger.shared.logStep(
                        sessionId: id.uuidString,
                        step: "clipboard_files_reverse_sent",
                        detail: "count=\(filesPayload.count)"
                    )
                    sendJson(["type": "clipboard_files_from_target", "files": filesPayload])
                }
            }
            return
        }

        let text = Self.clipboardPlainText() ?? ""
        if !text.isEmpty && text != lastSentClipboardText {
            lastSentClipboardText = text
            ConnectionLogger.shared.logStep(sessionId: id.uuidString, step: "clipboard_reverse_sent",
                detail: "len=\(text.count)")
            sendJson(["type": "clipboard_from_target", "text": text])
        }
        guard let pngData = clipboardImagePNG(), pngData.count != lastSentClipboardImageSize else { return }
        guard pngData.count <= 10 * 1024 * 1024 else { return }
        lastSentClipboardImageSize = pngData.count
        ConnectionLogger.shared.logStep(sessionId: id.uuidString, step: "clipboard_reverse_sent",
            detail: "image bytes=\(pngData.count)")
        sendJson(["type": "clipboard_from_target", "image": pngData.base64EncodedString()])
    }

    private static func clipboardFileURLs() -> [URL] {
        DispatchQueue.main.sync {
            let pb = NSPasteboard.general
            let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
            guard let objs = pb.readObjects(forClasses: [NSURL.self], options: options) as? [URL] else {
                return []
            }
            return objs.filter { $0.isFileURL }
        }
    }

    private static func canReadFile(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return false }
        if isDir.boolValue { return true }
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        try? fh.close()
        return true
    }

    private static func clipboardFilesSignature(urls: [URL]) -> String {
        let fm = FileManager.default
        let parts = urls.map { url -> String in
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            let mtime = Int64((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
            return "\(url.path)|\(size)|\(mtime)"
        }.sorted()
        return parts.joined(separator: "\n")
    }

    // Plain "public.utf8-plain-text" isn't always on the pasteboard — a
    // "copy" button in a web/Electron app (confirmed report: Claude Code's
    // own copy buttons) can write only a rich representation (RTF/HTML)
    // with no plain-text fallback, which NSPasteboard.string(forType: .string)
    // silently returns nil for — the reverse-sync poll then sees an "empty"
    // clipboard and never sends anything, even though something real was
    // just copied. Fall back to extracting plain text out of RTF/HTML.
    private static func clipboardPlainText() -> String? {
        // Dispatched onto main — see the timer setup comment in
        // startClipboardMonitor() for why: a real crash report showed
        // AppKit's NSPasteboard implementation isn't safe to hammer from a
        // background thread (EXC_BAD_ACCESS deep in
        // -[NSPasteboard _updateTypeCacheIfNeeded]), the same class of bug
        // InputSourceForcer hit with TIS APIs.
        DispatchQueue.main.sync {
            let pb = NSPasteboard.general
            if let s = pb.string(forType: .string), !s.isEmpty { return s }
            if let rtf = pb.data(forType: .rtf),
               let attr = try? NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil),
               !attr.string.isEmpty {
                return attr.string
            }
            if let html = pb.data(forType: .html),
               let attr = try? NSAttributedString(data: html, options: [.documentType: NSAttributedString.DocumentType.html], documentAttributes: nil),
               !attr.string.isEmpty {
                return attr.string
            }
            return nil
        }
    }

    private func clipboardImagePNG() -> Data? {
        // See clipboardPlainText() — same NSPasteboard-off-main-thread crash risk.
        DispatchQueue.main.sync {
            let pb = NSPasteboard.general
            if let png = pb.data(forType: .png) { return png }
            if let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) {
                return rep.representation(using: .png, properties: [:])
            }
            return nil
        }
    }

    private func stopClipboardMonitor() {
        guard clipboardTimer != nil else { return }
        // Copy-then-immediately-switch-tabs is the whole point of reverse
        // sync — without this, a copy landing inside the 3s gap before the
        // next scheduled poll tick gets silently stranded: the monitor
        // stops right here, and nothing checks the pasteboard again until
        // the user switches back to this tab, which defeats the "copy here,
        // paste elsewhere right away" workflow entirely. One last check
        // before tearing down the timer closes that gap.
        checkAndSendClipboardChanges()
        clipboardTimer?.cancel()
        clipboardTimer = nil
        // Previously unlogged — made it impossible to tell from
        // connections.log whether a "copy didn't sync" report was because
        // the monitor was stopped (client sent isActive=false right around
        // the copy) at that moment, or something else. Pairs with
        // clipboard_monitor_started.
        ConnectionLogger.shared.logStep(sessionId: id.uuidString, step: "clipboard_monitor_stopped")
    }

    // MARK: - 系统静音控制

    private func setSystemMuted(_ muted: Bool) {
        let script = muted
            ? "set volume output muted true"
            : "set volume output muted false"
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
    }

    // MARK: - 文件发送（Mac → 客户端）

    func sendFile(_ url: URL, offset startOffset: Int64 = 0) {
        guard authenticated else { return }
        guard let fh = try? FileHandle(forReadingFrom: url),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value else {
            print("[Session] sendFile: cannot read \(url.lastPathComponent)")
            ConnectionLogger.shared.logStep(sessionId: id.uuidString, step: "send_file_unreadable",
                detail: "path=\(url.path)")
            sendJson(["type": "error", "code": "file_unreadable",
                      "message": "被控端无法读取该文件（可能没有权限）：\(url.lastPathComponent)"])
            return
        }
        defer { try? fh.close() }

        let clampedOffset = min(max(0, startOffset), size)

        // 16-byte ASCII ID（取 UUID 去掉连字符后前16位）
        let rawId = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let idStr = String(rawId.prefix(16))
        let name  = url.lastPathComponent

        sendJson([
            "type": "file_start",
            "id": idStr,
            "name": name,
            "size": size,
            "offset": clampedOffset
        ])

        var idBytes = [UInt8](repeating: 0, count: 16)
        let idData  = idStr.data(using: .utf8)!
        for (i, b) in idData.enumerated() where i < 16 { idBytes[i] = b }

        let CHUNK = 64 * 1024
        var offset = clampedOffset
        if offset > 0 {
            try? fh.seek(toOffset: UInt64(offset))
        }
        while offset < size {
            let chunk = fh.readData(ofLength: CHUNK)
            if chunk.isEmpty { break }

            // 0x02 | 16-byte-id (padded) | 4-byte-offset (big-endian) | data
            var pkt = Data(capacity: 1 + 16 + 4 + chunk.count)
            pkt.append(0x02)
            pkt.append(contentsOf: idBytes)
            var offBE = UInt32(truncatingIfNeeded: offset).bigEndian
            withUnsafeBytes(of: &offBE) { pkt.append(contentsOf: $0) }
            pkt.append(chunk)

            connection.sendBinary(pkt)
            offset += Int64(chunk.count)
        }

        sendJson(["type": "file_end", "id": idStr])
        print("[Session] sendFile: sent \(name) (\(size) bytes, startOffset=\(clampedOffset))")
    }
}
