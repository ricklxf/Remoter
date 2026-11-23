import Foundation
import Darwin
import CryptoKit

/// Direct low-latency UDP video transport server with adaptive XOR-FEC,
/// AES-256-GCM encryption, and 128-packet ring-buffer NACK retransmission.
///
/// Wire protocol (Big-Endian, matches MacClient & WinClient bit-for-bit):
/// - Magic: [0x52, 0x55], Version: 0x01
/// - Control packets:
///   - HELLO     (0x01): [0x52, 0x55, 0x01, 0x01] + 16-byte session token (20B)
///   - HELLO_ACK (0x02): [0x52, 0x55, 0x01, 0x02] + 16-byte session token (20B)
///   - KEEPALIVE (0x03): [0x52, 0x55, 0x01, 0x03] + 16-byte session token (20B)
///   - NACK      (0x12): [0x52, 0x55, 0x01, 0x12] + 16B token + frameId(BE4) + count(1..16) + count*fragIndex
/// - Video packets (20-byte header + body [+ 16B GCM tag if header[18] & 0x01 != 0]):
///   - DATA       (0x10): header + fragment payload (<= 1200 bytes)
///   - FEC_PARITY (0x11): header + [2-byte XOR(BE payloadLen)] + [XOR(zero-padded payloads)]
///   Header layout (20 bytes):
///     0..1:  0x52, 0x55 (magic)
///     2:     0x01 (version)
///     3:     packetType (0x10 or 0x11)
///     4..7:  frameId (UInt32 BE)
///     8..11: ptsMs (UInt32 BE)
///     12:    flags (bit0 = isKeyframe, bit1 = isHEVC)
///     13:    fragIndex (0..<fragCount for DATA; group index for FEC_PARITY)
///     14:    fragCount (1...255)
///     15:    fecGroupSize (4 for keyframe, 8 for delta, 0 if fragCount == 1)
///     16..17: payloadLen (UInt16 BE, plaintext body length after 20-byte header)
///     18:    encFlags (bit0 = AES-256-GCM encrypted)
///     19:    reserved (0x00)
///   AES-256-GCM parameters when header[18] == 0x01:
///     Nonce (12B): [0x52, 0x55, packetType, fragIndex] + frameId(BE4) + ptsMs(BE4)
///     AAD   (20B): header[0..<20]
///     Wire:        header[0..<20] + ciphertext(payloadLen B) + tag(16B)
final class UdpVideoServer {
    static let shared = UdpVideoServer()

    static let magic0: UInt8 = 0x52
    static let magic1: UInt8 = 0x55
    static let version: UInt8 = 0x01

    static let packetHello: UInt8     = 0x01
    static let packetHelloAck: UInt8  = 0x02
    static let packetKeepalive: UInt8 = 0x03
    static let packetData: UInt8      = 0x10
    static let packetFecParity: UInt8 = 0x11
    static let packetNack: UInt8      = 0x12

    static let defaultPort: UInt16 = 7789
    static let maxFragmentPayload: Int = 1200
    static let maxFragments: Int = 255
    static let headerSize: Int = 20
    static let gcmTagSize: Int = 16
    static let ringBufferCapacity: Int = 128
    static let keepaliveTimeoutSeconds: TimeInterval = 6.0

    private enum FecLevel: String {
        case suppressed
        case light
        case moderate
        case heavy
    }

    private final class PeerSession {
        var peerAddr: sockaddr_storage?
        var peerLen: socklen_t = 0
        var isActive: Bool = false
        var lastKeepaliveAt: Date = .distantPast
        var symmetricKey: SymmetricKey?
        var onActivated: (Bool) -> Void
        var onLossFeedback: ((Double) -> Void)?

        // 2s sliding-window adaptive FEC & loss feedback
        var windowSentDataPackets: UInt64 = 0
        var windowNackPackets: UInt64 = 0
        var cleanWindows: Int = 0
        var allowFecSuppression: Bool = true
        var hasEverSeenNack: Bool = false
        var fecLevel: FecLevel = .light
        var deltaFecGroupSize: UInt8 = 8
        var keyFecGroupSize: UInt8 = 4

