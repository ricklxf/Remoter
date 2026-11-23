import Foundation
import Darwin

/// Lightweight RFC 5389 STUN Binding Client over pure POSIX UDP sockets.
/// Discovers the external NAT-mapped `(publicIp, publicPort)` via `XOR-MAPPED-ADDRESS (0x0020)`
/// with fallback to `MAPPED-ADDRESS (0x0001)` for IPv4.
public final class StunClient {
    public static let magicCookie: UInt32 = 0x2112A442
    public static let bindingRequestType: UInt16 = 0x0001
    public static let bindingSuccessResponseType: UInt16 = 0x0101
    public static let attrMappedAddress: UInt16 = 0x0001
    public static let attrXorMappedAddress: UInt16 = 0x0020

    public static let defaultServers: [(host: String, port: UInt16)] = [
        ("stun.cloudflare.com", 3478),
        ("stun.l.google.com", 19302)
    ]

    /// Builds a 20-byte RFC 5389 STUN Binding Request with magic cookie `0x2112A442` and a 12-byte transaction ID.
    public static func buildBindingRequest(txID: Data) -> Data {
        var packet = [UInt8](repeating: 0, count: 20)
        // Type: 0x0001 (Binding Request)
        packet[0] = 0x00
        packet[1] = 0x01
        // Message Length: 0
        packet[2] = 0x00
        packet[3] = 0x00
        // Magic Cookie: 0x2112A442
        packet[4] = 0x21
        packet[5] = 0x12
        packet[6] = 0xA4
        packet[7] = 0x42
        // 12-byte Transaction ID
        let copyLen = min(txID.count, 12)
        if copyLen > 0 {
            txID.copyBytes(to: &packet[8], count: copyLen)
        }
        return Data(packet)
    }

    /// Generates a 12-byte random STUN transaction ID.
    public static func randomTransactionID() -> Data {
        var bytes = [UInt8](repeating: 0, count: 12)
        for i in 0..<12 {
            bytes[i] = UInt8.random(in: 0...255)
        }
        return Data(bytes)
    }

    /// Encodes an RFC 5389 IPv4 `XOR-MAPPED-ADDRESS (0x0020)` TLV attribute (12 bytes total).
    public static func encodeXorMappedAddressAttribute(ip: String, port: UInt16) -> Data? {
        var addr = in_addr()
        guard inet_pton(AF_INET, ip, &addr) == 1 else { return nil }
        let ipHostOrder = UInt32(bigEndian: addr.s_addr)
        let xIp = ipHostOrder ^ magicCookie
        let xPort = port ^ UInt16((magicCookie >> 16) & 0xFFFF)

        let bytes: [UInt8] = [
            0x00, 0x20, // Attr Type: XOR-MAPPED-ADDRESS
            0x00, 0x08, // Attr Length: 8
            0x00, 0x01, // Reserved + IPv4 Family (0x01)
            UInt8((xPort >> 8) & 0xFF), UInt8(xPort & 0xFF),
            UInt8((xIp >> 24) & 0xFF),
            UInt8((xIp >> 16) & 0xFF),
            UInt8((xIp >> 8) & 0xFF),
            UInt8(xIp & 0xFF)
        ]
        return Data(bytes)
    }

