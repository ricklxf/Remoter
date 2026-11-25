import Foundation
import CryptoKit
import CoreGraphics
import Darwin

/// Built-in zero-dependency regression test suite (`swift run RemoterAgent --self-test`).
/// Covers:
///   1. UDP WAN/LAN pacing burst invariants & weak-network bitrate state machine simulations
///   2. Live loopback UDP handshake, AES-256-GCM video encryption, and NACK retransmission
///   3. Encrypted UDP 0x20 input channel latency (< 5ms avg), 2x/out-of-order dedup, and auth
///   4. Keyboard shortcuts (Keybot Ctrl->Cmd defaults, Chromium/Electron auto-detection,
///      phantom modifier stripping, Web keycode mapping, virtual CapsLock)
enum RegressionTestRunner {
    private struct Failure: Error {
        let message: String
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }

    static func runAll() -> Int32 {
        let tests: [(String, () throws -> Void)] = [
            ("UDP/WAN Pacer Caps Keyframe Burst (<=16Mbps, <=6 pkts/ms)", testWanPacerCapsKeyframeBurst),
            ("UDP/LAN Pacer Drains Large Frames Fast (>=24Mbps)", testLanPacerDrainsLargeFrames),
            ("Bitrate/Idle Session Recovers From Floor (No Blurry Scroll)", testIdleSessionRecoversFromFloor),
            ("Bitrate/WAN 2K Congestion Steps Down & Recovers To 8Mbps", testWan2KCongestionAndRecovery),
            ("Bitrate/Mild 3% Loss Absorbed Without Slashing Bitrate", testMildLossDoesNotSlashBitrate),
            ("Bitrate/Severe >=15% Loss Steps 60->30fps & Restores Cleanly", testSevereLossFpsSurvivalMode),
            ("AntiFreeze/VideoToolbox Burst Headroom Prevents Low-Bitrate Frame Drops", testVideoToolboxNoLowBitrateFrameDrop),
            ("AntiFreeze/UU Sustained-Overuse Suppresses Delta FEC & Caps NACKs", testUuSustainedOveruseFecAndNackLimit),
            ("AntiFreeze/Low-Bitrate Keyframe Drain & Heavy-Loss Throttle", testLowBitrateKeyframeDrainAndThrottle),
            ("AntiFreeze/No 4s Sawtooth Oscillation After Loss At 2.5Mbps", testNoSawtoothOscillationAfterLoss),
            ("AntiFreeze/Input Stays <5ms During Active Low-Bitrate Video Pacing", testInputLatencyDuringActiveVideoPacing),
            ("UDP/Loopback Handshake + AES-GCM Video + NACK Retransmit", testUdpHandshakeVideoAndNackLoopback),
            ("Input/UDP 0x20 Latency (<5ms), 2x Dedup & GCM Auth", testUdpInputLatencyDedupAndAuth),
            ("Shortcut/Default Keybot Ctrl->Cmd Rules (C/V/X/A/Z/S/W/T/F/R)", testDefaultCtrlToCmdShortcuts),
            ("Shortcut/Chromium & Electron Auto-Detection (Claude/Chrome/Edge/VSCode)", testChromiumElectronDetection),
            ("Shortcut/Strip Phantom Modifiers Prevents Stuck Cmd Key", testStripPhantomModifiers),
            ("Shortcut/Web KeyCode & Virtual CapsLock Flag Mapping", testWebKeyCodeAndModifierFlags),
        ]

        var passed = 0
        var failed = 0
        let t0 = CFAbsoluteTimeGetCurrent()
        print("▶ Running RemoterAgent regression self-test (\(tests.count) tests)…")

        for (name, body) in tests {
            let start = CFAbsoluteTimeGetCurrent()
            do {
                try body()
                let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
                print(String(format: "  ✅ PASS [%.1fms] %@", ms, name))
                passed += 1
            } catch let f as Failure {
                print("  ❌ FAIL \(name): \(f.message)")
                failed += 1
            } catch {
                print("  ❌ FAIL \(name): \(error)")
                failed += 1
            }
        }

        UdpVideoServer.shared.stop()
        let totalMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
        print(String(format: "▶ Self-test complete: %d passed, %d failed (%.1fms)", passed, failed, totalMs))
        return failed == 0 ? 0 : 1
    }

    // MARK: - 1. Pacing & WAN Burst Safety Invariants