        // 128-packet ring buffer keyed by (UInt64(frameId) << 8) | UInt64(fragIndex)
        var ringKeys: [UInt64] = Array(repeating: 0, count: UdpVideoServer.ringBufferCapacity)
        var ringData: [Data?] = Array(repeating: nil, count: UdpVideoServer.ringBufferCapacity)
        var ringIndexMap: [UInt64: Int] = [:]
        var ringWriteCursor: Int = 0
        var nackRetransmits: UInt64 = 0

        init(
            aesKey: Data?,
            allowFecSuppression: Bool,
            onActivated: @escaping (Bool) -> Void,
            onLossFeedback: ((Double) -> Void)?
        ) {
            if let aesKey, aesKey.count == 32 {
                self.symmetricKey = SymmetricKey(data: aesKey)
            }
            self.allowFecSuppression = allowFecSuppression
            self.onActivated = onActivated
            self.onLossFeedback = onLossFeedback
        }

        func storeInRing(key: UInt64, datagram: Data) {
            let slot = ringWriteCursor
            if ringData[slot] != nil {
                let evictedKey = ringKeys[slot]
                if ringIndexMap[evictedKey] == slot {
                    ringIndexMap.removeValue(forKey: evictedKey)
                }
            }
            ringKeys[slot] = key
            ringData[slot] = datagram
            ringIndexMap[key] = slot
            ringWriteCursor = (slot + 1) % UdpVideoServer.ringBufferCapacity
        }

        func lookupInRing(key: UInt64) -> Data? {
            guard let slot = ringIndexMap[key] else { return nil }
            return ringData[slot]
        }
    }

    private let lock = NSLock()
    private let ioQueue = DispatchQueue(label: "com.remoter.udp.video", qos: .userInteractive)
    private var sockfd: Int32 = -1
    private var isIPv6 = false
    private var readSource: DispatchSourceRead?
    private var timeoutTimer: DispatchSourceTimer?
    private var sessions: [Data: PeerSession] = [:]

    private(set) var listeningPort: UInt16 = 0

    private init() {}

    // MARK: - Lifecycle

    @discardableResult
    func start(preferredPort: UInt16 = UdpVideoServer.defaultPort) -> Bool {
        lock.lock()
        if sockfd >= 0 {
            lock.unlock()
            return true
        }
        lock.unlock()

        guard let (fd, boundPort, dualStack) = openAndBindSocket(preferredPort: preferredPort) else {
            ConnectionLogger.shared.logStep(sessionId: "udp", step: "udp_video_start_failed",
                                            detail: "preferredPort=\(preferredPort)")
            return false
        }

        let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
        reader.setEventHandler { [weak self] in
            self?.drainIncomingPackets()
        }
        reader.setCancelHandler {
            close(fd)
        }

        let timer = DispatchSource.makeTimerSource(queue: ioQueue)
        timer.schedule(deadline: .now() + .seconds(2), repeating: .seconds(2))
        timer.setEventHandler { [weak self] in
            self?.runMaintenanceTick()
        }

        lock.lock()
        sockfd = fd
        isIPv6 = dualStack
        listeningPort = boundPort
        readSource = reader
        timeoutTimer = timer
        lock.unlock()

        reader.resume()
        timer.resume()

        ConnectionLogger.shared.logStep(sessionId: "udp", step: "udp_video_started",
                                        detail: "port=\(boundPort) dualStack=\(dualStack)")
        return true
    }

    func stop() {
        lock.lock()
        let reader = readSource
        let timer = timeoutTimer
        readSource = nil
        timeoutTimer = nil
        sockfd = -1
        listeningPort = 0
        sessions.removeAll()
        lock.unlock()

        timer?.cancel()
        reader?.cancel()
        ConnectionLogger.shared.logStep(sessionId: "udp", step: "udp_video_stopped")
    }

    // MARK: - Session registration

