using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;

namespace RemoterWin;

/// <summary>
/// Built-in zero-dependency regression self-test suite (`RemoterWin.exe --self-test`).
/// Mirrors Remoter-MacServer/SelfTest/RegressionTestRunner.swift:
///   1. WAN/LAN UDP pacing burst safety invariants
///   2. Live loopback UDP handshake (21B HELLO_ACK), AES-256-GCM video, interleaved FEC,
///      per-fragment & count=0 whole-frame NACK retransmission
///   3. Encrypted UDP 0x20 input latency (<5ms avg), 2x/out-of-order 64-bit dedup, GCM auth
///   4. 0x13 delay-gradient GCC feedback parsing
///   5. Windows VK keycode & modifier mapping (including cmd/meta/ctrl/shift/alt)
/// </summary>
static class RegressionTestRunner
{
    private const byte Magic0 = 0x52;
    private const byte Magic1 = 0x55;
    private const byte ProtocolVersion = 0x01;
    private const byte PacketHello = 0x01;
    private const byte PacketHelloAck = 0x02;
    private const byte PacketData = 0x10;
    private const byte PacketNack = 0x12;
    private const byte PacketFeedback = 0x13;
    private const byte PacketInput = 0x20;

    private sealed class Failure(string message) : Exception(message);

    private static void Expect(bool condition, string message)
    {
        if (!condition) throw new Failure(message);
    }

    public static int RunAll()
    {
        var tests = new (string Name, Action Body)[]
        {
            ("UDP/WAN Pacer Caps Keyframe Burst (<=16Mbps, burst<=4)", TestWanPacerCapsKeyframeBurst),
            ("UDP/LAN Pacer Drains Large Frames Fast (>=24Mbps)", TestLanPacerDrainsLargeFrames),
            ("UDP/Loopback Handshake + AES-GCM Video + Fragment & Whole-Frame NACK", TestUdpHandshakeVideoAndNackLoopback),
            ("Input/UDP 0x20 Latency (<5ms), 2x Dedup & GCM Auth", TestUdpInputLatencyDedupAndAuth),
            ("GCC/UDP 0x13 Transport Feedback Parsing", TestUdpTransportFeedbackParsing),
            ("Shortcut/Web KeyCode & Modifier Mapping To Win32 VK", TestWebKeyCodeAndModifierMapping),
        };

        int passed = 0;
        int failed = 0;
        var totalSw = Stopwatch.StartNew();
        Console.WriteLine($"▶ Running RemoterWin regression self-test ({tests.Length} tests)...");

        foreach (var (name, body) in tests)
        {
            var sw = Stopwatch.StartNew();
            try
            {
                body();
                Console.WriteLine($"  ✅ PASS [{sw.Elapsed.TotalMilliseconds:F1}ms] {name}");
                passed++;
            }
            catch (Failure f)
            {
                Console.WriteLine($"  ❌ FAIL {name}: {f.Message}");
                failed++;
            }
            catch (Exception ex)
            {
                Console.WriteLine($"  ❌ FAIL {name}: {ex.Message}");
                failed++;
            }
        }

        UdpVideoServer.Shared.Stop();
        Console.WriteLine($"▶ Self-test complete: {passed} passed, {failed} failed ({totalSw.Elapsed.TotalMilliseconds:F1}ms)");
        return failed == 0 ? 0 : 1;
    }

    // ── 1. Pacing & WAN Burst Safety Invariants ─────────────────────────

    private static void TestWanPacerCapsKeyframeBurst()
    {
        var (paceRateBps, burstSize) = UdpVideoServer.ComputePacingParameters(6_000_000, 180, isLan: false);
        Expect(paceRateBps <= 16_000_000.0, $"WAN pacer exceeded 16 Mbps: {paceRateBps}");
        Expect(paceRateBps >= 10_000_000.0, $"WAN pacer below 10 Mbps: {paceRateBps}");
        Expect(burstSize <= 4, $"WAN burst size > 4: {burstSize}");

        double drainTimeMs = (180.0 * 1236.0 * 8.0 / paceRateBps) * 1000.0;
        Expect(drainTimeMs < 250.0, $"180-packet keyframe drainTimeMs={drainTimeMs:F1}ms too close to 350ms timeout");
    }

