using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Channels;
using System.Threading.Tasks;

namespace RemoterWin;

/// <summary>
/// Direct low-latency UDP video & input server with AES-256-GCM encryption,
/// stride-interleaved adaptive XOR-FEC, 1024-packet per-session NACK ring buffer
/// (per-fragment & count=0 whole-frame retransmit), 0x13 delay-gradient GCC feedback,
/// 0x20 encrypted UDP input channel with 64-bit sliding-window dedup, and WAN-safe
/// token-bucket pacing.
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
    private const byte PacketFeedback  = 0x13;
    private const byte PacketInput     = 0x20;

    private const byte HeaderFlagEncrypted = 0x01;
    private const byte FecFlagInterleaved  = 0x01;

    private const int ControlPacketSize = 20;
    private const int InputHeaderSize = 25;
    private const int FeedbackPacketSize = 28;
    private const int VideoHeaderSize = 20;
    private const int GcmTagSize = 16;
    private const int MaxFragmentPayload = 1200;
    private const int MaxFragmentsPerFrame = 255;
    private const int NackRingSize = 1024;
    private const int KeepaliveTimeoutMs = 6000;
    private const int MaintenanceIntervalMs = 2000;
    private const int FastPathMaxPackets = 4;

    private enum FecLevel
    {
        Suppressed, // 0% overhead (clean LAN only)
        Light,      // deltaG=8, keyG=4
        Moderate,   // deltaG=4, keyG=3
        Heavy,      // deltaG=3, keyG=3 (capped at +33% to avoid tunnel self-congestion)
    }

    private readonly record struct PacedBatch(List<byte[]> Packets, bool IsKeyframe, IPEndPoint Peer);

    private sealed class UdpSessionState : IDisposable
    {
        public readonly byte[] Token;
        public readonly string TokenKey;
        public readonly Action<bool> OnActivated;
        public readonly Action<double, ulong>? OnLossFeedback;
        public readonly Action<double, double, double, int>? OnTransportFeedback;
        public readonly Action<string>? OnInputMessage;
        public AesGcm? AesGcm;

        public IPEndPoint? Peer;
        public bool Active;
        public long LastKeepaliveTick;
        public bool AllowFecSuppression = true;
        public bool SupportsInterleavedFec;
        public FecLevel FecLevel = FecLevel.Light;
        public int CleanWindows;
        public int PacingBitrateBps = 8_000_000;

        public ulong WindowSentPackets;
        public ulong WindowNackedPackets;

        // 64-packet sliding-window deduplication for 2x-redundant UDP 0x20 input packets
        private bool _hasInputSeq;
        private uint _maxInputSeq;
        private ulong _inputSeenMask;

        // 1024-packet NACK ring buffer + O(1) lookup map keyed by ((ulong)frameId << 8) | fragIndex
        public readonly (ulong Key, uint FrameId, byte FragIndex, byte[] Packet)?[] Ring =
            new (ulong, uint, byte, byte[])?[NackRingSize];
        public readonly Dictionary<ulong, int> RingIndexMap = new(NackRingSize);
        public int RingHead;

        // Packet pacing state (strict FIFO so P-frames never bypass an in-flight keyframe)
        public readonly Channel<PacedBatch> PacingChannel = Channel.CreateUnbounded<PacedBatch>(
            new UnboundedChannelOptions { SingleReader = true, SingleWriter = false });
        public int QueuedPacedFrames;
        public CancellationTokenSource PacingCts = new();

        public UdpSessionState(
            byte[] token,
            string tokenKey,
            byte[]? aesKey,
            Action<bool> onActivated,
            Action<double, ulong>? onLossFeedback,
            Action<double, double, double, int>? onTransportFeedback,
            Action<string>? onInputMessage)
        {
            Token = token;
            TokenKey = tokenKey;
            OnActivated = onActivated;
            OnLossFeedback = onLossFeedback;
            OnTransportFeedback = onTransportFeedback;
            OnInputMessage = onInputMessage;
            if (aesKey != null && aesKey.Length == 32)
            {
                AesGcm = new AesGcm(aesKey, tagSizeInBytes: GcmTagSize);
            }
        }

        /// <summary>
        /// Returns true if <paramref name="seq"/> has not been seen before and records it
        /// in the 64-packet sliding window. Must only be called AFTER AES-GCM authentication!
        /// </summary>
        public bool AcceptInputSeq(uint seq)
        {
            if (!_hasInputSeq)
            {
                _hasInputSeq = true;
                _maxInputSeq = seq;
                _inputSeenMask = 1UL;
                return true;
            }
            int diff = unchecked((int)(seq - _maxInputSeq));
            if (diff > 0)
            {
                _inputSeenMask = diff >= 64 ? 1UL : ((_inputSeenMask << diff) | 1UL);
                _maxInputSeq = seq;
                return true;
            }
            int behind = -diff;
            if (behind >= 64) return false;
            ulong bit = 1UL << behind;
            if ((_inputSeenMask & bit) != 0) return false;
            _inputSeenMask |= bit;
            return true;
        }

        public void StoreInRing(uint frameId, byte fragIndex, byte[] wirePacket)
        {
            if (Ring[RingHead] is { } evicted &&
                RingIndexMap.TryGetValue(evicted.Key, out int mapped) &&
                mapped == RingHead)
            {
                RingIndexMap.Remove(evicted.Key);
            }
            ulong key = ((ulong)frameId << 8) | fragIndex;
            Ring[RingHead] = (key, frameId, fragIndex, wirePacket);
            RingIndexMap[key] = RingHead;
            RingHead = (RingHead + 1) % NackRingSize;
        }

        public byte[]? LookupInRing(uint frameId, byte fragIndex)
        {
            ulong key = ((ulong)frameId << 8) | fragIndex;
            if (RingIndexMap.TryGetValue(key, out int idx) &&
                Ring[idx] is { } entry &&
                entry.Key == key)
            {
                return entry.Packet;
            }
            return null;
        }

        public List<byte[]> LookupAllFragmentsInRing(uint frameId)
        {
            var found = new List<(byte FragIdx, byte[] Packet)>();
            for (int i = 0; i < NackRingSize; i++)
            {
                if (Ring[i] is { } entry && entry.FrameId == frameId)
                {
                    found.Add((entry.FragIndex, entry.Packet));
                }
            }
            found.Sort((a, b) => a.FragIdx.CompareTo(b.FragIdx));
            var result = new List<byte[]>(found.Count);
            foreach (var item in found) result.Add(item.Packet);
            return result;
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
        Action<double, ulong>? onLossFeedback = null,
        Action<double, double, double, int>? onTransportFeedback = null,
        Action<string>? onInputMessage = null)
    {
        if (token == null || token.Length != 16) return;
        string key = Convert.ToHexString(token);
        var state = new UdpSessionState(
            (byte[])token.Clone(), key, aesKey,
            onActivated, onLossFeedback, onTransportFeedback, onInputMessage);

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

    public void UpdatePacingBitrate(byte[]? token, int bitrateBps)
    {
        if (token == null || token.Length != 16) return;
        string key = Convert.ToHexString(token);
        lock (_lock)
        {
            if (_sessions.TryGetValue(key, out var state))
            {
                state.PacingBitrateBps = Math.Max(2_000_000, bitrateBps);
            }
        }
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
    /// Fragments, seals (AES-256-GCM if active), adds adaptive stride-interleaved XOR-FEC parity,
    /// stores in the 1024-packet NACK ring, and sends (strict FIFO when pacing queue is non-empty).
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
        bool interleavedFec;

        lock (_lock)
        {
            udp = _udp;
            if (!_running || udp == null) return false;
            if (!_sessions.TryGetValue(key, out state) || !state.Active || state.Peer == null)
                return false;

            peer = state.Peer;
            fecGroupSize = SelectFecGroupSize(state.FecLevel, isKeyframe);
            interleavedFec = state.SupportsInterleavedFec;
        }

        int fragCount = (data.Length + MaxFragmentPayload - 1) / MaxFragmentPayload;
        if (fragCount <= 0 || fragCount > MaxFragmentsPerFrame) return false;
        if (fragCount == 1) fecGroupSize = 0;

        byte flags = (byte)((isKeyframe ? 0x01 : 0x00) | (isHevc ? 0x02 : 0x00));
        byte fecFlags = (fecGroupSize > 0 && interleavedFec) ? FecFlagInterleaved : (byte)0x00;
        var wirePackets = new List<byte[]>(fragCount + (fecGroupSize > 0 ? (fragCount + fecGroupSize - 1) / fecGroupSize : 0));

        // 1. Build & seal data fragments
        lock (_lock)
        {
            if (!state.Active) return false;

            for (int i = 0; i < fragCount; i++)
            {
                int offset = i * MaxFragmentPayload;
                int len = Math.Min(MaxFragmentPayload, data.Length - offset);
                byte[] pkt = BuildVideoPacket(
                    PacketData, frameId, ptsMs, flags,
                    (byte)i, (byte)fragCount, (byte)fecGroupSize, fecFlags,
                    data.Slice(offset, len), state.AesGcm);
                state.StoreInRing(frameId, (byte)i, pkt);
                wirePackets.Add(pkt);
            }

            // 2. Build & seal XOR-FEC parity packets (stride-interleaved if client advertised support)
            if (fecGroupSize > 0)
            {
                int groupCount = (fragCount + fecGroupSize - 1) / fecGroupSize;
                for (int g = 0; g < groupCount; g++)
                {
                    int memberCount = 0;
                    int maxLen = 0;
                    if (interleavedFec)
                    {
                        for (int i = g; i < fragCount; i += groupCount)
                        {
                            memberCount++;
                            int len = Math.Min(MaxFragmentPayload, data.Length - i * MaxFragmentPayload);
                            if (len > maxLen) maxLen = len;
                        }
                    }
                    else
                    {
                        int start = g * fecGroupSize;
                        int end = Math.Min(start + fecGroupSize, fragCount);
                        memberCount = end - start;
                        for (int i = start; i < end; i++)
                        {
                            int len = Math.Min(MaxFragmentPayload, data.Length - i * MaxFragmentPayload);
                            if (len > maxLen) maxLen = len;
                        }
                    }
                    if (memberCount < 2) continue;

                    byte[] parityBody = new byte[2 + maxLen];
                    ushort xorLen = 0;
                    if (interleavedFec)
                    {
                        for (int i = g; i < fragCount; i += groupCount)
                        {
                            int offset = i * MaxFragmentPayload;
                            int len = Math.Min(MaxFragmentPayload, data.Length - offset);
                            xorLen ^= (ushort)len;
                            var fragSpan = data.Slice(offset, len);
                            for (int b = 0; b < len; b++) parityBody[2 + b] ^= fragSpan[b];
                        }
                    }
                    else
                    {
                        int start = g * fecGroupSize;
                        int end = Math.Min(start + fecGroupSize, fragCount);
                        for (int i = start; i < end; i++)
                        {
                            int offset = i * MaxFragmentPayload;
                            int len = Math.Min(MaxFragmentPayload, data.Length - offset);
                            xorLen ^= (ushort)len;
                            var fragSpan = data.Slice(offset, len);
                            for (int b = 0; b < len; b++) parityBody[2 + b] ^= fragSpan[b];
                        }
                    }
                    BinaryPrimitives.WriteUInt16BigEndian(parityBody.AsSpan(0, 2), xorLen);

                    byte[] parityPkt = BuildVideoPacket(
                        PacketFecParity, frameId, ptsMs, flags,
                        (byte)g, (byte)fragCount, (byte)fecGroupSize, fecFlags,
                        parityBody, state.AesGcm);
                    wirePackets.Add(parityPkt);
                }
            }

            state.WindowSentPackets += (ulong)fragCount;
        }

        // 3. Strict FIFO: only use inline fast path when pacing queue is empty!
        // Prevents small P-frames from overtaking an in-flight keyframe and evicting it at receiver.
        if (wirePackets.Count <= FastPathMaxPackets && Volatile.Read(ref state.QueuedPacedFrames) == 0)
        {
            foreach (var pkt in wirePackets)
            {
                try { udp.Send(pkt, pkt.Length, peer); }
                catch { }
            }
            return true;
        }

        // 4. Paced path: enqueue FIFO batch
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
        FecLevel.Moderate   => isKeyframe ? 3 : 4,
        FecLevel.Heavy      => 3,
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
        byte fecFlags,
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
        pkt[19] = fecFlags;

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
                    Interlocked.Decrement(ref state.QueuedPacedFrames);

                    UdpClient? udp;
                    bool isLan;
                    int bitrateBps;
                    lock (_lock)
                    {
                        udp = _udp;
                        isLan = state.AllowFecSuppression;
                        bitrateBps = state.PacingBitrateBps;
                    }
                    if (udp == null) continue;

                    int total = batch.Packets.Count;
                    // WAN mode: cap pacing to 10-16 Mbps (max 4 pkts/burst) so 2K keyframes drain smoothly
                    // over ~90-120ms without overflowing WireGuard/router UDP buffers!
                    // LAN mode: drain fast within ~14ms.
                    double paceRateBps = isLan
                        ? Math.Max(bitrateBps * 2.5, Math.Max((total * 1236.0 / 0.014) * 8.0, 24_000_000.0))
                        : Math.Min(Math.Max(bitrateBps * 2.5, 10_000_000.0), 16_000_000.0);
                    int burstSize = isLan ? 8 : 4;
                    double bytesPerBurst = burstSize * 1236.0;
                    double stepUs = (bytesPerBurst * 8.0 / paceRateBps) * 1_000_000.0;
                    long stepTicks = (long)(Math.Max(100.0, stepUs) * Stopwatch.Frequency / 1_000_000.0);

                    for (int i = 0; i < total; i += burstSize)
                    {
                        if (ct.IsCancellationRequested) return;
                        int end = Math.Min(i + burstSize, total);
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
            bool interleaved = buf.Length >= 21 && (buf[20] & FecFlagInterleaved) != 0;
            Action<bool>? activateCb = null;
            // 21-byte HELLO_ACK: byte[20] = 0x01 advertises encrypted UDP 0x20 input support
            byte[] ack = new byte[ControlPacketSize + 1];
            ack[0] = Magic0; ack[1] = Magic1; ack[2] = ProtocolVersion; ack[3] = PacketHelloAck;
            Buffer.BlockCopy(buf, 4, ack, 4, 16);
            ack[20] = 0x01;

            lock (_lock)
            {
                if (_sessions.TryGetValue(tokenKey, out var state))
                {
                    state.Peer = remote;
                    state.LastKeepaliveTick = Environment.TickCount64;
                    state.SupportsInterleavedFec = interleaved;
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
            // count == 0 means whole-frame NACK (retransmit all cached fragments of frameId)
            if (buf.Length < 25) return;
            uint frameId = BinaryPrimitives.ReadUInt32BigEndian(buf.AsSpan(20, 4));
            int count = buf[24];

            List<byte[]>? retransmits = null;
            IPEndPoint? peer = null;

            lock (_lock)
            {
                if (_sessions.TryGetValue(tokenKey, out var state) && state.Active && state.Peer != null)
                {
                    peer = state.Peer;
                    if (count == 0)
                    {
                        var allFrags = state.LookupAllFragmentsInRing(frameId);
                        if (allFrags.Count > 0)
                        {
                            state.WindowNackedPackets += (ulong)allFrags.Count;
                            retransmits = allFrags;
                        }
                    }
                    else
                    {
                        int actualCount = Math.Min(count, buf.Length - 25);
                        if (actualCount <= 0) return;
                        state.WindowNackedPackets += (ulong)actualCount;
                        for (int i = 0; i < actualCount; i++)
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
            }

            // Immediate unpaced NACK retransmission
            if (retransmits != null && peer != null)
            {
                foreach (var pkt in retransmits)
                {
                    try { udp.Send(pkt, pkt.Length, peer); } catch { }
                }
            }
            return;
        }

        if (pktType == PacketFeedback)
        {
            if (buf.Length < FeedbackPacketSize) return;
            double delayGradMs = BinaryPrimitives.ReadInt16BigEndian(buf.AsSpan(20, 2)) / 10.0;
            double lossRatio = Math.Min(1000, (int)BinaryPrimitives.ReadUInt16BigEndian(buf.AsSpan(22, 2))) / 1000.0;
            double jitterMs = BinaryPrimitives.ReadUInt16BigEndian(buf.AsSpan(24, 2)) / 10.0;
            int recvBps = BinaryPrimitives.ReadUInt16BigEndian(buf.AsSpan(26, 2)) * 1000;

            Action<double, double, double, int>? cb = null;
            lock (_lock)
            {
                if (_sessions.TryGetValue(tokenKey, out var state) && state.Active)
                {
                    state.Peer = remote;
                    state.LastKeepaliveTick = Environment.TickCount64;
                    cb = state.OnTransportFeedback;
                }
            }
            cb?.Invoke(delayGradMs, lossRatio, jitterMs, recvBps);
            return;
        }

        if (pktType == PacketInput)
        {
            HandleInputDatagram(tokenKey, buf, remote);
        }
    }

    private void HandleInputDatagram(string tokenKey, byte[] buf, IPEndPoint remote)
    {
        if (buf.Length <= InputHeaderSize) return;
        uint inputSeq = BinaryPrimitives.ReadUInt32BigEndian(buf.AsSpan(20, 4));
        bool isEncrypted = (buf[24] & HeaderFlagEncrypted) != 0;

        AesGcm? aes;
        Action<string>? callback;
        lock (_lock)
        {
            if (!_sessions.TryGetValue(tokenKey, out var state) || !state.Active) return;
            aes = state.AesGcm;
            callback = state.OnInputMessage;
        }
        if (callback == null) return;

        // Authenticate & decrypt BEFORE mutating peer or sliding dedup window so a
        // corrupted/tampered packet with a high inputSeq can never poison _maxInputSeq!
        byte[] plaintext;
        if (isEncrypted)
        {
            if (aes == null || buf.Length <= InputHeaderSize + GcmTagSize) return;
            int ctLen = buf.Length - InputHeaderSize - GcmTagSize;
            plaintext = new byte[ctLen];
            Span<byte> nonce = stackalloc byte[12];
            nonce[0] = Magic0;
            nonce[1] = Magic1;
            nonce[2] = PacketInput;
            nonce[3] = 0x00;
            buf.AsSpan(4, 4).CopyTo(nonce.Slice(4, 4));   // token[0..3]
            buf.AsSpan(20, 4).CopyTo(nonce.Slice(8, 4));  // inputSeq(BE4)

            try
            {
                lock (_lock)
                {
                    if (!_sessions.TryGetValue(tokenKey, out var s) || s.AesGcm == null) return;
                    s.AesGcm.Decrypt(
                        nonce,
                        buf.AsSpan(InputHeaderSize, ctLen),
                        buf.AsSpan(InputHeaderSize + ctLen, GcmTagSize),
                        plaintext,
                        associatedData: buf.AsSpan(0, InputHeaderSize));
                }
            }
            catch (CryptographicException) { return; }
            catch (ObjectDisposedException) { return; }
        }
        else
        {
            if (aes != null) return; // Reject unencrypted input on E2E-encrypted session
            int len = buf.Length - InputHeaderSize;
            plaintext = new byte[len];
            Buffer.BlockCopy(buf, InputHeaderSize, plaintext, 0, len);
        }

        bool accepted = false;
        lock (_lock)
        {
            if (_sessions.TryGetValue(tokenKey, out var state) && state.Active)
            {
                state.Peer = remote;
                state.LastKeepaliveTick = Environment.TickCount64;
                accepted = state.AcceptInputSeq(inputSeq);
            }
        }
        if (!accepted) return;

        string json = Encoding.UTF8.GetString(plaintext);
        callback(json);
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
        if (lossRatio >= 0.08)
        {
            state.CleanWindows = 0;
            state.FecLevel = FecLevel.Heavy;
        }
        else if (lossRatio >= 0.03)
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