    func registerSession(
        token: Data,
        aesKey: Data? = nil,
        allowFecSuppression: Bool = true,
        onActivated: @escaping (Bool) -> Void,
        onLossFeedback: ((Double) -> Void)? = nil
    ) {
        guard token.count == 16 else { return }
        lock.lock()
        if let existing = sessions[token] {
            // Preserve active UDP peer across pipeline rebuilds (resolution/codec switch)
            existing.onActivated = onActivated
            existing.onLossFeedback = onLossFeedback
            existing.allowFecSuppression = allowFecSuppression
            if !allowFecSuppression && existing.fecLevel == .suppressed {
                existing.fecLevel = .light
                existing.deltaFecGroupSize = 8
                existing.keyFecGroupSize = 4
            }
            if let aesKey, aesKey.count == 32 {
                existing.symmetricKey = SymmetricKey(data: aesKey)
            }
        } else {
            sessions[token] = PeerSession(
                aesKey: aesKey,
                allowFecSuppression: allowFecSuppression,
                onActivated: onActivated,
                onLossFeedback: onLossFeedback
            )
        }
        lock.unlock()
    }

    func setFecSuppressionAllowed(token: Data, allowed: Bool) {
        lock.lock()
        if let session = sessions[token] {
            session.allowFecSuppression = allowed
            if !allowed && session.fecLevel == .suppressed {
                session.fecLevel = .light
                session.deltaFecGroupSize = 8
                session.keyFecGroupSize = 4
            }
        }
        lock.unlock()
    }

    func unregisterSession(token: Data) {
        var retransmits: UInt64 = 0
        lock.lock()
        if let removed = sessions.removeValue(forKey: token) {
            retransmits = removed.nackRetransmits
        }
        lock.unlock()
        if retransmits > 0 {
            ConnectionLogger.shared.logStep(sessionId: "udp", step: "udp_nack_summary",
                                            detail: "retransmits=\(retransmits)")
        }
    }

    // MARK: - Video frame transmission

