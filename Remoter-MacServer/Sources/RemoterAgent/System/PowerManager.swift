import Foundation
import IOKit.pwr_mgt
import Darwin

/// Manages macOS anti-sleep power assertions (unattended host + active display),
/// remote power actions (lock / sleep / restart), and Wake-on-LAN Magic Packets.
final class PowerManager {
    static let shared = PowerManager()

    private let lock = NSLock()
    private var systemAssertionID: IOPMAssertionID = 0
    private var hasSystemAssertion = false
    private var displayAssertionID: IOPMAssertionID = 0
    private var hasDisplayAssertion = false
    private var activeDisplaySessions = 0

    private init() {}

    /// Prevents unattended system idle sleep while RemoterAgent is running.
    func preventSystemIdleSleep() {
        lock.lock()
        guard !hasSystemAssertion else {
            lock.unlock()
            return
        }
        var id: IOPMAssertionID = 0
        let res = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "RemoterAgent unattended host" as CFString,
            &id
        )
        if res == kIOReturnSuccess {
            systemAssertionID = id
            hasSystemAssertion = true
        }
        lock.unlock()

        ConnectionLogger.shared.logStep(
            sessionId: "power",
            step: "power_assertion",
            detail: "system_idle=\(res == kIOReturnSuccess ? "on" : "failed(\(res))")"
        )
    }

    /// Reference-counted display keep-awake assertion for active remote sessions.
    func setDisplayActive(_ active: Bool) {
        var logDetail: String?
        lock.lock()
        if active {
            activeDisplaySessions += 1
            if !hasDisplayAssertion {
                var id: IOPMAssertionID = 0
                let res = IOPMAssertionCreateWithName(
                    kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                    "RemoterAgent active remote session" as CFString,
                    &id
                )
                if res == kIOReturnSuccess {
                    displayAssertionID = id
                    hasDisplayAssertion = true
                    logDetail = "display_awake=on sessions=\(activeDisplaySessions)"
                } else {
                    logDetail = "display_awake=failed(\(res))"
                }
            }
        } else {
            if activeDisplaySessions > 0 {
                activeDisplaySessions -= 1
            }
            if activeDisplaySessions == 0 && hasDisplayAssertion {
                IOPMAssertionRelease(displayAssertionID)
                displayAssertionID = 0
                hasDisplayAssertion = false
                logDetail = "display_awake=off"
            }
        }
        lock.unlock()

        if let logDetail {
            ConnectionLogger.shared.logStep(sessionId: "power", step: "power_assertion", detail: logDetail)
        }
    }

    /// Releases all active IOKit power assertions (called on shutdown or before sleep).
    func releaseAllAssertions() {
        lock.lock()
        if hasDisplayAssertion {
            IOPMAssertionRelease(displayAssertionID)
            displayAssertionID = 0
            hasDisplayAssertion = false
        }
        activeDisplaySessions = 0
        if hasSystemAssertion {
            IOPMAssertionRelease(systemAssertionID)
            systemAssertionID = 0
            hasSystemAssertion = false
        }
        lock.unlock()
    }

    /// Executes a remote power action: "lock", "sleep", or "restart".
    func performAction(_ action: String) {
        let normalized = action.lowercased()
        ConnectionLogger.shared.logStep(sessionId: "power", step: "power_action", detail: normalized)

        switch normalized {
        case "lock":
            if !lockScreenImmediate() {
                runProcess("/usr/bin/pmset", arguments: ["displaysleepnow"])
            }
        case "sleep":
            releaseAllAssertions()
            runProcess("/usr/bin/pmset", arguments: ["sleepnow"])
        case "restart":
            runProcess("/usr/bin/osascript", arguments: ["-e", "tell application \"System Events\" to restart"])
        default:
            break
        }
    }

    /// Broadcasts a 102-byte Wake-on-LAN Magic Packet (`6x 0xFF` + `16x 6B MAC`)
    /// to `255.255.255.255:9` over UDP.
    @discardableResult
    static func sendWakeOnLan(macAddress: String) -> Bool {
        let parts = macAddress
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == ":" || $0 == "-" })
        guard parts.count == 6 else { return false }

        var mac = [UInt8]()
        mac.reserveCapacity(6)
        for p in parts {
            guard p.count == 2, let b = UInt8(p, radix: 16) else { return false }
            mac.append(b)
        }

        var packet = [UInt8](repeating: 0xFF, count: 6)
        packet.reserveCapacity(102)
        for _ in 0..<16 {
            packet.append(contentsOf: mac)
        }

        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }

        var one: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &one, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            return false
        }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(9).bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_BROADCAST.bigEndian)

        let sent = packet.withUnsafeBytes { rawBuf -> Int in
            withUnsafePointer(to: &addr) { ptr -> Int in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    Darwin.sendto(fd, rawBuf.baseAddress, packet.count, 0, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        return sent == packet.count
    }

    // MARK: - Private

    private func lockScreenImmediate() -> Bool {
        let path = "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login"
        guard let handle = dlopen(path, RTLD_LAZY) else { return false }
        defer { dlclose(handle) }
        guard let sym = dlsym(handle, "SACLockScreenImmediate") else { return false }
        typealias LockFunc = @convention(c) () -> Void
        let fn = unsafeBitCast(sym, to: LockFunc.self)
        DispatchQueue.main.async {
            fn()
        }
        return true
    }

    private func runProcess(_ executable: String, arguments: [String]) {
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: executable)
            p.arguments = arguments
            try? p.run()
        }
    }
}