    private static void TestLanPacerDrainsLargeFrames()
    {
        var (paceRateBps, burstSize) = UdpVideoServer.ComputePacingParameters(12_000_000, 180, isLan: true);
        Expect(paceRateBps >= 24_000_000.0, $"LAN pacer too slow: {paceRateBps}");
        Expect(burstSize == 8, $"LAN burst size expected 8, got {burstSize}");
    }

    // ── 2. Live Loopback UDP Video + AES-GCM + Fragment & Whole-Frame NACK ──

    private static void TestUdpHandshakeVideoAndNackLoopback()
    {
        var server = UdpVideoServer.Shared;
        server.Start(0);
        int port = server.ListeningPort;
        Expect(port > 0, "UdpVideoServer failed to bind ephemeral port");

        byte[] token = new byte[16];
        byte[] aesKey = new byte[32];
        for (int i = 0; i < 16; i++) token[i] = (byte)(i + 1);
        for (int i = 0; i < 32; i++) aesKey[i] = (byte)(i + 10);

        using var activated = new ManualResetEventSlim(false);
        server.RegisterSession(token, aesKey, active => { if (active) activated.Set(); });
        try
        {
            using var client = new UdpClient();
            client.Client.ReceiveTimeout = 1500;
            var remote = new IPEndPoint(IPAddress.Loopback, port);

            // 21-byte HELLO advertising stride-interleaved XOR-FEC
            byte[] hello = new byte[21];
            hello[0] = Magic0; hello[1] = Magic1; hello[2] = ProtocolVersion; hello[3] = PacketHello;
            Buffer.BlockCopy(token, 0, hello, 4, 16);
            hello[20] = 0x01;
            client.Send(hello, hello.Length, remote);

            var anyEp = new IPEndPoint(IPAddress.Any, 0);
            byte[] ack = client.Receive(ref anyEp);
            Expect(ack.Length == 21 && ack[3] == PacketHelloAck && ack[20] == 0x01,
                $"Expected 21-byte HELLO_ACK with byte[20]==0x01, got len={ack.Length}");
            Expect(activated.Wait(2000), "UDP session did not activate");

            byte[] framePayload = new byte[3000];
            for (int i = 0; i < framePayload.Length; i++) framePayload[i] = (byte)(i & 0xFF);
            Expect(server.SendVideoFrame(token, frameId: 42, ptsMs: 1234, framePayload, isKeyframe: false, isHevc: true),
                "SendVideoFrame returned false");

            using var gcm = new AesGcm(aesKey, tagSizeInBytes: 16);
            var frags = new Dictionary<byte, byte[]>();
            Span<byte> nonce = stackalloc byte[12];
            for (int i = 0; i < 10 && frags.Count < 3; i++)
            {
                byte[] pkt = client.Receive(ref anyEp);
                if (pkt.Length < 20 || pkt[3] != PacketData) continue;
                byte fragIdx = pkt[13];
                int pLen = BinaryPrimitives.ReadUInt16BigEndian(pkt.AsSpan(16, 2));
                Expect((pkt[18] & 0x01) != 0, "Video packet was not AES-GCM encrypted");
                Expect((pkt[19] & 0x01) != 0, "Interleaved FEC flag not set on header[19]");

                nonce[0] = Magic0; nonce[1] = Magic1; nonce[2] = pkt[3]; nonce[3] = fragIdx;
                pkt.AsSpan(4, 8).CopyTo(nonce.Slice(4, 8));

                byte[] plain = new byte[pLen];
                gcm.Decrypt(nonce, pkt.AsSpan(20, pLen), pkt.AsSpan(20 + pLen, 16), plain, associatedData: pkt.AsSpan(0, 20));
                frags[fragIdx] = plain;
            }
            Expect(frags.Count == 3, $"Expected 3 decrypted fragments, got {frags.Count}");

            // Per-fragment NACK for frag 1
            byte[] nack = new byte[26];
            nack[0] = Magic0; nack[1] = Magic1; nack[2] = ProtocolVersion; nack[3] = PacketNack;
            Buffer.BlockCopy(token, 0, nack, 4, 16);
            BinaryPrimitives.WriteUInt32BigEndian(nack.AsSpan(20, 4), 42u);
            nack[24] = 1; nack[25] = 1;
            client.Send(nack, nack.Length, remote);

            bool gotFrag1 = false;
            for (int i = 0; i < 5; i++)
            {
                byte[] pkt = client.Receive(ref anyEp);
                if (pkt.Length >= 20 && pkt[3] == PacketData && pkt[13] == 1) { gotFrag1 = true; break; }
            }
            Expect(gotFrag1, "Per-fragment NACK did not retransmit fragment 1");

            // Whole-frame NACK (count=0) must retransmit all 3 fragments
            byte[] wfNack = new byte[25];
            wfNack[0] = Magic0; wfNack[1] = Magic1; wfNack[2] = ProtocolVersion; wfNack[3] = PacketNack;
            Buffer.BlockCopy(token, 0, wfNack, 4, 16);
            BinaryPrimitives.WriteUInt32BigEndian(wfNack.AsSpan(20, 4), 42u);
            wfNack[24] = 0;
            client.Send(wfNack, wfNack.Length, remote);

            var wfFrags = new HashSet<byte>();
            for (int i = 0; i < 6 && wfFrags.Count < 3; i++)
            {
                byte[] pkt = client.Receive(ref anyEp);
                if (pkt.Length >= 20 && pkt[3] == PacketData) wfFrags.Add(pkt[13]);
            }
            Expect(wfFrags.Count == 3, $"Whole-frame NACK (count=0) expected 3 fragments, got {wfFrags.Count}");
        }
        finally
        {
            server.UnregisterSession(token);
        }
    }

