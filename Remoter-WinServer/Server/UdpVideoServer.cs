using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Channels;
using System.Threading.Tasks;

namespace RemoterWin;

/// <summary>
/// Direct low-latency UDP video server with AES-256-GCM encryption, adaptive XOR-FEC,
/// 128-packet per-session NACK ring buffer, and micro-burst packet pacing.
/// Wire protocol matches Remoter-MacServer/Server/UdpVideoServer.swift bit-for-bit.
/// </summary>
sealed class UdpVideoServer : IDisposable
{
    public static readonly UdpVideoServer Shared = new();
    public const int TokenLength = 16;

    private const byte Magic0 = 0x52; // 'R'
    private const byte Magic1 = 0x55; // 'U'
    private const byte ProtocolVersion = 0x01;

    private const byte PacketHello     = 0x01;
    private const byte PacketHelloAck  = 0x02;
    private const byte PacketKeepalive = 0x03;
    private const byte PacketData      = 0x10;
    private const byte PacketFecParity = 0x11;
    private const byte PacketNack      = 0x12;

    private const byte HeaderFlagEncrypted = 0x01;

    private const int ControlPacketSize = 20;
    private const int VideoHeaderSize = 20;
    private const int GcmTagSize = 16;
    private const int MaxFragmentPayload = 1200;
    private const int MaxFragmentsPerFrame = 255;
    private const int NackRingSize = 128;
    private const int KeepaliveTimeoutMs = 6000;
    private const int MaintenanceIntervalMs = 2000;
    private const int FastPathMaxPackets = 4;
    private const int PacingBurstSize = 3;

    private enum FecLevel
    {
        Suppressed, // 0% overhead (clean LAN only)
        Light,      // deltaG=8, keyG=4
        Moderate,   // deltaG=4, keyG=2
        Heavy,      // deltaG=2, keyG=2
    }

    private readonly record struct PacedBatch(List<byte[]> Packets, bool IsKeyframe, IPEndPoint Peer);

    private sealed class UdpSessionState : IDisposable
    {
        public readonly byte[] Token;
        public readonly string TokenKey;
        public readonly Action<bool> OnActivated;
        public readonly Action<double, ulong>? OnLossFeedback;
        public AesGcm? AesGcm;

        public IPEndPoint? Peer;
        public bool Active;
        public long LastKeepaliveTick;
        public bool AllowFecSuppression = true;
        public FecLevel FecLevel = FecLevel.Light;
        public int CleanWindows;

        public ulong WindowSentPackets;
        public ulong WindowNackedPackets;

        // 128-packet NACK ring buffer
        public readonly (uint FrameId, byte FragIndex, byte[] Packet)?[] Ring = new (uint, byte, byte[])?[NackRingSize];
        public int RingHead;

        // Packet pacing state
        public readonly Channel<PacedBatch> PacingChannel = Channel.CreateUnbounded<PacedBatch>(
            new UnboundedChannelOptions { SingleReader = true, SingleWriter = false });
        public int QueuedPacedFrames;
        public CancellationTokenSource PacingCts = new();

        public UdpSessionState(byte[] token, string tokenKey, byte[]? aesKey, Action<bool> onActivated, Action<double, ulong>? onLossFeedback)
        {
            Token = token;
            TokenKey = tokenKey;
            OnActivated = onActivated;
            OnLossFeedback = onLossFeedback;
            if (aesKey != null && aesKey.Length == 32)
            {
                AesGcm = new AesGcm(aesKey, tagSizeInBytes: GcmTagSize);
            }
        }

        public void StoreInRing(uint frameId, byte fragIndex, byte[] wirePacket)
        {
            Ring[RingHead] = (frameId, fragIndex, wirePacket);
            RingHead = (RingHead + 1) % NackRingSize;
        }

        public byte[]? LookupInRing(uint frameId, byte fragIndex)
        {
            for (int i = 0; i < NackRingSize; i++)
            {
                var entry = Ring[i];
                if (entry.HasValue && entry.Value.FrameId == frameId && entry.Value.FragIndex == fragIndex)
                {
                    return entry.Value.Packet;
                }
            }
            return null;
        }

