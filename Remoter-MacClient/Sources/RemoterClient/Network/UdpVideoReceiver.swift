import Foundation
import Darwin

/// Direct low-latency UDP video receiver with 0ms XOR-FEC recovery and automatic WebSocket fallback.
/// Wire protocol matches `Remoter-MacServer/Server/UdpVideoServer.swift` and `Remoter-WinClient/Network/UdpVideoReceiver.cs` bit-for-bit.
public final class UdpVideoReceiver: @unchecked Sendable {
    public static let magic0: UInt8 = 0x52 // 'R'
    public static let magic1: UInt8 = 0x55 // 'U'
    public static let version: UInt8 = 0x01

    public static let packetTypeHello: UInt8 = 0x01
    public static let packetTypeHelloAck: UInt8 = 0x02
    public static let packetTypeKeepalive: UInt8 = 0x03
    public static let packetTypeData: UInt8 = 0x10
    public static let packetTypeFecParity: UInt8 = 0x11

    public static let controlPacketSize = 20
    public static let videoHeaderSize = 20
    public static let tokenLength = 16

    private static let maxInFlightFrames = 4
    private static let frameTimeoutMs: UInt64 = 80
    private static let handshakeTimeoutSeconds: TimeInterval = 0.6
    private static let helloIntervalSeconds: TimeInterval = 0.1
    private static let keepaliveIntervalSeconds: TimeInterval = 2.0
    private static let receiveBufferSize: Int32 = 4 * 1024 * 1024

    // MARK: - Callbacks

    public var onConnected: ((Bool) -> Void)?
    public var onFrame: ((VideoFramePacket) -> Void)?
    public var onFrameDropped: (() -> Void)?

    // MARK: - Private State (accessed exclusively on `queue`)

    private struct FrameBuffer {
        let frameId: UInt32
        let ptsMs: UInt32
        let isKeyframe: Bool
        let isHEVC: Bool
        let fragCount: Int
        let fecGroupSize: Int
        let createdAtMs: UInt64
        var fragments: [Data?]
        var receivedCount: Int
        var parityPackets: [Int: Data]

        init(
            frameId: UInt32,
            ptsMs: UInt32,
            isKeyframe: Bool,
            isHEVC: Bool,
            fragCount: Int,
            fecGroupSize: Int,
            createdAtMs: UInt64
        ) {
            self.frameId = frameId
            self.ptsMs = ptsMs
            self.isKeyframe = isKeyframe
            self.isHEVC = isHEVC
            self.fragCount = fragCount
            self.fecGroupSize = fecGroupSize
            self.createdAtMs = createdAtMs
            self.fragments = Array(repeating: nil, count: fragCount)
            self.receivedCount = 0
            self.parityPackets = [:]
        }
    }

    private let queue = DispatchQueue(label: "com.remoter.client.udp-video", qos: .userInteractive)
    private var sockFd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var helloTimer: DispatchSourceTimer?
    private var handshakeTimeoutTimer: DispatchSourceTimer?
    private var keepaliveTimer: DispatchSourceTimer?
    private var cleanupTimer: DispatchSourceTimer?

    private var token = Data()
    private var isActive = false
    private var isConnected = false
    private var helloSentCount = 0

    private var frames: [UInt32: FrameBuffer] = [:]
    private var lastDeliveredFrameId: UInt32?
    private var recvScratch = [UInt8](repeating: 0, count: 65536)

    public init() {}

    deinit {
        stop()
    }

    // MARK: - Hex Token Helper

    public static func decodeHexToken(_ hex: String) -> Data? {
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == tokenLength * 2 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(tokenLength)
        var idx = trimmed.startIndex
        for _ in 0..<tokenLength {
            let next = trimmed.index(idx, offsetBy: 2)
            guard let b = UInt8(trimmed[idx..<next], radix: 16) else { return nil }
            bytes.append(b)
            idx = next
        }
        return Data(bytes)
    }

    // MARK: - Lifecycle