    // ── 3. Encrypted UDP 0x20 Input Latency, 2x Dedup & GCM Auth ────────

    private static byte[] BuildEncryptedInputPacket(byte[] token, uint seq, string json, AesGcm gcm, bool tamperTag = false)
    {
        byte[] plain = Encoding.UTF8.GetBytes(json);
        const int hdrLen = 25;
        byte[] pkt = new byte[hdrLen + plain.Length + 16];
        pkt[0] = Magic0; pkt[1] = Magic1; pkt[2] = ProtocolVersion; pkt[3] = PacketInput;
        Buffer.BlockCopy(token, 0, pkt, 4, 16);
        BinaryPrimitives.WriteUInt32BigEndian(pkt.AsSpan(20, 4), seq);
        pkt[24] = 0x01;

        Span<byte> nonce = stackalloc byte[12];
        nonce[0] = Magic0; nonce[1] = Magic1; nonce[2] = PacketInput; nonce[3] = 0x00;
        token.AsSpan(0, 4).CopyTo(nonce.Slice(4, 4));
        pkt.AsSpan(20, 4).CopyTo(nonce.Slice(8, 4));

        gcm.Encrypt(nonce, plain, pkt.AsSpan(hdrLen, plain.Length), pkt.AsSpan(hdrLen + plain.Length, 16), associatedData: pkt.AsSpan(0, hdrLen));
        if (tamperTag) pkt[^1] ^= 0xFF;
        return pkt;
    }