        public void Dispose()
        {
            PacingChannel.Writer.TryComplete();
            try { PacingCts.Cancel(); } catch { }
            try { PacingCts.Dispose(); } catch { }
            try { AesGcm?.Dispose(); } catch { }
            AesGcm = null;
        }
    }

    private readonly object _lock = new();
    private readonly Dictionary<string, UdpSessionState> _sessions = new(StringComparer.Ordinal);

    private UdpClient? _udp;
    private CancellationTokenSource? _cts;
    private bool _running;

    public int ListeningPort { get; private set; }

    private UdpVideoServer() { }

    public void Start(int preferredPort = 7789)
    {
        lock (_lock)
        {
            if (_running) return;

            UdpClient? udp = null;
            try
            {
                udp = new UdpClient(preferredPort);
            }
            catch (Exception ex)
            {
                AppLog.Write($"[UdpVideoServer] Port {preferredPort} busy ({ex.Message}), falling back to ephemeral port");
                try { udp = new UdpClient(0); }
                catch (Exception ex2)
                {
                    AppLog.Write($"[UdpVideoServer] Failed to bind UDP socket: {ex2.Message}");
                    return;
                }
            }

            try
            {
                udp.Client.SendBufferSize = 4 * 1024 * 1024;
                udp.Client.ReceiveBufferSize = 2 * 1024 * 1024;
            }
            catch { }

            ListeningPort = ((IPEndPoint)udp.Client.LocalEndPoint!).Port;
            _udp = udp;
            _cts = new CancellationTokenSource();
            _running = true;

            var ct = _cts.Token;
            _ = Task.Run(() => ReceiveLoopAsync(udp, ct), ct);
            _ = Task.Run(() => MaintenanceLoopAsync(ct), ct);

            AppLog.Write($"[UdpVideoServer] Listening on UDP port {ListeningPort}");
        }
    }

    public void Stop()
    {
        UdpClient? udp;
        CancellationTokenSource? cts;
        List<UdpSessionState> oldSessions;

        lock (_lock)
        {
            if (!_running) return;
            _running = false;
            ListeningPort = 0;
            udp = _udp;
            _udp = null;
            cts = _cts;
            _cts = null;
            oldSessions = new List<UdpSessionState>(_sessions.Values);
            _sessions.Clear();
        }

        try { cts?.Cancel(); } catch { }
        try { udp?.Close(); } catch { }
        try { udp?.Dispose(); } catch { }
        try { cts?.Dispose(); } catch { }

        foreach (var s in oldSessions)
        {
            s.Dispose();
        }
    }

    public void Dispose() => Stop();

    public void RegisterSession(
        byte[] token,
        byte[]? aesKey,
        Action<bool> onActivated,
        Action<double, ulong>? onLossFeedback = null)
    {
        if (token == null || token.Length != 16) return;
        string key = Convert.ToHexString(token);
        var state = new UdpSessionState((byte[])token.Clone(), key, aesKey, onActivated, onLossFeedback);

        UdpSessionState? replaced = null;
        lock (_lock)
        {
            if (_sessions.TryGetValue(key, out var existing))
            {
                replaced = existing;
            }
            _sessions[key] = state;
        }
        replaced?.Dispose();

        _ = Task.Run(() => PacingLoopAsync(state, state.PacingCts.Token));
    }

    public void UnregisterSession(byte[]? token)
    {
        if (token == null || token.Length != 16) return;
        string key = Convert.ToHexString(token);
        UdpSessionState? removed = null;
        lock (_lock)
        {
            if (_sessions.Remove(key, out var existing))
            {
                removed = existing;
            }
        }
        removed?.Dispose();
    }