    private static func testWanPacerCapsKeyframeBurst() throws {
        let (paceRateBps, maxPerTick) = UdpVideoServer.computePacingParameters(
            pacingBitrateBps: 6_000_000,
            pendingPackets: 180,
            allowFecSuppression: false
        )
        try expect(paceRateBps <= 10_000_000.0, "WAN pacer exceeded 10 Mbps: \(paceRateBps)")
        try expect(paceRateBps >= 8_000_000.0, "WAN pacer below 8 Mbps at 6M target: \(paceRateBps)")
        try expect(maxPerTick <= 3, "WAN pacer maxPacketsPerTick > 3: \(maxPerTick)")

        let (lowPaceBps, _) = UdpVideoServer.computePacingParameters(
            pacingBitrateBps: 1_800_000,
            pendingPackets: 40,
            allowFecSuppression: false
        )
        try expect(lowPaceBps == 2_500_000.0, "Low-bitrate WAN pacer should stay at 2.5 Mbps below 3.4M cliff, got \(lowPaceBps)")

        let drainTimeMs = (180.0 * 1236.0 * 8.0 / paceRateBps) * 1000.0
        try expect(drainTimeMs < 250.0, "180-packet keyframe drainTimeMs=\(drainTimeMs) too close to 350ms timeout")
        try expect(UdpVideoServer.keepaliveTimeoutSeconds >= 12.0,
                   "UDP keepaliveTimeoutSeconds must be >= 12s to survive brief WAN blips without ws_fallback")
    }

    private static func testLanPacerDrainsLargeFrames() throws {
        let (paceRateBps, maxPerTick) = UdpVideoServer.computePacingParameters(
            pacingBitrateBps: 12_000_000,
            pendingPackets: 180,
            allowFecSuppression: true
        )
        try expect(paceRateBps >= 24_000_000.0, "LAN pacer too slow: \(paceRateBps)")
        try expect(maxPerTick == 24, "LAN pacer maxPacketsPerTick expected 24, got \(maxPerTick)")
    }

    // MARK: - 2. Weak-Network Bitrate State Machine Simulations

    private static func testIdleSessionRecoversFromFloor() throws {
        var state = Session.UdpBitrateState(currentBitrate: 6_000_000)
        var t = 100.0
        for _ in 0..<4 {
            t += 2.0
            let action = state.step(
                lossRatio: 0.10, sentPackets: 200, now: t,
                clientNotOnLan: true, screenWidth: 1920, scrollBoostActive: false
            )
            if case .down = action {} else {
                throw Failure(message: "Expected .down on 10% loss, got \(action)")
            }
        }
        try expect(state.currentBitrate >= 1_200_000, "1080p WAN floor dropped below 1.2 Mbps: \(state.currentBitrate)")

        // Simulate 20s of idle (12 pkts/2s): must rapidly recover to >= 1.8 Mbps (not blurry),
        // and MUST NOT hallucinate higher ceilings (e.g. 5-8 Mbps) while idle!
        for _ in 0..<10 {
            t += 2.0
            _ = state.step(
                lossRatio: 0.012, sentPackets: 12, now: t,
                clientNotOnLan: true, screenWidth: 1920, scrollBoostActive: false
            )
        }
        try expect(state.currentBitrate >= 1_800_000 && state.currentBitrate <= 2_500_000,
                   "Idle session expected safe 1.8-2.5 Mbps baseline without overshoot, got \(state.currentBitrate)")
    }

    private static func testWan2KCongestionAndRecovery() throws {
        var state = Session.UdpBitrateState(currentBitrate: 8_000_000)
        var t = 0.0
        for _ in 0..<10 {
            t += 2.0
            _ = state.step(
                lossRatio: 0.08, sentPackets: 180, now: t,
                clientNotOnLan: true, screenWidth: 2560, scrollBoostActive: true
            )
        }
        try expect(state.currentBitrate == 1_500_000, "2K WAN floor expected 1.5 Mbps, got \(state.currentBitrate)")

        // Active clean traffic (>=320 pkts/2s) must climb smoothly back to 8 Mbps
        for _ in 0..<60 {
            t += 2.0
            _ = state.step(
                lossRatio: 0.0, sentPackets: 400, now: t,
                clientNotOnLan: true, screenWidth: 2560, scrollBoostActive: false
            )
        }
        try expect(state.currentBitrate == 8_000_000, "WAN session failed rapid recovery to 8 Mbps within 40s: \(state.currentBitrate)")
        try expect(state.learnedCeilingBps == nil, "Learned ceiling should clear at hard ceiling")
    }

    private static func testMildLossDoesNotSlashBitrate() throws {
        var state = Session.UdpBitrateState(currentBitrate: 6_000_000)
        let action = state.step(
            lossRatio: 0.03, sentPackets: 150, now: 10.0,
            clientNotOnLan: true, screenWidth: 2560, scrollBoostActive: false
        )
        try expect(action == .hold && state.currentBitrate == 6_000_000,
                   "3% loss should be held without slashing bitrate")
    }

