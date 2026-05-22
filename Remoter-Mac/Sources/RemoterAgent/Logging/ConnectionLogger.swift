import Foundation

// JSON Lines 格式连接日志
// 存储路径：~/Library/Logs/Remoter/connections.log
// 菜单栏"查看日志"在 Finder 中打开该文件

final class ConnectionLogger {
    static let shared = ConnectionLogger()

    let logFileURL: URL

    private let queue = DispatchQueue(label: "remoter.logger", qos: .background)
    private let iso   = ISO8601DateFormatter()

    private init() {
        let dir = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Remoter", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        logFileURL = dir.appendingPathComponent("connections.log")
    }

    // MARK: - Log events

    func logAgentStarted(port: UInt16, relayURL: String?) {
        var d: [String: Any] = ["event": "agent_started", "port": port]
        if let r = relayURL { d["relay"] = r }
        write(d)
    }

    func logConnected(sessionId: String, codec: String, encrypted: Bool) {
        write(["event": "connected", "session": sessionId,
               "codec": codec, "encrypted": encrypted])
    }

    func logDisconnected(sessionId: String, durationSecs: Int,
                         bytesSentMB: Double, bytesRecvMB: Double) {
        write(["event": "disconnected", "session": sessionId,
               "duration_s": durationSecs,
               "sent_mb":    String(format: "%.2f", bytesSentMB),
               "recv_mb":    String(format: "%.2f", bytesRecvMB)])
    }

    func logAuthFailed(sessionId: String) {
        write(["event": "auth_failed", "session": sessionId])
    }

    func logCodecChanged(sessionId: String, codec: String) {
        write(["event": "codec_changed", "session": sessionId, "codec": codec])
    }

    // MARK: - Private

    private func write(_ extra: [String: Any]) {
        queue.async { [weak self] in
            guard let self else { return }
            var entry = extra
            entry["ts"] = self.iso.string(from: Date())

            guard let data = try? JSONSerialization.data(withJSONObject: entry),
                  let line = String(data: data, encoding: .utf8) else { return }
            let lineData = Data((line + "\n").utf8)

            if let fh = try? FileHandle(forWritingTo: self.logFileURL) {
                defer { try? fh.close() }
                try? fh.seekToEnd()
                try? fh.write(contentsOf: lineData)
            } else {
                try? lineData.write(to: self.logFileURL)
            }
        }
    }
}
