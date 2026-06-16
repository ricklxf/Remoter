import Foundation
import AppKit
import Network

// MARK: - 命令行参数

struct Config {
    var pin: String    = ""
    var port: UInt16   = 7788
    var relayURL: String = ""
}

func parseArgs() -> (pin: String?, port: UInt16?, relayURL: String?) {
    var pin: String?     = nil
    var port: UInt16?    = nil
    var relayURL: String? = nil
    var args = CommandLine.arguments.dropFirst()
    while !args.isEmpty {
        let arg = args.removeFirst()
        switch arg {
        case "--pin":
            if !args.isEmpty { pin = String(args.removeFirst()) }
        case "--port":
            if !args.isEmpty, let p = UInt16(String(args.removeFirst())) { port = p }
        case "--relay":
            if !args.isEmpty { relayURL = String(args.removeFirst()) }
        default: break
        }
    }
    return (pin, port, relayURL)
}

// MARK: - RemoterAgent

final class RemoterAgent {
    private let config: Config
    private let wsServer = WebSocketServer()
    private let webDir: URL? = {
        guard let res = Bundle.main.resourceURL else { return nil }
        let dir = res.appendingPathComponent("web")
        return FileManager.default.fileExists(atPath: dir.path) ? dir : nil
    }()
    private var sessions: [UUID: Session] = [:]
    private var relaySessionId: String?
    private var pin = ""

    var onStatusUpdate: ((AgentStatus) -> Void)?

    init(config: Config) { self.config = config }

    // Non-blocking setup; run loop is owned by NSApplication
    func start() throws {
        pin = config.pin.isEmpty ? generatePin() : config.pin
        // Persist the effective PIN so next launch reuses it
        var c = AgentConfig.load(); c.pin = pin; c.save()

        wsServer.onConnect = { [weak self] conn in
            guard let self else { return }
            _ = self.getOrCreate(conn: conn)   // 握手完成立刻创建 Session，发送 hello
        }
        wsServer.onText = { [weak self] conn, text in
            guard let self else { return }
            self.getOrCreate(conn: conn).handleText(text)
        }
        wsServer.onBinary = { [weak self] conn, data in
            guard let self else { return }
            self.getOrCreate(conn: conn).handleBinary(data)
        }
        wsServer.onDisconnect = { [weak self] conn in
            self?.removeSession(for: conn)
        }

        wsServer.webDir = webDir
        try wsServer.start(port: config.port)

        let ips    = getLocalIPs()
        let vpnIPs = getVPNIPs()
        print("╔══════════════════════════════════╗")
        print("║        Remoter Mac Agent          ║")
        print("╚══════════════════════════════════╝")
        print("  PIN : \(pin)")
        print("  Port: \(config.port)")
        ips.forEach    { print("  LAN : wss://\($0):\(config.port)") }
        vpnIPs.forEach { print("  VPN : wss://\($0):\(config.port)") }
        if webDir != nil {
            let host = getLocalHostname()
            print("  Web : https://\(host):\(config.port)/  ← 推荐（.local 固定不变）")
            ips.forEach    { print("  Web : https://\($0):\(config.port)/") }
            vpnIPs.forEach { print("  Web : https://\($0):\(config.port)/") }
        }

        if !config.relayURL.isEmpty, let url = URL(string: config.relayURL) {
            connectRelay(url: url)
        }

        notifyStatus()
        print("\nReady. Waiting for connections…\n")
    }

    // MARK: - Private

    private func getOrCreate(conn: NWConnection) -> Session {
        if let s = sessions.values.first(where: { $0.connection === conn }) { return s }
        let id = UUID()
        let s  = Session(id: id, connection: conn, server: wsServer, pin: pin)
        sessions[id] = s
        s.start()
        return s
    }

    private func removeSession(for conn: NWConnection) {
        if let entry = sessions.first(where: { $0.value.connection === conn }) {
            entry.value.close()
            sessions.removeValue(forKey: entry.key)
            notifyStatus()
        }
    }

