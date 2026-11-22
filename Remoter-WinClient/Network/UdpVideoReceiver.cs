using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.Net.Sockets;
using System.Threading;
using System.Threading.Tasks;

namespace RemoterWinClient;

/// <summary>
/// Direct low-latency UDP video receiver with 0ms XOR-FEC single-packet recovery
/// and automatic fallback to WebSocket TCP when UDP handshake times out.
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

    private const int ControlPacketSize = 20;
    private const int VideoHeaderSize = 20;
    private const int MaxInFlightFrames = 4;
    private const int ReceiveBufferBytes = 4 * 1024 * 1024;
    private const int HelloRetryCount = 3;
    private const int HelloIntervalMs = 100;
    private const int HandshakeTimeoutMs = 600;
    private const int KeepaliveIntervalMs = 2000;

    private sealed class FrameAssembly
    {
        public uint FrameId;
        public uint PtsMs;
        public bool IsKeyframe;
        public VideoCodecType Codec;
        public int FragCount;
        public int FecGroupSize;
        public byte[]?[] Fragments = Array.Empty<byte[]?>();
        public int ReceivedCount;
        public Dictionary<int, byte[]>? ParityGroups;
    }

    private readonly object _lock = new();
    private readonly Dictionary<uint, FrameAssembly> _frames = new();

    private UdpClient? _udp;
    private CancellationTokenSource? _cts;
    private byte[]? _token;
    private bool _connected;
    private bool _hasCompletedFrame;
    private uint _lastCompletedFrameId;
    private bool _disposed;

    public bool IsConnected => Volatile.Read(ref _connected);

    public event Action<bool>? ConnectedChanged;
    public event Action<VideoFramePacket>? FrameReceived;
    public event Action? FrameDropped;

    public void Start(string host, int port, byte[] token)
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
            _connected = false;
            _hasCompletedFrame = false;
            _lastCompletedFrameId = 0;
            _frames.Clear();

            var udp = new UdpClient();
            udp.Client.ReceiveBufferSize = ReceiveBufferBytes;
            udp.Connect(host, port);

            var cts = new CancellationTokenSource();
            _udp = udp;
            _cts = cts;

            _ = Task.Run(() => ReceiveLoopAsync(udp, cts.Token), cts.Token);
            _ = Task.Run(() => HandshakeAndKeepaliveLoopAsync(udp, _token, cts.Token), cts.Token);
        }
    }

    public void Stop()
    {
        UdpClient? udp;
        CancellationTokenSource? cts;
        bool wasConnected;

        lock (_lock)
        {
            udp = _udp;
            _udp = null;
            cts = _cts;
            _cts = null;
            wasConnected = _connected;
            _connected = false;
            _frames.Clear();
        }

        try { cts?.Cancel(); } catch { }
        try { udp?.Close(); } catch { }
        try { udp?.Dispose(); } catch { }
        try { cts?.Dispose(); } catch { }

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

    private async Task HandshakeAndKeepaliveLoopAsync(UdpClient udp, byte[] token, CancellationToken ct)
    {
        byte[] helloPkt = BuildControlPacket(PacketHello, token);
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

            // Wait remaining time up to 600ms total for HELLO_ACK
            while (!Volatile.Read(ref _connected) && !ct.IsCancellationRequested)
            {
                long elapsed = Environment.TickCount64 - startTick;
                if (elapsed >= HandshakeTimeoutMs)
                {
                    // Handshake timed out — stop cleanly so WebSocket TCP continues uninterrupted
                    Stop();
                    return;
                }
                int waitMs = (int)Math.Min(25, HandshakeTimeoutMs - elapsed);
                if (waitMs > 0)
                {
                    await Task.Delay(waitMs, ct).ConfigureAwait(false);
                }
            }

            // Connected: send KEEPALIVE every 2s
            using var timer = new PeriodicTimer(TimeSpan.FromMilliseconds(KeepaliveIntervalMs));
            while (await timer.WaitForNextTickAsync(ct).ConfigureAwait(false))
            {
                if (!Volatile.Read(ref _connected)) return;
                await udp.SendAsync(keepalivePkt, ct).ConfigureAwait(false);
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
            lock (_lock)
            {
                if (_token != null && buf.AsSpan(4, 16).SequenceEqual(_token))
                {
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

        if (pktType != PacketData && pktType != PacketFecParity) return;
        if (buf.Length < VideoHeaderSize) return;

        uint frameId = BinaryPrimitives.ReadUInt32BigEndian(buf.AsSpan(4, 4));
        uint ptsMs = BinaryPrimitives.ReadUInt32BigEndian(buf.AsSpan(8, 4));
        byte flags = buf[12];
        byte fragIndex = buf[13];
        byte fragCount = buf[14];
        byte fecGroupSize = buf[15];
        ushort payloadLen = BinaryPrimitives.ReadUInt16BigEndian(buf.AsSpan(16, 2));

        if (fragCount == 0 || VideoHeaderSize + payloadLen > buf.Length) return;

        bool isKeyframe = (flags & 0x01) != 0;
        VideoCodecType codec = (flags & 0x02) != 0 ? VideoCodecType.H265 : VideoCodecType.H264;
        byte[] payload = new byte[payloadLen];
        Buffer.BlockCopy(buf, VideoHeaderSize, payload, 0, payloadLen);

        VideoFramePacket? completedPacket = null;
        int droppedCount = 0;

        lock (_lock)
        {
            // Drop late packets belonging to already-completed or older frames
            if (_hasCompletedFrame && (int)(frameId - _lastCompletedFrameId) <= 0)
            {
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
                    droppedCount++;
                }

                assembly = new FrameAssembly
                {
                    FrameId = frameId,
                    PtsMs = ptsMs,
                    IsKeyframe = isKeyframe,
                    Codec = codec,
                    FragCount = fragCount,
                    FecGroupSize = fecGroupSize,
                    Fragments = new byte[]?[fragCount],
                };
                _frames[frameId] = assembly;
            }

            if (pktType == PacketData)
            {
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
                byte[] assembled = AssembleFrame(assembly);
                _frames.Remove(frameId);

                // Drop any older incomplete frames
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
                        droppedCount++;
                    }
                }

                _hasCompletedFrame = true;
                _lastCompletedFrameId = frameId;
                completedPacket = new VideoFramePacket(
                    Data: assembled,
                    FrameId: assembly.FrameId,
                    PtsMs: assembly.PtsMs,
                    IsKeyframe: assembly.IsKeyframe,
                    Codec: assembly.Codec);
            }
        }

        for (int i = 0; i < droppedCount; i++)
        {
            FrameDropped?.Invoke();
        }

        if (completedPacket.HasValue)
        {
            FrameReceived?.Invoke(completedPacket.Value);
        }
    }

    private static void TryRecoverWithFec(FrameAssembly assembly)
    {
        int groupSize = assembly.FecGroupSize;
        if (groupSize <= 0 || assembly.ParityGroups == null) return;

        foreach (var kvp in assembly.ParityGroups)
        {
            int g = kvp.Key;
            byte[] parityBody = kvp.Value;
            if (parityBody.Length < 2) continue;

            int start = g * groupSize;
            if (start >= assembly.FragCount) continue;
            int end = Math.Min(start + groupSize, assembly.FragCount);
            if (end - start < 2) continue;

            int missingIdx = -1;
            int missingCount = 0;
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

            // First 2 bytes of parity body = XOR of each fragment's big-endian UInt16 payloadLen
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