    public void SetFecSuppressionAllowed(byte[]? token, bool allowed)
    {
        if (token == null || token.Length != 16) return;
        string key = Convert.ToHexString(token);
        lock (_lock)
        {
            if (_sessions.TryGetValue(key, out var state))
            {
                state.AllowFecSuppression = allowed;
                if (!allowed && state.FecLevel == FecLevel.Suppressed)
                {
                    state.FecLevel = FecLevel.Light;
                }
            }
        }
    }

    /// <summary>
    /// Fragments, seals (AES-256-GCM if active), adds adaptive XOR-FEC parity, stores in
    /// the 128-packet NACK ring, and sends (inline for <=4 packets, micro-burst paced for >4).
    /// Returns false if UDP is inactive or frame exceeds 255*1200 bytes (caller falls back to WS).
    /// </summary>
    public bool SendVideoFrame(
        byte[]? token,
        uint frameId,
        uint ptsMs,
        ReadOnlySpan<byte> data,
        bool isKeyframe,
        bool isHevc)
    {
        if (token == null || token.Length != 16 || data.IsEmpty) return false;
        if (data.Length > MaxFragmentsPerFrame * MaxFragmentPayload) return false;

        string key = Convert.ToHexString(token);
        UdpSessionState? state;
        UdpClient? udp;
        IPEndPoint? peer;
        int fecGroupSize;

        lock (_lock)
        {
            udp = _udp;
            if (!_running || udp == null) return false;
            if (!_sessions.TryGetValue(key, out state) || !state.Active || state.Peer == null)
                return false;

            peer = state.Peer;
            fecGroupSize = SelectFecGroupSize(state.FecLevel, isKeyframe);
        }

        int fragCount = (data.Length + MaxFragmentPayload - 1) / MaxFragmentPayload;
        if (fragCount <= 0 || fragCount > MaxFragmentsPerFrame) return false;
        if (fragCount == 1) fecGroupSize = 0;

        byte flags = (byte)((isKeyframe ? 0x01 : 0x00) | (isHevc ? 0x02 : 0x00));
        var wirePackets = new List<byte[]>(fragCount + (fecGroupSize > 0 ? (fragCount + fecGroupSize - 1) / fecGroupSize : 0));

        // 1. Build & seal data fragments
        lock (_lock)
        {
            if (!state.Active) return false;

            // Stale-queue guard for paced delta frames: never accumulate latency
            if (!isKeyframe && fragCount > FastPathMaxPackets && Volatile.Read(ref state.QueuedPacedFrames) >= 2)
            {
                return true; // Intentionally drop stale delta frame while keeping UDP active
            }

            for (int i = 0; i < fragCount; i++)
            {
                int offset = i * MaxFragmentPayload;
                int len = Math.Min(MaxFragmentPayload, data.Length - offset);
                byte[] pkt = BuildVideoPacket(
                    PacketData, frameId, ptsMs, flags,
                    (byte)i, (byte)fragCount, (byte)fecGroupSize,
                    data.Slice(offset, len), state.AesGcm);
                state.StoreInRing(frameId, (byte)i, pkt);
                wirePackets.Add(pkt);
            }

            // 2. Build & seal XOR-FEC parity packets
            if (fecGroupSize > 0)
            {
                int groupCount = (fragCount + fecGroupSize - 1) / fecGroupSize;
                for (int g = 0; g < groupCount; g++)
                {
                    int start = g * fecGroupSize;
                    int end = Math.Min(start + fecGroupSize, fragCount);
                    if (end - start < 2) continue;

                    int maxLen = 0;
                    for (int i = start; i < end; i++)
                    {
                        int offset = i * MaxFragmentPayload;
                        int len = Math.Min(MaxFragmentPayload, data.Length - offset);
                        if (len > maxLen) maxLen = len;
                    }

                    byte[] parityBody = new byte[2 + maxLen];
                    ushort xorLen = 0;
                    for (int i = start; i < end; i++)
                    {
                        int offset = i * MaxFragmentPayload;
                        int len = Math.Min(MaxFragmentPayload, data.Length - offset);
                        xorLen ^= (ushort)len;
                        var fragSpan = data.Slice(offset, len);
                        for (int b = 0; b < len; b++)
                        {
                            parityBody[2 + b] ^= fragSpan[b];
                        }
                    }
                    BinaryPrimitives.WriteUInt16BigEndian(parityBody.AsSpan(0, 2), xorLen);

                    byte[] parityPkt = BuildVideoPacket(
                        PacketFecParity, frameId, ptsMs, flags,
                        (byte)g, (byte)fragCount, (byte)fecGroupSize,
                        parityBody, state.AesGcm);
                    wirePackets.Add(parityPkt);
                }
            }

            state.WindowSentPackets += (ulong)fragCount;
        }

        // 3. Fast path (<= 4 packets): send immediately inline (0ms delay)
        if (wirePackets.Count <= FastPathMaxPackets)
        {
            foreach (var pkt in wirePackets)
            {
                try { udp.Send(pkt, pkt.Length, peer); }
                catch { }
            }
            return true;
        }

        // 4. Paced path (> 4 packets): enqueue micro-burst batch
        Interlocked.Increment(ref state.QueuedPacedFrames);
        if (!state.PacingChannel.Writer.TryWrite(new PacedBatch(wirePackets, isKeyframe, peer)))
        {
            Interlocked.Decrement(ref state.QueuedPacedFrames);
        }
        return true;
    }