    private func connectRelay(url: URL) {
        let relay = RelayClient()
        relay.onConnected = { [weak self] sid in
            guard let self else { return }
            self.relaySessionId = sid
            print("  Relay session ID: \(sid)")
            self.notifyStatus()
        }
        relay.onText = { [weak self] text in
            // relay 消息广播给所有活跃 session（通常只有一个）
            self?.sessions.values.forEach { $0.handleText(text) }
        }
        relay.onBinary = { [weak self] data in
            self?.sessions.values.forEach { $0.handleBinary(data) }
        }
        relay.onDisconnected = { [weak self] in
            guard let self else { return }
            self.relaySessionId = nil
            self.notifyStatus()
            print("[Relay] disconnected, retrying in 5s…")
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                self.connectRelay(url: url)
            }
        }
        relay.connect(relayURL: url, pin: pin)
    }

    func sendFileToAllSessions(_ url: URL) {
        sessions.values.forEach { $0.sendFile(url) }
    }

    private func notifyStatus() {
        let status = AgentStatus(
            pin: pin,
            sessionId: relaySessionId,
            localIPs: getLocalIPs(),
            vpnIPs: getVPNIPs(),
            connectedClients: sessions.count,
            webEnabled: webDir != nil,
            port: config.port,
            localHostname: getLocalHostname()
        )
        DispatchQueue.main.async { [weak self] in
            self?.onStatusUpdate?(status)
        }
    }

    private func generatePin() -> String {
        String(format: "%06d", Int.random(in: 100_000..<999_999))
    }
}

// MARK: - Helpers

// Returns all non-loopback IPv4 addresses with their interface name.
func getIfaceAddresses() -> [(ifname: String, ip: String)] {
    var result: [(String, String)] = []
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0 else { return [] }
    defer { freeifaddrs(ifaddr) }
    var ptr = ifaddr
    while let p = ptr {
        let fa = p.pointee
        if fa.ifa_addr.pointee.sa_family == UInt8(AF_INET) {
            let name = String(cString: fa.ifa_name)
            var addr = fa.ifa_addr.pointee
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(&addr, socklen_t(fa.ifa_addr.pointee.sa_len),
                        &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let ip = String(cString: host)
            if ip != "127.0.0.1" { result.append((name, ip)) }
        }
        ptr = fa.ifa_next
    }
    return result
}

// Tailscale uses the CGNAT range 100.64.0.0/10 (100.64–100.127).
// ZeroTier interface names start with "zt".
func isVPNIface(_ ifname: String, _ ip: String) -> Bool {
    ip.hasPrefix("100.") || ifname.hasPrefix("zt")
}

func getLocalIPs() -> [String] {
    getIfaceAddresses().filter { !isVPNIface($0.ifname, $0.ip) }.map { $0.ip }
}

func getVPNIPs() -> [String] {
    getIfaceAddresses().filter { isVPNIface($0.ifname, $0.ip) }.map { $0.ip }
}

func getLocalHostname() -> String {
    var name = [CChar](repeating: 0, count: 256)
    gethostname(&name, 256)
    let host = String(cString: name)
    // 去掉 .local 后缀再统一加回来，避免重复
    let base = host.hasSuffix(".local") ? String(host.dropLast(6)) : host
    return "\(base).local"
}

// MARK: - Entry point

// CLI args override persisted config; PIN is generated later if still empty.
let (cliPin, cliPort, cliRelay) = parseArgs()
let diskCfg = AgentConfig.load()

var cfg = Config()
cfg.pin      = cliPin    ?? (diskCfg.pin.isEmpty ? "" : diskCfg.pin)
cfg.port     = cliPort   ?? diskCfg.port
cfg.relayURL = cliRelay  ?? diskCfg.relayUrl

let menuBar    = MainActor.assumeIsolated { MenuBarController() }
let agent      = RemoterAgent(config: cfg)

agent.onStatusUpdate = { status in
    DispatchQueue.main.async {
        MainActor.assumeIsolated { menuBar.update(status) }
    }
}

MainActor.assumeIsolated {
    menuBar.onSendFile = { url in
        agent.sendFileToAllSessions(url)
    }
}

NSApplication.shared.delegate = menuBar

// 在主 RunLoop 启动前，先在后台 Task 中启动 Agent
Task.detached {
    do {
        try agent.start()
    } catch {
        await MainActor.run {
            let alert = NSAlert()
            alert.messageText     = "Remoter 启动失败"
            alert.informativeText = "\(error)"
            alert.runModal()
            NSApp.terminate(nil)
        }
    }
}

// NSApplication.run() 接管主线程 RunLoop（同时驱动菜单栏）
NSApplication.shared.run()
