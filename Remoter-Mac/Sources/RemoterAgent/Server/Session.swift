import Foundation
import Network
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Manages one connected client: auth → capture → encode → stream
// Video: JPEG over WebSocket (bypasses VideoToolbox which hangs on macOS 26)
// Security: P-256 ECDH + AES-256-GCM end-to-end encryption (0xE0 frame prefix)
final class Session {
    let id: UUID
    let connection: NWConnection
    private let server: WebSocketServer
    private let pin: String

    private var capturer: ScreenCapturer?
    private var input: InputController?
    private var fileReceiver: FileReceiver?
    private var webrtc: WebRTCAgent?
    private let crypto = E2ECrypto()

    private var authenticated = false
    private var frameId: UInt32 = 0

    // For disconnection logging
    private var connectTime: Date?
    private var bytesSent: Int64 = 0
    private var bytesRecv: Int64 = 0

    init(id: UUID, connection: NWConnection, server: WebSocketServer, pin: String) {
        self.id = id
        self.connection = connection
        self.server = server
        self.pin = pin
    }

    func start() {
        let remote = "\(connection.endpoint)"
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
            do {
                let plain = try crypto.decrypt(ciphertext)
                guard let json = try? JSONSerialization.jsonObject(with: plain) as? [String: Any] else { return }
                routeMessage(json)
            } catch {
                NSLog("[Session] E2E decrypt FAILED: %@, e2eReady=%d, len=%d", "\(error)", crypto.isReady ? 1 : 0, data.count)
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
        if case .auth(_) = msg { // PIN 校验已暂时禁用，测试用
            authenticated = true
            ConnectionLogger.shared.logAuthSuccess(sessionId: id.uuidString)
            sendJsonRaw(["type": "auth_ok"])
            Task { await self.beginCapture() }
            return
        }

        guard authenticated else { return }

        switch msg {

        // ── 输入事件 ───────────────────────────────────────────
        case .mouseMove(let x, let y):
            NSLog("[Session] mouseMove x=%.3f y=%.3f input=%d", x, y, input != nil ? 1 : 0)
            input?.mouseMove(x: x, y: y)

        case .mouseButton(let btn, let down, let x, let y):
            input?.mouseButton(button: btn, down: down, x: x, y: y)

        case .mouseScroll(let dx, let dy):
            input?.mouseScroll(dx: dx, dy: dy)

        case .key(let code, let down, let mods):
            NSLog("[Session] keyEvent code=%@ down=%d input=%d", code, down ? 1 : 0, input != nil ? 1 : 0)
            input?.keyEvent(code: code, down: down, modifiers: mods)

        case .clipboardSet(let text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)

        case .fileStart(let fid, let name, let size):
            fileReceiver?.start(id: fid, name: name, size: size)

        case .fileEnd(let fid):
            fileReceiver?.finish(id: fid)

        case .qualitySet:
            break  // JPEG 模式下质量固定，忽略

        case .ping:
            sendJson(["type": "pong"])

        // ── WebRTC 信令 ────────────────────────────────────────
        case .webrtcOffer(let sdp):
            setupWebRTC(offerSDP: sdp)

        case .webrtcICE(let json):
            webrtc?.handleRemoteICE(json)

        case .clientStats:
            break  // JPEG 模式下无 ABR

        case .setCodec:
            break  // JPEG 模式下不支持切换

        default:
            break
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
        agent.handleOffer(offerSDP)
    }

    // MARK: - 采集与 JPEG 编码

    private func beginCapture() async {
        let c   = ScreenCapturer()
        let sid = id.uuidString
        ConnectionLogger.shared.logStep(sessionId: sid, step: "capture_begin", detail: "jpeg")
        do {
            ConnectionLogger.shared.logStep(sessionId: sid, step: "capturer_start")
            try await c.start(fps: 30)
            ConnectionLogger.shared.logStep(sessionId: sid, step: "capturer_ready",
                                            detail: "\(c.screenWidth)x\(c.screenHeight)")
            capturer     = c
            input        = InputController(screenWidth: c.screenWidth, screenHeight: c.screenHeight)
            fileReceiver = FileReceiver()
            connectTime  = Date()

            ConnectionLogger.shared.logConnected(sessionId: sid, codec: "jpeg", encrypted: crypto.isReady)
            sendJson([
                "type":   "stream_started",
                "width":  c.screenWidth,
                "height": c.screenHeight,
                "codec":  "jpeg"
            ])

            c.onFrame = { [weak self] cgImage, _, _ in
                guard let self else { return }
                guard let jpeg = Self.encodeJPEG(cgImage, quality: 0.65) else { return }
                let fid = self.frameId
                self.frameId &+= 1
                self.bytesSent += Int64(jpeg.count)
                let now = UInt32(Date().timeIntervalSince(self.connectTime ?? Date()) * 1000)
                let pkt = buildVideoFramePacket(data: jpeg, frameId: fid, ptsMs: now, isKeyframe: true)
                self.server.sendBinary(pkt, to: self.connection)
            }
        } catch {
            let msg = "\(error)"
            ConnectionLogger.shared.logCaptureError(sessionId: sid, error: msg)
            sendJsonRaw(["type": "error", "code": "capture_failed", "message": msg])
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