    private static int SelectFecGroupSize(FecLevel level, bool isKeyframe) => level switch
    {
        FecLevel.Suppressed => 0,
        FecLevel.Light      => isKeyframe ? 4 : 8,
        FecLevel.Moderate   => isKeyframe ? 2 : 4,
        FecLevel.Heavy      => 2,
        _                   => isKeyframe ? 4 : 8,
    };

    private static byte[] BuildVideoPacket(
        byte pktType,
        uint frameId,
        uint ptsMs,
        byte flags,
        byte fragIndex,
        byte fragCount,
        byte fecGroupSize,
        ReadOnlySpan<byte> plaintext,
        AesGcm? aesGcm)
    {
        bool encrypted = aesGcm != null;
        int totalLen = VideoHeaderSize + plaintext.Length + (encrypted ? GcmTagSize : 0);
        byte[] pkt = new byte[totalLen];

        pkt[0] = Magic0;
        pkt[1] = Magic1;
        pkt[2] = ProtocolVersion;
        pkt[3] = pktType;
        BinaryPrimitives.WriteUInt32BigEndian(pkt.AsSpan(4, 4), frameId);
        BinaryPrimitives.WriteUInt32BigEndian(pkt.AsSpan(8, 4), ptsMs);
        pkt[12] = flags;
        pkt[13] = fragIndex;
        pkt[14] = fragCount;
        pkt[15] = fecGroupSize;
        BinaryPrimitives.WriteUInt16BigEndian(pkt.AsSpan(16, 2), (ushort)plaintext.Length);
        pkt[18] = encrypted ? HeaderFlagEncrypted : (byte)0x00;
        pkt[19] = 0x00;

        if (encrypted && aesGcm != null)
        {
            Span<byte> nonce = stackalloc byte[12];
            nonce[0] = Magic0;
            nonce[1] = Magic1;
            nonce[2] = pktType;
            nonce[3] = fragIndex;
            pkt.AsSpan(4, 8).CopyTo(nonce.Slice(4, 8)); // frameId(BE4) + ptsMs(BE4)

            ReadOnlySpan<byte> aad = pkt.AsSpan(0, VideoHeaderSize);
            Span<byte> ciphertext = pkt.AsSpan(VideoHeaderSize, plaintext.Length);
            Span<byte> tag = pkt.AsSpan(VideoHeaderSize + plaintext.Length, GcmTagSize);
            aesGcm.Encrypt(nonce, plaintext, ciphertext, tag, associatedData: aad);
        }
        else
        {
            plaintext.CopyTo(pkt.AsSpan(VideoHeaderSize));
        }

        return pkt;
    }

