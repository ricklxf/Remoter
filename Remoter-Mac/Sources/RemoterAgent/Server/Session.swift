import Foundation
import Network
import AppKit

// Manages one connected client: auth → capture → encode → stream
// Video: WebRTC DataChannel (UDP) preferred, WebSocket fallback
// Security: P-256 ECDH + AES-256-GCM end-to-end encryption (0xE0 frame prefix)
final class Session {
    let id: UUID
    let connection: NWConnection
    private let server: WebSocketServer
    private let pin: String

    private var capturer: ScreenCapturer?
    private var encoder: VideoEncoder?
    private var input: InputController?
    private var fileReceiver: FileReceiver?
    private var webrtc: WebRTCAgent?
    private let crypto = E2ECrypto()

    private var authenticated = false
    private var frameId: UInt32 = 0
    private var startTime: UInt32 = 0
    private var abr: ABRController?

    // For disconnection logging
    private var connectTime: Date?
    private var bytesSent: Int64 = 0
    private var bytesRecv: Int64 = 0
    private var sessionCodec: VideoCodec = .h264

    init(id: UUID, connection: NWConnection, server: WebSocketServer, pin: String) {
        self.id = id
        self.connection = connection
        self.server = server
        self.pin = pin
    }

    func start() {
        // 记录连接建立（WebSocket 握手完成，尚未 PIN 认证）
        let remote = "\(connection.endpoint)"
        print("[Session] 客户端接入 \(remote) | session=\(id.uuidString.prefix(8))")
        ConnectionLogger.shared.logClientConnected(sessionId: id.uuidString, remoteAddr: remote)

        // Include our E2E public key so client can initiate handshake
        sendJsonRaw(["type": "hello", "version": "1.0", "os": "macOS",
                     "pubkey": crypto.publicKeyBase64])
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
            guard let plain = try? crypto.decrypt(ciphertext),
                  let text = String(data: plain, encoding: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: plain) as? [String: Any]
            else { return }
            _ = text
            routeMessage(json)
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
        // Log disconnection if we were streaming
        if let t = connectTime {
            let secs = Int(Date().timeIntervalSince(t))
            ConnectionLogger.shared.logDisconnected(
                sessionId: id.uuidString,
                durationSecs: secs,
                bytesSentMB: Double(bytesSent) / 1_048_576,
                bytesRecvMB: Double(bytesRecv) / 1_048_576
            )
        }
        Task { await capturer?.stop() }
        encoder?.invalidate()
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

        // ── 认证 ──────────────────────────────────────────────
        if case .auth(let clientPin) = msg {
            if clientPin == pin {
                authenticated = true
                print("[Session] ✅ 认证通过 session=\(id.uuidString.prefix(8))")
                ConnectionLogger.shared.logAuthSuccess(sessionId: id.uuidString)
                sendJsonRaw(["type": "auth_ok"])
                Task { await self.beginCapture() }
            } else {
                print("[Session] ❌ PIN 错误 session=\(id.uuidString.prefix(8))")
                ConnectionLogger.shared.logAuthFailed(sessionId: id.uuidString)
                sendJsonRaw(["type": "error", "code": "auth_failed", "message": "Wrong PIN"])
                connection.cancel()
            }
            return
        }

        guard authenticated else { return }

        switch msg {

        // ── 输入事件 ───────────────────────────────────────────
        case .mouseMove(let x, let y):
            input?.mouseMove(x: x, y: y)

        case .mouseButton(let btn, let down, let x, let y):
            input?.mouseButton(button: btn, down: down, x: x, y: y)

        case .mouseScroll(let dx, let dy):
            input?.mouseScroll(dx: dx, dy: dy)

        case .key(let code, let down, let mods):
            input?.keyEvent(code: code, down: down, modifiers: mods)

        case .clipboardSet(let text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)

        case .fileStart(let fid, let name, let size):
            fileReceiver?.start(id: fid, name: name, size: size)

        case .fileEnd(let fid):
            fileReceiver?.finish(id: fid)

        case .qualitySet(let fps, let bitrate):
            Task {
                guard let c = self.capturer else { return }
                try? await c.updateConfig(fps: fps, width: c.screenWidth, height: c.screenHeight)
                self.encoder?.forceKeyframe()
                _ = bitrate
            }

        case .ping:
            sendJson(["type": "pong"])

        // ── WebRTC 信令 ────────────────────────────────────────
        case .webrtcOffer(let sdp):
            setupWebRTC(offerSDP: sdp)

        case .webrtcICE(let json):
            webrtc?.handleRemoteICE(json)

        case .clientStats(let fps, let rttMs):
            if let newBitrate = abr?.update(fps: fps, rttMs: rttMs) {
                encoder?.adjustBitrate(newBitrate)
                sendJson(["type": "bitrate_changed", "bitrate": newBitrate])
            }

        // ── 编解码切换 ─────────────────────────────────────────
        case .setCodec(let codecStr):
            let newCodec: VideoCodec = codecStr == "h265" ? .h265 : .h264
            switchCodec(to: newCodec)

        default:
            break
        }
    }

