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
    private var cursorMonitor: CursorMonitor?
    private var lastFrame: CVPixelBuffer?
    private var input: InputController?
    private var fileReceiver: FileReceiver?
    private var webrtc: WebRTCAgent?
    private let crypto = E2ECrypto()

    private var authenticated = false
    private var isClosed = false
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
    private var usingJpeg = false  // re-applied after a resolution switch's beginCapture() rebuild, which defaults back to h264

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
    private static let autoFpsTiers:     [Int] = [30, 60]
    private static let autoBitrateTiers: [Int] = [2_000_000, 4_000_000, 8_000_000, 15_000_000]
    // Independent — the client can put either on auto while pinning the
    // other to a manual value, matching the fact they're genuinely two
    // separate knobs, not one bundled "quality" choice.
    private var autoFpsEnabled = false
    private var autoBitrateEnabled = false
    private var autoFpsIndex = 0
    private var autoBitrateIndex = 0
    private var autoFpsCleanStreak = 0
    private var autoBitrateCleanStreak = 0

    // For disconnection logging
    private var connectTime: Date?
    private var bytesSent: Int64 = 0
    private var bytesRecv: Int64 = 0
    private var loggedFirstInput = false

    // Clipboard auto-sync
    private var clipboardTimer: DispatchSourceTimer?
    private var lastClipboardContent = ""
    private var lastClipboardImageSize: Int = -1

    // Keepalive: send a JSON message every 3s so the client's stale-timeout (6s)
    // doesn't fire when the screen is static and CGDisplayStream pushes no frames.
    private var keepaliveTimer: DispatchSourceTimer?

    init(id: UUID, connection: WSClient, pin: String) {
        self.id = id
        self.connection = connection
        self.pin = pin
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
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        routeMessage(json)
    }

    func handleBinary(_ data: Data) {
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
        cursorMonitor?.stop()
        cursorMonitor = nil
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
            if !loggedFirstInput {
                loggedFirstInput = true
                ConnectionLogger.shared.logStep(sessionId: id.uuidString, step: "first_input",
                                                detail: "input=\(input != nil), ax=\(AXIsProcessTrusted())")
            }
            input?.mouseMove(x: x, y: y, dragging: dragging)

        case .mouseButton(let btn, let down, let x, let y):
            guard inputEnabled else { break }
            input?.mouseButton(button: btn, down: down, x: x, y: y)

        case .mouseDoubleClick(let btn, let x, let y):
            guard inputEnabled else { break }
            input?.mouseDoubleClick(button: btn, x: x, y: y)

        case .mouseScroll(let dx, let dy):
            guard inputEnabled else { break }
            input?.mouseScroll(dx: dx, dy: dy)

        case .key(let code, let down, let mods):
            guard inputEnabled else { break }
            NSLog("[Session] keyEvent code=%@ down=%d input=%d", code, down ? 1 : 0, input != nil ? 1 : 0)
            input?.keyEvent(code: code, down: down, modifiers: mods)

        case .textInput(let text):
            guard inputEnabled else { break }
            input?.typeText(text)

        case .clipboardSet(let text):
            lastClipboardContent = text   // prevent echo-back
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)

        case .clipboardSetImage(let data):
            guard !data.isEmpty, let imgData = Data(base64Encoded: data) else { break }
            lastClipboardImageSize = imgData.count
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.declareTypes([.png, .tiff], owner: nil)
            pb.setData(imgData, forType: .png)
            if let rep = NSBitmapImageRep(data: imgData),
               let tiff = rep.representation(using: .tiff, properties: [:]) {
                pb.setData(tiff, forType: .tiff)
            }

        case .fileStart(let fid, let name, let size):
            fileReceiver?.start(id: fid, name: name, size: size)

        case .fileEnd(let fid):
            fileReceiver?.finish(id: fid)

        case .fpsSet(let fps, let auto):
            autoFpsEnabled = auto
            if auto {
                autoFpsIndex = 0
                autoFpsCleanStreak = 0
                applyFps(Self.autoFpsTiers[0])
            } else {
                applyFps(fps)
            }

        case .bitrateSet(let bitrate, let auto):
            autoBitrateEnabled = auto
            if auto {
                autoBitrateIndex = 0
                autoBitrateCleanStreak = 0
                applyBitrate(Self.autoBitrateTiers[0])
            } else {
                applyBitrate(bitrate)
            }

        case .resolutionSet(let tier):
            let newMax: Int? = tier == "2k" ? 2560 : (tier == "1080" ? 1920 : nil)
            guard newMax != resolutionMaxDimension else { break }
            resolutionMaxDimension = newMax
            Task { await rebuildPipeline() }

        case .setAudioEnabled(let enabled):
            audioEnabled = enabled
            if enabled { startAudioStream() } else { stopAudioStream() }

        case .displaySet(let did):
            guard did != selectedDisplayID else { break }
            selectedDisplayID = did
            Task { await rebuildPipeline() }

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
            guard now.timeIntervalSince(lastForcedKeyframeAt) > 1.0 else { break }
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

        case .clientStats:
            break  // JPEG 模式下无 ABR

        case .setCodec(let codec):
            if codec == "jpeg" {
                switchToJpeg()
            } else if let c = StreamCodec(rawValue: codec), c != currentCodec || usingJpeg {
                // Codec is baked into the VTCompressionSession at creation, so
                // like a resolution change this needs the full pipeline rebuild.
                currentCodec = c
                usingJpeg = false
                Task { await rebuildPipeline() }
            }

        case .listDir(let path):
            handleListDir(path)

        case .requestFile(let path):
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            sendFile(url)

        case .setMuted(let muted):
            setSystemMuted(muted)

        case .ctrlAltDel:
            input?.keyEvent(code: "Delete", down: true,  modifiers: ["ctrl", "alt"])
            input?.keyEvent(code: "Delete", down: false, modifiers: ["ctrl", "alt"])

        case .setClipboardSync(let enabled):
            if enabled { startClipboardMonitor() } else { stopClipboardMonitor() }

        case .setInputEnabled(let enabled):
            inputEnabled = enabled

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

    private func beginCapture() async {
        let c   = ScreenCapturer()
        let sid = id.uuidString
        ConnectionLogger.shared.logStep(sessionId: sid, step: "capture_begin", detail: "jpeg")
        do {
            ConnectionLogger.shared.logStep(sessionId: sid, step: "capturer_start")
            // currentFps defaults to 30 (matches the client's default "自动"
            // preset) on a fresh session, or carries over whatever was
            // already active when this is a resolution-switch re-run.
            try await c.start(fps: currentFps, maxDimension: resolutionMaxDimension,
                              displayID: selectedDisplayID)
            ConnectionLogger.shared.logStep(sessionId: sid, step: "capturer_ready",
                                            detail: "\(c.screenWidth)x\(c.screenHeight)")
            capturer     = c
            input        = InputController(screenWidth: c.physWidth, screenHeight: c.physHeight,
                                           originX: c.originX, originY: c.originY)
            fileReceiver = FileReceiver()
            connectTime  = Date()

            // Set up the video encoder (H.264 default, HEVC if the client
            // opted in) — same currentFps/currentBitrate carry-over as above.
            encoder?.close()
            let enc = VideoEncoder()
            try enc.setup(width: c.screenWidth, height: c.screenHeight,
                          fps: currentFps, bitrateBps: currentBitrate, codec: currentCodec)
            encoder = enc

            ConnectionLogger.shared.logConnected(sessionId: sid, codec: currentCodec.rawValue, encrypted: crypto.isReady)
            startClipboardMonitor()
            startKeepalive()
            startCursorMonitor()
            sendJson([
                "type":   "stream_started",
                "width":  c.screenWidth,
                "height": c.screenHeight,
                "codec":  currentCodec.rawValue,
                "displays": c.displays.map { ["id": Int($0.id), "name": $0.name,
                                              "width": $0.width, "height": $0.height] },
                "display": Int(selectedDisplayID ?? CGMainDisplayID())
            ])

            enc.onEncodedFrame = { [weak self] data, isKeyframe in
                guard let self else { return }
                guard self.connection.isActive else { return }

                let fid = self.frameId
                self.frameId &+= 1
                self.bytesSent += Int64(data.count)

                // Prefer WebRTC's unreliable-ish DataChannel (frame-level drop on
                // congestion, no TCP head-of-line blocking) whenever it's actually
                // open; re-checked per frame so a mid-session ICE failure falls
                // back to the always-available WebSocket path transparently.
                if let webrtc = self.webrtc, webrtc.isVideoChannelOpen {
                    if !self.usingWebRTCVideo {
                        self.usingWebRTCVideo = true
                        ConnectionLogger.shared.logStep(sessionId: self.id.uuidString,
                            step: "video_transport", detail: "webrtc")
                    }
                    if webrtc.sendVideoFrame(data, isKeyframe: isKeyframe, frameId: fid) {
                        self.recordSentFrame()
                    } else {
                        // Dropped due to send-buffer backpressure — the client
                        // never saw this frame, so any later delta frame that
                        // references it will decode into garbage. Force the
                        // next frame to be a fresh keyframe so corruption is
                        // brief instead of lasting up to 2s.
                        //
                        // But a keyframe is much bigger than a delta frame —
                        // if the link is *sustained*-congested (not just a
                        // brief blip), forcing one on every single drop just
                        // pours more data into an already-overloaded pipe,
                        // causing more drops, more forced keyframes, and so
                        // on. Cool down to at most once/second so we recover
                        // fast from a blip without feeding a runaway loop
                        // under real, sustained bandwidth shortage.
                        self.backpressureDrops += 1
                        let now = Date()
                        if now.timeIntervalSince(self.lastForcedKeyframeAt) > 1.0 {
                            self.lastForcedKeyframeAt = now
                            self.keyframesForced += 1
                            self.encoder?.forceKeyframe()
                        }
                    }
                } else {
                    if self.usingWebRTCVideo {
                        self.usingWebRTCVideo = false
                        ConnectionLogger.shared.logStep(sessionId: self.id.uuidString,
                            step: "video_transport", detail: "websocket")
                    }
                    guard self.wsSendSem.wait(timeout: .now()) == .success else { return }
                    let now = UInt32(Date().timeIntervalSince(self.connectTime ?? Date()) * 1000)
                    let pkt = buildVideoFramePacket(data: data, frameId: fid, ptsMs: now, isKeyframe: isKeyframe)
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

            c.onFrame = { [weak self] pixelBuffer, _, _ in
                guard let self else { return }
                self.lastFrame = pixelBuffer
                // RTP media track first: raw buffer straight into libwebrtc
                // (it encodes + paces + congestion-controls internally). Our
                // own VT encoder + WS/DataChannel path stays as the fallback
                // whenever the media track isn't up — checked per frame so a
                // mid-session ICE failure degrades transparently, same as
                // the old DataChannel→WS fallback did.
                if let webrtc = self.webrtc, webrtc.isMediaReady {
                    if !self.usingRtpVideo {
                        self.usingRtpVideo = true
                        ConnectionLogger.shared.logStep(sessionId: self.id.uuidString,
                            step: "video_transport", detail: "rtp")
                    }
                    webrtc.sendVideoBuffer(pixelBuffer)
                    self.recordSentFrame()
                } else {
                    if self.usingRtpVideo {
                        self.usingRtpVideo = false
                        ConnectionLogger.shared.logStep(sessionId: self.id.uuidString,
                            step: "video_transport", detail: "fallback")
                    }
                    self.encoder?.encode(pixelBuffer)
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
            ConnectionLogger.shared.logStep(sessionId: id.uuidString,
                step: "sent_5s", detail: "sent=\(sentFrames) fps=\(String(format: "%.0f", Double(sentFrames)/dt)) transport=\(usingRtpVideo ? "rtp" : (usingWebRTCVideo ? "webrtc" : "ws")) bpDrops=\(backpressureDrops) kfForced=\(keyframesForced) kfReq=\(keyframeRequests)")
            // On the RTP path libwebrtc's GCC owns bandwidth adaptation and
            // the browser handles decode-overload (frame dropping + PLI), so
            // our reactive stepping would just fight it — only run it for
            // the fallback (WS/DataChannel + WebCodecs) transport.
            if !usingRtpVideo && (autoFpsEnabled || autoBitrateEnabled) { evaluateAutoQuality() }
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
        var fpsChanged = false
        var bitrateChanged = false

        let decodeOverloaded = keyframeRequests > 0

        if autoFpsEnabled {
            if decodeOverloaded {
                autoFpsCleanStreak = 0
                if autoFpsIndex > 0 { autoFpsIndex -= 1; fpsChanged = true }
            } else {
                autoFpsCleanStreak += 1
                if autoFpsCleanStreak >= 3 && autoFpsIndex < Self.autoFpsTiers.count - 1 {
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
                if autoBitrateCleanStreak >= 3 && autoBitrateIndex < Self.autoBitrateTiers.count - 1 {
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
    private func applyFps(_ fps: Int, notify: Bool = true) {
        currentFps = fps
        capturer?.updateFps(fps)
        if notify { notifyQualityActive() }
    }

    private func applyBitrate(_ bitrate: Int, notify: Bool = true) {
        currentBitrate = bitrate
        jpegQuality = bitrateToJpegQuality(bitrate)
        encoder?.setBitrate(bitrate)
        webrtc?.setMaxBitrate(bitrate)   // RTP path: sets the GCC ceiling
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

    // MARK: - 剪贴板监控（双向自动同步）

    private func startClipboardMonitor() {
        stopClipboardMonitor()  // safe to call repeatedly (e.g. beginCapture() re-run for a resolution switch)
        lastClipboardContent = NSPasteboard.general.string(forType: .string) ?? ""
        lastClipboardImageSize = clipboardImagePNG()?.count ?? -1

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            // Text
            let text = NSPasteboard.general.string(forType: .string) ?? ""
            if !text.isEmpty && text != self.lastClipboardContent {
                self.lastClipboardContent = text
                self.sendJson(["type": "clipboard", "text": text])
            }
            // Image
            guard let pngData = self.clipboardImagePNG() else { return }
            guard pngData.count != self.lastClipboardImageSize else { return }
            guard pngData.count <= 4 * 1024 * 1024 else { return }
            self.lastClipboardImageSize = pngData.count
            self.sendJson(["type": "clipboard", "image": pngData.base64EncodedString()])
        }
        timer.resume()
        clipboardTimer = timer
    }

    private func clipboardImagePNG() -> Data? {
        let pb = NSPasteboard.general
        if let png = pb.data(forType: .png) { return png }
        if let tiff = pb.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiff) {
            return rep.representation(using: .png, properties: [:])
        }
        return nil
    }

    private func stopClipboardMonitor() {
        clipboardTimer?.cancel()
        clipboardTimer = nil
    }

    // MARK: - 保活定时器

    private func startKeepalive() {
        stopKeepalive()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + .seconds(3), repeating: .seconds(3))
        timer.setEventHandler { [weak self] in
            self?.sendJson(["type": "keepalive"])
        }
        timer.resume()
        keepaliveTimer = timer
    }

    private func stopKeepalive() {
        keepaliveTimer?.cancel()
        keepaliveTimer = nil
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

    func sendFile(_ url: URL) {
        guard authenticated else { return }
        guard let fileData = try? Data(contentsOf: url) else {
            print("[Session] sendFile: cannot read \(url.lastPathComponent)")
            return
        }

        // 16-byte ASCII ID（取 UUID 去掉连字符后前16位）
        let rawId = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let idStr = String(rawId.prefix(16))
        let name  = url.lastPathComponent
        let size  = fileData.count

        sendJson(["type": "file_start", "id": idStr, "name": name, "size": size])

        let CHUNK = 64 * 1024
        var offset = 0
        while offset < size {
            let end   = min(offset + CHUNK, size)
            let chunk = fileData[offset..<end]

            // 0x02 | 16-byte-id (padded) | 4-byte-offset (big-endian) | data
            var idBytes = [UInt8](repeating: 0, count: 16)
            let idData  = idStr.data(using: .utf8)!
            for (i, b) in idData.enumerated() where i < 16 { idBytes[i] = b }

            var pkt = Data(capacity: 1 + 16 + 4 + chunk.count)
            pkt.append(0x02)
            pkt.append(contentsOf: idBytes)
            var offBE = UInt32(offset).bigEndian
            withUnsafeBytes(of: &offBE) { pkt.append(contentsOf: $0) }
            pkt.append(chunk)

            connection.sendBinary(pkt)
            offset += CHUNK
        }

        sendJson(["type": "file_end", "id": idStr])
        print("[Session] sendFile: sent \(name) (\(size) bytes)")
    }
}