    private static func testSevereLossFpsSurvivalMode() throws {
        var guardState = Session.UdpSevereFpsGuard()
        var fps = 60

        // 1st window of 12% loss should NOT prematurely slash 60fps
        try expect(guardState.step(lossRatio: 0.12, sentPackets: 200, currentFps: fps, manualFpsSelected: false) == nil,
                   "1st 12% window must not drop FPS yet")
        // 2nd consecutive >=10% window (4s) MUST step down to 30fps
        let downFps = guardState.step(lossRatio: 0.14, sentPackets: 200, currentFps: fps, manualFpsSelected: false)
        try expect(downFps == 30, "2nd consecutive >=10% loss window must step FPS down to 30, got \(String(describing: downFps))")
        fps = downFps ?? fps

        // 2 clean windows (<2.5% loss, 4s) MUST rapidly restore original 60fps
        try expect(guardState.step(lossRatio: 0.005, sentPackets: 120, currentFps: fps, manualFpsSelected: false) == nil, "1st clean window")
        let upFps = guardState.step(lossRatio: 0.01, sentPackets: 120, currentFps: fps, manualFpsSelected: false)
        try expect(upFps == 60, "2nd clean window must restore 60fps, got \(String(describing: upFps))")
        fps = upFps ?? fps

        // Catastrophic >=20% loss MUST drop to 30fps on the VERY FIRST window
        let instantDown = guardState.step(lossRatio: 0.35, sentPackets: 120, currentFps: fps, manualFpsSelected: false)
        try expect(instantDown == 30, "Catastrophic >=20% loss must drop to 30fps immediately, got \(String(describing: instantDown))")
    }

    // MARK: - 2B. Anti-Freeze Invariants ("Blurry MUST NEVER Freeze")

    private static func testVideoToolboxNoLowBitrateFrameDrop() throws {
        // When bitrate adapts down (blurry mode), DataRateLimits burst budget MUST stay >= 260 KB/s
        // (enough to avoid VideoToolbox frame drops after keyframes) AND <= 350 KB/s at 1.5-2.0M
        // so scrolling doesn't burst to 3.8 Mbps and trigger WAN bufferbloat!
        for bps in [1_200_000, 1_500_000, 2_000_000] {
            let burstBytes = VideoEncoder.computeBurstByteLimit(bitrateBps: bps)
            try expect(burstBytes >= 260_000 && burstBytes <= 350_000,
                       "At \(bps) bps, VideoToolbox burstByteLimit=\(burstBytes) out of safe 260-350KB/s window!")
        }
        // At high bitrate (8 Mbps), burst headroom scales proportionally (1.35x = 1.35 MB/s)
        let highBurst = VideoEncoder.computeBurstByteLimit(bitrateBps: 8_000_000)
        try expect(highBurst >= 1_300_000, "At 8 Mbps, expected >= 1.3MB/s burst headroom, got \(highBurst)")
    }

    private static func testUuSustainedOveruseFecAndNackLimit() throws {
        // 1st heavy window (transient 18% loss): deltaG=3, keyG=2 (+50% keyframe protection)
        let transient = UdpVideoServer.computeFecPolicy(
            lossRatio: 0.18, sustainedOveruseWindows: 1,
            allowFecSuppression: false, hasEverSeenNack: true, cleanWindows: 0
        )
        try expect(transient.deltaFec == 3 && transient.keyFec == 2 && !transient.suppressedByOveruse,
                   "Transient heavy loss should protect keyframes (keyG=2), got \(transient)")

        // 2nd+ consecutive >=15% window (UU sustained_overuse): MUST suppress delta FEC (deltaG=0)
        // so +33% parity stops amplifying tunnel congestion while keeping keyframe FEC (keyG=3).
        let overuse = UdpVideoServer.computeFecPolicy(
            lossRatio: 0.25, sustainedOveruseWindows: 2,
            allowFecSuppression: false, hasEverSeenNack: true, cleanWindows: 0
        )
        try expect(overuse.deltaFec == 0 && overuse.keyFec == 3 && overuse.suppressedByOveruse,
                   "Sustained overuse must suppress delta FEC (deltaG=0) to prevent congestion amplification, got \(overuse)")

        // Once link clears (<5% loss, sustainedOveruseWindows reset to 0), normal light FEC restores
        let recovered = UdpVideoServer.computeFecPolicy(
            lossRatio: 0.01, sustainedOveruseWindows: 0,
            allowFecSuppression: false, hasEverSeenNack: true, cleanWindows: 1
        )
        try expect(recovered.deltaFec == 8 && recovered.keyFec == 4 && !recovered.suppressedByOveruse,
                   "Safe headroom should restore normal light FEC, got \(recovered)")

        // UU RetransmissionRateLimit: NACK budget never starves live video (capped at max(24, sent/3))
        try expect(UdpVideoServer.computeWindowNackBudget(recentSentPackets: 60) == 24,
                   "Low-rate NACK budget floor expected 24")
        try expect(UdpVideoServer.computeWindowNackBudget(recentSentPackets: 300) == 100,
                   "Active NACK budget expected 100 (33% of 300)")
    }

