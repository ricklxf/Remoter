import Foundation
import Network

/// Minimal static-file HTTP server for serving the Remoter web client.
/// Files are served from `<app bundle>/Contents/Resources/web/`.
/// SPA routing: requests for unknown paths fall back to index.html.
final class HTTPFileServer {

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "remoter.http", qos: .utility)

    /// Directory containing the web build (nil → not embedded, server won't start)
    let webDir: URL?

    var isEnabled: Bool { webDir != nil }

    init() {
        if let res = Bundle.main.resourceURL {
            let dir = res.appendingPathComponent("web")
            webDir = FileManager.default.fileExists(atPath: dir.path) ? dir : nil
        } else {
            webDir = nil
        }
    }

    func start(port: UInt16) {
        guard let webDir else { return }

        let params = NWParameters.tcp
        guard let p = NWEndpoint.Port(rawValue: port),
              let l = try? NWListener(using: params, on: p) else { return }

        l.stateUpdateHandler = { state in
            if case .ready = state {
                print("[HTTP] Web client: http://localhost:\(port)")
            }
        }
        l.newConnectionHandler = { [weak self] conn in
            conn.start(queue: self?.queue ?? .global())
            self?.handle(conn, webDir: webDir)
        }
        l.start(queue: queue)
        listener = l
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Private

    private func handle(_ conn: NWConnection, webDir: URL) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let data, !data.isEmpty else { conn.cancel(); return }
            let path = Self.parsePath(data)
            self?.serve(path: path, webDir: webDir, to: conn)
        }
    }

    private static func parsePath(_ data: Data) -> String {
        let str = String(data: data.prefix(1024), encoding: .utf8) ?? ""
        let firstLine = str.components(separatedBy: "\r\n").first ?? ""
        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return "/" }
        return parts[1].removingPercentEncoding ?? parts[1]
    }

    private func serve(path: String, webDir: URL, to conn: NWConnection) {
        // Strip query string
        let cleanPath = path.components(separatedBy: "?").first ?? path

        // Map path to file
        let relative = cleanPath == "/" ? "index.html"
                                       : String(cleanPath.drop(while: { $0 == "/" }))
        var fileURL = webDir.appendingPathComponent(relative)

        // SPA fallback: unknown paths (no dot extension) → index.html
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            fileURL = webDir.appendingPathComponent("index.html")
        }

        guard let body = try? Data(contentsOf: fileURL) else {
            send("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n", to: conn)
            return
        }

        let mime = Self.mimeType(for: fileURL.pathExtension)
        let header = "HTTP/1.1 200 OK\r\n"
                   + "Content-Type: \(mime)\r\n"
                   + "Content-Length: \(body.count)\r\n"
                   + "Cache-Control: no-cache\r\n"
                   + "\r\n"
        var response = Data(header.utf8)
        response.append(body)
        conn.send(content: response, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func send(_ text: String, to conn: NWConnection) {
        conn.send(content: Data(text.utf8),
                  completion: .contentProcessed { _ in conn.cancel() })
    }

    static func mimeType(for ext: String) -> String {
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
}
