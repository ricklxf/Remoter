import Foundation

// 纯文本日志，对齐格式
// 存储路径：~/Library/Logs/Remoter/connections.log
// 菜单栏"查看日志"在 Finder 中打开该文件

final class ConnectionLogger {
    static let shared = ConnectionLogger()

    let logFileURL: URL

    private let queue = DispatchQueue(label: "remoter.logger", qos: .background)
    private let iso: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone   = TimeZone(identifier: "Asia/Shanghai")
        return f
    }()

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

    /// 客户端 TCP/WebSocket 握手完成，尚未认证
    func logClientConnected(sessionId: String, remoteAddr: String) {
        write(["event": "client_connected", "session": sessionId, "remote": remoteAddr])
    }

    /// PIN 认证通过
    func logAuthSuccess(sessionId: String) {
        write(["event": "auth_success", "session": sessionId])
    }

    /// PIN 认证失败
    func logAuthFailed(sessionId: String) {
        write(["event": "auth_failed", "session": sessionId])
    }

    /// 屏幕捕获 / 编码器启动失败
    func logCaptureError(sessionId: String, error: String) {
        write(["event": "capture_error", "session": sessionId, "error": error])
    }

    /// 流已成功启动
    func logConnected(sessionId: String, codec: String, encrypted: Bool) {
        write(["event": "stream_started", "session": sessionId,
               "codec": codec, "encrypted": encrypted])
    }

    func logDisconnected(sessionId: String, durationSecs: Int,
                         bytesSentMB: Double, bytesRecvMB: Double) {
        write(["event": "disconnected", "session": sessionId,
               "duration_s": durationSecs,
               "sent_mb":    String(format: "%.2f", bytesSentMB),
               "recv_mb":    String(format: "%.2f", bytesRecvMB)])
    }

    func logCodecChanged(sessionId: String, codec: String) {
        write(["event": "codec_changed", "session": sessionId, "codec": codec])
    }

    /// 通用步骤日志（用于采集流程中间步骤的诊断）
    func logStep(sessionId: String, step: String, detail: String? = nil) {
        var d: [String: Any] = ["event": "step", "session": sessionId, "step": step]
        if let detail { d["detail"] = detail }
        write(d)
    }

    /// E2E 握手状态
    func logE2E(sessionId: String, state: String) {
        write(["event": "e2e", "session": sessionId, "state": state])
    }

    /// 权限检查结果
    func logPermission(event: String, detail: String? = nil) {
        var d: [String: Any] = ["event": event]
        if let detail { d["detail"] = detail }
        write(d)
    }

    // MARK: - Private

    private func write(_ fields: [String: Any]) {
        queue.async { [weak self] in
            guard let self else { return }

            let ts    = self.iso.string(from: Date())
            let event = fields["event"] as? String ?? "unknown"

            // 事件名：step 类展示为 step/xxx，其余直接用 event 值
            let tag: String
            if event == "step", let step = fields["step"] as? String {
                tag = "step/\(step)"
            } else {
                tag = event
            }

            // 附加字段（去掉 event/step，按固定顺序排列常用字段）
            let keyOrder = ["session", "remote", "codec", "detail",
                            "error", "state", "port", "relay",
                            "duration_s", "sent_mb", "recv_mb",
                            "encrypted", "step"]
            var extras: [String] = []
            for key in keyOrder {
                guard key != "event", key != "step" || event != "step" else { continue }
                if let val = fields[key] {
                    // session 只显示前 8 位
                    if key == "session", let s = val as? String {
                        extras.append("session=\(s.prefix(8))")
                    } else {
                        extras.append("\(key)=\(val)")
                    }
                }
            }
            // 其他未列出的字段追加在末尾
            let knownKeys = Set(keyOrder + ["event"])
            for key in fields.keys.sorted() where !knownKeys.contains(key) {
                extras.append("\(key)=\(fields[key]!)")
            }

            let tagPadded = tag.padding(toLength: 24, withPad: " ", startingAt: 0)
            let line = "\(ts)  \(tagPadded)  \(extras.joined(separator: "  "))"

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
