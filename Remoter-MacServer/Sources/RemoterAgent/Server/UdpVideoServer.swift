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
    static let packetFeedback: UInt8  = 0x13
    static let packetInput: UInt8     = 0x20
    static let packetAudio: UInt8     = 0x14

    static let defaultPort: UInt16 = 7789
    static let maxFragmentPayload: Int = 1200
    static let maxFragments: Int = 255
    static let headerSize: Int = 20
    static let gcmTagSize: Int = 16
    static let ringBufferCapacity: Int = 1024
    static let keepaliveTimeoutSeconds: TimeInterval = 12.0
    static let maxPacingQueuePackets: Int = 512
    static let immediateBurstPackets: Int = 8

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
        var onLossFeedback: ((Double, UInt64) -> Void)?
        var onTransportFeedback: ((Double, Double, Double, Int) -> Void)?
        var onInputMessage: ((String) -> Void)?

        // 64-packet sliding-window deduplication for 2x-redundant UDP input packets
        var hasInputSeq: Bool = false
        var maxInputSeq: UInt32 = 0
        var inputSeenMask: UInt64 = 0

        // 1ms token-bucket pacer state (prevents WireGuard/router burst tail-drops on 2K keyframes)
        var pacingBitrateBps: Int = 12_000_000
        var pacingQueue: [Data] = []
        var pacingReadIndex: Int = 0
        var pacingBudgetBytes: Double = 0
        var lastPaceTickAt: CFAbsoluteTime = 0

        // 2s sliding-window adaptive FEC & loss feedback
        var windowSentDataPackets: UInt64 = 0
        var lastWindowSentDataPackets: UInt64 = 0
        var windowNackPackets: UInt64 = 0
        var windowRetransmittedPackets: UInt64 = 0
        var cleanWindows: Int = 0
        var sustainedOveruseWindows: Int = 0
        var fecSuppressedByOveruse: Bool = false
        var allowFecSuppression: Bool = true
        var hasEverSeenNack: Bool = false
        var fecLevel: FecLevel = .light
        var deltaFecGroupSize: UInt8 = 8
        var keyFecGroupSize: UInt8 = 4
        var supportsInterleavedFec: Bool = false

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
            onLossFeedback: ((Double, UInt64) -> Void)?,
            onTransportFeedback: ((Double, Double, Double, Int) -> Void)?,
            onInputMessage: ((String) -> Void)?
        ) {
            if let aesKey, aesKey.count == 32 {
                self.symmetricKey = SymmetricKey(data: aesKey)
            }
            self.allowFecSuppression = allowFecSuppression
            self.onActivated = onActivated
            self.onLossFeedback = onLossFeedback
            self.onTransportFeedback = onTransportFeedback
            self.onInputMessage = onInputMessage
        }

        /// Returns true if `seq` has not been seen yet (and marks it seen).
        func acceptInputSeq(_ seq: UInt32) -> Bool {
            if !hasInputSeq {
                hasInputSeq = true
                maxInputSeq = seq
                inputSeenMask = 1
                return true
            }
            let diff = Int32(bitPattern: seq &- maxInputSeq)
            if diff > 0 {
                let shift = Int(diff)
                if shift >= 64 {
                    inputSeenMask = 1
                } else {
                    inputSeenMask = (inputSeenMask << shift) | 1
                }
                maxInputSeq = seq
                return true
            } else {
                let age = Int(-diff)
                if age >= 64 {
                    return false
                }
                let bit: UInt64 = 1 << age
                if (inputSeenMask & bit) != 0 {
                    return false
                }
                inputSeenMask |= bit
                return true
            }
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
    private var pacerTimer: DispatchSourceTimer?
    private var pacerRunning = false
    private var sessions: [Data: PeerSession] = [:]

    // Cached public STUN endpoint (60s TTL) for P2P NAT hole punching
    private var _publicEndpoint: (ip: String, port: UInt16)?
    private var lastStunRefreshAt: Date = .distantPast
    private var pendingStunTxID: Data?
    private static let stunTtlSeconds: TimeInterval = 60.0

    var publicEndpoint: (ip: String, port: UInt16)? {
        lock.lock()
        defer { lock.unlock() }
        return _publicEndpoint
    }

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

        let pacer = DispatchSource.makeTimerSource(queue: ioQueue)
        pacer.schedule(deadline: .now(), repeating: .milliseconds(1), leeway: .microseconds(250))
        pacer.setEventHandler { [weak self] in
            self?.drainPacerTick()
        }

        lock.lock()
        sockfd = fd
        isIPv6 = dualStack
        listeningPort = boundPort
        readSource = reader
        timeoutTimer = timer
        pacerTimer = pacer
        pacerRunning = false
        lock.unlock()

        reader.resume()
        timer.resume()

        ConnectionLogger.shared.logStep(sessionId: "udp", step: "udp_video_started",
                                        detail: "port=\(boundPort) dualStack=\(dualStack)")
        refreshPublicEndpointAsync(force: true)
        return true
    }

    /// Probes STUN directly out of the bound `sockfd` (60s TTL) so the discovered
    /// external `(ip, port)` matches our exact UDP listening port for NAT hole punching.
    func refreshPublicEndpointAsync(force: Bool = false) {
        lock.lock()
        let fd = sockfd
        let dualStack = isIPv6
        let now = Date()
        if fd < 0 || (!force && now.timeIntervalSince(lastStunRefreshAt) < Self.stunTtlSeconds) {
            lock.unlock()
            return
        }
        lastStunRefreshAt = now
        let txID = StunClient.randomTransactionID()
        pendingStunTxID = txID
        lock.unlock()

        let request = StunClient.buildBindingRequest(txID: txID)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            for server in StunClient.defaultServers {
                guard var dest = self.resolveUdpTarget(host: server.host, port: server.port, asDualStackIPv6: dualStack) else {
                    continue
                }
                self.lock.lock()
                let curFd = self.sockfd
                self.lock.unlock()
                guard curFd >= 0 else { return }
                self.sendDataPacket(fd: curFd, data: request, peerAddr: &dest.addr, peerLen: dest.len)
            }
        }
    }

    /// Sends 3 `HELLO_ACK` datagrams 50ms apart to `(ip, port)` to punch a NAT pinhole
    /// for incoming client `HELLO` packets during STUN UDP hole punching.
    func sendHolePunch(token: Data, ip: String, port: UInt16) {
        guard token.count == 16, port > 0, !ip.isEmpty else { return }
        lock.lock()
        let dualStack = isIPv6
        let hasSession = sessions[token] != nil
        lock.unlock()
        guard hasSession else { return }

        var ack = [UInt8](repeating: 0, count: 20)
        ack[0] = Self.magic0
        ack[1] = Self.magic1
        ack[2] = Self.version
        ack[3] = Self.packetHelloAck
        token.copyBytes(to: &ack[4], count: 16)
        let ackData = Data(ack)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self,
                  let dest = self.resolveUdpTarget(host: ip, port: port, asDualStackIPv6: dualStack) else {
                return
            }
            for i in 0..<3 {
                let delayMs = i * 50
                self.ioQueue.asyncAfter(deadline: .now() + .milliseconds(delayMs)) { [weak self] in
                    guard let self else { return }
                    self.lock.lock()
                    let fd = self.sockfd
                    self.lock.unlock()
                    guard fd >= 0 else { return }
                    var addrCopy = dest.addr
                    self.sendDataPacket(fd: fd, data: ackData, peerAddr: &addrCopy, peerLen: dest.len)
                }
            }
        }
    }

    func stop() {
        lock.lock()
        let reader = readSource
        let timer = timeoutTimer
        let pacer = pacerTimer
        let wasPacerRunning = pacerRunning
        readSource = nil
        timeoutTimer = nil
        pacerTimer = nil
        pacerRunning = false
        sockfd = -1
        listeningPort = 0
        sessions.removeAll()
        lock.unlock()

        if let pacer {
            if !wasPacerRunning { pacer.resume() }
            pacer.cancel()
        }
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
        onLossFeedback: ((Double, UInt64) -> Void)? = nil,
        onTransportFeedback: ((Double, Double, Double, Int) -> Void)? = nil,
        onInputMessage: ((String) -> Void)? = nil
    ) {
        guard token.count == 16 else { return }
        lock.lock()
        if let existing = sessions[token] {
            // Preserve active UDP peer across pipeline rebuilds (resolution/codec switch)
            existing.onActivated = onActivated
            existing.onLossFeedback = onLossFeedback
            existing.onTransportFeedback = onTransportFeedback
            existing.onInputMessage = onInputMessage
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
                onLossFeedback: onLossFeedback,
                onTransportFeedback: onTransportFeedback,
                onInputMessage: onInputMessage
            )
        }
        lock.unlock()
    }

    func updatePacingBitrate(token: Data, bitrateBps: Int) {
        lock.lock()
        if let session = sessions[token] {
            session.pacingBitrateBps = max(2_000_000, bitrateBps)
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
        let supportsInterleavedFec = session.supportsInterleavedFec
        let pacerHasBacklog = session.pacingReadIndex < session.pacingQueue.count
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
        let useInterleavedFec = supportsInterleavedFec && fecGroupSize > 0 && fragCount > Int(fecGroupSize)
        let fecFlags: UInt8 = useInterleavedFec ? 0x01 : 0x00

        // Reusable buffer: 20B header + 2B length XOR + 1200B max payload + 16B GCM tag
        var packetBuf = [UInt8](repeating: 0, count: Self.headerSize + 2 + Self.maxFragmentPayload + Self.gcmTagSize)
        var addrCopy = peerAddr
        var cachedDataPackets: [(UInt64, Data)] = []
        cachedDataPackets.reserveCapacity(fragCount)
        // Maintain strict FIFO ordering: if previous frame packets are still draining in the pacer,
        // enqueue ALL packets of this frame behind them so P-frames never overtake a keyframe!
        let usePacing = pacerHasBacklog || (fragCount > Self.immediateBurstPackets)
        let immediateLimit = pacerHasBacklog ? 0 : Self.immediateBurstPackets
        var pacedPackets: [Data] = []
        if usePacing {
            pacedPackets.reserveCapacity(fragCount + 32)
        }

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
                    encFlag: encryptedFlag,
                    fecFlags: fecFlags
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

                let wireData = Data(packetBuf[0..<wireLen])
                let cacheKey = (UInt64(frameId) << 8) | UInt64(fragIdx)
                cachedDataPackets.append((cacheKey, wireData))

                if usePacing && i >= immediateLimit {
                    pacedPackets.append(wireData)
                } else {
                    if !sendPacket(fd: fd, buffer: packetBuf, length: wireLen,
                                   peerAddr: &addrCopy, peerLen: peerLen) {
                        return false
                    }
                }
            }

            // 2. Send XOR-FEC parity packets (0x11) per group where group has >= 2 fragments
            if fecGroupSize > 0 {
                let groupSz = Int(fecGroupSize)
                let groupCount = (fragCount + groupSz - 1) / groupSz
                var parityBody = [UInt8](repeating: 0, count: 2 + Self.maxFragmentPayload)

                for g in 0..<groupCount {
                    var members: [Int] = []
                    members.reserveCapacity(groupSz)
                    if useInterleavedFec {
                        var idx = g
                        while idx < fragCount {
                            members.append(idx)
                            idx += groupCount
                        }
                    } else {
                        let start = g * groupSz
                        let end = min(start + groupSz, fragCount)
                        for idx in start..<end {
                            members.append(idx)
                        }
                    }
                    guard members.count >= 2 else { continue }

                    var maxLenInGroup = 0
                    for idx in members {
                        let offset = idx * Self.maxFragmentPayload
                        let flen = min(Self.maxFragmentPayload, totalLen - offset)
                        if flen > maxLenInGroup { maxLenInGroup = flen }
                    }

                    let bodyLen = 2 + maxLenInGroup
                    for k in 0..<bodyLen {
                        parityBody[k] = 0
                    }

                    var xorLen: UInt16 = 0
                    for idx in members {
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
                        encFlag: encryptedFlag,
                        fecFlags: fecFlags
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

                    if usePacing {
                        pacedPackets.append(Data(packetBuf[0..<wireLen]))
                    } else {
                        _ = sendPacket(fd: fd, buffer: packetBuf, length: wireLen,
                                       peerAddr: &addrCopy, peerLen: peerLen)
                    }
                }
            }

            return true
        }

        var shouldResumePacer = false
        if !cachedDataPackets.isEmpty || !pacedPackets.isEmpty {
            lock.lock()
            if let s = sessions[token] {
                s.windowSentDataPackets += UInt64(cachedDataPackets.count)
                for (cacheKey, datagram) in cachedDataPackets {
                    s.storeInRing(key: cacheKey, datagram: datagram)
                }
                if !pacedPackets.isEmpty {
                    let pending = s.pacingQueue.count - s.pacingReadIndex
                    if pending + pacedPackets.count > Self.maxPacingQueuePackets {
                        // Drop stale queued packets if encoder outruns link (never build multi-frame lag)
                        s.pacingQueue.removeAll(keepingCapacity: true)
                        s.pacingReadIndex = 0
                    }
                    s.pacingQueue.append(contentsOf: pacedPackets)
                    if !pacerRunning, pacerTimer != nil {
                        pacerRunning = true
                        shouldResumePacer = true
                    }
                }
            }
            lock.unlock()
        }
        if shouldResumePacer {
            pacerTimer?.resume()
        }

        return ok
    }

    /// Strictly video-first UDP audio transmission (`packetType = 0x14`).
    /// - Returns `false` if UDP is inactive or frame exceeds single-packet MTU (caller uses WS TCP).
    /// - Under congestion (`pendingPaced > 4` or `fecLevel == .heavy`) or socket `EAGAIN`/`ENOBUFS`,
    ///   silently drops the audio packet and returns `true` so audio never competes with video or
    ///   falls back to TCP head-of-line blocking.
    /// - Never caches in NACK ring buffer, never emits FEC parity, never enqueues into `pacingQueue`,
    ///   and never increments `windowSentDataPackets`.
    func sendAudioFrame(
        token: Data,
        seq: UInt32,
        ptsMs: UInt32,
        data: Data
    ) -> Bool {
        let totalLen = data.count
        guard totalLen > 0, totalLen <= Self.maxFragmentPayload else {
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
        let pendingPaced = session.pacingQueue.count - session.pacingReadIndex
        if pendingPaced > 4 || session.fecLevel == .heavy {
            lock.unlock()
            return true
        }
        let peerLen = session.peerLen
        let symmetricKey = session.symmetricKey
        lock.unlock()

        let encryptedFlag: UInt8 = (symmetricKey != nil) ? 0x01 : 0x00
        var packetBuf = [UInt8](repeating: 0, count: Self.headerSize + totalLen + Self.gcmTagSize)
        writeHeader(
            into: &packetBuf,
            packetType: Self.packetAudio,
            frameId: seq,
            ptsMs: ptsMs,
            flags: 0,
            fragIndex: 0,
            fragCount: 1,
            fecGroupSize: 0,
            payloadLen: UInt16(totalLen),
            encFlag: encryptedFlag,
            fecFlags: 0
        )

        let wireLen: Int? = data.withUnsafeBytes { rawBuf in
            guard let basePtr = rawBuf.bindMemory(to: UInt8.self).baseAddress else { return nil }
            if let key = symmetricKey {
                let slice = UnsafeBufferPointer(start: basePtr, count: totalLen)
                return sealIntoPacketBuffer(
                    packetBuf: &packetBuf,
                    plaintext: slice,
                    key: key,
                    packetType: Self.packetAudio,
                    fragIndex: 0,
                    frameId: seq,
                    ptsMs: ptsMs
                )
            } else {
                for j in 0..<totalLen {
                    packetBuf[Self.headerSize + j] = basePtr[j]
                }
                return Self.headerSize + totalLen
            }
        }
        guard let wireLen else { return true }

        var addrCopy = peerAddr
        _ = sendPacket(fd: fd, buffer: packetBuf, length: wireLen, peerAddr: &addrCopy, peerLen: peerLen)
        return true
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
        encFlag: UInt8,
        fecFlags: UInt8 = 0
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
        buf[19] = fecFlags
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

        var recvBuf = [UInt8](repeating: 0, count: 2048)
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
            // RFC 5389 STUN Binding Success Response (0x0101 + magic cookie 0x2112A442)
            if n >= 20,
               recvBuf[0] == 0x01, recvBuf[1] == 0x01,
               recvBuf[4] == 0x21, recvBuf[5] == 0x12,
               recvBuf[6] == 0xA4, recvBuf[7] == 0x42 {
                handleStunResponse(Data(recvBuf[0..<n]))
                continue
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
                let interleaved = (n >= 21) && ((recvBuf[20] & 0x01) != 0)
                handleHello(fd: fd, token: token, interleavedFec: interleaved, srcAddr: srcAddr, srcLen: srcLen)
            case Self.packetKeepalive:
                handleKeepalive(token: token, srcAddr: srcAddr, srcLen: srcLen)
            case Self.packetNack:
                handleNack(fd: fd, token: token, buf: recvBuf, length: n, srcAddr: srcAddr, srcLen: srcLen)
            case Self.packetFeedback:
                handleFeedback(token: token, buf: recvBuf, length: n, srcAddr: srcAddr, srcLen: srcLen)
            case Self.packetInput:
                handleInput(token: token, buf: recvBuf, length: n, srcAddr: srcAddr, srcLen: srcLen)
            default:
                break
            }
        }
    }

    private func handleStunResponse(_ data: Data) {
        lock.lock()
        let txID = pendingStunTxID
        lock.unlock()
        guard let txID, let mapped = StunClient.parseBindingResponse(data, expectedTxID: txID) else {
            return
        }
        lock.lock()
        _publicEndpoint = (ip: mapped.publicIp, port: mapped.publicPort)
        pendingStunTxID = nil
        lock.unlock()
        ConnectionLogger.shared.logStep(
            sessionId: "udp",
            step: "udp_stun_discovered",
            detail: "\(mapped.publicIp):\(mapped.publicPort)"
        )
    }

    private func resolveUdpTarget(host: String, port: UInt16, asDualStackIPv6: Bool) -> (addr: sockaddr_storage, len: socklen_t)? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_protocol = IPPROTO_UDP

        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let first = res else {
            return nil
        }
        defer { freeaddrinfo(res) }
        guard let rawAddr = first.pointee.ai_addr else { return nil }
        let ipv4 = rawAddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }

        var storage = sockaddr_storage()
        if asDualStackIPv6 {
            var v6 = sockaddr_in6()
            v6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            v6.sin6_family = sa_family_t(AF_INET6)
            v6.sin6_port = ipv4.sin_port
            // IPv4-mapped IPv6 address ::ffff:a.b.c.d
            let ipBytes = withUnsafeBytes(of: ipv4.sin_addr.s_addr) { Array($0) }
            v6.sin6_addr.__u6_addr.__u6_addr8 = (
                0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF,
                ipBytes[0], ipBytes[1], ipBytes[2], ipBytes[3]
            )
            withUnsafeMutablePointer(to: &storage) { ptr in
                ptr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee = v6 }
            }
            return (storage, socklen_t(MemoryLayout<sockaddr_in6>.size))
        } else {
            withUnsafeMutablePointer(to: &storage) { ptr in
                ptr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee = ipv4 }
            }
            return (storage, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }

    private func handleHello(fd: Int32, token: Data, interleavedFec: Bool, srcAddr: sockaddr_storage, srcLen: socklen_t) {
        var callbackToFire: ((Bool) -> Void)?
        lock.lock()
        if let session = sessions[token] {
            session.peerAddr = srcAddr
            session.peerLen = srcLen
            session.lastKeepaliveAt = Date()
            session.supportsInterleavedFec = interleavedFec
            if !session.isActive {
                session.isActive = true
                callbackToFire = session.onActivated
            }
        } else {
            lock.unlock()
            return
        }
        lock.unlock()

        // Reply HELLO_ACK (21B): [0x52, 0x55, 0x01, 0x02] + 16-byte token + 0x01 (supports UDP input 0x20)
        var ack = [UInt8](repeating: 0, count: 21)
        ack[0] = Self.magic0
        ack[1] = Self.magic1
        ack[2] = Self.version
        ack[3] = Self.packetHelloAck
        token.copyBytes(to: &ack[4], count: 16)
        ack[20] = 0x01
        var addrCopy = srcAddr
        _ = sendPacket(fd: fd, buffer: ack, length: 21, peerAddr: &addrCopy, peerLen: srcLen)

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
    /// [0x52, 0x55, 0x01, 0x12] + 16B token + frameId(BE4) + count(0..16) + count * fragIndex
    /// When count == 0, requests whole-frame retransmission (for lost 1-fragment / small P-frames).
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
        guard count >= 0, count <= 16, length >= 25 + count else { return }

        var toRetransmit: [Data] = []
        toRetransmit.reserveCapacity(count == 0 ? 8 : count)
        var destAddr = srcAddr
        var destLen = srcLen
        var totalRetransmits: UInt64 = 0

        lock.lock()
        if let session = sessions[token], session.isActive {
            session.hasEverSeenNack = true
            if let boundAddr = session.peerAddr {
                destAddr = boundAddr
                destLen = session.peerLen
            }
            if count == 0 {
                // Whole-frame NACK: retransmit all cached fragments of frameId (up to 16)
                for fragIdx in 0..<16 {
                    let key = (UInt64(frameId) << 8) | UInt64(fragIdx)
                    if let cached = session.lookupInRing(key: key) {
                        toRetransmit.append(cached)
                    } else {
                        break
                    }
                }
                session.windowNackPackets += UInt64(max(1, toRetransmit.count))
            } else {
                session.windowNackPackets += UInt64(count)
                for idx in 0..<count {
                    let fragIndex = buf[25 + idx]
                    let key = (UInt64(frameId) << 8) | UInt64(fragIndex)
                    if let cached = session.lookupInRing(key: key) {
                        toRetransmit.append(cached)
                    }
                }
            }
            if !toRetransmit.isEmpty {
                let recentSent = max(session.windowSentDataPackets, session.lastWindowSentDataPackets)
                let budget = Self.computeWindowNackBudget(recentSentPackets: recentSent)
                let remaining = budget > session.windowRetransmittedPackets
                    ? Int(budget - session.windowRetransmittedPackets)
                    : 0
                if toRetransmit.count > remaining {
                    toRetransmit = Array(toRetransmit.prefix(remaining))
                }
                if !toRetransmit.isEmpty {
                    session.windowRetransmittedPackets += UInt64(toRetransmit.count)
                    session.nackRetransmits += UInt64(toRetransmit.count)
                    totalRetransmits = session.nackRetransmits
                }
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

    /// Handles incoming 0x13 FEEDBACK (28 bytes):
    /// [0x52, 0x55, 0x01, 0x13] + 16B token + delayGradDeciMs(Int16 BE) + lossPermille(UInt16 BE)
    /// + jitterDeciMs(UInt16 BE) + recvKbps(UInt16 BE)
    private func handleFeedback(
        token: Data,
        buf: [UInt8],
        length: Int,
        srcAddr: sockaddr_storage,
        srcLen: socklen_t
    ) {
        guard length >= 28 else { return }
        let rawDelayGrad = UInt16(buf[20]) << 8 | UInt16(buf[21])
        let delayGradMs = Double(Int16(bitPattern: rawDelayGrad)) / 10.0
        let lossPermille = UInt16(buf[22]) << 8 | UInt16(buf[23])
        let lossRatio = Double(min(1000, Int(lossPermille))) / 1000.0
        let jitterDeciMs = UInt16(buf[24]) << 8 | UInt16(buf[25])
        let jitterMs = Double(jitterDeciMs) / 10.0
        let recvKbps = Int(UInt16(buf[26]) << 8 | UInt16(buf[27]))
        let recvBps = recvKbps * 1000

        var callback: ((Double, Double, Double, Int) -> Void)?
        lock.lock()
        if let session = sessions[token], session.isActive {
            session.peerAddr = srcAddr
            session.peerLen = srcLen
            session.lastKeepaliveAt = Date()
            callback = session.onTransportFeedback
        }
        lock.unlock()

        callback?(delayGradMs, lossRatio, jitterMs, recvBps)
    }

    /// Handles incoming 0x20 INPUT packet:
    /// [0x52, 0x55, 0x01, 0x20] + 16B token + inputSeq(BE4) + encFlags(1B) + payload [+ 16B GCM tag]
    private func handleInput(
        token: Data,
        buf: [UInt8],
        length: Int,
        srcAddr: sockaddr_storage,
        srcLen: socklen_t
    ) {
        let hdrLen = 25
        guard length > hdrLen else { return }
        let inputSeq: UInt32 = (UInt32(buf[20]) << 24) |
                               (UInt32(buf[21]) << 16) |
                               (UInt32(buf[22]) << 8) |
                               UInt32(buf[23])
        let isEncrypted = (buf[24] & 0x01) != 0

        var key: SymmetricKey?
        var callback: ((String) -> Void)?

        lock.lock()
        if let session = sessions[token], session.isActive {
            key = session.symmetricKey
            callback = session.onInputMessage
        }
        lock.unlock()

        guard let callback else { return }

        // Authenticate & decrypt BEFORE mutating peerAddr or the sliding dedup window so
        // a corrupted/tampered packet with a high inputSeq can NEVER poison maxInputSeq!
        let plaintextData: Data
        if isEncrypted {
            guard let key, length > hdrLen + Self.gcmTagSize else { return }
            let ctLen = length - hdrLen - Self.gcmTagSize
            var nonceBytes = [UInt8](repeating: 0, count: 12)
            nonceBytes[0] = Self.magic0
            nonceBytes[1] = Self.magic1
            nonceBytes[2] = Self.packetInput
            nonceBytes[3] = 0x00
            for i in 0..<4 { nonceBytes[4 + i] = buf[4 + i] }
            nonceBytes[8]  = buf[20]
            nonceBytes[9]  = buf[21]
            nonceBytes[10] = buf[22]
            nonceBytes[11] = buf[23]

            guard let nonce = try? AES.GCM.Nonce(data: nonceBytes),
                  let sealedBox = try? AES.GCM.SealedBox(
                      nonce: nonce,
                      ciphertext: Data(buf[hdrLen..<(hdrLen + ctLen)]),
                      tag: Data(buf[(hdrLen + ctLen)..<length])
                  ),
                  let opened = try? AES.GCM.open(sealedBox, using: key, authenticating: Data(buf[0..<hdrLen])) else {
                return
            }
            plaintextData = opened
        } else {
            // Reject unencrypted input if session requires E2E encryption
            guard key == nil else { return }
            plaintextData = Data(buf[hdrLen..<length])
        }

        var accepted = false
        lock.lock()
        if let session = sessions[token], session.isActive {
            session.peerAddr = srcAddr
            session.peerLen = srcLen
            session.lastKeepaliveAt = Date()
            accepted = session.acceptInputSeq(inputSeq)
        }
        lock.unlock()
        guard accepted else { return }

        if let jsonText = String(data: plaintextData, encoding: .utf8) {
            callback(jsonText)
        }
    }

    /// 1ms token-bucket pacer tick: smoothly drains queued large-frame datagrams at
    /// `max(pacingBitrateBps * 1.4, 12 Mbps)` so WireGuard/router queues never suffer
    /// micro-burst tail drops on 2K keyframes or fast scrolling.
    /// Pure pacing rate calculator shared by `drainPacerTick` and regression tests.
    static func computePacingParameters(
        pacingBitrateBps: Int,
        pendingPackets: Int,
        allowFecSuppression: Bool
    ) -> (paceRateBps: Double, maxPacketsPerTick: Int) {
        let estQueuedBytes = Double(pendingPackets) * 1236.0
        if !allowFecSuppression {
            // WAN / tunnel mode: pace proportionally to target bitrate (1.5x, floor 4 Mbps,
            // ceiling 12 Mbps, max 4 pkts/ms) so scroll/keyframe bursts don't overflow a
            // 3-5 Mbps WAN/VPN router queue while still draining a 40KB keyframe in ~80ms.
            let targetBps = max(Double(pacingBitrateBps) * 1.5, 4_000_000.0)
            return (min(targetBps, 12_000_000.0), 4)
        } else {
            // LAN mode: drain large frames within 14ms for sub-frame latency
            let drainTargetBps = (estQueuedBytes / 0.014) * 8.0
            return (max(Double(pacingBitrateBps) * 2.5, drainTargetBps, 24_000_000.0), 24)
        }
    }

    private func drainPacerTick() {
        let now = CFAbsoluteTimeGetCurrent()
        var batch: [(sockaddr_storage, socklen_t, [Data])] = []
        var fd: Int32 = -1
        var anyRemaining = false
        var shouldSuspend = false

        lock.lock()
        fd = sockfd
        if fd >= 0 {
            for session in sessions.values {
                guard session.isActive,
                      let addr = session.peerAddr,
                      session.pacingReadIndex < session.pacingQueue.count else {
                    continue
                }
                let dt = session.lastPaceTickAt > 0
                    ? min(0.015, max(0.0005, now - session.lastPaceTickAt))
                    : 0.002
                session.lastPaceTickAt = now

                // Drain any queued large frame within ~14ms (1 frame interval at 60fps) so
                // keyframes never time out on the receiver while still smoothing 0.2ms micro-bursts.
                let pendingCount = session.pacingQueue.count - session.pacingReadIndex
                let (paceRateBps, maxPacketsPerTick) = Self.computePacingParameters(
                    pacingBitrateBps: session.pacingBitrateBps,
                    pendingPackets: pendingCount,
                    allowFecSuppression: session.allowFecSuppression
                )
                let addBytes = (paceRateBps / 8.0) * dt
                let maxBucket = max(session.allowFecSuppression ? 7200.0 : 3600.0, (paceRateBps / 8.0) * 0.004)
                session.pacingBudgetBytes = min(maxBucket, session.pacingBudgetBytes + addBytes)

                var toSend: [Data] = []
                while session.pacingReadIndex < session.pacingQueue.count && session.pacingBudgetBytes >= 1.0 {
                    let pkt = session.pacingQueue[session.pacingReadIndex]
                    session.pacingReadIndex += 1
                    session.pacingBudgetBytes -= Double(pkt.count)
                    toSend.append(pkt)
                    if toSend.count >= maxPacketsPerTick { break }
                }

                if session.pacingReadIndex >= session.pacingQueue.count {
                    session.pacingQueue.removeAll(keepingCapacity: true)
                    session.pacingReadIndex = 0
                } else {
                    if session.pacingReadIndex > 64 {
                        session.pacingQueue.removeFirst(session.pacingReadIndex)
                        session.pacingReadIndex = 0
                    }
                    anyRemaining = true
                }

                if !toSend.isEmpty {
                    batch.append((addr, session.peerLen, toSend))
                }
            }
        }
        if !anyRemaining && pacerRunning {
            pacerRunning = false
            shouldSuspend = true
        }
        lock.unlock()

        if shouldSuspend {
            pacerTimer?.suspend()
        }

        guard fd >= 0 else { return }
        for (addr, len, packets) in batch {
            var addrCopy = addr
            for pkt in packets {
                sendDataPacket(fd: fd, data: pkt, peerAddr: &addrCopy, peerLen: len)
            }
        }
    }

    /// UU `WebRTC-RetransmissionRateLimit` equivalent: cap NACK retransmissions per 2s
    /// window so stale retransmits never exceed ~33% of live data traffic and starve live frames.
    static func computeWindowNackBudget(recentSentPackets: UInt64) -> UInt64 {
        max(24, recentSentPackets / 3)
    }

    /// UU `fec_suppression_change reason=sustained_overuse` equivalent:
    /// - Transient / moderate loss: protect frames with adaptive XOR FEC.
    /// - Sustained severe congestion (>=15% loss for 2+ consecutive windows): suppress delta FEC
    ///   (deltaG=0) so +33% parity stops amplifying tunnel congestion, while keeping keyframe FEC (keyG=3).
    static func computeFecPolicy(
        lossRatio: Double,
        sustainedOveruseWindows: Int,
        allowFecSuppression: Bool,
        hasEverSeenNack: Bool,
        cleanWindows: Int
    ) -> (levelName: String, deltaFec: UInt8, keyFec: UInt8, suppressedByOveruse: Bool) {
        if sustainedOveruseWindows >= 2 {
            return ("overuse_suppressed", 0, 3, true)
        } else if lossRatio >= 0.08 {
            return ("heavy", 3, lossRatio >= 0.15 ? 2 : 3, false)
        } else if lossRatio >= 0.03 {
            return ("moderate", 4, 3, false)
        } else if allowFecSuppression && !hasEverSeenNack && cleanWindows >= 3 {
            return ("suppressed", 0, 8, false)
        } else {
            return ("light", 8, 4, false)
        }
    }

    private func runMaintenanceTick() {
        let now = Date()
        var deactivated: [(Bool) -> Void] = []
        var lossCallbacks: [((Double, UInt64) -> Void, Double, UInt64)] = []
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
            session.lastWindowSentDataPackets = sent
            session.windowSentDataPackets = 0
            session.windowNackPackets = 0
            session.windowRetransmittedPackets = 0

            guard sent > 0 else { continue }
            let lossRatio = min(1.0, Double(nacks) / Double(max(1, sent)))
            if nacks == 0 {
                session.cleanWindows += 1
            } else {
                session.cleanWindows = 0
            }

            if lossRatio >= 0.15 && sent >= 80 {
                session.sustainedOveruseWindows += 1
            } else if lossRatio < 0.05 {
                session.sustainedOveruseWindows = 0
            }

            let policy = Self.computeFecPolicy(
                lossRatio: lossRatio,
                sustainedOveruseWindows: session.sustainedOveruseWindows,
                allowFecSuppression: session.allowFecSuppression,
                hasEverSeenNack: session.hasEverSeenNack,
                cleanWindows: session.cleanWindows
            )
            let newLevel: FecLevel
            switch policy.levelName {
            case "overuse_suppressed", "suppressed": newLevel = .suppressed
            case "heavy": newLevel = .heavy
            case "moderate": newLevel = .moderate
            default: newLevel = .light
            }
            let newDeltaFec = policy.deltaFec
            let newKeyFec = policy.keyFec

            if newLevel != session.fecLevel || policy.suppressedByOveruse != session.fecSuppressedByOveruse || newDeltaFec != session.deltaFecGroupSize || newKeyFec != session.keyFecGroupSize {
                session.fecLevel = newLevel
                session.fecSuppressedByOveruse = policy.suppressedByOveruse
                session.deltaFecGroupSize = newDeltaFec
                session.keyFecGroupSize = newKeyFec
                fecTransitions.append((newLevel, lossRatio, newDeltaFec, newKeyFec))
            }

            if let cb = session.onLossFeedback {
                lossCallbacks.append((cb, lossRatio, sent))
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
        for (cb, lossRatio, sent) in lossCallbacks {
            cb(lossRatio, sent)
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