    /// Fragments and transmits an encoded video frame over UDP with optional
    /// AES-256-GCM encryption, adaptive XOR-FEC, and ring-buffer caching for NACKs.
    /// Returns `false` if UDP is inactive for this session or the frame exceeds 255 * 1200 bytes
    /// (caller should fall back to WebSocket binary transport).
    func sendVideoFrame(
        token: Data,
        frameId: UInt32,
        ptsMs: UInt32,
        data: Data,
        isKeyframe: Bool,
        isHEVC: Bool
    ) -> Bool {
        let totalLen = data.count
        guard totalLen > 0, totalLen <= Self.maxFragments * Self.maxFragmentPayload else {
            return false
        }

        lock.lock()
        let fd = sockfd
        guard fd >= 0,
              let session = sessions[token],
              session.isActive,
              let peerAddr = session.peerAddr else {
            lock.unlock()
            return false
        }
        let peerLen = session.peerLen
        let symmetricKey = session.symmetricKey
        let deltaFec = session.deltaFecGroupSize
        let keyFec = session.keyFecGroupSize
        lock.unlock()

        let fragCount = (totalLen + Self.maxFragmentPayload - 1) / Self.maxFragmentPayload
        guard fragCount >= 1, fragCount <= Self.maxFragments else { return false }

        let fecGroupSize: UInt8
        if fragCount == 1 {
            fecGroupSize = 0
        } else {
            fecGroupSize = isKeyframe ? keyFec : deltaFec
        }

        let flags: UInt8 = (isKeyframe ? 0x01 : 0x00) | (isHEVC ? 0x02 : 0x00)
        let fragCountU8 = UInt8(fragCount)
        let encryptedFlag: UInt8 = (symmetricKey != nil) ? 0x01 : 0x00

        // Reusable buffer: 20B header + 2B length XOR + 1200B max payload + 16B GCM tag
        var packetBuf = [UInt8](repeating: 0, count: Self.headerSize + 2 + Self.maxFragmentPayload + Self.gcmTagSize)
        var addrCopy = peerAddr
        var cachedDataPackets: [(UInt64, Data)] = []
        cachedDataPackets.reserveCapacity(fragCount)

        let ok = data.withUnsafeBytes { rawBuf -> Bool in
            guard let basePtr = rawBuf.bindMemory(to: UInt8.self).baseAddress else { return false }

            // 1. Send all data fragments (0x10)
            for i in 0..<fragCount {
                let offset = i * Self.maxFragmentPayload
                let fragLen = min(Self.maxFragmentPayload, totalLen - offset)
                let fragIdx = UInt8(i)
                writeHeader(
                    into: &packetBuf,
                    packetType: Self.packetData,
                    frameId: frameId,
                    ptsMs: ptsMs,
                    flags: flags,
                    fragIndex: fragIdx,
                    fragCount: fragCountU8,
                    fecGroupSize: fecGroupSize,
                    payloadLen: UInt16(fragLen),
                    encFlag: encryptedFlag
                )

                let wireLen: Int
                if let key = symmetricKey {
                    let plaintext = UnsafeBufferPointer(start: basePtr.advanced(by: offset), count: fragLen)
                    guard let sealedLen = sealIntoPacketBuffer(
                        packetBuf: &packetBuf,
                        plaintext: plaintext,
                        key: key,
                        packetType: Self.packetData,
                        fragIndex: fragIdx,
                        frameId: frameId,
                        ptsMs: ptsMs
                    ) else {
                        return false
                    }
                    wireLen = sealedLen
                } else {
                    for j in 0..<fragLen {
                        packetBuf[Self.headerSize + j] = basePtr[offset + j]
                    }
                    wireLen = Self.headerSize + fragLen
                }

                let cacheKey = (UInt64(frameId) << 8) | UInt64(fragIdx)
                cachedDataPackets.append((cacheKey, Data(packetBuf[0..<wireLen])))

                if !sendPacket(fd: fd, buffer: packetBuf, length: wireLen,
                               peerAddr: &addrCopy, peerLen: peerLen) {
                    return false
                }
            }

            // 2. Send XOR-FEC parity packets (0x11) per group where group has >= 2 fragments
            if fecGroupSize > 0 {
                let groupSz = Int(fecGroupSize)
                let groupCount = (fragCount + groupSz - 1) / groupSz
                var parityBody = [UInt8](repeating: 0, count: 2 + Self.maxFragmentPayload)

                for g in 0..<groupCount {
                    let start = g * groupSz
                    let end = min(start + groupSz, fragCount)
                    guard end - start >= 2 else { continue }

                    var maxLenInGroup = 0
                    for idx in start..<end {
                        let offset = idx * Self.maxFragmentPayload
                        let flen = min(Self.maxFragmentPayload, totalLen - offset)
                        if flen > maxLenInGroup { maxLenInGroup = flen }
                    }

                    let bodyLen = 2 + maxLenInGroup
                    for k in 0..<bodyLen {
                        parityBody[k] = 0
                    }

                    var xorLen: UInt16 = 0
                    for idx in start..<end {
                        let offset = idx * Self.maxFragmentPayload
                        let flen = min(Self.maxFragmentPayload, totalLen - offset)
                        xorLen ^= UInt16(flen)
                        for j in 0..<flen {
                            parityBody[2 + j] ^= basePtr[offset + j]
                        }
                    }

                    parityBody[0] = UInt8((xorLen >> 8) & 0xFF)
                    parityBody[1] = UInt8(xorLen & 0xFF)

                    let groupIdx = UInt8(g)
                    writeHeader(
                        into: &packetBuf,
                        packetType: Self.packetFecParity,
                        frameId: frameId,
                        ptsMs: ptsMs,
                        flags: flags,
                        fragIndex: groupIdx,
                        fragCount: fragCountU8,
                        fecGroupSize: fecGroupSize,
                        payloadLen: UInt16(bodyLen),
                        encFlag: encryptedFlag
                    )

                    let wireLen: Int
                    if let key = symmetricKey {
                        let sealedLen: Int? = parityBody.withUnsafeBufferPointer { pbPtr in
                            let slice = UnsafeBufferPointer(start: pbPtr.baseAddress, count: bodyLen)
                            return sealIntoPacketBuffer(
                                packetBuf: &packetBuf,
                                plaintext: slice,
                                key: key,
                                packetType: Self.packetFecParity,
                                fragIndex: groupIdx,
                                frameId: frameId,
                                ptsMs: ptsMs
                            )
                        }
                        guard let sealedLen else { continue }
                        wireLen = sealedLen
                    } else {
                        for k in 0..<bodyLen {
                            packetBuf[Self.headerSize + k] = parityBody[k]
                        }
                        wireLen = Self.headerSize + bodyLen
                    }

                    _ = sendPacket(fd: fd, buffer: packetBuf, length: wireLen,
                                   peerAddr: &addrCopy, peerLen: peerLen)
                }
            }

            return true
        }

        if !cachedDataPackets.isEmpty {
            lock.lock()
            if let s = sessions[token] {
                s.windowSentDataPackets += UInt64(cachedDataPackets.count)
                for (cacheKey, datagram) in cachedDataPackets {
                    s.storeInRing(key: cacheKey, datagram: datagram)
                }
            }
            lock.unlock()
        }

        return ok
    }

