using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;

namespace RemoterWinClient;

/// <summary>
/// Direct low-latency UDP video receiver with AES-256-GCM decryption, 0ms XOR-FEC
/// single-packet recovery, per-fragment NACK (0x12) retransmission, and automatic
/// fallback to WebSocket TCP when UDP handshake times out.
/// Wire protocol matches Remoter-MacServer/Server/UdpVideoServer.swift bit-for-bit.
/// </summary>
public sealed class UdpVideoReceiver : IDisposable
{
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
    private const byte PacketAudio     = 0x14;
    private const byte PacketInput     = 0x20;

    private const byte HeaderFlagEncrypted = 0x01;

    private const int ControlPacketSize = 20;
    private const int InputHeaderSize = 25;
    private const int FeedbackPacketSize = 28;
    private const int FeedbackIntervalMs = 200;
    private const int VideoHeaderSize = 20;
    private const int GcmTagSize = 16;
    private const int MaxNackIndices = 16;
    private const int MaxInFlightFrames = 16;
    private const int FrameTimeoutMs = 220;
    private const int KeyframeTimeoutMs = 350;
    private const int TailNackDelayMs = 25;
    private const int NackRetryCooldownMs = 45;
    private const int CleanupIntervalMs = 20;
    private const int ReceiveBufferBytes = 4 * 1024 * 1024;
    private const int HelloRetryCount = 3;
    private const int HelloIntervalMs = 100;
    private const int HandshakeTimeoutMs = 600;
    private const int PunchHandshakeTimeoutMs = 1200;
    private const int KeepaliveIntervalMs = 2000;

    private sealed class FrameAssembly
    {
        public uint FrameId;
        public uint PtsMs;
        public bool IsKeyframe;
        public VideoCodecType Codec;
        public int FragCount;
        public int FecGroupSize;
        public bool InterleavedFec;
        public long CreatedAtTick;
        public long LastPacketTick;
        public byte[]?[] Fragments = Array.Empty<byte[]?>();
        public int ReceivedCount;
        public bool IsComplete;
        public Dictionary<int, byte[]>? ParityGroups;
        public Dictionary<byte, (long LastTick, byte Count)>? NackedFrags;
    }

    private readonly object _lock = new();
    private readonly Dictionary<uint, FrameAssembly> _frames = new();
    private readonly HashSet<uint> _wholeFrameNacked = new();

    private UdpClient? _udp;
    private CancellationTokenSource? _cts;
    private byte[]? _token;
    private AesGcm? _aesGcm;
    private bool _connected;
    private bool _supportsUdpInput;
    private int _inputSeq;
    private bool _hasCompletedFrame;
    private uint _lastCompletedFrameId;
    private bool _hasLastAudioSeq;
    private uint _lastAudioSeq;
    private bool _awaitingKeyframe = true;
    private long _lastAwaitingKeyframeRetryTick;
    private bool _disposed;

    // Delay-gradient GCC telemetry (reported every 200ms via 0x13 FEEDBACK)
    private bool _hasDelayRef;
    private uint _prevFeedbackPtsMs;
    private double _prevFeedbackRecvMs;
    private double _ewmaDelayGradMs;
    private double _ewmaJitterMs;
    private int _windowRecvPackets;
    private int _windowNackPackets;
    private long _windowRecvBytes;
    private long _lastFeedbackSentTick;

    public bool IsConnected => Volatile.Read(ref _connected);
    public bool SupportsUdpInput => Volatile.Read(ref _connected) && Volatile.Read(ref _supportsUdpInput);

    public event Action<bool>? ConnectedChanged;
    public event Action<VideoFramePacket>? FrameReceived;
    public event Action<byte[]>? AudioFrameReceived;
    public event Action? FrameDropped;

    public void Start(string host, int port, byte[] token, byte[]? aesKey = null)
    {
        if (string.IsNullOrWhiteSpace(host))
            throw new ArgumentException("Host must not be empty.", nameof(host));
        if (port <= 0 || port > 65535)
            throw new ArgumentOutOfRangeException(nameof(port));
        if (token == null || token.Length != 16)
            throw new ArgumentException("UDP session token must be 16 bytes.", nameof(token));

        Stop();

        lock (_lock)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);

            _token = (byte[])token.Clone();
            _aesGcm = (aesKey != null && aesKey.Length == 32)
                ? new AesGcm(aesKey, tagSizeInBytes: GcmTagSize)
                : null;
            _connected = false;
            _supportsUdpInput = false;
            _inputSeq = 0;
            _hasCompletedFrame = false;
            _lastCompletedFrameId = 0;
            _hasLastAudioSeq = false;
            _lastAudioSeq = 0;
            _awaitingKeyframe = true;
            _hasDelayRef = false;
            _ewmaDelayGradMs = 0;
            _ewmaJitterMs = 0;
            _windowRecvPackets = 0;
            _windowNackPackets = 0;
            _windowRecvBytes = 0;
            _lastFeedbackSentTick = Environment.TickCount64;
            _frames.Clear();
            _wholeFrameNacked.Clear();

            var udp = new UdpClient();
            udp.Client.ReceiveBufferSize = ReceiveBufferBytes;
            udp.Connect(host, port);

            var cts = new CancellationTokenSource();
            _udp = udp;
            _cts = cts;

