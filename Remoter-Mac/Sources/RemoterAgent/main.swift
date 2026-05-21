import Foundation
import Network

// MARK: - Argument parsing

struct Config {
    var pin: String = ""
    var port: UInt16 = 7788
    var relayURL: String = ""
}

func parseArgs() -> Config {
    var config = Config()
    var args = CommandLine.arguments.dropFirst()
    while !args.isEmpty {
        let arg = args.removeFirst()
        switch arg {
        case "--pin":
            config.pin = args.isEmpty ? "" : String(args.removeFirst())
        case "--port":
            config.port = UInt16(args.isEmpty ? "7788" : String(args.removeFirst())) ?? 7788
        case "--relay":
            config.relayURL = args.isEmpty ? "" : String(args.removeFirst())
        default:
            break
        }
    }
    return config
}

// MARK: - Agent

final class RemoterAgent {
    private let config: Config
    private let wsServer = WebSocketServer()
    private var sessions: [UUID: Session] = [:]
    private var relaySession: RelaySession?

    init(config: Config) {
        self.config = config
    }

    func run() throws {
        let pin = config.pin.isEmpty ? generatePin() : config.pin
        print("╔══════════════════════════════════╗")
        print("║        Remoter Mac Agent          ║")
        print("╚══════════════════════════════════╝")
        print("  PIN: \(pin)")

        wsServer.onText = { [weak self] conn, text in
            self?.route(conn: conn, text: text)
        }
        wsServer.onBinary = { [weak self] conn, data in
            self?.route(conn: conn, binary: data)
        }
        wsServer.onDisconnect = { [weak self] conn in
            self?.removeSession(for: conn)
        }

        // Register new connections as sessions
        wsServer.onText = { [weak self] conn, text in
            guard let self else { return }
            let session = self.getOrCreateSession(for: conn, pin: pin)
            session.handleText(text)
        }
        wsServer.onBinary = { [weak self] conn, data in
            guard let self else { return }
            let session = self.getOrCreateSession(for: conn, pin: pin)
            session.handleBinary(data)
        }

        try wsServer.start(port: config.port)

        // Print local IPs
        let ips = getLocalIPs()
        print("\n  Direct connections (LAN):")
        for ip in ips {
            print("    ws://\(ip):\(config.port)")
        }

        // Connect to relay if configured
        if !config.relayURL.isEmpty, let url = URL(string: config.relayURL) {
            startRelaySession(relayURL: url, pin: pin)
        }

        print("\nReady. Waiting for connections...\n")
        RunLoop.main.run()
    }

    // MARK: - Private

    private func getOrCreateSession(for conn: NWConnection, pin: String) -> Session {
        let existing = sessions.values.first { $0.connection === conn }
        if let s = existing { return s }
        let id = UUID()
        let s = Session(id: id, connection: conn, server: wsServer, pin: pin)
        sessions[id] = s
        s.start()
        return s
    }

    private func removeSession(for conn: NWConnection) {
        if let entry = sessions.first(where: { $0.value.connection === conn }) {
            entry.value.close()
            sessions.removeValue(forKey: entry.key)
            print("[Agent] Session closed: \(entry.key)")
        }
    }

    private func route(conn: NWConnection, text: String) { }
    private func route(conn: NWConnection, binary: Data) { }

    private func startRelaySession(relayURL: URL, pin: String) {
        let relay = RelayClient()
        relay.onConnected = { sid in
            print("\n  Relay session ID: \(sid)")
            print("  Use this ID to connect from the Windows client\n")
        }
        relay.onDisconnected = {
            print("[Relay] Disconnected. Reconnecting in 5s...")
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.startRelaySession(relayURL: relayURL, pin: pin)
            }
        }
        relay.connect(relayURL: relayURL, pin: pin)
    }

    private func generatePin() -> String {
        String(format: "%06d", Int.random(in: 100_000..<999_999))
    }
}

func getLocalIPs() -> [String] {
    var addresses: [String] = []
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0 else { return [] }
    defer { freeifaddrs(ifaddr) }
    var ptr = ifaddr
    while let p = ptr {
        let fa = p.pointee
        if fa.ifa_addr.pointee.sa_family == UInt8(AF_INET) {
            var addr = fa.ifa_addr.pointee
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(&addr, socklen_t(fa.ifa_addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let ip = String(cString: host)
            if ip != "127.0.0.1" { addresses.append(ip) }
        }
        ptr = fa.ifa_next
    }
    return addresses
}

// MARK: - Entry

let cfg = parseArgs()
let agent = RemoterAgent(config: cfg)
do {
    try agent.run()
} catch {
    fputs("Fatal error: \(error)\n", stderr)
    exit(1)
}
