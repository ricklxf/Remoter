import Foundation

/// Advertises this Remoter Mac host on the local network via Bonjour / mDNS (`_remoter._tcp.`)
/// so native clients can auto-discover LAN machines with one click.
final class LanDiscoveryAdvertiser: NSObject, NetServiceDelegate, @unchecked Sendable {
    static let shared = LanDiscoveryAdvertiser()

    private var service: NetService?
    private var currentWsPort: UInt16 = 7788
    private var currentUdpPort: UInt16 = 7789

    private override init() {
        super.init()
    }

    func start(wsPort: UInt16, udpPort: UInt16) {
        let work = { [weak self] in
            guard let self else { return }
            self.stopOnMain()
            self.currentWsPort = wsPort
            self.currentUdpPort = udpPort

            let hostName = Host.current().localizedName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let serviceName = (hostName?.isEmpty == false) ? hostName! : "Mac"
            let svc = NetService(domain: "local.", type: "_remoter._tcp.", name: serviceName, port: Int32(wsPort))
            svc.delegate = self

            let txtDict: [String: Data] = [
                "os": Data("macos".utf8),
                "wsPort": Data(String(wsPort).utf8),
                "udpPort": Data(String(udpPort).utf8),
                "ver": Data(kAppVersion.utf8)
            ]
            svc.setTXTRecord(NetService.data(fromTXTRecord: txtDict))
            svc.schedule(in: .main, forMode: .common)
            svc.publish()
            self.service = svc

            ConnectionLogger.shared.logStep(
                sessionId: "mdns",
                step: "advertise_start",
                detail: "name=\(serviceName) wsPort=\(wsPort) udpPort=\(udpPort) ver=\(kAppVersion)"
            )
        }

        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    func stop() {
        if Thread.isMainThread {
            stopOnMain()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.stopOnMain()
            }
        }
    }

    private func stopOnMain() {
        if let svc = service {
            svc.stop()
            svc.remove(from: .main, forMode: .common)
            svc.delegate = nil
            service = nil
            ConnectionLogger.shared.logStep(sessionId: "mdns", step: "advertise_stop")
        }
    }

    // MARK: - NetServiceDelegate

    func netServiceDidPublish(_ sender: NetService) {
        ConnectionLogger.shared.logStep(
            sessionId: "mdns",
            step: "advertise_published",
            detail: "name=\(sender.name) port=\(sender.port)"
        )
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        ConnectionLogger.shared.logStep(
            sessionId: "mdns",
            step: "advertise_failed",
            detail: "\(errorDict)"
        )
    }
}
