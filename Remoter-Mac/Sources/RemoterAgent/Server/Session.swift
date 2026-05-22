import Foundation
import Network
import AppKit

// Manages one connected client: auth → capture → encode → stream
// Video: WebRTC DataChannel (UDP) preferred, WebSocket fallback
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

    private var authenticated = false
    private var frameId: UInt32 = 0
    private var startTime: UInt32 = 0

    init(id: UUID, connection: NWConnection, server: WebSocketServer, pin: String) {
        self.id = id
        self.connection = connection
        self.server = server
        self.pin = pin
    }

    func start() {
        sendJson(["type": "hello", "version": "1.0", "os": "macOS"])
    }

    func handleText(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        let msg = ClientMessage.parse(json)

        // ── 认证 ──────────────────────────────────────────────
        if case .auth(let clientPin) = msg {
            if clientPin == pin {
                authenticated = true
                sendJson(["type": "auth_ok"])
                Task { await self.beginCapture() }
            } else {
                sendJson(["type": "error", "code": "auth_failed", "message": "Wrong PIN"])
                connection.cancel()
            }
            return
        }

        guard authenticated else { return }

        switch msg {

        // ── 输入事件（通过 WebSocket，UDP 丢包不影响控制准确性）──
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

        default:
            break
        }
    }

    func handleBinary(_ data: Data) {
        guard authenticated, data.count > 1, data[0] == FrameType.fileChunk.rawValue else { return }
        guard data.count > 21 else { return }
        let idData = data[1..<17]
        let fid = String(data: idData, encoding: .utf8)?
            .trimmingCharacters(in: .init(charactersIn: "\0")) ?? ""
        var offsetBE: UInt32 = 0
        (data[17..<21] as NSData).getBytes(&offsetBE, length: 4)
        let offset = CFSwapInt32BigToHost(offsetBE)
        fileReceiver?.receive(id: fid, offset: Int64(offset), chunk: Data(data[21...]))
    }

    func close() {
        Task { await capturer?.stop() }
        encoder?.invalidate()
        webrtc?.close()
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
            // DataChannel 建立后强制一个关键帧
            self?.encoder?.forceKeyframe()
        }
        agent.onDisconnected = { [weak self] in
            // DataChannel 断开，视频自动回落到 WebSocket（onEncodedFrame 里判断）
            print("[Session] WebRTC disconnected, falling back to WebSocket")
        }
        // DataChannel 上收到的控制消息，路由到和 WebSocket 一样的处理逻辑
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

        c.onFrame = { [weak enc] buf in enc?.encode(sampleBuffer: buf) }

        enc.onEncodedFrame = { [weak self] data, isKeyframe in
            guard let self else { return }
            let fid = self.frameId
            self.frameId &+= 1

            // 优先走 WebRTC DataChannel（UDP），否则 WebSocket 兜底
            if let rtc = self.webrtc, rtc.isVideoChannelOpen {
                rtc.sendVideoFrame(data, isKeyframe: isKeyframe, frameId: fid)
            } else {
                let now = UInt32(Date().timeIntervalSince1970 * 1000) - self.startTime
                let pkt = buildVideoFramePacket(data: data, frameId: fid, ptsMs: now, isKeyframe: isKeyframe)
                self.server.sendBinary(pkt, to: self.connection)
            }
        }

        do {
            try enc.setup(width: 2560, height: 1440, fps: 60, bitrate: 15_000_000)
            try await c.start(fps: 60)
            capturer     = c
            encoder      = enc
            input        = InputController(screenWidth: c.screenWidth, screenHeight: c.screenHeight)
            fileReceiver = FileReceiver()
            startTime    = UInt32(Date().timeIntervalSince1970 * 1000)
            sendJson([
                "type":   "stream_started",
                "width":  c.screenWidth,
                "height": c.screenHeight
            ])
        } catch {
            sendJson(["type": "error", "code": "capture_failed", "message": "\(error)"])
        }
    }

    private func sendJson(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else { return }
        server.sendText(text, to: connection)
    }
}