    // MARK: - Private helpers

    private func sealIntoPacketBuffer(
        packetBuf: inout [UInt8],
        plaintext: UnsafeBufferPointer<UInt8>,
        key: SymmetricKey,
        packetType: UInt8,
        fragIndex: UInt8,
        frameId: UInt32,
        ptsMs: UInt32
    ) -> Int? {
        var nonceBytes = [UInt8](repeating: 0, count: 12)
        nonceBytes[0]  = Self.magic0
        nonceBytes[1]  = Self.magic1
        nonceBytes[2]  = packetType
        nonceBytes[3]  = fragIndex
        nonceBytes[4]  = UInt8((frameId >> 24) & 0xFF)
        nonceBytes[5]  = UInt8((frameId >> 16) & 0xFF)
        nonceBytes[6]  = UInt8((frameId >> 8) & 0xFF)
        nonceBytes[7]  = UInt8(frameId & 0xFF)
        nonceBytes[8]  = UInt8((ptsMs >> 24) & 0xFF)
        nonceBytes[9]  = UInt8((ptsMs >> 16) & 0xFF)
        nonceBytes[10] = UInt8((ptsMs >> 8) & 0xFF)
        nonceBytes[11] = UInt8(ptsMs & 0xFF)

        guard let nonce = try? AES.GCM.Nonce(data: nonceBytes) else { return nil }
        let aad = packetBuf[0..<Self.headerSize]
        guard let sealed = try? AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: aad) else {
            return nil
        }