    /// Parses an RFC 5389 STUN Binding Success Response (`0x0101`), preferring `XOR-MAPPED-ADDRESS (0x0020)`
    /// and falling back to `MAPPED-ADDRESS (0x0001)` for IPv4.
    public static func parseBindingResponse(_ data: Data, expectedTxID: Data) -> (publicIp: String, publicPort: UInt16)? {
        guard data.count >= 20, expectedTxID.count == 12 else { return nil }
        let bytes = [UInt8](data)

        let msgType = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
        guard msgType == bindingSuccessResponseType else { return nil }

        let msgLen = Int((UInt16(bytes[2]) << 8) | UInt16(bytes[3]))
        guard data.count >= 20 + msgLen else { return nil }

        let cookie = (UInt32(bytes[4]) << 24)
            | (UInt32(bytes[5]) << 16)
            | (UInt32(bytes[6]) << 8)
            | UInt32(bytes[7])
        guard cookie == magicCookie else { return nil }

        let txBytes = [UInt8](expectedTxID)
        for i in 0..<12 {
            if bytes[8 + i] != txBytes[i] { return nil }
        }

        var fallbackMapped: (String, UInt16)?
        var offset = 20
        let endOffset = 20 + msgLen

        while offset + 4 <= endOffset {
            let attrType = (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
            let attrLen = Int((UInt16(bytes[offset + 2]) << 8) | UInt16(bytes[offset + 3]))
            let valStart = offset + 4
            guard valStart + attrLen <= endOffset else { break }

            if attrType == attrXorMappedAddress, attrLen >= 8 {
                let family = bytes[valStart + 1]
                if family == 0x01 { // IPv4
                    let xPort = (UInt16(bytes[valStart + 2]) << 8) | UInt16(bytes[valStart + 3])
                    let port = xPort ^ UInt16((magicCookie >> 16) & 0xFFFF)
                    let xIp = (UInt32(bytes[valStart + 4]) << 24)
                        | (UInt32(bytes[valStart + 5]) << 16)
                        | (UInt32(bytes[valStart + 6]) << 8)
                        | UInt32(bytes[valStart + 7])
                    let ip = xIp ^ magicCookie
                    let ipStr = "\((ip >> 24) & 0xFF).\((ip >> 16) & 0xFF).\((ip >> 8) & 0xFF).\(ip & 0xFF)"
                    return (ipStr, port)
                }
            } else if attrType == attrMappedAddress, attrLen >= 8, fallbackMapped == nil {
                let family = bytes[valStart + 1]
                if family == 0x01 { // IPv4
                    let port = (UInt16(bytes[valStart + 2]) << 8) | UInt16(bytes[valStart + 3])
                    let ipStr = "\(bytes[valStart + 4]).\(bytes[valStart + 5]).\(bytes[valStart + 6]).\(bytes[valStart + 7])"
                    fallbackMapped = (ipStr, port)
                }
            }

            let paddedLen = (attrLen + 3) & ~3
            offset = valStart + paddedLen
        }

        return fallbackMapped
    }

    /// Probes STUN servers using either an existing bound UDP socket fd or a temporary IPv4 UDP socket.
    /// Returns `(publicIp, publicPort)` or `nil` on timeout/failure.
    public static func discoverPublicEndpoint(
        existingSocketFd: Int32? = nil,
        servers: [(host: String, port: UInt16)] = defaultServers,
        timeoutSeconds: TimeInterval = 1.5
    ) -> (publicIp: String, publicPort: UInt16)? {
        let fd: Int32
        let ownsSocket: Bool
        if let existing = existingSocketFd, existing >= 0 {
            fd = existing
            ownsSocket = false
        } else {
            let newFd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard newFd >= 0 else { return nil }
            let flags = fcntl(newFd, F_GETFL, 0)
            if flags >= 0 {
                _ = fcntl(newFd, F_SETFL, flags | O_NONBLOCK)
            }
            fd = newFd
            ownsSocket = true
        }
        defer {
            if ownsSocket {
                close(fd)
            }
        }

        for server in servers {
            guard var addr = resolveIPv4(host: server.host, port: server.port) else { continue }
            let txID = randomTransactionID()
            let request = buildBindingRequest(txID: txID)

            let sent = request.withUnsafeBytes { rawBuf -> ssize_t in
                guard let base = rawBuf.baseAddress else { return -1 }
                return withUnsafePointer(to: &addr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                        sendto(fd, base, request.count, 0, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            guard sent == request.count else { continue }

            let deadline = Date().addingTimeInterval(timeoutSeconds)
            var recvBuf = [UInt8](repeating: 0, count: 1024)

            while true {
                let remainingMs = Int32((deadline.timeIntervalSinceNow * 1000.0).rounded())
                if remainingMs <= 0 { break }

                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&pfd, 1, remainingMs)
                if ready <= 0 { break }

                var fromAddr = sockaddr_storage()
                var fromLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
                let n = recvBuf.withUnsafeMutableBytes { rawBuf -> ssize_t in
                    guard let base = rawBuf.baseAddress else { return -1 }
                    return withUnsafeMutablePointer(to: &fromAddr) { ptr in
                        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                            recvfrom(fd, base, rawBuf.count, 0, sockPtr, &fromLen)
                        }
                    }
                }
                if n >= 20 {
                    let resp = Data(recvBuf[0..<Int(n)])
                    if let parsed = parseBindingResponse(resp, expectedTxID: txID) {
                        return parsed
                    }
                } else if n < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                    break
                }
            }
        }

        return nil
    }

    private static func resolveIPv4(host: String, port: UInt16) -> sockaddr_in? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_protocol = IPPROTO_UDP

        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let first = res else {
            return nil
        }
        defer { freeaddrinfo(first) }
        guard let addrPtr = first.pointee.ai_addr else { return nil }
        return addrPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
    }
}