            _ = Task.Run(() => ReceiveLoopAsync(udp, cts.Token), cts.Token);
            _ = Task.Run(() => HandshakeAndKeepaliveLoopAsync(udp, _token, HandshakeTimeoutMs, cts.Token), cts.Token);
            _ = Task.Run(() => StaleFrameCleanupLoopAsync(cts.Token), cts.Token);
        }
    }

    /// <summary>
    /// Opens an unbound IPv4 UDP socket, probes STUN on that exact socket to discover the client's
    /// NAT-mapped public endpoint, invokes <paramref name="onLocalPublicEndpoint"/> so the caller can
    /// send `udp_punch` over WebSocket, and initiates the UDP HELLO handshake to (<paramref name="publicHost"/>,
    /// <paramref name="publicPort"/>) with a 1.2s timeout (gracefully stopping on failure so Relay TCP continues).
    /// </summary>
    public void StartWithStunPunch(
        string publicHost,
        int publicPort,
        byte[] token,
        byte[]? aesKey,
        Action<string, int> onLocalPublicEndpoint)
    {
        if (string.IsNullOrWhiteSpace(publicHost))
            throw new ArgumentException("Public host must not be empty.", nameof(publicHost));
        if (publicPort <= 0 || publicPort > 65535)
            throw new ArgumentOutOfRangeException(nameof(publicPort));
        if (token == null || token.Length != 16)
            throw new ArgumentException("UDP session token must be 16 bytes.", nameof(token));

        Stop();

        UdpClient udp;
        CancellationTokenSource cts;
        byte[] tokenCopy;

        lock (_lock)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);

            tokenCopy = (byte[])token.Clone();
            _token = tokenCopy;
            _aesGcm = (aesKey != null && aesKey.Length == 32)
                ? new AesGcm(aesKey, tagSizeInBytes: GcmTagSize)
                : null;
            _connected = false;
            _supportsUdpInput = false;
            _inputSeq = 0;
            _hasCompletedFrame = false;
            _lastCompletedFrameId = 0;
            _hasLastAudioSeq = false;
            _lastAudioSeq = 0;
            _awaitingKeyframe = true;
            _hasDelayRef = false;
            _ewmaDelayGradMs = 0;
            _ewmaJitterMs = 0;
            _windowRecvPackets = 0;
            _windowNackPackets = 0;
            _windowRecvBytes = 0;
            _lastFeedbackSentTick = Environment.TickCount64;
            _frames.Clear();
            _wholeFrameNacked.Clear();

            udp = new UdpClient(0, AddressFamily.InterNetwork);
            udp.Client.ReceiveBufferSize = ReceiveBufferBytes;

            cts = new CancellationTokenSource();
            _udp = udp;
            _cts = cts;
        }

        _ = Task.Run(async () =>
        {
            try
            {
                var localPub = await StunClient.DiscoverPublicEndpointAsync(udp, cts.Token).ConfigureAwait(false);
                if (cts.IsCancellationRequested) return;

                if (localPub.HasValue)
                {
                    try
                    {
                        onLocalPublicEndpoint(localPub.Value.Ip, localPub.Value.Port);
                    }
                    catch { }
                }

                lock (_lock)
                {
                    if (_disposed || _udp != udp || cts.IsCancellationRequested) return;
                }

                udp.Connect(publicHost, publicPort);

                _ = Task.Run(() => ReceiveLoopAsync(udp, cts.Token), cts.Token);
                _ = Task.Run(() => HandshakeAndKeepaliveLoopAsync(udp, tokenCopy, PunchHandshakeTimeoutMs, cts.Token), cts.Token);
                _ = Task.Run(() => StaleFrameCleanupLoopAsync(cts.Token), cts.Token);
            }
            catch
            {
                Stop();
            }
        }, cts.Token);
    }

    public void NotifyExternalFrame(uint frameId, bool isKeyframe)
    {
        List<VideoFramePacket>? completedPackets = null;
        lock (_lock)
        {
            if (!_hasCompletedFrame || unchecked((int)(frameId - _lastCompletedFrameId)) > 0)
            {
                _lastCompletedFrameId = frameId;
                _hasCompletedFrame = true;
            }
            if (isKeyframe)
            {
                _awaitingKeyframe = false;
            }
            _frames.Remove(frameId);
            FlushConsecutiveCompletedFrames(ref completedPackets);
        }
        if (completedPackets != null)
        {
            foreach (var pkt in completedPackets)
            {
                FrameReceived?.Invoke(pkt);
            }
        }
    }

    public void Stop()
    {
        UdpClient? udp;
        CancellationTokenSource? cts;
        AesGcm? aes;
        bool wasConnected;

        lock (_lock)
        {
            udp = _udp;
            _udp = null;
            cts = _cts;
            _cts = null;
            aes = _aesGcm;
            _aesGcm = null;
            wasConnected = _connected;
            _connected = false;
            _supportsUdpInput = false;
            _awaitingKeyframe = true;
            _hasDelayRef = false;
            _ewmaDelayGradMs = 0;
            _ewmaJitterMs = 0;
            _windowRecvPackets = 0;
            _windowNackPackets = 0;
            _windowRecvBytes = 0;
            _lastFeedbackSentTick = Environment.TickCount64;
            _frames.Clear();
            _wholeFrameNacked.Clear();
        }

        try { cts?.Cancel(); } catch { }
        try { udp?.Close(); } catch { }
        try { udp?.Dispose(); } catch { }
        try { cts?.Dispose(); } catch { }
        try { aes?.Dispose(); } catch { }

        if (wasConnected)
        {
            ConnectedChanged?.Invoke(false);
        }
    }

    public void Dispose()
    {
        lock (_lock)
        {
            if (_disposed) return;
            _disposed = true;
        }
        Stop();
    }

    // ── Control Loops ────────────────────────────────────────────────────

    private async Task HandshakeAndKeepaliveLoopAsync(UdpClient udp, byte[] token, int handshakeTimeoutMs, CancellationToken ct)
    {
        // 21-byte HELLO: byte[20] = 0x01 advertises stride-interleaved XOR-FEC support
        byte[] helloPkt = new byte[ControlPacketSize + 1];
        helloPkt[0] = Magic0;
        helloPkt[1] = Magic1;
        helloPkt[2] = ProtocolVersion;
        helloPkt[3] = PacketHello;
        Buffer.BlockCopy(token, 0, helloPkt, 4, 16);
        helloPkt[20] = 0x01;
        byte[] keepalivePkt = BuildControlPacket(PacketKeepalive, token);
        long startTick = Environment.TickCount64;

        try
        {
            // Send up to 3 HELLO packets 100ms apart
            for (int i = 0; i < HelloRetryCount && !ct.IsCancellationRequested; i++)
            {
                if (Volatile.Read(ref _connected)) break;
                await udp.SendAsync(helloPkt, ct).ConfigureAwait(false);
                if (i + 1 < HelloRetryCount)
                {
                    await Task.Delay(HelloIntervalMs, ct).ConfigureAwait(false);
                }
            }

            // Wait remaining time up to handshakeTimeoutMs total for HELLO_ACK
            while (!Volatile.Read(ref _connected) && !ct.IsCancellationRequested)
            {
                long elapsed = Environment.TickCount64 - startTick;
                if (elapsed >= handshakeTimeoutMs)
                {
                    // Handshake timed out — stop cleanly so WebSocket TCP continues uninterrupted
                    Stop();
                    return;
                }
                int waitMs = (int)Math.Min(25, handshakeTimeoutMs - elapsed);
                if (waitMs > 0)
                {
                    await Task.Delay(waitMs, ct).ConfigureAwait(false);
                }
            }

            // Connected: send 0x13 FEEDBACK every 200ms and KEEPALIVE every 2s
            int tickCount = 0;
            using var timer = new PeriodicTimer(TimeSpan.FromMilliseconds(FeedbackIntervalMs));
            while (await timer.WaitForNextTickAsync(ct).ConfigureAwait(false))
            {
                if (!Volatile.Read(ref _connected)) return;
                tickCount++;

                byte[]? fbPkt = BuildFeedbackPacketIfActive(token);
                if (fbPkt != null)
                {
                    await udp.SendAsync(fbPkt, ct).ConfigureAwait(false);
                }

                if (tickCount % (KeepaliveIntervalMs / FeedbackIntervalMs) == 0)
                {
                    await udp.SendAsync(keepalivePkt, ct).ConfigureAwait(false);
                }
            }
        }
        catch (OperationCanceledException) { }
        catch (ObjectDisposedException) { }
        catch (SocketException) { }
    }

    private async Task ReceiveLoopAsync(UdpClient udp, CancellationToken ct)
    {
        try
        {
            while (!ct.IsCancellationRequested)
            {
                UdpReceiveResult result = await udp.ReceiveAsync(ct).ConfigureAwait(false);
                ProcessDatagram(result.Buffer);
            }
        }
        catch (OperationCanceledException) { }
        catch (ObjectDisposedException) { }
        catch (SocketException) { }
    }

    private async Task StaleFrameCleanupLoopAsync(CancellationToken ct)
    {
        try
        {
            using var timer = new PeriodicTimer(TimeSpan.FromMilliseconds(CleanupIntervalMs));
            while (await timer.WaitForNextTickAsync(ct).ConfigureAwait(false))
            {
                int dropped = 0;
                bool retryKeyframe = false;
                List<byte[]>? tailNacks = null;
                UdpClient? nackUdp = null;
                long now = Environment.TickCount64;
                lock (_lock)
                {
                    if (_frames.Count > 0)
                    {
                        List<uint>? expired = null;
                        foreach (var kvp in _frames)
                        {
                            var asm = kvp.Value;
                            int timeout = asm.IsKeyframe ? KeyframeTimeoutMs : FrameTimeoutMs;
                            long age = now - asm.CreatedAtTick;
                            long idleMs = now - asm.LastPacketTick;
                            if (age > timeout)
                            {
                                expired ??= new List<uint>();
                                expired.Add(kvp.Key);
                            }
                            else if (!asm.IsComplete && idleMs >= TailNackDelayMs && _udp != null && _token != null)
                            {
                                // Proactive tail-loss NACK & retry (up to 2 rounds, 45ms cooldown)
                                // only after 25ms of SILENCE on this frame so we never collide with pacing.
                                List<byte>? missing = null;
                                for (int i = 0; i < asm.FragCount; i++)
                                {
                                    if (asm.Fragments[i] != null) continue;
                                    byte idx = (byte)i;
                                    if (asm.NackedFrags != null && asm.NackedFrags.TryGetValue(idx, out var info))
                                    {
                                        if (info.Count >= 2 || (now - info.LastTick) < NackRetryCooldownMs) continue;
                                    }
                                    missing ??= new List<byte>();
                                    missing.Add(idx);
                                    if (missing.Count >= MaxNackIndices) break;
                                }
                                if (missing != null && missing.Count > 0)
                                {
                                    asm.NackedFrags ??= new Dictionary<byte, (long, byte)>();
                                    foreach (byte idx in missing)
                                    {
                                        byte prevCount = asm.NackedFrags.TryGetValue(idx, out var info) ? info.Count : (byte)0;
                                        asm.NackedFrags[idx] = (now, (byte)(prevCount + 1));
                                    }
                                    _windowNackPackets += missing.Count;
                                    tailNacks ??= new List<byte[]>();
                                    tailNacks.Add(BuildNackPacket(_token, asm.FrameId, missing));
                                    nackUdp = _udp;
                                }
                            }
                        }
                        if (expired != null)
                        {
                            foreach (uint id in expired)
                            {
                                _frames.Remove(id);
                                dropped++;
                            }
                            _awaitingKeyframe = true;
                            _lastAwaitingKeyframeRetryTick = now;
                        }
                    }

                    // While awaiting a keyframe (and ignoring P-frames), periodically retry
                    // FrameDropped -> request_keyframe every 450ms so a single throttled/lost
                    // keyframe can NEVER freeze the screen for 5-10s waiting for periodic IDR!
                    if (_connected && _awaitingKeyframe && dropped == 0 &&
                        now - _lastAwaitingKeyframeRetryTick >= 450)
                    {
                        _lastAwaitingKeyframeRetryTick = now;
                        retryKeyframe = true;
                    }
                }
                if (tailNacks != null && nackUdp != null)
                {
                    foreach (var pkt in tailNacks)
                    {
                        _ = SendNackAsync(nackUdp, pkt);
                    }
                }
                if (dropped > 0 || retryKeyframe)
                {
                    FrameDropped?.Invoke();
                }
            }
        }
        catch (OperationCanceledException) { }
        catch (ObjectDisposedException) { }
    }

    // ── Packet Parsing & 0ms XOR-FEC Reassembly ──────────────────────────

    private void ProcessDatagram(byte[] buf)
    {
        if (buf.Length < 4) return;
        if (buf[0] != Magic0 || buf[1] != Magic1 || buf[2] != ProtocolVersion) return;

        byte pktType = buf[3];
        if (pktType == PacketHelloAck)
        {
            if (buf.Length < ControlPacketSize) return;
            bool becameConnected = false;
            bool serverSupportsInput = buf.Length >= 21 && (buf[20] & 0x01) != 0;
            lock (_lock)
            {
                if (_token != null && buf.AsSpan(4, 16).SequenceEqual(_token))
                {
                    if (serverSupportsInput)
                    {
                        _supportsUdpInput = true;
                    }
                    if (!_connected)
                    {
                        _connected = true;
                        becameConnected = true;
                    }
                }
            }
            if (becameConnected)
            {
                ConnectedChanged?.Invoke(true);
            }
            return;
        }

        if (pktType == PacketAudio)
        {
            HandleAudioPacket(buf);
            return;
        }

        if (pktType != PacketData && pktType != PacketFecParity) return;
        if (buf.Length < VideoHeaderSize) return;

        uint frameId = BinaryPrimitives.ReadUInt32BigEndian(buf.AsSpan(4, 4));
        uint ptsMs = BinaryPrimitives.ReadUInt32BigEndian(buf.AsSpan(8, 4));
        byte flags = buf[12];
        byte fragIndex = buf[13];
        byte fragCount = buf[14];
        byte fecGroupSize = buf[15];
        ushort payloadLen = BinaryPrimitives.ReadUInt16BigEndian(buf.AsSpan(16, 2));
        bool isEncrypted = (buf[18] & HeaderFlagEncrypted) != 0;
        bool interleavedFec = (buf[19] & 0x01) != 0;

        if (fragCount == 0) return;

        byte[] payload = new byte[payloadLen];
        if (isEncrypted)
        {
            if (VideoHeaderSize + payloadLen + GcmTagSize > buf.Length) return;

            Span<byte> nonce = stackalloc byte[12];
            nonce[0] = Magic0;
            nonce[1] = Magic1;
            nonce[2] = pktType;
            nonce[3] = fragIndex;
            buf.AsSpan(4, 8).CopyTo(nonce.Slice(4, 8)); // frameId(BE4) + ptsMs(BE4)

            ReadOnlySpan<byte> aad = buf.AsSpan(0, VideoHeaderSize);
            ReadOnlySpan<byte> ciphertext = buf.AsSpan(VideoHeaderSize, payloadLen);
            ReadOnlySpan<byte> tag = buf.AsSpan(VideoHeaderSize + payloadLen, GcmTagSize);

            lock (_lock)
            {
                if (_aesGcm == null) return;
                try
                {
                    _aesGcm.Decrypt(nonce, ciphertext, tag, payload, associatedData: aad);
                }
                catch (CryptographicException)
                {
                    return;
                }
                catch (ObjectDisposedException)
                {
                    return;
                }
            }
        }
        else
        {
            if (VideoHeaderSize + payloadLen > buf.Length) return;
            Buffer.BlockCopy(buf, VideoHeaderSize, payload, 0, payloadLen);
        }

        bool isKeyframe = (flags & 0x01) != 0;
        VideoCodecType codec = (flags & 0x02) != 0 ? VideoCodecType.H265 : VideoCodecType.H264;

        List<VideoFramePacket>? completedPackets = null;
        List<byte[]>? nackPackets = null;
        UdpClient? nackUdp = null;
        int droppedCount = 0;

        lock (_lock)
        {
            // Drop late packets belonging to already-completed or older frames
            if (_hasCompletedFrame && (int)(frameId - _lastCompletedFrameId) <= 0)
            {
                return;
            }

            // While awaiting a keyframe, ignore P-frame packets completely so they can never
            // fill _frames and evict an in-progress multi-fragment keyframe!
            if (_awaitingKeyframe && !isKeyframe)
            {
                if (pktType == PacketData)
                {
                    _windowRecvPackets++;
                    _windowRecvBytes += buf.Length;
                }
                return;
            }

            if (!_frames.TryGetValue(frameId, out var assembly))
            {
                // Keep at most MaxInFlightFrames in flight; evict oldest incomplete frame if full
                while (_frames.Count >= MaxInFlightFrames)
                {
                    uint oldestId = 0;
                    bool found = false;
                    foreach (uint existingId in _frames.Keys)
                    {
                        if (!found || (int)(existingId - oldestId) < 0)
                        {
                            oldestId = existingId;
                            found = true;
                        }
                    }
                    if (!found) break;
                    _frames.Remove(oldestId);
                    _awaitingKeyframe = true;
                    droppedCount++;
                }

                long nowTick = Environment.TickCount64;
                assembly = new FrameAssembly
                {
                    FrameId = frameId,
                    PtsMs = ptsMs,
                    IsKeyframe = isKeyframe,
                    Codec = codec,
                    FragCount = fragCount,
                    FecGroupSize = fecGroupSize,
                    InterleavedFec = interleavedFec,
                    CreatedAtTick = nowTick,
                    LastPacketTick = nowTick,
                    Fragments = new byte[]?[fragCount],
                };
                _frames[frameId] = assembly;

                // Immediate Gap & Tail-Fragment NACK: when frameId jumps past expected (_lastCompletedFrameId + 1),
                // immediately NACK missing tail fragments of older in-flight frames (once idle >= 15ms) OR whole
                // missing 1-packet frames (count=0) so they recover in 1 RTT (~10ms) instead of keyframe freezing!
                if (_hasCompletedFrame && !_awaitingKeyframe && _udp != null && _token != null)
                {
                    int gap = unchecked((int)(frameId - _lastCompletedFrameId));
                    if (gap > 1 && gap <= 5)
                    {
                        for (int step = 1; step < gap; step++)
                        {
                            uint missingFrameId = unchecked(_lastCompletedFrameId + (uint)step);
                            if (_frames.TryGetValue(missingFrameId, out var prevAsm))
                            {
                                if (prevAsm.IsComplete || (nowTick - prevAsm.LastPacketTick) < 15) continue;
                                List<byte>? prevMissing = null;
                                for (int fi = 0; fi < prevAsm.FragCount; fi++)
                                {
                                    if (prevAsm.Fragments[fi] != null) continue;
                                    byte fIdx = (byte)fi;
                                    if (prevAsm.NackedFrags != null && prevAsm.NackedFrags.TryGetValue(fIdx, out var info))
                                    {
                                        if (info.Count >= 2 || (nowTick - info.LastTick) < NackRetryCooldownMs) continue;
                                    }
                                    prevMissing ??= new List<byte>();
                                    prevMissing.Add(fIdx);
                                    if (prevMissing.Count >= MaxNackIndices) break;
                                }
                                if (prevMissing != null && prevMissing.Count > 0)
                                {
                                    prevAsm.NackedFrags ??= new Dictionary<byte, (long, byte)>();
                                    foreach (byte fIdx in prevMissing)
                                    {
                                        byte prevCount = prevAsm.NackedFrags.TryGetValue(fIdx, out var info) ? info.Count : (byte)0;
                                        prevAsm.NackedFrags[fIdx] = (nowTick, (byte)(prevCount + 1));
                                    }
                                    _windowNackPackets += prevMissing.Count;
                                    nackPackets ??= new List<byte[]>();
                                    nackPackets.Add(BuildNackPacket(_token, missingFrameId, prevMissing));
                                    nackUdp = _udp;
                                }
                            }
                            else if (_wholeFrameNacked.Add(missingFrameId))
                            {
                                if (_wholeFrameNacked.Count > 64) _wholeFrameNacked.Clear();
                                // Entire small/1-fragment frame was dropped: send count=0 whole-frame NACK!
                                _windowNackPackets++;
                                nackPackets ??= new List<byte[]>();
                                nackPackets.Add(BuildWholeFrameNackPacket(_token, missingFrameId));
                                nackUdp = _udp;
                            }
                        }
                    }
                }
            }

            if (assembly.IsComplete)
            {
                return;
            }

            assembly.LastPacketTick = Environment.TickCount64;

            if (pktType == PacketData)
            {
                _windowRecvPackets++;
                _windowRecvBytes += buf.Length;
                if (fragIndex < assembly.FragCount && assembly.Fragments[fragIndex] == null)
                {
                    assembly.Fragments[fragIndex] = payload;
                    assembly.ReceivedCount++;
                }
            }
            else // PacketFecParity
            {
                if (assembly.FecGroupSize > 0 && payload.Length >= 2)
                {
                    assembly.ParityGroups ??= new Dictionary<int, byte[]>();
                    assembly.ParityGroups[fragIndex] = payload;
                }
            }

            // Attempt 0ms XOR-FEC recovery if any group has parity and exactly 1 missing fragment
            if (assembly.ReceivedCount < assembly.FragCount &&
                assembly.FecGroupSize > 0 &&
                assembly.ParityGroups != null)
            {
                TryRecoverWithFec(assembly);
            }

            if (assembly.ReceivedCount == assembly.FragCount)
            {
                assembly.IsComplete = true;
                UpdateDelayGradientSample(assembly.PtsMs);

                if (assembly.IsKeyframe)
                {
                    // A fresh keyframe resets the decode chain: drop any older incomplete frames
                    _frames.Remove(frameId);
                    List<uint>? stale = null;
                    foreach (uint existingId in _frames.Keys)
                    {
                        if ((int)(existingId - frameId) < 0)
                        {
                            stale ??= new List<uint>();
                            stale.Add(existingId);
                        }
                    }
                    if (stale != null)
                    {
                        foreach (uint id in stale)
                        {
                            _frames.Remove(id);
                        }
                    }

                    _hasCompletedFrame = true;
                    _lastCompletedFrameId = frameId;
                    _awaitingKeyframe = false;

                    completedPackets ??= new List<VideoFramePacket>();
                    completedPackets.Add(new VideoFramePacket(
                        Data: AssembleFrame(assembly),
                        FrameId: assembly.FrameId,
                        PtsMs: assembly.PtsMs,
                        IsKeyframe: true,
                        Codec: assembly.Codec));

                    // Flush any consecutive completed P-frames that arrived right after this keyframe
                    FlushConsecutiveCompletedFrames(ref completedPackets);
                }
                else if (_awaitingKeyframe)
                {
                    // Discard P-frame while awaiting keyframe so decoder never smears against a missing reference
                    _frames.Remove(frameId);
                    _hasCompletedFrame = true;
                    _lastCompletedFrameId = frameId;
                    droppedCount = Math.Max(droppedCount, 1);
                }
                else if (!_hasCompletedFrame || unchecked(frameId - _lastCompletedFrameId) == 1)
                {
                    // Strictly next in-order P-frame: deliver immediately and flush any buffered successors
                    _frames.Remove(frameId);
                    _hasCompletedFrame = true;
                    _lastCompletedFrameId = frameId;

                    completedPackets ??= new List<VideoFramePacket>();
                    completedPackets.Add(new VideoFramePacket(
                        Data: AssembleFrame(assembly),
                        FrameId: assembly.FrameId,
                        PtsMs: assembly.PtsMs,
                        IsKeyframe: false,
                        Codec: assembly.Codec));

                    FlushConsecutiveCompletedFrames(ref completedPackets);
                }
                else
                {
                    // Newer P-frame finished while an older frame (e.g. large scroll frame) is still
                    // awaiting FEC parity or NACK retransmission. Keep it buffered in _frames instead
                    // of prematurely killing the older frame and triggering a keyframe storm!
                }
            }
            else if (pktType == PacketData && _udp != null && _token != null && fragIndex > 0)
            {
                // Smart FEC-aware per-fragment NACK (0x12): avoid spamming NACKs for single
                // out-of-order packets that XOR-FEC is about to recover in 0ms.
                int upper = Math.Min((int)fragIndex, assembly.FragCount);
                List<byte>? missing = null;
                long nowNackTick = Environment.TickCount64;
                for (int i = 0; i < upper; i++)
                {
                    if (assembly.Fragments[i] != null) continue;
                    byte idx = (byte)i;
                    if (assembly.NackedFrags != null && assembly.NackedFrags.TryGetValue(idx, out var info))
                    {
                        if (info.Count >= 2 || (nowNackTick - info.LastTick) < NackRetryCooldownMs) continue;
                    }

                    bool shouldNack = assembly.FecGroupSize == 0;
                    if (!shouldNack && assembly.FecGroupSize > 0)
                    {
                        int groupCount = (assembly.FragCount + assembly.FecGroupSize - 1) / assembly.FecGroupSize;
                        int groupMissing = 0;
                        if (assembly.InterleavedFec)
                        {
                            int g = i % groupCount;
                            for (int j = g; j < assembly.FragCount; j += groupCount)
                            {
                                if (assembly.Fragments[j] == null)
                                {
                                    groupMissing++;
                                    if (groupMissing >= 2) break;
                                }
                            }
                            if (groupMissing >= 2 || fragIndex + 1 >= assembly.FragCount)
                            {
                                shouldNack = true;
                            }
                        }
                        else
                        {
                            int g = i / assembly.FecGroupSize;
                            int start = g * assembly.FecGroupSize;
                            int end = Math.Min(start + assembly.FecGroupSize, assembly.FragCount);
                            for (int j = start; j < end; j++)
                            {
                                if (assembly.Fragments[j] == null)
                                {
                                    groupMissing++;
                                    if (groupMissing >= 2) break;
                                }
                            }
                            if (groupMissing >= 2 || fragIndex >= end)
                            {
                                shouldNack = true;
                            }
                        }
                    }

                    if (shouldNack)
                    {
                        missing ??= new List<byte>();
                        missing.Add(idx);
                        if (missing.Count >= MaxNackIndices) break;
                    }
                }

                if (missing != null && missing.Count > 0)
                {
                    _windowNackPackets += missing.Count;
                    assembly.NackedFrags ??= new Dictionary<byte, (long, byte)>();
                    foreach (byte idx in missing)
                    {
                        byte prevCount = assembly.NackedFrags.TryGetValue(idx, out var info) ? info.Count : (byte)0;
                        assembly.NackedFrags[idx] = (nowNackTick, (byte)(prevCount + 1));
                    }
                    nackPackets ??= new List<byte[]>();
                    nackPackets.Add(BuildNackPacket(_token, frameId, missing));
                    nackUdp = _udp;
                }
            }
        }

        if (nackPackets != null && nackUdp != null)
        {
            foreach (var pkt in nackPackets)
            {
                _ = SendNackAsync(nackUdp, pkt);
            }
        }

        for (int i = 0; i < droppedCount; i++)
        {
            FrameDropped?.Invoke();
        }

        if (completedPackets != null)
        {
            foreach (var pkt in completedPackets)
            {
                FrameReceived?.Invoke(pkt);
            }
        }
    }

    private void FlushConsecutiveCompletedFrames(ref List<VideoFramePacket>? completedPackets)
    {
        while (_hasCompletedFrame && !_awaitingKeyframe)
        {
            uint nextId = unchecked(_lastCompletedFrameId + 1);
            if (!_frames.TryGetValue(nextId, out var next) || !next.IsComplete)
            {
                break;
            }
            _frames.Remove(nextId);
            _wholeFrameNacked.Remove(nextId);
            _lastCompletedFrameId = nextId;
            completedPackets ??= new List<VideoFramePacket>();
            completedPackets.Add(new VideoFramePacket(
                Data: AssembleFrame(next),
                FrameId: next.FrameId,
                PtsMs: next.PtsMs,
                IsKeyframe: next.IsKeyframe,
                Codec: next.Codec));
        }
    }

    /// <summary>
    /// Sends a low-latency encrypted input JSON message over UDP (packetType 0x20),
    /// bypassing WebSocket TCP head-of-line blocking under packet loss.
    /// When <paramref name="redundant"/> is true (discrete clicks/keys/scrolls),
    /// sends a duplicate copy 5ms later with the same inputSeq (server deduplicates via 64-bit mask).
    /// Returns false if UDP input is not active so caller can fall back to WebSocket TCP.
    /// </summary>
    public bool TrySendInput(byte[] utf8Json, bool redundant)
    {
        if (utf8Json == null || utf8Json.Length == 0 || utf8Json.Length > 1400) return false;
        if (!SupportsUdpInput) return false;

        UdpClient? udp;
        byte[]? pkt;
        uint seq = unchecked((uint)Interlocked.Increment(ref _inputSeq));

        lock (_lock)
        {
            if (_disposed || !_connected || !_supportsUdpInput || _udp == null || _token == null)
            {
                return false;
            }
            udp = _udp;
            bool encrypted = _aesGcm != null;
            int totalLen = InputHeaderSize + utf8Json.Length + (encrypted ? GcmTagSize : 0);
            pkt = new byte[totalLen];
            pkt[0] = Magic0;
            pkt[1] = Magic1;
            pkt[2] = ProtocolVersion;
            pkt[3] = PacketInput;
            Buffer.BlockCopy(_token, 0, pkt, 4, 16);
            BinaryPrimitives.WriteUInt32BigEndian(pkt.AsSpan(20, 4), seq);
            pkt[24] = encrypted ? HeaderFlagEncrypted : (byte)0x00;

            if (encrypted)
            {
                Span<byte> nonce = stackalloc byte[12];
                nonce[0] = Magic0;
                nonce[1] = Magic1;
                nonce[2] = PacketInput;
                nonce[3] = 0x00;
                _token.AsSpan(0, 4).CopyTo(nonce.Slice(4, 4));
                pkt.AsSpan(20, 4).CopyTo(nonce.Slice(8, 4));

                try
                {
                    _aesGcm!.Encrypt(
                        nonce,
                        utf8Json,
                        pkt.AsSpan(InputHeaderSize, utf8Json.Length),
                        pkt.AsSpan(InputHeaderSize + utf8Json.Length, GcmTagSize),
                        associatedData: pkt.AsSpan(0, InputHeaderSize));
                }
                catch
                {
                    return false;
                }
            }
            else
            {
                Buffer.BlockCopy(utf8Json, 0, pkt, InputHeaderSize, utf8Json.Length);
            }
        }

        _ = SendInputDatagramAsync(udp, pkt, redundant);
        return true;
    }

    private static async Task SendInputDatagramAsync(UdpClient udp, byte[] pkt, bool redundant)
    {
        try
        {
            await udp.SendAsync(pkt).ConfigureAwait(false);
            if (redundant)
            {
                await Task.Delay(5).ConfigureAwait(false);
                await udp.SendAsync(pkt).ConfigureAwait(false);
            }
        }
        catch { }
    }

    private static async Task SendNackAsync(UdpClient udp, byte[] nackPacket)
    {
        try
        {
            await udp.SendAsync(nackPacket).ConfigureAwait(false);
        }
        catch { }
    }

    private static byte[] BuildWholeFrameNackPacket(byte[] token, uint frameId)
    {
        byte[] pkt = new byte[4 + 16 + 4 + 1];
        pkt[0] = Magic0;
        pkt[1] = Magic1;
        pkt[2] = ProtocolVersion;
        pkt[3] = PacketNack;
        Buffer.BlockCopy(token, 0, pkt, 4, 16);
        BinaryPrimitives.WriteUInt32BigEndian(pkt.AsSpan(20, 4), frameId);
        pkt[24] = 0; // count == 0 -> retransmit all cached fragments of frameId
        return pkt;
    }

    private static byte[] BuildNackPacket(byte[] token, uint frameId, List<byte> missingIndices)
    {
        int count = Math.Min(missingIndices.Count, MaxNackIndices);
        byte[] pkt = new byte[4 + 16 + 4 + 1 + count];
        pkt[0] = Magic0;
        pkt[1] = Magic1;
        pkt[2] = ProtocolVersion;
        pkt[3] = PacketNack;
        Buffer.BlockCopy(token, 0, pkt, 4, 16);
        BinaryPrimitives.WriteUInt32BigEndian(pkt.AsSpan(20, 4), frameId);
        pkt[24] = (byte)count;
        for (int i = 0; i < count; i++)
        {
            pkt[25 + i] = missingIndices[i];
        }
        return pkt;
    }

    private static void TryRecoverWithFec(FrameAssembly assembly)
    {
        int groupSize = assembly.FecGroupSize;
        if (groupSize <= 0 || assembly.ParityGroups == null) return;

        int groupCount = (assembly.FragCount + groupSize - 1) / groupSize;

        foreach (var kvp in assembly.ParityGroups)
        {
            int g = kvp.Key;
            byte[] parityBody = kvp.Value;
            if (parityBody.Length < 2) continue;

            int missingIdx = -1;
            int missingCount = 0;
            int memberCount = 0;

            if (assembly.InterleavedFec)
            {
                if (g < 0 || g >= groupCount) continue;
                for (int i = g; i < assembly.FragCount; i += groupCount)
                {
                    memberCount++;
                    if (assembly.Fragments[i] == null)
                    {
                        missingIdx = i;
                        missingCount++;
                        if (missingCount > 1) break;
                    }
                }
                if (memberCount < 2 || missingCount != 1 || missingIdx < 0) continue;

                ushort recoveredLen = BinaryPrimitives.ReadUInt16BigEndian(parityBody.AsSpan(0, 2));
                for (int i = g; i < assembly.FragCount; i += groupCount)
                {
                    if (i == missingIdx) continue;
                    recoveredLen ^= (ushort)assembly.Fragments[i]!.Length;
                }

                int maxParityPayload = parityBody.Length - 2;
                if (recoveredLen > maxParityPayload) continue;

                byte[] recovered = new byte[recoveredLen];
                Buffer.BlockCopy(parityBody, 2, recovered, 0, recoveredLen);

                for (int i = g; i < assembly.FragCount; i += groupCount)
                {
                    if (i == missingIdx) continue;
                    byte[] other = assembly.Fragments[i]!;
                    int n = Math.Min(recoveredLen, other.Length);
                    for (int b = 0; b < n; b++)
                    {
                        recovered[b] ^= other[b];
                    }
                }

                assembly.Fragments[missingIdx] = recovered;
                assembly.ReceivedCount++;
            }
            else
            {
                int start = g * groupSize;
                if (start >= assembly.FragCount) continue;
                int end = Math.Min(start + groupSize, assembly.FragCount);
                if (end - start < 2) continue;

                for (int i = start; i < end; i++)
                {
                    if (assembly.Fragments[i] == null)
                    {
                        missingIdx = i;
                        missingCount++;
                        if (missingCount > 1) break;
                    }
                }

                if (missingCount != 1 || missingIdx < 0) continue;

                ushort recoveredLen = BinaryPrimitives.ReadUInt16BigEndian(parityBody.AsSpan(0, 2));
                for (int i = start; i < end; i++)
                {
                    if (i == missingIdx) continue;
                    recoveredLen ^= (ushort)assembly.Fragments[i]!.Length;
                }

                int maxParityPayload = parityBody.Length - 2;
                if (recoveredLen > maxParityPayload) continue;

                byte[] recovered = new byte[recoveredLen];
                Buffer.BlockCopy(parityBody, 2, recovered, 0, recoveredLen);

                for (int i = start; i < end; i++)
                {
                    if (i == missingIdx) continue;
                    byte[] other = assembly.Fragments[i]!;
                    int n = Math.Min(recoveredLen, other.Length);
                    for (int b = 0; b < n; b++)
                    {
                        recovered[b] ^= other[b];
                    }
                }

                assembly.Fragments[missingIdx] = recovered;
                assembly.ReceivedCount++;
            }
        }
    }

    private static byte[] AssembleFrame(FrameAssembly assembly)
    {
        int totalLen = 0;
        for (int i = 0; i < assembly.FragCount; i++)
        {
            totalLen += assembly.Fragments[i]!.Length;
        }

        byte[] assembled = new byte[totalLen];
        int offset = 0;
        for (int i = 0; i < assembly.FragCount; i++)
        {
            byte[] frag = assembly.Fragments[i]!;
            Buffer.BlockCopy(frag, 0, assembled, offset, frag.Length);
            offset += frag.Length;
        }
        return assembled;
    }

    private void UpdateDelayGradientSample(uint ptsMs)
    {
        double nowMs = System.Diagnostics.Stopwatch.GetTimestamp() * 1000.0 / System.Diagnostics.Stopwatch.Frequency;
        if (!_hasDelayRef)
        {
            _hasDelayRef = true;
            _prevFeedbackPtsMs = ptsMs;
            _prevFeedbackRecvMs = nowMs;
            return;
        }

        double sendDeltaMs = unchecked((int)(ptsMs - _prevFeedbackPtsMs));
        double recvDeltaMs = nowMs - _prevFeedbackRecvMs;
        _prevFeedbackPtsMs = ptsMs;
        _prevFeedbackRecvMs = nowMs;

        // Ignore idle gaps > 150ms or negative pts wrap so delay gradient tracks active congestion
        if (sendDeltaMs <= 0 || sendDeltaMs > 150.0 || recvDeltaMs < 0 || recvDeltaMs > 300.0)
        {
            _ewmaDelayGradMs *= 0.5;
            return;
        }

        double oneWayDelta = Math.Clamp(recvDeltaMs - sendDeltaMs, -40.0, 100.0);
        _ewmaDelayGradMs = _ewmaDelayGradMs * 0.75 + oneWayDelta * 0.25;
        _ewmaJitterMs = _ewmaJitterMs * 0.85 + Math.Abs(oneWayDelta) * 0.15;
    }

    private byte[]? BuildFeedbackPacketIfActive(byte[] token)
    {
        long nowTick = Environment.TickCount64;
        double delayGradMs;
        double jitterMs;
        int recvPkts;
        int nackPkts;
        long recvBytes;
        long elapsedMs;

        lock (_lock)
        {
            recvPkts = _windowRecvPackets;
            nackPkts = _windowNackPackets;
            recvBytes = _windowRecvBytes;
            delayGradMs = _ewmaDelayGradMs;
            jitterMs = _ewmaJitterMs;
            elapsedMs = Math.Max(50, nowTick - _lastFeedbackSentTick);

            _windowRecvPackets = 0;
            _windowNackPackets = 0;
            _windowRecvBytes = 0;
            _lastFeedbackSentTick = nowTick;
            // Gently decay gradient toward 0 across quiet windows
            if (recvPkts == 0)
            {
                _ewmaDelayGradMs *= 0.5;
                return null;
            }
        }

        int lossPermille = recvPkts > 0 ? Math.Clamp((int)Math.Round(nackPkts * 1000.0 / recvPkts), 0, 1000) : 0;
        short delayGradDeci = (short)Math.Clamp((int)Math.Round(delayGradMs * 10.0), short.MinValue, short.MaxValue);
        ushort jitterDeci = (ushort)Math.Clamp((int)Math.Round(jitterMs * 10.0), 0, ushort.MaxValue);
        ushort recvKbps = (ushort)Math.Clamp((int)Math.Round((recvBytes * 8.0) / elapsedMs), 0, ushort.MaxValue);

        byte[] pkt = new byte[FeedbackPacketSize];
        pkt[0] = Magic0;
        pkt[1] = Magic1;
        pkt[2] = ProtocolVersion;
        pkt[3] = PacketFeedback;
        Buffer.BlockCopy(token, 0, pkt, 4, 16);
        BinaryPrimitives.WriteInt16BigEndian(pkt.AsSpan(20, 2), delayGradDeci);
        BinaryPrimitives.WriteUInt16BigEndian(pkt.AsSpan(22, 2), (ushort)lossPermille);
        BinaryPrimitives.WriteUInt16BigEndian(pkt.AsSpan(24, 2), jitterDeci);
        BinaryPrimitives.WriteUInt16BigEndian(pkt.AsSpan(26, 2), recvKbps);
        return pkt;
    }

    /// Handles strictly video-first UDP audio packet (`0x14`), completely isolated
    /// from video frame tracking (`_lastCompletedFrameId`, `_awaitingKeyframe`, `_frames`).
    private void HandleAudioPacket(byte[] buf)
    {
        if (buf.Length < VideoHeaderSize) return;

        uint seq = BinaryPrimitives.ReadUInt32BigEndian(buf.AsSpan(4, 4));
        byte fragIndex = buf[13];
        ushort payloadLen = BinaryPrimitives.ReadUInt16BigEndian(buf.AsSpan(16, 2));
        bool isEncrypted = (buf[18] & HeaderFlagEncrypted) != 0;
        if (payloadLen == 0) return;

        lock (_lock)
        {
            if (_hasLastAudioSeq && unchecked((int)(seq - _lastAudioSeq)) <= 0)
            {
                return;
            }
        }

        byte[] payload = new byte[payloadLen];
        if (isEncrypted)
        {
            if (VideoHeaderSize + payloadLen + GcmTagSize > buf.Length) return;

            Span<byte> nonce = stackalloc byte[12];
            nonce[0] = Magic0;
            nonce[1] = Magic1;
            nonce[2] = PacketAudio;
            nonce[3] = fragIndex;
            buf.AsSpan(4, 8).CopyTo(nonce.Slice(4, 8)); // seq(BE4) + ptsMs(BE4)

            ReadOnlySpan<byte> aad = buf.AsSpan(0, VideoHeaderSize);
            ReadOnlySpan<byte> ciphertext = buf.AsSpan(VideoHeaderSize, payloadLen);
            ReadOnlySpan<byte> tag = buf.AsSpan(VideoHeaderSize + payloadLen, GcmTagSize);

            lock (_lock)
            {
                if (_aesGcm == null) return;
                try
                {
                    _aesGcm.Decrypt(nonce, ciphertext, tag, payload, associatedData: aad);
                }
                catch (CryptographicException)
                {
                    return;
                }
                catch (ObjectDisposedException)
                {
                    return;
                }
            }
        }
        else
        {
            if (VideoHeaderSize + payloadLen > buf.Length) return;
            Buffer.BlockCopy(buf, VideoHeaderSize, payload, 0, payloadLen);
        }

        lock (_lock)
        {
            if (_hasLastAudioSeq && unchecked((int)(seq - _lastAudioSeq)) <= 0)
            {
                return;
            }
            _hasLastAudioSeq = true;
            _lastAudioSeq = seq;
        }

        AudioFrameReceived?.Invoke(payload);
    }

    private static byte[] BuildControlPacket(byte pktType, byte[] token)
    {
        byte[] pkt = new byte[ControlPacketSize];
        pkt[0] = Magic0;
        pkt[1] = Magic1;
        pkt[2] = ProtocolVersion;
        pkt[3] = pktType;
        Buffer.BlockCopy(token, 0, pkt, 4, 16);
        return pkt;
    }
}