    // ── Background Loops ─────────────────────────────────────────────────

    private async Task PacingLoopAsync(UdpSessionState state, CancellationToken ct)
    {
        var reader = state.PacingChannel.Reader;
        try
        {
            while (await reader.WaitToReadAsync(ct).ConfigureAwait(false))
            {
                while (reader.TryRead(out var batch))
                {
                    int remaining = Interlocked.Decrement(ref state.QueuedPacedFrames);

                    // Drop stale delta batch if newer frames are already queued
                    if (!batch.IsKeyframe && remaining > 0)
                    {
                        continue;
                    }

                    UdpClient? udp;
                    lock (_lock) { udp = _udp; }
                    if (udp == null) continue;

                    int total = batch.Packets.Count;
                    int budgetUs = Math.Min(8_000, Math.Max(1_200, total * 75));
                    int burstCount = Math.Max(1, (total + PacingBurstSize - 1) / PacingBurstSize);
                    int stepUs = Math.Min(350, Math.Max(80, budgetUs / burstCount));
                    long stepTicks = stepUs * Stopwatch.Frequency / 1_000_000L;

                    for (int i = 0; i < total; i += PacingBurstSize)
                    {
                        if (ct.IsCancellationRequested) return;
                        int end = Math.Min(i + PacingBurstSize, total);
                        for (int j = i; j < end; j++)
                        {
                            byte[] pkt = batch.Packets[j];
                            try { udp.Send(pkt, pkt.Length, batch.Peer); }
                            catch { }
                        }

                        if (end < total && stepTicks > 0)
                        {
                            long target = Stopwatch.GetTimestamp() + stepTicks;
                            while (Stopwatch.GetTimestamp() < target)
                            {
                                Thread.Yield();
                            }
                        }
                    }
                }
            }
        }
        catch (OperationCanceledException) { }
        catch (ObjectDisposedException) { }
    }

    private async Task ReceiveLoopAsync(UdpClient udp, CancellationToken ct)
    {
        try
        {
            while (!ct.IsCancellationRequested)
            {
                var res = await udp.ReceiveAsync(ct).ConfigureAwait(false);
                HandleInboundDatagram(udp, res.Buffer, res.RemoteEndPoint);
            }
        }
        catch (OperationCanceledException) { }
        catch (ObjectDisposedException) { }
        catch (SocketException) { }
    }

    private void HandleInboundDatagram(UdpClient udp, byte[] buf, IPEndPoint remote)
    {
        if (buf.Length < ControlPacketSize) return;
        if (buf[0] != Magic0 || buf[1] != Magic1 || buf[2] != ProtocolVersion) return;

        byte pktType = buf[3];
        string tokenKey = Convert.ToHexString(buf, 4, 16);

        if (pktType == PacketHello)
        {
            Action<bool>? activateCb = null;
            byte[] ack = new byte[ControlPacketSize];
            ack[0] = Magic0; ack[1] = Magic1; ack[2] = ProtocolVersion; ack[3] = PacketHelloAck;
            Buffer.BlockCopy(buf, 4, ack, 4, 16);

            lock (_lock)
            {
                if (_sessions.TryGetValue(tokenKey, out var state))
                {
                    state.Peer = remote;
                    state.LastKeepaliveTick = Environment.TickCount64;
                    if (!state.Active)
                    {
                        state.Active = true;
                        activateCb = state.OnActivated;
                    }
                }
                else
                {
                    return;
                }
            }

            try { udp.Send(ack, ack.Length, remote); } catch { }
            activateCb?.Invoke(true);
            return;
        }

        if (pktType == PacketKeepalive)
        {
            lock (_lock)
            {
                if (_sessions.TryGetValue(tokenKey, out var state))
                {
                    state.Peer = remote;
                    state.LastKeepaliveTick = Environment.TickCount64;
                }
            }
            return;
        }

        if (pktType == PacketNack)
        {
            // [0..3] header | [4..19] 16B token | [20..23] frameId BE4 | [24] count | [25..] missing indices
            if (buf.Length < 25) return;
            uint frameId = BinaryPrimitives.ReadUInt32BigEndian(buf.AsSpan(20, 4));
            int count = Math.Min((int)buf[24], buf.Length - 25);
            if (count <= 0) return;

            List<byte[]>? retransmits = null;
            IPEndPoint? peer = null;

            lock (_lock)
            {
                if (_sessions.TryGetValue(tokenKey, out var state) && state.Active && state.Peer != null)
                {
                    peer = state.Peer;
                    state.WindowNackedPackets += (ulong)count;
                    for (int i = 0; i < count; i++)
                    {
                        byte fragIdx = buf[25 + i];
                        var cached = state.LookupInRing(frameId, fragIdx);
                        if (cached != null)
                        {
                            retransmits ??= new List<byte[]>();
                            retransmits.Add(cached);
                        }
                    }
                }
            }

            // Immediate unpaced NACK retransmission
            if (retransmits != null && peer != null)
            {
                foreach (var pkt in retransmits)
                {
                    try { udp.Send(pkt, pkt.Length, peer); } catch { }
                }
            }
        }
    }

