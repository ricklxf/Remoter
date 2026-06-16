import Foundation
import Network
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import ApplicationServices
import SystemConfiguration
import PamAuthHelper

// Manages one connected client: auth → capture → encode → stream
// Video: JPEG over WebSocket (bypasses VideoToolbox which hangs on macOS 26)
// Security: P-256 ECDH + AES-256-GCM end-to-end encryption (0xE0 frame prefix)
final class Session {
    let id: UUID
    let connection: NWConnection
    private let server: WebSocketServer
    private let pin: String

    private var capturer: ScreenCapturer?
    private var encoder: H264Encoder?
    private var input: InputController?
    private var fileReceiver: FileReceiver?
    private var webrtc: WebRTCAgent?
    private let crypto = E2ECrypto()

    private var authenticated = false
    private var frameId: UInt32 = 0
    private var inputEnabled = true
    private var jpegQuality: Double = 0.75

    // Video send semaphore: allow several small H.264 frames in flight so a
    // single high-RTT contentProcessed round-trip doesn't throttle throughput.
    // Frames are tiny (a few KB), so a small backlog adds negligible latency
    // while keeping the pipe full. Excess frames are dropped (backpressure).
    private let wsSendSem = DispatchSemaphore(value: 4)

    // Sent-frame diagnostics
    private var sentFrames = 0
    private var sentTick = Date()

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
                     "pubkey": crypto.publicKeyBase64,
                     "computerName": Self.computerName(),
                     "modelId": Self.modelId()])
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
        stopKeepalive()
        stopClipboardMonitor()
        encoder?.close()
        encoder = nil
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

        // ── PIN 认证 ──────────────────────────────────────────
        if case .auth(_) = msg {
            let token = TokenStore.shared.generate(username: "__pin__")
            authenticated = true
            ConnectionLogger.shared.logAuthSuccess(sessionId: id.uuidString)
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
        case .mouseMove(let x, let y):
            guard inputEnabled else { break }
            if !loggedFirstInput {
                loggedFirstInput = true
                ConnectionLogger.shared.logStep(sessionId: id.uuidString, step: "first_input",
                                                detail: "input=\(input != nil), ax=\(AXIsProcessTrusted())")
            }
            input?.mouseMove(x: x, y: y)

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

        case .qualitySet(let fps, let bitrate):
            capturer?.updateFps(fps)
            jpegQuality = bitrateToJpegQuality(bitrate)

        case .ping:
            sendJson(["type": "pong"])

        // ── WebRTC 信令 ────────────────────────────────────────
        case .webrtcOffer(let sdp):
            setupWebRTC(offerSDP: sdp)

        case .webrtcICE(let json):
            webrtc?.handleRemoteICE(json)

        case .clientStats:
            break  // JPEG 模式下无 ABR

        case .setCodec(let codec):
            if codec == "jpeg" { switchToJpeg() }

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
            try await c.start(fps: 60)
            ConnectionLogger.shared.logStep(sessionId: sid, step: "capturer_ready",
                                            detail: "\(c.screenWidth)x\(c.screenHeight)")
            capturer     = c
            input        = InputController(screenWidth: c.physWidth, screenHeight: c.physHeight)
            fileReceiver = FileReceiver()
            connectTime  = Date()

            // Set up H.264 encoder
            encoder?.close()
            let enc = H264Encoder()
            try enc.setup(width: c.screenWidth, height: c.screenHeight, fps: 60, bitrateBps: 8_000_000)
            encoder = enc

            ConnectionLogger.shared.logConnected(sessionId: sid, codec: "h264", encrypted: crypto.isReady)
            startClipboardMonitor()
            startKeepalive()
            sendJson([
                "type":   "stream_started",
                "width":  c.screenWidth,
                "height": c.screenHeight,
                "codec":  "h264"
            ])

            enc.onEncodedFrame = { [weak self] data, isKeyframe in
                guard let self else { return }
                guard self.wsSendSem.wait(timeout: .now()) == .success else { return }

                let fid = self.frameId
                self.frameId &+= 1
                self.bytesSent += Int64(data.count)

                let now = UInt32(Date().timeIntervalSince(self.connectTime ?? Date()) * 1000)
                let pkt = buildVideoFramePacket(data: data, frameId: fid, ptsMs: now, isKeyframe: isKeyframe)
                self.server.sendBinaryVideo(pkt, to: self.connection) {
                    self.wsSendSem.signal()
                    self.sentFrames += 1
                    let dt = Date().timeIntervalSince(self.sentTick)
                    if dt >= 5 {
                        ConnectionLogger.shared.logStep(sessionId: self.id.uuidString,
                            step: "sent_5s", detail: "sent=\(self.sentFrames) fps=\(String(format: "%.0f", Double(self.sentFrames)/dt))")
                        self.sentFrames = 0
                        self.sentTick = Date()
                    }
                }

                if fid == 0 {
                    ConnectionLogger.shared.logStep(sessionId: self.id.uuidString,
                        step: "first_frame_h264", detail: "\(data.count)B keyframe=\(isKeyframe)")
                }
            }

            c.onFrame = { [weak self] cgImage, _, _ in
                guard let self else { return }
                self.encoder?.encode(cgImage)
            }

            // CGDisplayStream stops when macOS locks the screen, goes to sleep,
            // or revokes screen recording permission. Restart the stream so the
            // client resumes automatically when the display comes back.
            c.onStopped = { [weak self] in
                guard let self else { return }
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
        encoder?.close()
        encoder = nil
        ConnectionLogger.shared.logStep(sessionId: id.uuidString, step: "codec_switch", detail: "h264→jpeg")
        sendJson([
            "type":   "stream_started",
            "width":  c.screenWidth,
            "height": c.screenHeight,
            "codec":  "jpeg"
        ])
        c.onFrame = { [weak self] cgImage, _, _ in
            guard let self else { return }
            guard let jpeg = Self.encodeJPEG(cgImage, quality: self.jpegQuality) else { return }
            guard self.wsSendSem.wait(timeout: .now()) == .success else { return }
            let fid = self.frameId
            self.frameId &+= 1
            self.bytesSent += Int64(jpeg.count)
            let now = UInt32(Date().timeIntervalSince(self.connectTime ?? Date()) * 1000)
            let pkt = buildVideoFramePacket(data: jpeg, frameId: fid, ptsMs: now, isKeyframe: true)
            self.server.sendBinaryVideo(pkt, to: self.connection) {
                self.wsSendSem.signal()
            }
        }
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

            server.sendBinary(pkt, to: connection)
            offset += CHUNK
        }

        sendJson(["type": "file_end", "id": idStr])
        print("[Session] sendFile: sent \(name) (\(size) bytes)")
    }
}
