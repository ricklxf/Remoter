import Foundation
import Network
import CryptoKit
import Security

typealias MessageHandler    = (NWConnection, String) -> Void
typealias BinaryHandler     = (NWConnection, Data)   -> Void
typealias DisconnectHandler = (NWConnection)          -> Void

final class WebSocketServer {
    var onConnect:    ((NWConnection) -> Void)?
    var onText:       MessageHandler?
    var onBinary:     BinaryHandler?
    var onDisconnect: DisconnectHandler?

    /// When set, plain HTTP GET requests on this port are served from this directory.
    var webDir: URL?

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "remoter.server", qos: .userInteractive)

    func start(port: UInt16) throws {
        let p = NWEndpoint.Port(rawValue: port)!
        // TLS (HTTPS/WSS) so browsers get a secure context and can use WebCodecs (H.264).
        // Falls back to plain TCP if the embedded cert is missing.
        let tlsParams = Self.makeTLSParameters()
        let params = tlsParams ?? .tcp
        let scheme = tlsParams != nil ? "wss/https" : "ws/http"
        ConnectionLogger.shared.logStep(sessionId: "tls", step: "listen_scheme", detail: scheme)
        let l = try NWListener(using: params, on: p)
        l.stateUpdateHandler = { state in
            switch state {
            case .ready:        print("[Server] Listening on :\(port) (\(scheme))")
            case .failed(let e): print("[Server] Failed: \(e)")
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        l.start(queue: queue)
        listener = l
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - TLS

    private static func makeTLSParameters() -> NWParameters? {
        guard let identity = loadIdentity() else { return nil }
        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tlsOptions.securityProtocolOptions, identity)
        return NWParameters(tls: tlsOptions)
    }

    // Retain the identity for the process lifetime so NW Framework can access the
    // private key at any point during TLS handshakes without it being deallocated.
    private static var tlsIdentity: SecIdentity?

    /// Load TLS identity entirely in-process — no keychain involved.
    ///
    /// SecPKCS12Import without kSecImportExportKeychain returns a temporary SecIdentity
    /// whose private key lives in process memory. secd is never consulted, so macOS
    /// never shows a keychain authorization dialog regardless of how many clients connect.
    private static func loadIdentity() -> sec_identity_t? {
        guard let p12URL  = Bundle.main.url(forResource: "server", withExtension: "p12"),
              let p12Data = try? Data(contentsOf: p12URL) else {
            ConnectionLogger.shared.logStep(sessionId: "tls", step: "p12_not_found")
            return nil
        }

        let opts: [String: Any] = [kSecImportExportPassphrase as String: "remoter"]
        var items: CFArray?
        let status = SecPKCS12Import(p12Data as CFData, opts as CFDictionary, &items)
        guard status == errSecSuccess,
              let arr  = items as? [[String: Any]],
              let first = arr.first,
              let id   = first[kSecImportItemIdentity as String] as! SecIdentity? else {
            ConnectionLogger.shared.logStep(sessionId: "tls", step: "p12_import_failed",
                detail: "status=\(status)")
            return nil
        }

        tlsIdentity = id
        ConnectionLogger.shared.logStep(sessionId: "tls", step: "identity_ok")
        return sec_identity_create(id)
    }

    func sendText(_ text: String, to conn: NWConnection) {
        guard let data = text.data(using: .utf8) else { return }
        sendFrame(opcode: 0x01, payload: data, to: conn)
    }

    func sendBinary(_ data: Data, to conn: NWConnection) {
        sendFrame(opcode: 0x02, payload: data, to: conn)
    }

    /// Video-frame variant: fires onSent when TCP has accepted the data, giving
    /// the caller real backpressure so frames are never queued ahead of the
    /// network's actual capacity.
    func sendBinaryVideo(_ data: Data, to conn: NWConnection, onSent: @escaping () -> Void) {
        var frame = Data()
        frame.append(0x82)                          // FIN + binary opcode
        let len = data.count
        if len < 126 {
            frame.append(UInt8(len))
        } else if len < 65536 {
            frame.append(126)
            frame.append(UInt8((len >> 8) & 0xFF))
            frame.append(UInt8( len       & 0xFF))
        } else {
            frame.append(127)
            for i in (0..<8).reversed() { frame.append(UInt8((len >> (i * 8)) & 0xFF)) }
        }
        frame.append(contentsOf: data)
        // One-shot guard: ensures onSent() fires exactly once even when both
        // the watchdog and contentProcessed callback race.
        let lock = NSLock()
        var completed = false
        let finish: (Bool) -> Void = { [weak self] cancel in
            lock.lock()
            let already = completed
            completed = true
            lock.unlock()
            guard !already else { return }
            if cancel {
                ConnectionLogger.shared.logStep(sessionId: "ws", step: "video_send_timeout")
                conn.cancel()
                // Immediately notify disconnect via server queue so the session's
                // encoder stops right away — avoids a flood of video_send_err while
                // the receive path slowly detects the cancel.
                self?.queue.async { [weak self] in self?.onDisconnect?(conn) }
            }
            onSent()
        }
        // Watchdog: if TCP flow-control stalls contentProcessed (client recv buffer full),
        // cancel the connection after 5s so the client can reconnect cleanly.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { finish(true) }
        conn.send(content: frame, completion: .contentProcessed { error in
            if let error {
                ConnectionLogger.shared.logStep(sessionId: "ws", step: "video_send_err",
                    detail: "\(error)")
            }
            finish(false)
        })
    }

    // MARK: - Accept + HTTP/WS dispatch

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, error in
            guard let self, let data, !data.isEmpty, error == nil else { conn.cancel(); return }
            let request = String(data: data.prefix(4096), encoding: .ascii) ?? ""
            if let wsKey = Self.extractHeader(request, "Sec-WebSocket-Key") {
                self.upgradeWS(conn: conn, key: wsKey)
            } else {
                self.serveHTTP(request: request, conn: conn)
            }
        }
    }

    // MARK: - WebSocket upgrade + frame loop

    private func upgradeWS(conn: NWConnection, key: String) {
        let combined = key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let accept   = Data(Insecure.SHA1.hash(data: Data(combined.utf8))).base64EncodedString()
        let resp     = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
        conn.send(content: Data(resp.utf8), completion: .contentProcessed { [weak self] _ in
            self?.onConnect?(conn)        // 握手完成即通知，不等第一条消息
            self?.recvFrames(conn: conn, reader: WsFrameReader())
        })
    }

    private func recvFrames(conn: NWConnection, reader: WsFrameReader) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self else { return }
            guard let data, !data.isEmpty, error == nil else {
                ConnectionLogger.shared.logStep(sessionId: "ws", step: "recv_disconnect",
                    detail: "err=\(String(describing: error)) emptyData=\(data?.isEmpty ?? true)")
                self.onDisconnect?(conn); return
            }
            var close = false
            reader.feed(data) { opcode, payload in
                switch opcode {
                case 0x01:
                    if let text = String(data: payload, encoding: .utf8) { self.onText?(conn, text) }
                case 0x02:
                    self.onBinary?(conn, payload)
                case 0x08:
                    close = true
                case 0x09: // ping → pong
                    self.sendFrame(opcode: 0x0A, payload: payload, to: conn)
                default: break
                }
            }
            if close {
                ConnectionLogger.shared.logStep(sessionId: "ws", step: "client_close_frame")
                self.onDisconnect?(conn); conn.cancel()
            }
            else { self.recvFrames(conn: conn, reader: reader) }
        }
    }

    private func sendFrame(opcode: UInt8, payload: Data, to conn: NWConnection) {
        var frame = Data()
        frame.append(0x80 | opcode)
        let len = payload.count
        if len < 126 {
            frame.append(UInt8(len))
        } else if len < 65536 {
            frame.append(126)
            frame.append(UInt8((len >> 8) & 0xFF))
            frame.append(UInt8( len       & 0xFF))
        } else {
            frame.append(127)
            for i in (0..<8).reversed() { frame.append(UInt8((len >> (i * 8)) & 0xFF)) }
        }
        frame.append(contentsOf: payload)
        conn.send(content: frame, completion: .idempotent)
    }

    // MARK: - HTTP file serving

    private func serveHTTP(request: String, conn: NWConnection) {
        guard let webDir else { conn.cancel(); return }
        let firstLine = request.components(separatedBy: "\r\n").first ?? ""
        let parts     = firstLine.components(separatedBy: " ")
        guard parts.count >= 2, parts[0] == "GET" else { conn.cancel(); return }

        let rawPath = parts[1].components(separatedBy: "?").first ?? "/"
        let rel     = rawPath == "/" ? "index.html" : String(rawPath.drop(while: { $0 == "/" }))
        var fileURL = webDir.appendingPathComponent(rel)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            fileURL = webDir.appendingPathComponent("index.html")
        }
        guard let body = try? Data(contentsOf: fileURL) else {
            let r = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"
            conn.send(content: Data(r.utf8), completion: .contentProcessed { _ in conn.cancel() })
            return
        }
        let mime   = Self.mimeType(for: fileURL.pathExtension)
        let header = "HTTP/1.1 200 OK\r\nContent-Type: \(mime)\r\nContent-Length: \(body.count)\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        conn.send(content: response, completion: .contentProcessed { _ in conn.cancel() })
    }

    private static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "html":         return "text/html; charset=utf-8"
        case "js", "mjs":    return "application/javascript"
        case "css":          return "text/css"
        case "ico":          return "image/x-icon"
        case "png":          return "image/png"
        case "jpg", "jpeg":  return "image/jpeg"
        case "svg":          return "image/svg+xml"
        case "woff2":        return "font/woff2"
        case "woff":         return "font/woff"
        case "json":         return "application/json"
        default:             return "application/octet-stream"
        }
    }

    // MARK: - Helpers

    private static func extractHeader(_ request: String, _ name: String) -> String? {
        let prefix = name.lowercased() + ": "
        for line in request.components(separatedBy: "\r\n") {
            if line.lowercased().hasPrefix(prefix) {
                return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}

// MARK: - WebSocket frame accumulator (handles fragmented TCP reads)

final class WsFrameReader {
    private var buf = Data()

    func feed(_ data: Data, handler: (UInt8, Data) -> Void) {
        buf.append(data)
        while tryParse(handler: handler) { }
    }

    private func tryParse(handler: (UInt8, Data) -> Void) -> Bool {
        guard buf.count >= 2 else { return false }
        let masked     = (buf[1] & 0x80) != 0
        var headerLen  = 2
        var payloadLen = Int(buf[1] & 0x7F)
        if payloadLen == 126 {
            guard buf.count >= 4 else { return false }
            payloadLen = (Int(buf[2]) << 8) | Int(buf[3])
            headerLen  = 4
        } else if payloadLen == 127 {
            guard buf.count >= 10 else { return false }
            payloadLen = 0
            for i in 2..<10 { payloadLen = (payloadLen << 8) | Int(buf[i]) }
            headerLen  = 10
        }
        let maskLen = masked ? 4 : 0
        let total   = headerLen + maskLen + payloadLen
        guard buf.count >= total else { return false }

        let opcode     = buf[0] & 0x0F
        let maskStart  = headerLen
        var payload    = Data(buf[(maskStart + maskLen) ..< total])
        if masked {
            for i in 0..<payload.count { payload[i] ^= buf[maskStart + (i % 4)] }
        }
        buf = Data(buf[total...])
        handler(opcode, payload)
        return true
    }
}