    private static void TestUdpInputLatencyDedupAndAuth()
    {
        var server = UdpVideoServer.Shared;
        server.Start(0);
        int port = server.ListeningPort;

        byte[] token = new byte[16];
        byte[] aesKey = new byte[32];
        for (int i = 0; i < 16; i++) token[i] = (byte)(i + 0x40);
        for (int i = 0; i < 32; i++) aesKey[i] = (byte)(i + 0x20);

        var listLock = new object();
        var received = new List<(string Json, long RecvTimestamp)>();
        using var done = new ManualResetEventSlim(false);

        server.RegisterSession(
            token, aesKey,
            onActivated: _ => { },
            onInputMessage: msg =>
            {
                long ts = Stopwatch.GetTimestamp();
                lock (listLock)
                {
                    received.Add((msg, ts));
                    if (received.Count == 30) done.Set();
                }
            });

        try
        {
            using var client = new UdpClient();
            var remote = new IPEndPoint(IPAddress.Loopback, port);
            using var gcm = new AesGcm(aesKey, tagSizeInBytes: 16);

            byte[] hello = new byte[21];
            hello[0] = Magic0; hello[1] = Magic1; hello[2] = ProtocolVersion; hello[3] = PacketHello;
            Buffer.BlockCopy(token, 0, hello, 4, 16); hello[20] = 0x01;
            client.Send(hello, hello.Length, remote);
            Thread.Sleep(25);

            // Tampered high-seq packet must be rejected AND must not poison _maxInputSeq!
            byte[] tampered = BuildEncryptedInputPacket(token, 9999, "{\"type\":\"key\",\"code\":\"KeyX\"}", gcm, tamperTag: true);
            client.Send(tampered, tampered.Length, remote);

            var sendTimes = new Dictionary<uint, long>();
            for (uint i = 1; i <= 30; i++)
            {
                string json = $"{{\"type\":\"key\",\"seq\":{i},\"code\":\"KeyC\",\"down\":true}}";
                byte[] pkt = BuildEncryptedInputPacket(token, i, json, gcm);
                sendTimes[i] = Stopwatch.GetTimestamp();
                client.Send(pkt, pkt.Length, remote);
                client.Send(pkt, pkt.Length, remote); // 2x redundant duplicate
                if (i > 2)
                {
                    string oldJson = $"{{\"type\":\"key\",\"seq\":{i - 2},\"code\":\"KeyC\",\"down\":true}}";
                    byte[] oldPkt = BuildEncryptedInputPacket(token, i - 2, oldJson, gcm);
                    client.Send(oldPkt, oldPkt.Length, remote);
                }
            }

            Expect(done.Wait(2000), "Timed out waiting for 30 deduplicated UDP input deliveries");
            Thread.Sleep(30);

            List<(string Json, long RecvTimestamp)> snapshot;
            lock (listLock) { snapshot = new List<(string, long)>(received); }

            Expect(snapshot.Count == 30, $"Expected exactly 30 deduplicated deliveries, got {snapshot.Count}");
            double totalMs = 0;
            double maxMs = 0;
            foreach (var (json, recvTs) in snapshot)
            {
                Expect(!json.Contains("KeyX"), "Tampered AES-GCM input packet was delivered!");
                using var doc = JsonDocument.Parse(json);
                uint seq = doc.RootElement.GetProperty("seq").GetUInt32();
                double ms = (recvTs - sendTimes[seq]) * 1000.0 / Stopwatch.Frequency;
                totalMs += ms;
                if (ms > maxMs) maxMs = ms;
            }
            double avgMs = totalMs / snapshot.Count;
            Expect(avgMs < 5.0, $"Average UDP input dispatch latency too high: {avgMs:F2}ms");
            Expect(maxMs < 25.0, $"Max UDP input dispatch latency too high: {maxMs:F2}ms");
        }
        finally
        {
            server.UnregisterSession(token);
        }
    }

    // ── 4. 0x13 Transport Feedback Parsing ──────────────────────────────

