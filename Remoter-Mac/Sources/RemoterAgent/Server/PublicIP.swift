import Foundation

// Discovers this machine's apparent public-facing IP by asking an external
// echo service — more reliable than reading local interfaces, since those
// only show a private address when there's a router doing NAT/forwarding in
// front (the public IP itself isn't bound to any local interface in that case).
// Fetched once at startup and cached; refreshed periodically in case the ISP
// rotates the address.
actor PublicIPResolver {
    static let shared = PublicIPResolver()

    private var cached: String?

    func current() -> String? { cached }

    // Tries multiple echo services — some networks/proxies block one but not
    // another (seen in practice: api.ipify.org failing TLS through a local
    // proxy while icanhazip.com succeeds on the same machine).
    private static let echoServices = [
        "https://icanhazip.com",
        "https://ifconfig.me",
        "https://api.ipify.org",
    ]

    func refresh() async {
        for service in Self.echoServices {
            guard let url = URL(string: service) else { continue }
            var req = URLRequest(url: url)
            req.timeoutInterval = 5
            do {
                let (data, _) = try await URLSession.shared.data(for: req)
                guard let ip = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !ip.isEmpty else { continue }
                cached = ip
                ConnectionLogger.shared.logStep(sessionId: "turn", step: "public_ip_resolved",
                    detail: "\(ip) via \(service) isIPv6=\(ip.contains(":"))")
                return
            } catch {
                ConnectionLogger.shared.logStep(sessionId: "turn", step: "public_ip_try_failed",
                    detail: "\(service): \(error)")
            }
        }
    }

    // TURN/STUN URI syntax requires IPv6 literals in brackets: turn:[::1]:3478.
    // IPv4 / hostnames pass through unchanged.
    nonisolated func bracketedForURI(_ ip: String) -> String {
        ip.contains(":") ? "[\(ip)]" : ip
    }

    func startPeriodicRefresh() {
        Task {
            while true {
                await refresh()
                try? await Task.sleep(nanoseconds: 10 * 60 * 1_000_000_000) // 10 min
            }
        }
    }
}