    public func start(host: String, port: UInt16, token: Data) {
        guard token.count == Self.tokenLength, port > 0, !host.isEmpty else { return }

        queue.async { [weak self] in
            guard let self else { return }
            self.stopLocked(notifyDisconnect: false)

            guard let fd = Self.openConnectedUdpSocket(host: host, port: port) else {
                return
            }

            self.sockFd = fd
            self.token = token
            self.isActive = true
            self.isConnected = false
            self.helloSentCount = 0
            self.frames.removeAll()
            self.lastDeliveredFrameId = nil

            // Setup non-blocking read source
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: self.queue)
            source.setEventHandler { [weak self] in
                self?.drainSocketLocked()
            }
            source.setCancelHandler {
                close(fd)
            }
            self.readSource = source
            source.resume()

            // Send 3 HELLO packets 100ms apart
            self.sendControlPacketLocked(type: Self.packetTypeHello)
            self.helloSentCount = 1

            let hTimer = DispatchSource.makeTimerSource(queue: self.queue)
            hTimer.schedule(deadline: .now() + Self.helloIntervalSeconds, repeating: Self.helloIntervalSeconds)
            hTimer.setEventHandler { [weak self] in
                guard let self, self.isActive, !self.isConnected else {
                    self?.helloTimer?.cancel()
                    self?.helloTimer = nil
                    return
                }
                if self.helloSentCount >= 3 {
                    self.helloTimer?.cancel()
                    self.helloTimer = nil
                    return
                }
                self.sendControlPacketLocked(type: Self.packetTypeHello)
                self.helloSentCount += 1
            }
            self.helloTimer = hTimer
            hTimer.resume()

            // If no HELLO_ACK within 600ms, stop cleanly so WS TCP continues uninterrupted
            let timeoutTimer = DispatchSource.makeTimerSource(queue: self.queue)
            timeoutTimer.schedule(deadline: .now() + Self.handshakeTimeoutSeconds)
            timeoutTimer.setEventHandler { [weak self] in
                guard let self, self.isActive, !self.isConnected else { return }
                self.stopLocked(notifyDisconnect: false)
            }
            self.handshakeTimeoutTimer = timeoutTimer
            timeoutTimer.resume()
        }
    }

    public func stop() {
        queue.sync {
            stopLocked(notifyDisconnect: false)
        }
    }

    // MARK: - Socket Helpers

    private static func openConnectedUdpSocket(host: String, port: UInt16) -> Int32? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_protocol = IPPROTO_UDP

        var resultPtr: UnsafeMutablePointer<addrinfo>?
        let portStr = String(port)
        guard getaddrinfo(host, portStr, &hints, &resultPtr) == 0, let first = resultPtr else {
            return nil
        }
        defer { freeaddrinfo(first) }

        var ptr: UnsafeMutablePointer<addrinfo>? = first
        while let current = ptr {
            let ai = current.pointee
            let fd = socket(ai.ai_family, ai.ai_socktype, ai.ai_protocol)
            if fd >= 0 {
                var rcvBuf = Self.receiveBufferSize
                _ = setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvBuf, socklen_t(MemoryLayout<Int32>.size))

                let flags = fcntl(fd, F_GETFL, 0)
                if flags >= 0 {
                    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
                }

                if Darwin.connect(fd, ai.ai_addr, ai.ai_addrlen) == 0 {
                    return fd
                }
                close(fd)
            }
            ptr = ai.ai_next
        }
        return nil
    }

    private func stopLocked(notifyDisconnect: Bool) {
        let wasConnected = isConnected
        isActive = false
        isConnected = false

        helloTimer?.cancel()
        helloTimer = nil
        handshakeTimeoutTimer?.cancel()
        handshakeTimeoutTimer = nil
        keepaliveTimer?.cancel()
        keepaliveTimer = nil
        cleanupTimer?.cancel()
        cleanupTimer = nil

        if let source = readSource {
            readSource = nil
            sockFd = -1
            source.cancel()
        } else if sockFd >= 0 {
            close(sockFd)
            sockFd = -1
        }

        frames.removeAll()
        lastDeliveredFrameId = nil
        token = Data()

        if notifyDisconnect && wasConnected {
            onConnected?(false)
        }
    }

    private func sendControlPacketLocked(type: UInt8) {
        guard sockFd >= 0, token.count == Self.tokenLength else { return }
        var pkt = [UInt8](repeating: 0, count: Self.controlPacketSize)
        pkt[0] = Self.magic0
        pkt[1] = Self.magic1
        pkt[2] = Self.version
        pkt[3] = type
        token.copyBytes(to: &pkt[4], count: Self.tokenLength)

        pkt.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            _ = Darwin.send(sockFd, base, raw.count, 0)
        }
    }

    private func drainSocketLocked() {
        guard isActive, sockFd >= 0 else { return }
        while isActive && sockFd >= 0 {
            let n = recvScratch.withUnsafeMutableBytes { raw -> ssize_t in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.recv(sockFd, base, raw.count, 0)
            }
            if n > 0 {
                handleDatagramLocked(count: Int(n))
            } else {
                let err = errno
                if err == EAGAIN || err == EWOULDBLOCK || err == EINTR {
                    break
                }
                // Fatal socket error (e.g. ICMP port unreachable / network down)
                stopLocked(notifyDisconnect: true)
                break
            }
        }
    }

    // MARK: - Datagram Parsing & Frame Reassembly

    private func handleDatagramLocked(count: Int) {
        guard count >= Self.controlPacketSize else { return }
        guard recvScratch[0] == Self.magic0,
              recvScratch[1] == Self.magic1,
              recvScratch[2] == Self.version else {
            return
        }

        let pktType = recvScratch[3]
        switch pktType {
        case Self.packetTypeHelloAck:
            handleHelloAckLocked(count: count)
        case Self.packetTypeData:
            handleVideoPacketLocked(count: count, isParity: false)
        case Self.packetTypeFecParity:
            handleVideoPacketLocked(count: count, isParity: true)
        default:
            break
        }
    }

    private func handleHelloAckLocked(count: Int) {
        guard count >= Self.controlPacketSize, token.count == Self.tokenLength else { return }
        // Verify matching 16-byte token
        let matches = token.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
            for i in 0..<Self.tokenLength {
                if recvScratch[4 + i] != base[i] { return false }
            }
            return true
        }
        guard matches else { return }

        if !isConnected {
            isConnected = true
            helloTimer?.cancel()
            helloTimer = nil
            handshakeTimeoutTimer?.cancel()
            handshakeTimeoutTimer = nil

            // Start 2s KEEPALIVE timer
            let kTimer = DispatchSource.makeTimerSource(queue: queue)
            kTimer.schedule(deadline: .now() + Self.keepaliveIntervalSeconds, repeating: Self.keepaliveIntervalSeconds)
            kTimer.setEventHandler { [weak self] in
                guard let self, self.isActive, self.isConnected else { return }
                self.sendControlPacketLocked(type: Self.packetTypeKeepalive)
            }
            keepaliveTimer = kTimer
            kTimer.resume()

            // Start 40ms stale-frame cleanup timer (80ms timeout)
            let cTimer = DispatchSource.makeTimerSource(queue: queue)
            cTimer.schedule(deadline: .now() + 0.04, repeating: 0.04)
            cTimer.setEventHandler { [weak self] in
                self?.evictTimedOutFramesLocked()
            }
            cleanupTimer = cTimer
            cTimer.resume()

            onConnected?(true)
        }
    }

    private func handleVideoPacketLocked(count: Int, isParity: Bool) {
        guard count >= Self.videoHeaderSize else { return }

        let frameId = (UInt32(recvScratch[4]) << 24)
            | (UInt32(recvScratch[5]) << 16)
            | (UInt32(recvScratch[6]) << 8)
            | UInt32(recvScratch[7])
        let ptsMs = (UInt32(recvScratch[8]) << 24)
            | (UInt32(recvScratch[9]) << 16)
            | (UInt32(recvScratch[10]) << 8)
            | UInt32(recvScratch[11])
        let flags = recvScratch[12]
        let isKeyframe = (flags & 0x01) != 0
        let isHEVC = (flags & 0x02) != 0
        let fragIndex = Int(recvScratch[13])
        let fragCount = Int(recvScratch[14])
        let fecGroupSize = Int(recvScratch[15])
        let payloadLen = Int((UInt16(recvScratch[16]) << 8) | UInt16(recvScratch[17]))

        guard fragCount > 0, count >= Self.videoHeaderSize + payloadLen else { return }

        // Ignore late packets for already-delivered or older frames
        if let lastId = lastDeliveredFrameId, !Self.isFrameNewer(frameId, than: lastId) {
            return
        }

        let nowMs = Self.monotonicMs()
        if frames[frameId] == nil {
            // Keep at most maxInFlightFrames buffered; drop oldest incomplete frame if full
            if frames.count >= Self.maxInFlightFrames {
                if let oldestId = frames.keys.min(by: { Self.isFrameNewer($1, than: $0) }) {
                    if Self.isFrameNewer(frameId, than: oldestId) {
                        frames.removeValue(forKey: oldestId)
                        onFrameDropped?()
                    } else {
                        return
                    }
                }
            }
            frames[frameId] = FrameBuffer(
                frameId: frameId,
                ptsMs: ptsMs,
                isKeyframe: isKeyframe,
                isHEVC: isHEVC,
                fragCount: fragCount,
                fecGroupSize: fecGroupSize,
                createdAtMs: nowMs
            )
        }

        guard var fb = frames[frameId] else { return }
        guard fb.fragCount == fragCount else { return }

        let payload = Data(bytes: &recvScratch[Self.videoHeaderSize], count: payloadLen)

        if isParity {
            fb.parityPackets[fragIndex] = payload
        } else {
            guard fragIndex < fb.fragCount else { return }
            if fb.fragments[fragIndex] == nil {
                fb.fragments[fragIndex] = payload
                fb.receivedCount += 1
            }
        }

        // Attempt 0ms XOR-FEC recovery if not yet complete
        if fb.receivedCount < fb.fragCount && fb.fecGroupSize > 0 && !fb.parityPackets.isEmpty {
            Self.attemptFecRecovery(&fb)
        }

        if fb.receivedCount == fb.fragCount {
            // Assemble complete frame
            var totalLen = 0
            for frag in fb.fragments {
                totalLen += frag?.count ?? 0
            }
            var assembled = Data(capacity: totalLen)
            for frag in fb.fragments {
                if let frag {
                    assembled.append(frag)
                }
            }

            // Drop any older incomplete frames
            var droppedOlder = false
            for existingId in Array(frames.keys) where existingId != frameId {
                if Self.isFrameNewer(frameId, than: existingId) {
                    frames.removeValue(forKey: existingId)
                    droppedOlder = true
                }
            }
            frames.removeValue(forKey: frameId)
            lastDeliveredFrameId = frameId

            if droppedOlder {
                onFrameDropped?()
            }

            let codec: VideoCodec = fb.isHEVC ? .h265 : .h264
            let packet = VideoFramePacket(
                data: assembled,
                frameId: fb.frameId,
                ptsMs: fb.ptsMs,
                isKeyframe: fb.isKeyframe,
                codec: codec
            )
            onFrame?(packet)
        } else {
            frames[frameId] = fb
        }
    }

    private static func attemptFecRecovery(_ fb: inout FrameBuffer) {
        let groupSize = fb.fecGroupSize
        guard groupSize > 0 else { return }

        for (groupIdx, parityBody) in fb.parityPackets {
            let start = groupIdx * groupSize
            let end = min(start + groupSize, fb.fragCount)
            guard end - start >= 2, parityBody.count >= 2 else { continue }

            var missingIdx: Int?
            var missingCount = 0
            for i in start..<end {
                if fb.fragments[i] == nil {
                    missingIdx = i
                    missingCount += 1
                    if missingCount > 1 { break }
                }
            }

            guard missingCount == 1, let targetIdx = missingIdx else { continue }

            // Parity body: [2-byte BE XOR of payloadLen] + [XOR of zero-padded payloads]
            var recoveredLen: UInt16 = (UInt16(parityBody[0]) << 8) | UInt16(parityBody[1])
            for i in start..<end where i != targetIdx {
                if let frag = fb.fragments[i] {
                    recoveredLen ^= UInt16(frag.count)
                }
            }

            let parityPayloadLen = parityBody.count - 2
            let targetLen = Int(recoveredLen)
            guard targetLen >= 0 && targetLen <= parityPayloadLen else { continue }

            var recovered = [UInt8](repeating: 0, count: targetLen)
            if targetLen > 0 {
                parityBody.copyBytes(to: &recovered, from: 2..<(2 + targetLen))
                for i in start..<end where i != targetIdx {
                    if let frag = fb.fragments[i] {
                        let n = min(frag.count, targetLen)
                        frag.withUnsafeBytes { raw in
                            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                            for b in 0..<n {
                                recovered[b] ^= base[b]
                            }
                        }
                    }
                }
            }

            fb.fragments[targetIdx] = Data(recovered)
            fb.receivedCount += 1
        }
    }

    private func evictTimedOutFramesLocked() {
        guard !frames.isEmpty else { return }
        let now = Self.monotonicMs()
        var droppedAny = false
        for (id, fb) in frames {
            if now >= fb.createdAtMs && (now - fb.createdAtMs) > Self.frameTimeoutMs {
                frames.removeValue(forKey: id)
                droppedAny = true
            }
        }
        if droppedAny {
            onFrameDropped?()
        }
    }

    private static func isFrameNewer(_ a: UInt32, than b: UInt32) -> Bool {
        Int32(bitPattern: a &- b) > 0
    }

    private static func monotonicMs() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds / 1_000_000
    }
}