    private static func testLowBitrateKeyframeDrainAndThrottle() throws {
        // At blurry floor (1.2M / 1.5M), a 45-packet (~55KB) low-bitrate keyframe MUST drain in < 200ms
        // (well inside client's 350ms keyframe timeout) while pacing <= 2.5 Mbps to stay below WAN cliff!
        for floorBps in [1_200_000, 1_500_000] {
            let (paceRateBps, maxPerTick) = UdpVideoServer.computePacingParameters(
                pacingBitrateBps: floorBps,
                pendingPackets: 45,
                allowFecSuppression: false
            )
            let drainMs = (45.0 * 1236.0 * 8.0 / paceRateBps) * 1000.0
            try expect(drainMs < 200.0, "Low-bitrate (\(floorBps)) 45-pkt keyframe drainMs=\(drainMs) risks 350ms client timeout!")
            try expect(paceRateBps <= 2_500_000.0 && maxPerTick <= 3,
                       "Low-bitrate WAN pacer should stay gentle (<=2.5Mbps, <=3 pkts/ms), got \(paceRateBps)/\(maxPerTick)")
        }

        // Heavy-loss keyframe throttle MUST be >= 1.5s to prevent 6-keyframes-in-5s storm
        try expect(Session.computeKeyframeCooldown(usingUdpVideo: true, lossRatio: 0.25) >= 1.5,
                   "Heavy-loss keyframe cooldown must be >= 1.5s")
        try expect(Session.computeKeyframeCooldown(usingUdpVideo: true, lossRatio: 0.0) <= 0.4,
                   "Clean-link keyframe cooldown should remain fast (<= 0.4s)")
    }

    private static func testNoSawtoothOscillationAfterLoss() throws {
        // Reproduces mac2 13:48:36-13:48:52 sawtooth: 6.4% loss at 2.5M backs off to 1.875M/cap=2.0M.
        // Over the next 10s of clean active traffic, it should hold steady at 2.0M instead of
        // slamming straight back into 2.5M after 4s and causing repeated kfReq=3 scroll freezes!
        var state = Session.UdpBitrateState(currentBitrate: 2_500_000)
        var t = 100.0
        _ = state.step(lossRatio: 0.064, sentPackets: 251, now: t, clientNotOnLan: true, screenWidth: 2560, scrollBoostActive: false)
        try expect(state.currentBitrate == 1_875_000 && state.learnedCeilingBps == 2_000_000,
                   "Expected backoff to 1.875M/cap=2.0M, got \(state.currentBitrate)/\(String(describing: state.learnedCeilingBps))")

        for _ in 0..<5 { // +10 seconds
            t += 2.0
            _ = state.step(lossRatio: 0.0, sentPackets: 450, now: t, clientNotOnLan: true, screenWidth: 2560, scrollBoostActive: false)
        }
        try expect(state.currentBitrate == 2_000_000,
                   "Bitrate sawtoothed past learned 2.0M ceiling within 10s: \(state.currentBitrate)")

        // After >= 12s cooldown + 3 clean windows, it should gently probe up (+12% -> 2.24M)
        for _ in 0..<4 {
            t += 2.0
            _ = state.step(lossRatio: 0.0, sentPackets: 450, now: t, clientNotOnLan: true, screenWidth: 2560, scrollBoostActive: false)
        }
        try expect(state.currentBitrate == 2_240_000,
                   "Expected gentle +12% probe to 2.24M after cooldown, got \(state.currentBitrate)")
    }

