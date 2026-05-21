import Foundation
import Network
import AppKit

// Manages one connected client: auth → capture → encode → stream
final class Session {
    let id: UUID
    let connection: NWConnection
    private let server: WebSocketServer
    private let pin: String

    private var capturer: ScreenCapturer?
    private var encoder: VideoEncoder?
    private var input: InputController?
    private var fileReceiver: FileReceiver?

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
            Task { try? await self.capturer?.updateConfig(fps: fps, width: capturer?.screenWidth ?? 2560, height: capturer?.screenHeight ?? 1440) }
            encoder?.forceKeyframe()
            _ = bitrate // bitrate change would require encoder re-setup

        case .ping:
            sendJson(["type": "pong"])

        default:
            break
        }
    }

    func handleBinary(_ data: Data) {
        guard authenticated, data.count > 1, data[0] == FrameType.fileChunk.rawValue else { return }
        // [0x02][16B id][4B offset BE][rest: chunk data]
        guard data.count > 21 else { return }
        let idData = data[1..<17]
        let fid = String(data: idData, encoding: .utf8)?.trimmingCharacters(in: .init(charactersIn: "\0")) ?? ""
        var offsetBE: UInt32 = 0
        (data[17..<21] as NSData).getBytes(&offsetBE, length: 4)
        let offset = CFSwapInt32BigToHost(offsetBE)
        let chunk = data[21...]
        fileReceiver?.receive(id: fid, offset: Int64(offset), chunk: Data(chunk))
    }

    func close() {
        Task { await capturer?.stop() }
        encoder?.invalidate()
    }

    // MARK: - Private

    private func beginCapture() async {
        let c = ScreenCapturer()
        let enc = VideoEncoder()

        c.onFrame = { [weak self, weak enc] buf in
            enc?.encode(sampleBuffer: buf)
        }

        enc.onEncodedFrame = { [weak self] data, isKeyframe in
            guard let self else { return }
            let now = UInt32(Date().timeIntervalSince1970 * 1000) - self.startTime
            let packet = buildVideoFramePacket(
                data: data, frameId: self.frameId, ptsMs: now, isKeyframe: isKeyframe
            )
            self.frameId &+= 1
            self.server.sendBinary(packet, to: self.connection)
        }

        do {
            try enc.setup(
                width: 2560, height: 1440, fps: 60,
                bitrate: 15_000_000
            )
            try await c.start(fps: 60)
            self.capturer = c
            self.encoder = enc
            self.input = InputController(screenWidth: c.screenWidth, screenHeight: c.screenHeight)
            self.fileReceiver = FileReceiver()
            self.startTime = UInt32(Date().timeIntervalSince1970 * 1000)
            sendJson([
                "type": "stream_started",
                "width": c.screenWidth,
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