    // MARK: - 编解码切换

    private func switchCodec(to codec: VideoCodec) {
        guard let enc = encoder, let cap = capturer else { return }
        let w = cap.screenWidth, h = cap.screenHeight
        do {
            enc.invalidate()
            try enc.setup(width: w, height: h, fps: 60,
                          bitrate: abr?.currentBitrate ?? 15_000_000, codec: codec)
            sessionCodec = codec
            sendJson(["type": "codec_changed", "codec": codec.rawValue])
            ConnectionLogger.shared.logCodecChanged(sessionId: id.uuidString, codec: codec.rawValue)
        } catch {
            sendJson(["type": "error", "code": "codec_switch_failed", "message": "\(error)"])
        }
    }

    // MARK: - WebRTC 信令设置

    private func setupWebRTC(offerSDP: String) {
        let agent = WebRTCAgent()

        agent.onLocalDescription = { [weak self] type, sdp in
            self?.sendJson(["type": "webrtc_\(type)", "sdp": sdp])
        }
        agent.onICECandidate = { [weak self] json in
            self?.sendJson(["type": "webrtc_ice", "candidate": json])
        }
        agent.onConnected = { [weak self] in
            self?.encoder?.forceKeyframe()
        }
        agent.onDisconnected = { [weak self] in
            print("[Session] WebRTC disconnected, falling back to WebSocket")
        }
        agent.onControlMessage = { [weak self] text in
            self?.handleText(text)
        }

        self.webrtc = agent
        agent.handleOffer(offerSDP)
    }

    // MARK: - 采集与编码

    private func beginCapture() async {
        let c   = ScreenCapturer()
        let enc = VideoEncoder()
        let useHEVC = VideoEncoder.isHEVCSupported()
        let codec: VideoCodec = useHEVC ? .h265 : .h264
        sessionCodec = codec

        c.onFrame = { [weak enc] buf in enc?.encode(sampleBuffer: buf) }

        enc.onEncodedFrame = { [weak self] data, isKeyframe in
            guard let self else { return }
            let fid = self.frameId
            self.frameId &+= 1
            self.bytesSent += Int64(data.count)

            if let rtc = self.webrtc, rtc.isVideoChannelOpen {
                rtc.sendVideoFrame(data, isKeyframe: isKeyframe, frameId: fid)
            } else {
                let now = UInt32(Date().timeIntervalSince1970 * 1000) - self.startTime
                let pkt = buildVideoFramePacket(data: data, frameId: fid, ptsMs: now, isKeyframe: isKeyframe)
                self.server.sendBinary(pkt, to: self.connection)
            }
        }

        let initialBitrate = 15_000_000
        print("[Session] ▶ 开始采集 codec=\(codec.rawValue) session=\(id.uuidString.prefix(8))")
        do {
            print("[Session]   1/4 设置编码器…")
            try enc.setup(width: 2560, height: 1440, fps: 60,
                          bitrate: initialBitrate, codec: codec)
            print("[Session]   2/4 编码器就绪，启动屏幕捕获…")
            try await c.start(fps: 60)
            print("[Session]   3/4 屏幕捕获已启动 \(c.screenWidth)x\(c.screenHeight)")
            capturer     = c
            encoder      = enc
            input        = InputController(screenWidth: c.screenWidth, screenHeight: c.screenHeight)
            fileReceiver = FileReceiver()
            abr          = ABRController(targetFPS: 60, initialBitrate: initialBitrate)
            startTime    = UInt32(Date().timeIntervalSince1970 * 1000)
            connectTime  = Date()

            print("[Session]   4/4 发送 stream_started…")
            print("[Session] ✅ 流启动 \(c.screenWidth)x\(c.screenHeight) codec=\(codec.rawValue) e2e=\(crypto.isReady)")
            ConnectionLogger.shared.logConnected(
                sessionId: id.uuidString,
                codec: codec.rawValue,
                encrypted: crypto.isReady
            )

            sendJson([
                "type":   "stream_started",
                "width":  c.screenWidth,
                "height": c.screenHeight,
                "codec":  codec.rawValue
            ])
        } catch {
            let msg = "\(error)"
            print("[Session] ❌ 采集失败: \(msg)")
            ConnectionLogger.shared.logCaptureError(sessionId: id.uuidString, error: msg)
            sendJsonRaw(["type": "error", "code": "capture_failed", "message": msg])
        }
    }

    // MARK: - JSON 发送

    /// 加密发送（E2E 握手完成后）；握手前或握手消息本身走明文
    private func sendJson(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        if crypto.isReady, let encrypted = try? crypto.encrypt(data) {
            // 0xE0 前缀 + AES-GCM 密文
            var frame = Data([0xE0])
            frame.append(encrypted)
            server.sendBinary(frame, to: connection)
        } else {
            guard let text = String(data: data, encoding: .utf8) else { return }
            server.sendText(text, to: connection)
        }
    }

    /// 无条件明文发送（hello / crypto_ok 等握手消息）
    private func sendJsonRaw(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else { return }
        server.sendText(text, to: connection)
    }
}