    private static func testInputLatencyDuringActiveVideoPacing() throws {
        // Even while a large 96KB keyframe is actively being paced at 1.5 Mbps (blurry mode),
        // encrypted UDP 0x20 input MUST bypass the pacer and arrive in < 5ms!
        let server = UdpVideoServer.shared
        try expect(server.start(preferredPort: 0), "Failed to bind UDP port")
        let port = server.listeningPort

        let token = Data((0..<16).map { UInt8($0 + 70) })
        let aesKey = Data((0..<32).map { UInt8($0 + 80) })
        let symKey = SymmetricKey(data: aesKey)
        let activatedSem = DispatchSemaphore(value: 0)
        let inputSem = DispatchSemaphore(value: 0)
        var receivedAt: CFAbsoluteTime = 0

        server.registerSession(
            token: token, aesKey: aesKey, allowFecSuppression: false,
            onActivated: { active in if active { activatedSem.signal() } },
            onInputMessage: { _ in
                receivedAt = CFAbsoluteTimeGetCurrent()
                inputSem.signal()
            }
        )
        defer { server.unregisterSession(token: token) }
        server.updatePacingBitrate(token: token, bitrateBps: 1_500_000)

        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        try expect(fd >= 0, "Failed to open UDP socket")
        defer { close(fd) }

        var dest = sockaddr_in()
        dest.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = port.bigEndian
        inet_pton(AF_INET, "127.0.0.1", &dest.sin_addr)

        func sendBytes(_ bytes: [UInt8]) {
            _ = withUnsafePointer(to: &dest) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(fd, bytes, bytes.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        var hello = [UInt8](repeating: 0, count: 21)
        hello[0] = UdpVideoServer.magic0; hello[1] = UdpVideoServer.magic1
        hello[2] = UdpVideoServer.version; hello[3] = UdpVideoServer.packetHello
        token.copyBytes(to: &hello[4], count: 16); hello[20] = 0x01
        sendBytes(hello)
        try expect(activatedSem.wait(timeout: .now() + 2.0) == .success, "UDP session did not activate")

        // Enqueue a large 96KB keyframe into the 1.5 Mbps WAN pacer (occupies pacer for ~150ms)
        let bigKeyframe = Data(repeating: 0xAB, count: 96 * 1024)
        try expect(server.sendVideoFrame(token: token, frameId: 99, ptsMs: 1000, data: bigKeyframe, isKeyframe: true, isHEVC: true),
                   "Failed to enqueue keyframe into pacer")

        // Immediately send encrypted UDP 0x20 input while pacer is actively draining video
        let pkt = try buildEncryptedInputPacket(
            token: token, seq: 1, json: "{\"type\":\"mousemove\",\"x\":0.5,\"y\":0.5}", key: symKey
        )

        let sentAt = CFAbsoluteTimeGetCurrent()
        sendBytes(pkt)
        try expect(inputSem.wait(timeout: .now() + 0.5) == .success, "Input packet stalled during active video pacing!")
        let latencyMs = (receivedAt - sentAt) * 1000.0
        try expect(latencyMs < 5.0, "Input latency under low-bitrate video pacing too high: \(latencyMs)ms")
    }

    // MARK: - 3. Live Loopback UDP Video + AES-GCM + NACK Retransmit

    private static func testUdpHandshakeVideoAndNackLoopback() throws {
        let server = UdpVideoServer.shared
        try expect(server.start(preferredPort: 0), "Failed to bind ephemeral UDP port")
        let port = server.listeningPort
        try expect(port > 0, "Listening port must be > 0")

        let token = Data((0..<16).map { UInt8($0 + 1) })
        let aesKey = Data((0..<32).map { UInt8($0 + 10) })
        let symKey = SymmetricKey(data: aesKey)
        let activatedSem = DispatchSemaphore(value: 0)

        server.registerSession(
            token: token, aesKey: aesKey, allowFecSuppression: false,
            onActivated: { active in if active { activatedSem.signal() } }
        )
        defer { server.unregisterSession(token: token) }

        let clientFd = socket(AF_INET, SOCK_DGRAM, 0)
        try expect(clientFd >= 0, "Failed to open client UDP socket")
        defer { close(clientFd) }

        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(clientFd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var dest = sockaddr_in()
        dest.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = port.bigEndian
        inet_pton(AF_INET, "127.0.0.1", &dest.sin_addr)

        func sendBytes(_ bytes: [UInt8]) {
            _ = withUnsafePointer(to: &dest) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(clientFd, bytes, bytes.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        var hello = [UInt8](repeating: 0, count: 21)
        hello[0] = UdpVideoServer.magic0; hello[1] = UdpVideoServer.magic1
        hello[2] = UdpVideoServer.version; hello[3] = UdpVideoServer.packetHello
        token.copyBytes(to: &hello[4], count: 16); hello[20] = 0x01
        sendBytes(hello)

        var ackBuf = [UInt8](repeating: 0, count: 64)
        let ackLen = recv(clientFd, &ackBuf, ackBuf.count, 0)
        try expect(ackLen == 21 && ackBuf[3] == UdpVideoServer.packetHelloAck && ackBuf[20] == 0x01,
                   "Expected 21-byte HELLO_ACK with byte[20]==0x01, got len=\(ackLen)")
        try expect(activatedSem.wait(timeout: .now() + 2.0) == .success, "UDP session did not activate")

        let framePayload = Data((0..<3000).map { UInt8($0 & 0xFF) })
        try expect(server.sendVideoFrame(token: token, frameId: 42, ptsMs: 1234, data: framePayload, isKeyframe: false, isHEVC: true),
                   "sendVideoFrame returned false")

        var receivedFrags: [UInt8: Data] = [:]
        var recvBuf = [UInt8](repeating: 0, count: 2048)
        for _ in 0..<10 {
            let n = recv(clientFd, &recvBuf, recvBuf.count, 0)
            if n < UdpVideoServer.headerSize { break }
            if recvBuf[3] == UdpVideoServer.packetData {
                let fragIdx = recvBuf[13]
                let pLen = Int(UInt16(recvBuf[16]) << 8 | UInt16(recvBuf[17]))
                try expect((recvBuf[18] & 0x01) != 0, "Video packet was not AES-GCM encrypted")

                var nonceBytes = [UInt8](repeating: 0, count: 12)
                nonceBytes[0] = UdpVideoServer.magic0; nonceBytes[1] = UdpVideoServer.magic1
                nonceBytes[2] = recvBuf[3]; nonceBytes[3] = fragIdx
                for i in 0..<8 { nonceBytes[4 + i] = recvBuf[4 + i] }

                let box = try AES.GCM.SealedBox(
                    nonce: try AES.GCM.Nonce(data: nonceBytes),
                    ciphertext: Data(recvBuf[20..<(20 + pLen)]),
                    tag: Data(recvBuf[(20 + pLen)..<(20 + pLen + 16)])
                )
                receivedFrags[fragIdx] = try AES.GCM.open(box, using: symKey, authenticating: Data(recvBuf[0..<20]))
                if receivedFrags.count == 3 { break }
            }
        }
        try expect(receivedFrags.count == 3, "Expected 3 fragments, got \(receivedFrags.count)")
        let reassembled = (receivedFrags[0] ?? Data()) + (receivedFrags[1] ?? Data()) + (receivedFrags[2] ?? Data())
        try expect(reassembled == framePayload, "Reassembled decrypted payload mismatch")

        // NACK fragment 1 and verify immediate retransmission
        var nack = [UInt8](repeating: 0, count: 26)
        nack[0] = UdpVideoServer.magic0; nack[1] = UdpVideoServer.magic1
        nack[2] = UdpVideoServer.version; nack[3] = UdpVideoServer.packetNack
        token.copyBytes(to: &nack[4], count: 16)
        nack[23] = 42; nack[24] = 1; nack[25] = 1
        sendBytes(nack)

        var gotRetransmit = false
        for _ in 0..<5 {
            let n = recv(clientFd, &recvBuf, recvBuf.count, 0)
            if n >= UdpVideoServer.headerSize && recvBuf[3] == UdpVideoServer.packetData && recvBuf[13] == 1 {
                gotRetransmit = true
                break
            }
        }
        try expect(gotRetransmit, "NACK for fragment 1 did not trigger retransmission")
    }

    // MARK: - 4. Encrypted UDP 0x20 Input Latency, 2x Dedup & Auth

    private static func buildEncryptedInputPacket(
        token: Data, seq: UInt32, json: String, key: SymmetricKey, tamperTag: Bool = false
    ) throws -> [UInt8] {
        let plaintext = Data(json.utf8)
        let hdrLen = 25
        var pkt = [UInt8](repeating: 0, count: hdrLen + plaintext.count + 16)
        pkt[0] = UdpVideoServer.magic0; pkt[1] = UdpVideoServer.magic1
        pkt[2] = UdpVideoServer.version; pkt[3] = UdpVideoServer.packetInput
        token.copyBytes(to: &pkt[4], count: 16)
        pkt[20] = UInt8((seq >> 24) & 0xFF); pkt[21] = UInt8((seq >> 16) & 0xFF)
        pkt[22] = UInt8((seq >> 8) & 0xFF);  pkt[23] = UInt8(seq & 0xFF)
        pkt[24] = 0x01

        var nonceBytes = [UInt8](repeating: 0, count: 12)
        nonceBytes[0] = UdpVideoServer.magic0; nonceBytes[1] = UdpVideoServer.magic1
        nonceBytes[2] = UdpVideoServer.packetInput; nonceBytes[3] = 0x00
        token.copyBytes(to: &nonceBytes[4], count: 4)
        for i in 0..<4 { nonceBytes[8 + i] = pkt[20 + i] }

        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: try AES.GCM.Nonce(data: nonceBytes), authenticating: Data(pkt[0..<hdrLen]))
        sealed.ciphertext.copyBytes(to: &pkt[hdrLen], count: sealed.ciphertext.count)
        sealed.tag.copyBytes(to: &pkt[hdrLen + sealed.ciphertext.count], count: 16)
        if tamperTag { pkt[pkt.count - 1] ^= 0xFF }
        return pkt
    }

    private static func testUdpInputLatencyDedupAndAuth() throws {
        let server = UdpVideoServer.shared
        try expect(server.start(preferredPort: 0), "Failed to bind UDP port")
        let port = server.listeningPort

        let token = Data((0..<16).map { UInt8($0 + 0x40) })
        let aesKey = Data((0..<32).map { UInt8($0 + 0x20) })
        let symKey = SymmetricKey(data: aesKey)

        let lock = NSLock()
        var received: [(String, CFAbsoluteTime)] = []
        let doneSem = DispatchSemaphore(value: 0)

        server.registerSession(
            token: token, aesKey: aesKey, allowFecSuppression: false,
            onActivated: { _ in },
            onInputMessage: { msg in
                let now = CFAbsoluteTimeGetCurrent()
                lock.lock()
                received.append((msg, now))
                let c = received.count
                lock.unlock()
                if c == 30 { doneSem.signal() }
            }
        )
        defer { server.unregisterSession(token: token) }

        let clientFd = socket(AF_INET, SOCK_DGRAM, 0)
        try expect(clientFd >= 0, "Failed to open client UDP socket")
        defer { close(clientFd) }

        var dest = sockaddr_in()
        dest.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = port.bigEndian
        inet_pton(AF_INET, "127.0.0.1", &dest.sin_addr)

        func sendBytes(_ bytes: [UInt8]) {
            _ = withUnsafePointer(to: &dest) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(clientFd, bytes, bytes.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        var hello = [UInt8](repeating: 0, count: 21)
        hello[0] = UdpVideoServer.magic0; hello[1] = UdpVideoServer.magic1
        hello[2] = UdpVideoServer.version; hello[3] = UdpVideoServer.packetHello
        token.copyBytes(to: &hello[4], count: 16); hello[20] = 0x01
        sendBytes(hello)
        usleep(20_000)

        // Tampered packet must be rejected
        sendBytes(try buildEncryptedInputPacket(token: token, seq: 9999, json: #"{"type":"key","code":"KeyX"}"#, key: symKey, tamperTag: true))

        var sendTimes: [UInt32: CFAbsoluteTime] = [:]
        for i: UInt32 in 1...30 {
            let json = #"{"type":"key","seq":\#(i),"code":"KeyC","down":true}"#
            let pkt = try buildEncryptedInputPacket(token: token, seq: i, json: json, key: symKey)
            sendTimes[i] = CFAbsoluteTimeGetCurrent()
            sendBytes(pkt)
            sendBytes(pkt) // 2x redundant duplicate
            if i > 2 {
                let oldJson = #"{"type":"key","seq":\#(i - 2),"code":"KeyC","down":true}"#
                sendBytes(try buildEncryptedInputPacket(token: token, seq: i - 2, json: oldJson, key: symKey))
            }
        }

        try expect(doneSem.wait(timeout: .now() + 2.0) == .success, "Timed out waiting for 30 UDP input messages")
        usleep(30_000)

        lock.lock()
        let snapshot = received
        lock.unlock()

        try expect(snapshot.count == 30, "Expected exactly 30 deduplicated deliveries, got \(snapshot.count)")
        var latenciesMs: [Double] = []
        for (msg, recvAt) in snapshot {
            try expect(!msg.contains("KeyX"), "Tampered packet was delivered!")
            if let data = msg.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let seq = obj["seq"] as? Int,
               let sentAt = sendTimes[UInt32(seq)] {
                latenciesMs.append((recvAt - sentAt) * 1000.0)
            }
        }
        let avgMs = latenciesMs.reduce(0, +) / Double(max(1, latenciesMs.count))
        let maxMs = latenciesMs.max() ?? 999
        try expect(avgMs < 5.0, "Avg UDP input latency too high: \(avgMs)ms")
        try expect(maxMs < 25.0, "Max UDP input latency too high: \(maxMs)ms")
    }

    // MARK: - 5. Keyboard Shortcuts & Keybot Tests

    private static func testDefaultCtrlToCmdShortcuts() throws {
        let mappings = KeybotConfigStore.defaultMappings()
        let expected: [(String, Int)] = [
            ("Ctrl+C", 8), ("Ctrl+V", 9), ("Ctrl+X", 7), ("Ctrl+Z", 6),
            ("Ctrl+A", 0), ("Ctrl+S", 1), ("Ctrl+F", 3), ("Ctrl+P", 35),
        ]
        for (name, kc) in expected {
            let match = mappings.first {
                $0.enabled &&
                $0.trigger.matches(keyCode: CGKeyCode(kc), flags: .maskControl) &&
                $0.condition.matches(bundleID: "com.google.Chrome")
            }
            try expect(match != nil, "Missing default Keybot mapping for \(name)")
            if case .remap(let targetKC, let targetMods) = match?.action {
                try expect(targetKC == kc && Set(targetMods) == Set([ModifierKey.command]),
                           "\(name) did not remap to Cmd+\(name.suffix(1))")
            } else {
                throw Failure(message: "\(name) action is not .remap")
            }
        }

        // Terminal Ctrl+C must require text selection so unselected Ctrl+C preserves SIGINT!
        let termCtrlC = mappings.first {
            $0.enabled &&
            $0.trigger.matches(keyCode: 8, flags: .maskControl) &&
            $0.condition.matches(bundleID: "com.apple.Terminal")
        }
        try expect(termCtrlC?.requireTextSelection == true,
                   "Terminal Ctrl+C must have requireTextSelection=true to preserve SIGINT")

        // F5 -> Cmd+R in Edge
        let edgeF5 = mappings.first {
            $0.enabled &&
            $0.trigger.matches(keyCode: 96, flags: []) &&
            $0.condition.matches(bundleID: "com.microsoft.edgemac")
        }
        if case .remap(let kc, let mods) = edgeF5?.action {
            try expect(kc == 15 && Set(mods) == Set([ModifierKey.command]), "Edge F5 must map to Cmd+R")
        } else {
            throw Failure(message: "Missing Edge F5 -> Cmd+R mapping")
        }
    }

    private static func testChromiumElectronDetection() throws {
        let fm = FileManager.default
        let tmpRoot = fm.temporaryDirectory.appendingPathComponent("remoter-selftest-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmpRoot) }

        let cases = [
            ("Claude.app", "Electron Framework.framework"),
            ("Google Chrome.app", "Google Chrome Framework.framework"),
            ("Microsoft Edge.app", "Microsoft Edge Framework.framework"),
            ("VSCode.app", "Electron Framework.framework"),
            ("CEFApp.app", "Chromium Embedded Framework.framework"),
        ]
        for (appName, fw) in cases {
            let appURL = tmpRoot.appendingPathComponent(appName)
            try fm.createDirectory(at: appURL.appendingPathComponent("Contents/Frameworks/\(fw)"), withIntermediateDirectories: true)
            try expect(KeybotEventTap.shared.isChromiumOrElectronBundle(at: appURL),
                       "\(appName) was not detected as Chromium/Electron")
        }

        let nativeApp = tmpRoot.appendingPathComponent("NativeApp.app")
        try fm.createDirectory(at: nativeApp.appendingPathComponent("Contents/Frameworks"), withIntermediateDirectories: true)
        try expect(!KeybotEventTap.shared.isChromiumOrElectronBundle(at: nativeApp),
                   "NativeApp was falsely detected as Chromium/Electron")
    }

    private static func testStripPhantomModifiers() throws {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 59, keyDown: false) else {
            throw Failure(message: "Failed to create CGEvent")
        }
        event.type = .flagsChanged
        event.flags = [.maskCommand]
        KeybotEventTap.shared.stripPhantomModifiers(event)
        try expect(!event.flags.contains(.maskCommand),
                   "Phantom Command flag on ControlLeft release was not stripped")
    }

    private static func testWebKeyCodeAndModifierFlags() throws {
        let essentialCodes = [
            "KeyA", "KeyC", "KeyV", "KeyX", "KeyZ", "KeyS", "KeyW", "KeyT", "KeyF", "KeyR",
            "Digit0", "Digit1", "Digit9", "Enter", "Tab", "Space", "Backspace", "Delete", "Escape",
            "ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown", "Home", "End", "PageUp", "PageDown",
            "F1", "F5", "F12", "ControlLeft", "ControlRight", "MetaLeft", "MetaRight",
            "AltLeft", "AltRight", "ShiftLeft", "ShiftRight",
        ]
        for code in essentialCodes {
            try expect(InputController.mapWebKeyCode(code) != nil, "Missing CGKeyCode for \(code)")
        }

        let ctrlDown = InputController.computeKeyFlags(code: "ControlLeft", modifiers: [], virtualCapsLockOn: false, down: true)
        try expect(ctrlDown.isModifierKey && ctrlDown.flags.contains(.maskControl), "ControlLeft down flag mismatch")

        let ctrlUp = InputController.computeKeyFlags(code: "ControlLeft", modifiers: ["ctrl"], virtualCapsLockOn: false, down: false)
        try expect(ctrlUp.isModifierKey && !ctrlUp.flags.contains(.maskControl), "ControlLeft up did not clear .maskControl")

        let capsLetter = InputController.computeKeyFlags(code: "KeyA", modifiers: [], virtualCapsLockOn: true, down: true)
        try expect(capsLetter.flags.contains(.maskShift), "Virtual CapsLock should shift KeyA")

        let capsShiftLetter = InputController.computeKeyFlags(code: "KeyA", modifiers: ["shift"], virtualCapsLockOn: true, down: true)
        try expect(!capsShiftLetter.flags.contains(.maskShift), "Virtual CapsLock + Shift should cancel on KeyA")

        let capsDigit = InputController.computeKeyFlags(code: "Digit1", modifiers: [], virtualCapsLockOn: true, down: true)
        try expect(!capsDigit.flags.contains(.maskShift), "Virtual CapsLock must not shift Digit1")
    }
}