    private async Task MaintenanceLoopAsync(CancellationToken ct)
    {
        try
        {
            using var timer = new PeriodicTimer(TimeSpan.FromMilliseconds(MaintenanceIntervalMs));
            while (await timer.WaitForNextTickAsync(ct).ConfigureAwait(false))
            {
                long now = Environment.TickCount64;
                List<Action<bool>>? timedOut = null;
                List<(Action<double, ulong> Cb, double Loss, ulong Sent)>? feedbacks = null;

                lock (_lock)
                {
                    foreach (var state in _sessions.Values)
                    {
                        if (!state.Active) continue;

                        if (now - state.LastKeepaliveTick > KeepaliveTimeoutMs)
                        {
                            state.Active = false;
                            timedOut ??= new List<Action<bool>>();
                            timedOut.Add(state.OnActivated);
                            continue;
                        }

                        ulong sent = state.WindowSentPackets;
                        ulong nacked = state.WindowNackedPackets;
                        state.WindowSentPackets = 0;
                        state.WindowNackedPackets = 0;

                        if (sent > 0)
                        {
                            double lossRatio = Math.Min(1.0, (double)nacked / sent);
                            UpdateAdaptiveFecLocked(state, lossRatio);
                            if (state.OnLossFeedback != null)
                            {
                                feedbacks ??= new List<(Action<double, ulong>, double, ulong)>();
                                feedbacks.Add((state.OnLossFeedback, lossRatio, sent));
                            }
                        }
                    }
                }

                if (timedOut != null)
                {
                    foreach (var cb in timedOut) cb.Invoke(false);
                }
                if (feedbacks != null)
                {
                    foreach (var f in feedbacks) f.Cb.Invoke(f.Loss, f.Sent);
                }
            }
        }
        catch (OperationCanceledException) { }
    }

    private static void UpdateAdaptiveFecLocked(UdpSessionState state, double lossRatio)
    {
        if (lossRatio >= 0.05)
        {
            state.CleanWindows = 0;
            state.FecLevel = FecLevel.Heavy;
        }
        else if (lossRatio >= 0.015)
        {
            state.CleanWindows = 0;
            state.FecLevel = FecLevel.Moderate;
        }
        else if (lossRatio > 0.002)
        {
            state.CleanWindows = 0;
            state.FecLevel = FecLevel.Light;
        }
        else
        {
            state.CleanWindows++;
            if (state.CleanWindows >= 3)
            {
                if (state.FecLevel == FecLevel.Heavy) state.FecLevel = FecLevel.Moderate;
                else if (state.FecLevel == FecLevel.Moderate) state.FecLevel = FecLevel.Light;
                else if (state.FecLevel == FecLevel.Light && state.AllowFecSuppression) state.FecLevel = FecLevel.Suppressed;
                state.CleanWindows = 0;
            }
        }
    }
}