    private static void TestUdpTransportFeedbackParsing()
    {
        var server = UdpVideoServer.Shared;
        server.Start(0);
        int port = server.ListeningPort;

        byte[] token = new byte[16];
        for (int i = 0; i < 16; i++) token[i] = (byte)(i + 0x70);

        double gotGrad = 0, gotLoss = 0, gotJitter = 0;
        int gotBps = 0;
        using var got = new ManualResetEventSlim(false);

        server.RegisterSession(
            token, aesKey: null,
            onActivated: _ => { },
            onTransportFeedback: (grad, loss, jitter, bps) =>
            {
                gotGrad = grad; gotLoss = loss; gotJitter = jitter; gotBps = bps;
                got.Set();
            });

        try
        {
            using var client = new UdpClient();
            var remote = new IPEndPoint(IPAddress.Loopback, port);

            byte[] hello = new byte[21];
            hello[0] = Magic0; hello[1] = Magic1; hello[2] = ProtocolVersion; hello[3] = PacketHello;
            Buffer.BlockCopy(token, 0, hello, 4, 16); hello[20] = 0x01;
            client.Send(hello, hello.Length, remote);
            Thread.Sleep(25);

            byte[] fb = new byte[28];
            fb[0] = Magic0; fb[1] = Magic1; fb[2] = ProtocolVersion; fb[3] = PacketFeedback;
            Buffer.BlockCopy(token, 0, fb, 4, 16);
            BinaryPrimitives.WriteInt16BigEndian(fb.AsSpan(20, 2), 145);    // 14.5 ms
            BinaryPrimitives.WriteUInt16BigEndian(fb.AsSpan(22, 2), 35);    // 3.5%
            BinaryPrimitives.WriteUInt16BigEndian(fb.AsSpan(24, 2), 62);    // 6.2 ms
            BinaryPrimitives.WriteUInt16BigEndian(fb.AsSpan(26, 2), 4200);  // 4200 kbps
            client.Send(fb, fb.Length, remote);

            Expect(got.Wait(1500), "Timed out waiting for 0x13 feedback callback");
            Expect(Math.Abs(gotGrad - 14.5) < 0.01, $"Unexpected delayGradMs={gotGrad}");
            Expect(Math.Abs(gotLoss - 0.035) < 0.001, $"Unexpected lossRatio={gotLoss}");
            Expect(Math.Abs(gotJitter - 6.2) < 0.01, $"Unexpected jitterMs={gotJitter}");
            Expect(gotBps == 4_200_000, $"Unexpected recvBps={gotBps}");
        }
        finally
        {
            server.UnregisterSession(token);
        }
    }

    // ── 5. Windows VK KeyCode & Modifier Mapping ────────────────────────

    private static void TestWebKeyCodeAndModifierMapping()
    {
        string[] essentialCodes =
        [
            "KeyA", "KeyC", "KeyV", "KeyX", "KeyZ", "KeyS", "KeyW", "KeyT", "KeyF", "KeyR",
            "Digit0", "Digit1", "Digit9", "Enter", "Tab", "Space", "Backspace", "Delete", "Escape",
            "ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown", "Home", "End", "PageUp", "PageDown",
            "F1", "F5", "F12", "ControlLeft", "ControlRight", "MetaLeft", "MetaRight",
            "AltLeft", "AltRight", "ShiftLeft", "ShiftRight",
        ];
        foreach (string code in essentialCodes)
        {
            Expect(InputController.MapWebKeyCodeToVk(code) != 0, $"Missing Win32 VK mapping for {code}");
        }

        Expect(InputController.MapModifierToVk("ctrl") != 0, "Missing ctrl modifier VK");
        Expect(InputController.MapModifierToVk("shift") != 0, "Missing shift modifier VK");
        Expect(InputController.MapModifierToVk("alt") != 0, "Missing alt modifier VK");
        Expect(InputController.MapModifierToVk("meta") != 0, "Missing meta modifier VK");
        Expect(InputController.MapModifierToVk("cmd") != 0, "Missing cmd modifier VK");
    }
}
