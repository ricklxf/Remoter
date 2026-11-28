import Foundation
import Combine
import Darwin

/// A Remoter host discovered on the local network via Bonjour / mDNS (`_remoter._tcp.`).
public struct DiscoveredLanPeer: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let host: String
    public let wsPort: Int
    public let udpPort: Int
    public let os: String
    public let version: String

    public init(
        id: String,
        name: String,
        host: String,
        wsPort: Int,
        udpPort: Int,
        os: String,
        version: String
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.wsPort = wsPort
        self.udpPort = udpPort
        self.os = os
        self.version = version
    }
}

/// Discovers `_remoter._tcp.` hosts on the local network using Bonjour (`NetServiceBrowser`)
/// and publishes resolved LAN peers for one-click connection in `ConnectWindowController`.
public final class LanDiscoveryBrowser: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate, @unchecked Sendable {
    @Published public private(set) var peers: [DiscoveredLanPeer] = []
    public var onPeersChanged: (([DiscoveredLanPeer]) -> Void)?

    private let browser = NetServiceBrowser()
    private var resolvingServices: [NetService] = []
    private var peersByKey: [String: DiscoveredLanPeer] = [:]
    private var isBrowsing = false

    public override init() {
        super.init()
        browser.delegate = self
    }

    deinit {
        stop()
    }

    public func start() {
        let work = { [weak self] in
            guard let self, !self.isBrowsing else { return }
            self.isBrowsing = true
            self.peersByKey.removeAll()
            self.publishPeers()
            self.browser.schedule(in: .main, forMode: .common)
            self.browser.searchForServices(ofType: "_remoter._tcp.", inDomain: "local.")
        }
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    public func stop() {
        let work = { [weak self] in
            guard let self else { return }
            self.isBrowsing = false
            self.browser.stop()
            self.browser.remove(from: .main, forMode: .common)
            for svc in self.resolvingServices {
                svc.stop()
                svc.delegate = nil
            }
            self.resolvingServices.removeAll()
        }
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    // MARK: - NetServiceBrowserDelegate

    public func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        resolvingServices.append(service)
        service.schedule(in: .main, forMode: .common)
        service.resolve(withTimeout: 5.0)
    }

    public func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        let key = Self.serviceKey(service)
        resolvingServices.removeAll { $0 === service || Self.serviceKey($0) == key }
        if peersByKey.removeValue(forKey: key) != nil {
            publishPeers()
        }
    }

    public func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        isBrowsing = false
    }

    // MARK: - NetServiceDelegate

    public func netServiceDidResolveAddress(_ sender: NetService) {
        let key = Self.serviceKey(sender)
        let txtDict = sender.txtRecordData().map { NetService.dictionary(fromTXTRecord: $0) } ?? [:]
        let txtString: (String) -> String? = { k in
            guard let data = txtDict[k] else { return nil }
            return String(data: data, encoding: .utf8)
        }

        // Hosts with several NICs resolve to several addresses; the server names its primary one in TXT `ip`.
        let advertisedIp = txtString("ip").flatMap { Self.isIPv4Literal($0) ? $0 : nil }
        let host = advertisedIp
            ?? Self.extractIPv4(from: sender.addresses)
            ?? sender.hostName?.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            ?? ""
        guard !host.isEmpty else { return }

        let wsPort = txtString("wsPort").flatMap(Int.init) ?? (sender.port > 0 ? sender.port : 7788)
        let udpPort = txtString("udpPort").flatMap(Int.init) ?? 7789
        let os = txtString("os") ?? "macos"
        let version = txtString("ver") ?? ""

        let peer = DiscoveredLanPeer(
            id: key,
            name: sender.name,
            host: host,
            wsPort: wsPort,
            udpPort: udpPort,
            os: os,
            version: version
        )
        peersByKey[key] = peer
        publishPeers()
    }

    public func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        resolvingServices.removeAll { $0 === sender }
    }

    // MARK: - Helpers

    /// This Mac's own IPv4 addresses (all interfaces) — it advertises itself too, but is never a remote to pick.
    private static func localIPv4Addresses() -> Set<String> {
        var result = Set<String>()
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return result }
        defer { freeifaddrs(ifaddr) }
        var ptr = ifaddr
        while let p = ptr {
            let fa = p.pointee
            if let sa = fa.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET) {
                var addr = sa.pointee
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(&addr, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    result.insert(String(cString: host))
                }
            }
            ptr = fa.ifa_next
        }
        return result
    }

    private func publishPeers() {
        let own = Self.localIPv4Addresses()
        let sorted = peersByKey.values.filter { !own.contains($0.host) }.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        peers = sorted
        onPeersChanged?(sorted)
    }

    private static func isIPv4Literal(_ s: String) -> Bool {
        var addr = in_addr()
        return inet_pton(AF_INET, s, &addr) == 1
    }

    private static func serviceKey(_ service: NetService) -> String {
        "\(service.domain)|\(service.type)|\(service.name)"
    }

    private static func extractIPv4(from addresses: [Data]?) -> String? {
        guard let addresses else { return nil }
        var fallbackLoopback: String?
        for data in addresses {
            let ip: String? = data.withUnsafeBytes { rawBuf in
                guard rawBuf.count >= MemoryLayout<sockaddr>.size,
                      let base = rawBuf.baseAddress else { return nil }
                let sa = base.assumingMemoryBound(to: sockaddr.self).pointee
                guard sa.sa_family == sa_family_t(AF_INET),
                      rawBuf.count >= MemoryLayout<sockaddr_in>.size else { return nil }
                var sin = base.assumingMemoryBound(to: sockaddr_in.self).pointee
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                guard inet_ntop(AF_INET, &sin.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else {
                    return nil
                }
                return String(cString: buf)
            }
            guard let ip else { continue }
            if ip.hasPrefix("127.") {
                fallbackLoopback = ip
            } else {
                return ip
            }
        }
        return fallbackLoopback
    }
}