        let ctLen = sealed.ciphertext.count
        let tagLen = sealed.tag.count
        sealed.ciphertext.copyBytes(to: &packetBuf[Self.headerSize], count: ctLen)
        sealed.tag.copyBytes(to: &packetBuf[Self.headerSize + ctLen], count: tagLen)
        return Self.headerSize + ctLen + tagLen
    }

    private func writeHeader(
        into buf: inout [UInt8],
        packetType: UInt8,
        frameId: UInt32,
        ptsMs: UInt32,
        flags: UInt8,
        fragIndex: UInt8,
        fragCount: UInt8,
        fecGroupSize: UInt8,
        payloadLen: UInt16,
        encFlag: UInt8
    ) {
        buf[0]  = Self.magic0
        buf[1]  = Self.magic1
        buf[2]  = Self.version
        buf[3]  = packetType
        buf[4]  = UInt8((frameId >> 24) & 0xFF)
        buf[5]  = UInt8((frameId >> 16) & 0xFF)
        buf[6]  = UInt8((frameId >> 8) & 0xFF)
        buf[7]  = UInt8(frameId & 0xFF)
        buf[8]  = UInt8((ptsMs >> 24) & 0xFF)
        buf[9]  = UInt8((ptsMs >> 16) & 0xFF)
        buf[10] = UInt8((ptsMs >> 8) & 0xFF)
        buf[11] = UInt8(ptsMs & 0xFF)
        buf[12] = flags
        buf[13] = fragIndex
        buf[14] = fragCount
        buf[15] = fecGroupSize
        buf[16] = UInt8((payloadLen >> 8) & 0xFF)
        buf[17] = UInt8(payloadLen & 0xFF)
        buf[18] = encFlag
        buf[19] = 0x00
    }

    private func sendPacket(
        fd: Int32,
        buffer: [UInt8],
        length: Int,
        peerAddr: inout sockaddr_storage,
        peerLen: socklen_t
    ) -> Bool {
        let sent = buffer.withUnsafeBytes { rawPtr -> Int in
            withUnsafePointer(to: &peerAddr) { storagePtr -> Int in
                storagePtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    Darwin.sendto(fd, rawPtr.baseAddress, length, 0, saPtr, peerLen)
                }
            }
        }
        if sent < 0 {
            let err = errno
            // Transient congestion on non-blocking UDP socket: keep UDP active
            if err == EAGAIN || err == EWOULDBLOCK || err == ENOBUFS {
                return true
            }
            return false
        }
        return true
    }

    private func sendDataPacket(
        fd: Int32,
        data: Data,
        peerAddr: inout sockaddr_storage,
        peerLen: socklen_t
    ) {
        _ = data.withUnsafeBytes { rawPtr -> Int in
            withUnsafePointer(to: &peerAddr) { storagePtr -> Int in
                storagePtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    Darwin.sendto(fd, rawPtr.baseAddress, data.count, 0, saPtr, peerLen)
                }
            }
        }
    }

    private func drainIncomingPackets() {
        lock.lock()
        let fd = sockfd
        lock.unlock()
        guard fd >= 0 else { return }

        var recvBuf = [UInt8](repeating: 0, count: 128)
        while true {
            var srcAddr = sockaddr_storage()
            var srcLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let n = withUnsafeMutablePointer(to: &srcAddr) { storagePtr -> Int in
                storagePtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    Darwin.recvfrom(fd, &recvBuf, recvBuf.count, 0, saPtr, &srcLen)
                }
            }
            if n < 0 {
                let err = errno
                if err == EAGAIN || err == EWOULDBLOCK { break }
                break
            }
            guard n >= 20,
                  recvBuf[0] == Self.magic0,
                  recvBuf[1] == Self.magic1,
                  recvBuf[2] == Self.version else {
                continue
            }
            let packetType = recvBuf[3]
            let token = Data(recvBuf[4..<20])

            switch packetType {
            case Self.packetHello:
                handleHello(fd: fd, token: token, srcAddr: srcAddr, srcLen: srcLen)
            case Self.packetKeepalive:
                handleKeepalive(token: token, srcAddr: srcAddr, srcLen: srcLen)
            case Self.packetNack:
                handleNack(fd: fd, token: token, buf: recvBuf, length: n, srcAddr: srcAddr, srcLen: srcLen)
            default:
                break
            }
        }
    }

    private func handleHello(fd: Int32, token: Data, srcAddr: sockaddr_storage, srcLen: socklen_t) {
        var callbackToFire: ((Bool) -> Void)?
        lock.lock()
        if let session = sessions[token] {
            session.peerAddr = srcAddr
            session.peerLen = srcLen
            session.lastKeepaliveAt = Date()
            if !session.isActive {
                session.isActive = true
                callbackToFire = session.onActivated
            }
        } else {
            lock.unlock()
            return
        }
        lock.unlock()

        // Reply HELLO_ACK: [0x52, 0x55, 0x01, 0x02] + 16-byte token
        var ack = [UInt8](repeating: 0, count: 20)
        ack[0] = Self.magic0
        ack[1] = Self.magic1
        ack[2] = Self.version
        ack[3] = Self.packetHelloAck
        token.copyBytes(to: &ack[4], count: 16)
        var addrCopy = srcAddr
        _ = sendPacket(fd: fd, buffer: ack, length: 20, peerAddr: &addrCopy, peerLen: srcLen)

        callbackToFire?(true)
    }

    private func handleKeepalive(token: Data, srcAddr: sockaddr_storage, srcLen: socklen_t) {
        var callbackToFire: ((Bool) -> Void)?
        lock.lock()
        if let session = sessions[token] {
            session.peerAddr = srcAddr
            session.peerLen = srcLen
            session.lastKeepaliveAt = Date()
            if !session.isActive {
                session.isActive = true
                callbackToFire = session.onActivated
            }
        }
        lock.unlock()
        callbackToFire?(true)
    }

    /// Handles incoming 0x12 NACK:
    /// [0x52, 0x55, 0x01, 0x12] + 16B token + frameId(BE4) + count(1..16) + count * fragIndex
    private func handleNack(
        fd: Int32,
        token: Data,
        buf: [UInt8],
        length: Int,
        srcAddr: sockaddr_storage,
        srcLen: socklen_t
    ) {
        guard length >= 25 else { return }
        let frameId: UInt32 = (UInt32(buf[20]) << 24) |
                              (UInt32(buf[21]) << 16) |
                              (UInt32(buf[22]) << 8) |
                              UInt32(buf[23])
        let count = Int(buf[24])
        guard count >= 1, count <= 16, length >= 25 + count else { return }

        var toRetransmit: [Data] = []
        toRetransmit.reserveCapacity(count)
        var destAddr = srcAddr
        var destLen = srcLen
        var totalRetransmits: UInt64 = 0

        lock.lock()
        if let session = sessions[token], session.isActive {
            session.windowNackPackets += UInt64(count)
            session.hasEverSeenNack = true
            if let boundAddr = session.peerAddr {
                destAddr = boundAddr
                destLen = session.peerLen
            }
            for idx in 0..<count {
                let fragIndex = buf[25 + idx]
                let key = (UInt64(frameId) << 8) | UInt64(fragIndex)
                if let cached = session.lookupInRing(key: key) {
                    toRetransmit.append(cached)
                }
            }
            if !toRetransmit.isEmpty {
                session.nackRetransmits += UInt64(toRetransmit.count)
                totalRetransmits = session.nackRetransmits
            }
        }
        lock.unlock()

        for datagram in toRetransmit {
            sendDataPacket(fd: fd, data: datagram, peerAddr: &destAddr, peerLen: destLen)
        }

        if !toRetransmit.isEmpty && (totalRetransmits == UInt64(toRetransmit.count) || totalRetransmits % 50 == 0) {
            ConnectionLogger.shared.logStep(
                sessionId: "udp",
                step: "udp_nack_retransmit",
                detail: "frameId=\(frameId) sent=\(toRetransmit.count)/\(count) total=\(totalRetransmits)"
            )
        }
    }

    private func runMaintenanceTick() {
        let now = Date()
        var deactivated: [(Bool) -> Void] = []
        var lossCallbacks: [((Double) -> Void, Double)] = []
        var fecTransitions: [(FecLevel, Double, UInt8, UInt8)] = []

        lock.lock()
        for session in sessions.values {
            guard session.isActive else { continue }
            if now.timeIntervalSince(session.lastKeepaliveAt) > Self.keepaliveTimeoutSeconds {
                session.isActive = false
                session.peerAddr = nil
                session.peerLen = 0
                session.windowSentDataPackets = 0
                session.windowNackPackets = 0
                session.cleanWindows = 0
                session.fecLevel = .light
                session.deltaFecGroupSize = 8
                session.keyFecGroupSize = 4
                deactivated.append(session.onActivated)
                continue
            }

            let sent = session.windowSentDataPackets
            let nacks = session.windowNackPackets
            session.windowSentDataPackets = 0
            session.windowNackPackets = 0

            guard sent > 0 else { continue }
            let lossRatio = Double(nacks) / Double(max(1, sent))
            if nacks == 0 {
                session.cleanWindows += 1
            } else {
                session.cleanWindows = 0
            }

            let newLevel: FecLevel
            let newDeltaFec: UInt8
            let newKeyFec: UInt8
            if lossRatio >= 0.08 {
                newLevel = .heavy
                newDeltaFec = 2
                newKeyFec = 2
            } else if lossRatio >= 0.03 {
                newLevel = .moderate
                newDeltaFec = 4
                newKeyFec = 2
            } else if session.allowFecSuppression && !session.hasEverSeenNack && session.cleanWindows >= 3 {
                newLevel = .suppressed
                newDeltaFec = 0
                newKeyFec = 8
            } else {
                newLevel = .light
                newDeltaFec = 8
                newKeyFec = 4
            }

            if newLevel != session.fecLevel {
                session.fecLevel = newLevel
                session.deltaFecGroupSize = newDeltaFec
                session.keyFecGroupSize = newKeyFec
                fecTransitions.append((newLevel, lossRatio, newDeltaFec, newKeyFec))
            }

            if let cb = session.onLossFeedback {
                lossCallbacks.append((cb, lossRatio))
            }
        }
        lock.unlock()

        for cb in deactivated {
            cb(false)
        }
        for (level, lossRatio, deltaFec, keyFec) in fecTransitions {
            ConnectionLogger.shared.logStep(
                sessionId: "udp",
                step: "fec_state",
                detail: "level=\(level.rawValue) loss=\(String(format: "%.3f", lossRatio)) deltaG=\(deltaFec) keyG=\(keyFec)"
            )
        }
        for (cb, lossRatio) in lossCallbacks {
            cb(lossRatio)
        }
    }

    private func openAndBindSocket(preferredPort: UInt16) -> (Int32, UInt16, Bool)? {
        // Try dual-stack IPv6 first (handles both IPv4-mapped and IPv6 clients)
        if let res = createBoundSocket(ipv6: true, port: preferredPort) {
            return res
        }
        if preferredPort != 0, let res = createBoundSocket(ipv6: true, port: 0) {
            return res
        }
        // Fallback to IPv4-only
        if let res = createBoundSocket(ipv6: false, port: preferredPort) {
            return res
        }
        if preferredPort != 0, let res = createBoundSocket(ipv6: false, port: 0) {
            return res
        }
        return nil
    }

    private func createBoundSocket(ipv6: Bool, port: UInt16) -> (Int32, UInt16, Bool)? {
        let family = ipv6 ? AF_INET6 : AF_INET
        let fd = Darwin.socket(family, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }

        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        if ipv6 {
            var zero: Int32 = 0
            _ = setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &zero, socklen_t(MemoryLayout<Int32>.size))
        }

        var sndBuf: Int32 = 4 * 1024 * 1024
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sndBuf, socklen_t(MemoryLayout<Int32>.size))
        var rcvBuf: Int32 = 256 * 1024
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvBuf, socklen_t(MemoryLayout<Int32>.size))

        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }

        let bindResult: Int32
        if ipv6 {
            var addr = sockaddr_in6()
            addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = port.bigEndian
            addr.sin6_addr = in6addr_any
            bindResult = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    Darwin.bind(fd, saPtr, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        } else {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr = in_addr(s_addr: INADDR_ANY.bigEndian)
            bindResult = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    Darwin.bind(fd, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        guard bindResult == 0 else {
            close(fd)
            return nil
        }

        // Read back the actual bound port (needed when port == 0)
        var boundPort: UInt16 = port
        if ipv6 {
            var actual = sockaddr_in6()
            var len = socklen_t(MemoryLayout<sockaddr_in6>.size)
            let ok = withUnsafeMutablePointer(to: &actual) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    getsockname(fd, saPtr, &len)
                }
            }
            if ok == 0 { boundPort = UInt16(bigEndian: actual.sin6_port) }
        } else {
            var actual = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let ok = withUnsafeMutablePointer(to: &actual) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    getsockname(fd, saPtr, &len)
                }
            }
            if ok == 0 { boundPort = UInt16(bigEndian: actual.sin_port) }
        }

        return (fd, boundPort, ipv6)
    }
}
