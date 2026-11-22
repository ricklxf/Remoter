using System;
using System.Buffers;
using System.IO;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Security;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Channels;
using System.Threading.Tasks;

namespace RemoterWinClient;

/// <summary>
/// Pure native .NET 10 WebSocket connection to Remoter-Mac and Remoter-Win agents.
/// Implements P-256 ECDH + AES-256-GCM E2E encryption, self-signed CN=Remoter TLS validation,
/// LAN subnet net_hint detection, high-frequency coalesced send queue, heartbeat/RTT stats,
/// automatic reconnect, and chunked file transfer.
/// </summary>
public sealed class RemoterConnection : IDisposable
{
    private const int MaxReconnects = 5;
    private const int StatsIntervalMs = 2000;
    private const int StaleTimeoutMs = 6000;
    private const int ReceiveBufferSize = 64 * 1024;

    private enum OutboundKind : byte
    {
        RawText,
        CryptoHello,
        ControlJson,
        RawBinary,
        CoalescedMouseMove,
        CoalescedScroll,
    }

    private readonly record struct OutboundItem(OutboundKind Kind, byte[]? Payload = null);

    private readonly record struct PendingMouseMove(double X, double Y, string? Dragging);

    private struct PendingScroll
    {
        public int Dx;
        public int Dy;
        public int? Px;
        public int? Py;
        public bool? IsPrecise;
        public int? Phase;
        public int? MomentumPhase;
    }

    private readonly E2ECrypto _e2e = new();
    private readonly FileTransferClient _fileTransfer;
    private readonly object _stateLock = new();
    private readonly object _coalesceLock = new();

    private ClientWebSocket? _ws;
    private UdpVideoReceiver? _udpReceiver;
    private volatile bool _udpActive;
    private long _lastUdpKeyframeReqTicks;
    private CancellationTokenSource? _lifecycleCts;
    private CancellationTokenSource? _connCts;
    private Channel<OutboundItem>? _sendChannel;
    private Channel<byte[]>? _bulkChannel;
    private SemaphoreSlim? _sendSignal;
    private Task? _connectionTask;

    private ConnectParams? _params;
    private ConnectionState _state = ConnectionState.Idle;
    private VideoCodecType _activeCodec = VideoCodecType.H264;
    private StreamInfo? _streamInfo;

    private volatile bool _intentionalClose;
    private volatile bool _wasStreaming;
    private volatile bool _disposed;
    private volatile bool _e2eSendActive;
    private int _reconnectCount;

    // Coalesced high-frequency input state
    private PendingMouseMove? _pendingMouseMove;
    private bool _mouseMoveQueued;
    private PendingScroll? _pendingScroll;
    private bool _scrollQueued;

    // Clipboard sync state (UU FNV-1a 64-bit anti-loop hashing + Remoter-Client semantics)
    private volatile bool _clipboardEnabled = true;
    private volatile bool _reverseClipboardActive = true;
    private readonly object _clipboardLock = new();
    private ulong _lastSentTextHash;
    private ulong _lastInjectedTextHash;
    private ulong _lastSentImageHash;
    private ulong _lastInjectedImageHash;

    // Stats & heartbeat tracking
    private long _lastRecvTicks;
    private long _pingSentTicks;
    private int _rttMs;
    private int _encodeMs;
    private int _frameCount;
    private long _bytesCount;

    // Server metadata from hello
    public string ServerOs { get; private set; } = "";
    public string ServerComputerName { get; private set; } = "";
    public string ServerModelId { get; private set; } = "";

    public ConnectionState State => _state;
    public VideoCodecType ActiveCodec => _activeCodec;
    public StreamInfo? CurrentStreamInfo => _streamInfo;
    public bool IsConnected => _state == ConnectionState.Streaming || _state == ConnectionState.Authenticating;
    public bool IsEncrypted => _e2e.IsReady;
    public int RttMs => Volatile.Read(ref _rttMs);
    public int EncodeMs => Volatile.Read(ref _encodeMs);
    public FileTransferClient FileTransfer => _fileTransfer;

    /// <summary>
    /// Optional callback supplied by the video decoder to report decode latency (ms) in ClientStats.
    /// </summary>
    public Func<double>? DecodeMsProvider { get; set; }

    // ── Events (invoked on background thread; UI consumers should marshal via BeginInvoke) ──

    public event Action<ConnectionState>? StateChanged;
    public event Action<StreamInfo>? StreamStarted;
    public event Action<VideoFramePacket>? VideoFrameReceived;
    public event Action<AudioFramePacket>? AudioFrameReceived;
    public event Action<VideoCodecType>? CodecChanged;
    public event Action<int, int>? QualityActiveChanged;
    public event Action<ChromaMode>? ChromaActiveChanged;
    public event Action<bool>? HdrActiveChanged;
    public event Action<bool>? ForceCanvasChanged;
    public event Action<CursorShapeInfo>? CursorShapeReceived;
    public event Action<ClipboardData>? ClipboardReceived;
    public event Action<bool>? InputLockChanged;
    public event Action<ClientStats>? StatsUpdated;
    public event Action<ServerStats>? ServerStatsReceived;
    public event Action<FileTransferProgress>? FileTransferProgress;
    public event Action<string, DirEntry[]>? DirListingReceived;
    public event Action<string, string>? AuthSucceeded;
    public event Action<string, string, string>? ServerHelloReceived;
    public event Action<string>? ErrorOccurred;
    public event Action<string>? Disconnected;

    public RemoterConnection(string? downloadDirectory = null)
    {
        _fileTransfer = new FileTransferClient(
            sendJsonBytes: EnqueueControlJson,
            sendBinaryAsync: SendBinaryQueuedAsync,
            downloadDirectory: downloadDirectory);

        _fileTransfer.ProgressChanged += progress => FileTransferProgress?.Invoke(progress);
    }

    // ── Connection Lifecycle ─────────────────────────────────────────────

    public Task ConnectAsync(ConnectParams parameters, CancellationToken ct = default)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        ArgumentNullException.ThrowIfNull(parameters);

        StopCurrentLifecycle();

        _params = parameters;
        _intentionalClose = false;
        _wasStreaming = false;
        _reconnectCount = 0;

        var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        _lifecycleCts = cts;

        _connectionTask = Task.Run(() => ConnectionSupervisorLoopAsync(parameters, cts.Token), cts.Token);
        return Task.CompletedTask;
    }

    public async Task DisconnectAsync()
    {
        _intentionalClose = true;
        _wasStreaming = false;
        _reconnectCount = 0;

        CancellationTokenSource? lifeCts;
        CancellationTokenSource? connCts;
        ClientWebSocket? ws;
        Task? runningTask;

        lock (_stateLock)
        {
            lifeCts = _lifecycleCts;
            _lifecycleCts = null;
            connCts = _connCts;
            _connCts = null;
            ws = _ws;
            _ws = null;
            runningTask = _connectionTask;
            _connectionTask = null;
        }

        _sendChannel?.Writer.TryComplete();
        _bulkChannel?.Writer.TryComplete();
        SignalSender();
        try { connCts?.Cancel(); } catch { }
        try { lifeCts?.Cancel(); } catch { }

        if (ws != null)
        {
            try
            {
                if (ws.State == WebSocketState.Open || ws.State == WebSocketState.CloseReceived)
                {
                    using var closeTimeout = new CancellationTokenSource(500);
                    await ws.CloseOutputAsync(WebSocketCloseStatus.NormalClosure, "Client disconnect", closeTimeout.Token)
                        .ConfigureAwait(false);
                }
            }
            catch { }
            finally
            {
                try { ws.Dispose(); } catch { }
            }
        }

        if (runningTask != null)
        {
            try { await runningTask.ConfigureAwait(false); } catch { }
        }

        connCts?.Dispose();
        lifeCts?.Dispose();
        _e2eSendActive = false;
        _e2e.Reset();
        StopUdpReceiver();
        _fileTransfer.CancelAllDownloads();
        ClearCoalescedInput();

        SetState(ConnectionState.Disconnected);
        Disconnected?.Invoke("Disconnected by user");
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _intentionalClose = true;

        StopCurrentLifecycle();
        _e2e.Dispose();
        _fileTransfer.Dispose();
    }

    private void StopCurrentLifecycle()
    {
        CancellationTokenSource? lifeCts;
        CancellationTokenSource? connCts;
        ClientWebSocket? ws;

        lock (_stateLock)
        {
            lifeCts = _lifecycleCts;
            _lifecycleCts = null;
            connCts = _connCts;
            _connCts = null;
            ws = _ws;
            _ws = null;
            _connectionTask = null;
        }

        _sendChannel?.Writer.TryComplete();
        _bulkChannel?.Writer.TryComplete();
        SignalSender();
        try { connCts?.Cancel(); } catch { }
        try { lifeCts?.Cancel(); } catch { }
        try { ws?.Abort(); } catch { }
        try { ws?.Dispose(); } catch { }
        connCts?.Dispose();
        lifeCts?.Dispose();
        StopUdpReceiver();
    }

    private async Task ConnectionSupervisorLoopAsync(ConnectParams parameters, CancellationToken lifeCt)
    {
        string lastReason = "Connection closed";

        while (!lifeCt.IsCancellationRequested && !_intentionalClose)
        {
            if (_reconnectCount == 0)
            {
                SetState(ConnectionState.Connecting);
            }

            try
            {
                lastReason = await RunSingleSessionAsync(parameters, lifeCt).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (lifeCt.IsCancellationRequested || _intentionalClose)
            {
                return;
            }
            catch (Exception ex)
            {
                string site = ex.TargetSite != null
                    ? $" [{ex.TargetSite.DeclaringType?.Name}.{ex.TargetSite.Name}]"
                    : "";
                lastReason = ex.Message + site;
                if (!_wasStreaming || _reconnectCount == 0)
                {
                    ErrorOccurred?.Invoke(lastReason);
                }
            }

            if (_intentionalClose || lifeCt.IsCancellationRequested)
                return;

            bool canReconnect = _wasStreaming && _reconnectCount < MaxReconnects;
            if (!canReconnect)
            {
                SetState(_wasStreaming ? ConnectionState.Disconnected : ConnectionState.Error);
                Disconnected?.Invoke(lastReason);
                return;
            }

            _reconnectCount++;
            int delayMs = Math.Min(500 * (1 << (_reconnectCount - 1)), 5000);
            SetState(ConnectionState.Reconnecting);

            try
            {
                await Task.Delay(delayMs, lifeCt).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                return;
            }
        }
    }

    private async Task<string> RunSingleSessionAsync(ConnectParams parameters, CancellationToken lifeCt)
    {
        _e2eSendActive = false;
        _e2e.Reset();
        ClearCoalescedInput();
        lock (_clipboardLock)
        {
            _lastSentTextHash = 0;
            _lastInjectedTextHash = 0;
            _lastSentImageHash = 0;
            _lastInjectedImageHash = 0;
        }
        ServerOs = "";
        ServerComputerName = "";
        ServerModelId = "";
        Interlocked.Exchange(ref _frameCount, 0);
        Interlocked.Exchange(ref _bytesCount, 0);
        Volatile.Write(ref _rttMs, 0);
        Volatile.Write(ref _encodeMs, 0);
        Volatile.Write(ref _pingSentTicks, 0);
        Volatile.Write(ref _lastRecvTicks, Environment.TickCount64);

        var uri = parameters.BuildWebSocketUri();
        var ws = new ClientWebSocket();
        ws.Options.KeepAliveInterval = TimeSpan.FromSeconds(15);
        ws.Options.SetBuffer(ReceiveBufferSize, ReceiveBufferSize);
        ws.Options.RemoteCertificateValidationCallback = ValidateRemoterCertificate;

        var connCts = CancellationTokenSource.CreateLinkedTokenSource(lifeCt);
        var sendChannel = Channel.CreateUnbounded<OutboundItem>(new UnboundedChannelOptions
        {
            SingleReader = true,
            SingleWriter = false,
            AllowSynchronousContinuations = false,
        });
        // Low-priority bounded channel for bulk file chunks so uploads apply backpressure
        // and never starve high-priority mouse/keyboard/control packets.
        var bulkChannel = Channel.CreateBounded<byte[]>(new BoundedChannelOptions(8)
        {
            SingleReader = true,
            SingleWriter = false,
            FullMode = BoundedChannelFullMode.Wait,
            AllowSynchronousContinuations = false,
        });
        var sendSignal = new SemaphoreSlim(0);

        lock (_stateLock)
        {
            _ws = ws;
            _connCts = connCts;
            _sendChannel = sendChannel;
            _bulkChannel = bulkChannel;
            _sendSignal = sendSignal;
        }

        try
        {
            using (var connectTimeout = CancellationTokenSource.CreateLinkedTokenSource(connCts.Token))
            {
                connectTimeout.CancelAfter(TimeSpan.FromSeconds(10));
                await ws.ConnectAsync(uri, connectTimeout.Token).ConfigureAwait(false);
            }

            Volatile.Write(ref _lastRecvTicks, Environment.TickCount64);
            SetState(ConnectionState.Authenticating);

            // Start dedicated serialized priority send loop (control/input preempts bulk chunks)
            var sendTask = Task.Run(
                () => SendLoopAsync(ws, sendChannel.Reader, bulkChannel.Reader, sendSignal, connCts.Token),
                connCts.Token);
            var statsTask = Task.Run(() => StatsLoopAsync(ws, connCts.Token), connCts.Token);

            // Match Remoter-Client Connection.ts: PIN auth is sent immediately on WS open
            if (parameters.Mode == ConnectMode.Direct && parameters.AuthMethod == AuthMethod.Pin)
            {
                EnqueueControlJson(ClientMessages.AuthPin(parameters.Pin));
            }

            string closeReason = await ReceiveLoopAsync(ws, connCts.Token).ConfigureAwait(false);

            sendChannel.Writer.TryComplete();
            bulkChannel.Writer.TryComplete();
            try { sendSignal.Release(); } catch { }
            try { connCts.Cancel(); } catch { }

            try { await Task.WhenAll(sendTask, statsTask).ConfigureAwait(false); } catch { }

            return closeReason;
        }
        finally
        {
            sendChannel.Writer.TryComplete();
            bulkChannel.Writer.TryComplete();
            try { connCts.Cancel(); } catch { }

            lock (_stateLock)
            {
                if (ReferenceEquals(_ws, ws)) _ws = null;
                if (ReferenceEquals(_connCts, connCts)) _connCts = null;
                if (ReferenceEquals(_sendChannel, sendChannel)) _sendChannel = null;
                if (ReferenceEquals(_bulkChannel, bulkChannel)) _bulkChannel = null;
                if (ReferenceEquals(_sendSignal, sendSignal)) _sendSignal = null;
            }

            try { ws.Dispose(); } catch { }
            connCts.Dispose();
            sendSignal.Dispose();
            StopUdpReceiver();
        }
    }

    // ── TLS Self-Signed Cert Validation (CN=Remoter) ─────────────────────

    private static bool ValidateRemoterCertificate(
        object sender,
        X509Certificate? certificate,
        X509Chain? chain,
        SslPolicyErrors sslPolicyErrors)
    {
        if (sslPolicyErrors == SslPolicyErrors.None)
            return true;

        if (certificate == null)
            return false;

        X509Certificate2? cert2 = certificate as X509Certificate2;
        bool created = false;
        try
        {
            if (cert2 == null)
            {
                cert2 = new X509Certificate2(certificate);
                created = true;
            }

            string subjectSimple = cert2.GetNameInfo(X509NameType.SimpleName, forIssuer: false);
            string issuerSimple = cert2.GetNameInfo(X509NameType.SimpleName, forIssuer: true);

            if (string.Equals(subjectSimple, "Remoter", StringComparison.OrdinalIgnoreCase) ||
                string.Equals(issuerSimple, "Remoter", StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }

            if (cert2.Subject.Contains("CN=Remoter", StringComparison.OrdinalIgnoreCase) ||
                cert2.Issuer.Contains("CN=Remoter", StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }

            return false;
        }
        catch
        {
            return false;
        }
        finally
        {
            if (created)
                cert2?.Dispose();
        }
    }

    // ── Send & Receive Loops ─────────────────────────────────────────────

    private async Task SendLoopAsync(
        ClientWebSocket ws,
        ChannelReader<OutboundItem> controlReader,
        ChannelReader<byte[]> bulkReader,
        SemaphoreSlim signal,
        CancellationToken ct)
    {
        try
        {
            while (!ct.IsCancellationRequested && ws.State == WebSocketState.Open)
            {
                bool didWork = false;

                // Always drain all high-priority control/input packets first
                while (controlReader.TryRead(out var item))
                {
                    didWork = true;
                    if (ws.State != WebSocketState.Open) return;

                    switch (item.Kind)
                    {
                        case OutboundKind.RawText:
                            if (item.Payload != null)
                            {
                                await ws.SendAsync(item.Payload, WebSocketMessageType.Text, true, ct)
                                    .ConfigureAwait(false);
                            }
                            break;

                        case OutboundKind.CryptoHello:
                            if (item.Payload != null)
                            {
                                await ws.SendAsync(item.Payload, WebSocketMessageType.Text, true, ct)
                                    .ConfigureAwait(false);
                                _e2eSendActive = true;
                            }
                            break;

                        case OutboundKind.ControlJson:
                            if (item.Payload != null)
                            {
                                await SendJsonPayloadAsync(ws, item.Payload, ct).ConfigureAwait(false);
                            }
                            break;

                        case OutboundKind.RawBinary:
                            if (item.Payload != null)
                            {
                                await ws.SendAsync(item.Payload, WebSocketMessageType.Binary, true, ct)
                                    .ConfigureAwait(false);
                            }
                            break;

                        case OutboundKind.CoalescedMouseMove:
                        {
                            PendingMouseMove? move;
                            lock (_coalesceLock)
                            {
                                move = _pendingMouseMove;
                                _pendingMouseMove = null;
                                _mouseMoveQueued = false;
                            }
                            if (move.HasValue)
                            {
                                var json = ClientMessages.MouseMove(move.Value.X, move.Value.Y, move.Value.Dragging);
                                await SendJsonPayloadAsync(ws, json, ct).ConfigureAwait(false);
                            }
                            break;
                        }

                        case OutboundKind.CoalescedScroll:
                        {
                            PendingScroll? scroll;
                            lock (_coalesceLock)
                            {
                                scroll = _pendingScroll;
                                _pendingScroll = null;
                                _scrollQueued = false;
                            }
                            if (scroll.HasValue)
                            {
                                var s = scroll.Value;
                                var json = ClientMessages.MouseScroll(
                                    s.Dx, s.Dy, s.Px, s.Py, s.IsPrecise, s.Phase, s.MomentumPhase);
                                await SendJsonPayloadAsync(ws, json, ct).ConfigureAwait(false);
                            }
                            break;
                        }
                    }
                }

                // Send at most ONE bulk file chunk before re-checking high-priority input
                if (bulkReader.TryRead(out var bulkChunk))
                {
                    didWork = true;
                    if (ws.State != WebSocketState.Open) return;
                    await ws.SendAsync(bulkChunk, WebSocketMessageType.Binary, true, ct)
                        .ConfigureAwait(false);
                    continue;
                }

                if (!didWork)
                {
                    if (controlReader.Completion.IsCompleted && bulkReader.Completion.IsCompleted)
                        return;
                    await signal.WaitAsync(ct).ConfigureAwait(false);
                }
            }
        }
        catch (OperationCanceledException) { }
        catch (WebSocketException) { }
        catch (ObjectDisposedException) { }
    }

    private async Task SendJsonPayloadAsync(ClientWebSocket ws, byte[] utf8Json, CancellationToken ct)
    {
        if (_e2eSendActive && _e2e.IsReady)
        {
            var cipher = _e2e.Encrypt(utf8Json);
            var frame = new byte[1 + cipher.Length];
            frame[0] = FrameType.Encrypted;
            Buffer.BlockCopy(cipher, 0, frame, 1, cipher.Length);
            await ws.SendAsync(frame, WebSocketMessageType.Binary, true, ct).ConfigureAwait(false);
        }
        else
        {
            await ws.SendAsync(utf8Json, WebSocketMessageType.Text, true, ct).ConfigureAwait(false);
        }
    }

    private async Task<string> ReceiveLoopAsync(ClientWebSocket ws, CancellationToken ct)
    {
        byte[] recvBuf = ArrayPool<byte>.Shared.Rent(ReceiveBufferSize);
        using var messageStream = new MemoryStream(ReceiveBufferSize);

        try
        {
            while (!ct.IsCancellationRequested && ws.State == WebSocketState.Open)
            {
                messageStream.SetLength(0);
                ValueWebSocketReceiveResult result;

                do
                {
                    result = await ws.ReceiveAsync(recvBuf.AsMemory(), ct).ConfigureAwait(false);
                    if (result.MessageType == WebSocketMessageType.Close)
                    {
                        string reason = ws.CloseStatusDescription ?? $"Server closed ({ws.CloseStatus})";
                        try
                        {
                            if (ws.State == WebSocketState.CloseReceived)
                            {
                                using var ackCts = new CancellationTokenSource(300);
                                await ws.CloseOutputAsync(WebSocketCloseStatus.NormalClosure, "Ack", ackCts.Token)
                                    .ConfigureAwait(false);
                            }
                        }
                        catch { }
                        return reason;
                    }

                    if (result.Count > 0)
                    {
                        messageStream.Write(recvBuf, 0, result.Count);
                    }
                }
                while (!result.EndOfMessage);

                Volatile.Write(ref _lastRecvTicks, Environment.TickCount64);

                int msgLen = (int)messageStream.Length;
                if (msgLen == 0) continue;

                var msgSpan = messageStream.GetBuffer().AsSpan(0, msgLen);
                if (result.MessageType == WebSocketMessageType.Text)
                {
                    HandleTextMessage(msgSpan);
                }
                else if (result.MessageType == WebSocketMessageType.Binary)
                {
                    HandleBinaryMessage(msgSpan);
                }
            }

            return "WebSocket closed";
        }
        finally
        {
            ArrayPool<byte>.Shared.Return(recvBuf);
        }
    }

    private async Task StatsLoopAsync(ClientWebSocket ws, CancellationToken ct)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromMilliseconds(StatsIntervalMs));
        try
        {
            while (await timer.WaitForNextTickAsync(ct).ConfigureAwait(false))
            {
                if (_state != ConnectionState.Streaming) continue;

                long lastRecv = Volatile.Read(ref _lastRecvTicks);
                if (lastRecv > 0 && Environment.TickCount64 - lastRecv > StaleTimeoutMs)
                {
                    // Stale connection — abort socket to trigger reconnect
                    try { ws.Abort(); } catch { }
                    return;
                }

                int frames = Interlocked.Exchange(ref _frameCount, 0);
                long bytes = Interlocked.Exchange(ref _bytesCount, 0);

                double fps = frames / (StatsIntervalMs / 1000.0);
                int bitrateKbps = (int)Math.Round(bytes * 8.0 / StatsIntervalMs);
                int decodeMs = (int)Math.Round(DecodeMsProvider?.Invoke() ?? 0.0);
                int rttMs = Volatile.Read(ref _rttMs);
                int encodeMs = Volatile.Read(ref _encodeMs);

                Volatile.Write(ref _pingSentTicks, Environment.TickCount64);
                EnqueueControlJson(ClientMessages.Ping());
                EnqueueControlJson(ClientMessages.ClientStatsMsg(Math.Round(fps), rttMs, ""));

                StatsUpdated?.Invoke(new ClientStats(
                    Fps: fps,
                    RttMs: rttMs,
                    BitrateKbps: bitrateKbps,
                    EncodeMs: encodeMs,
                    DecodeMs: decodeMs,
                    Transport: _udpActive ? "UDP" : "TCP",
                    Codec: _activeCodec));
            }
        }
        catch (OperationCanceledException) { }
    }

    // ── Inbound Message Handling ─────────────────────────────────────────

    private void HandleTextMessage(ReadOnlySpan<byte> utf8Json)
    {
        try
        {
            using var doc = JsonDocument.Parse(utf8Json.ToArray());
            RouteServerMessage(ServerMessage.Parse(doc.RootElement));
        }
        catch { /* ignore malformed JSON */ }
    }

    private void HandleBinaryMessage(ReadOnlySpan<byte> data)
    {
        if (data.Length < 1) return;
        byte prefix = data[0];

        if (prefix == FrameType.Encrypted)
        {
            if (data.Length <= 1) return;
            try
            {
                var plain = _e2e.Decrypt(data[1..]);
                using var doc = JsonDocument.Parse(plain);
                RouteServerMessage(ServerMessage.Parse(doc.RootElement));
            }
            catch { /* ignore decrypt failure */ }
            return;
        }

        if (prefix == FrameType.VideoFrame)
        {
            Interlocked.Increment(ref _frameCount);
            Interlocked.Add(ref _bytesCount, data.Length);
            if (BinaryFrames.TryParseVideoFrame(data, _activeCodec, out var videoPacket))
            {
                VideoFrameReceived?.Invoke(videoPacket);
            }
            return;
        }

        if (prefix == FrameType.AudioFrame)
        {
            if (BinaryFrames.TryParseAudioFrame(data, out var audioPacket))
            {
                AudioFrameReceived?.Invoke(audioPacket);
            }
            return;
        }

        if (prefix == FrameType.FileChunk)
        {
            if (BinaryFrames.TryParseFileChunk(data, out var fileId, out var offset, out var chunk))
            {
                _fileTransfer.HandleFileChunk(fileId, offset, chunk);
            }
        }
    }

    private void RouteServerMessage(ServerMessage msg)
    {
        switch (msg)
        {
            case ServerMessage.Hello hello:
                ServerOs = hello.Os;
                ServerComputerName = hello.ComputerName;
                ServerModelId = hello.ModelId;
                ServerHelloReceived?.Invoke(hello.Os, hello.ComputerName, hello.ModelId);

                if (hello.InputLocked.HasValue)
                    InputLockChanged?.Invoke(hello.InputLocked.Value);

                if (!string.IsNullOrEmpty(hello.Pubkey))
                {
                    try
                    {
                        var myPub = _e2e.GenerateKeyPairAndGetPublicKeyBase64();
                        _e2e.DeriveSharedKey(hello.Pubkey);
                        // Send crypto_hello as raw plaintext; SendLoopAsync activates E2E right after it goes out
                        if (_sendChannel?.Writer.TryWrite(new OutboundItem(OutboundKind.CryptoHello, ClientMessages.CryptoHello(myPub))) == true)
                        {
                            SignalSender();
                        }
                    }
                    catch
                    {
                        _e2e.Reset();
                        SendDeferredAuth();
                    }
                }
                else
                {
                    SendDeferredAuth();
                }
                break;

            case ServerMessage.CryptoOk:
                SendDeferredAuth();
                break;

            case ServerMessage.AuthOk authOk:
                if (!string.IsNullOrEmpty(authOk.Token))
                {
                    AuthSucceeded?.Invoke(authOk.Username ?? _params?.Username ?? "", authOk.Token);
                }
                SendNetHint();
                break;

            case ServerMessage.StreamStarted started:
                _wasStreaming = true;
                _reconnectCount = 0;
                _activeCodec = started.Info.Codec;
                _streamInfo = started.Info;
                SetState(ConnectionState.Streaming);
                StreamStarted?.Invoke(started.Info);
                break;

            case ServerMessage.CodecChanged codecChanged:
                _activeCodec = codecChanged.Codec;
                CodecChanged?.Invoke(codecChanged.Codec);
                break;

            case ServerMessage.QualityActive qa:
                QualityActiveChanged?.Invoke(qa.Fps, qa.Bitrate);
                break;

            case ServerMessage.ChromaActive ca:
                ChromaActiveChanged?.Invoke(ca.Mode);
                break;

            case ServerMessage.HdrActive hdr:
                HdrActiveChanged?.Invoke(hdr.Enabled);
                break;

            case ServerMessage.InputLockChanged il:
                InputLockChanged?.Invoke(il.Locked);
                break;

            case ServerMessage.CursorShape cs:
                CursorShapeReceived?.Invoke(cs.Cursor);
                break;

            case ServerMessage.Pong pong:
                long sent = Interlocked.Exchange(ref _pingSentTicks, 0);
                if (sent > 0)
                {
                    Volatile.Write(ref _rttMs, (int)Math.Max(0, Environment.TickCount64 - sent));
                }
                Volatile.Write(ref _encodeMs, pong.EncodeMs);
                break;

            case ServerMessage.ServerStatsMsg serverStats:
                ServerStatsReceived?.Invoke(serverStats.Stats);
                break;

            case ServerMessage.FileStart fs:
                _fileTransfer.HandleFileStart(fs.Id, fs.Name, fs.Size);
                break;

            case ServerMessage.FileEnd fe:
                _fileTransfer.HandleFileEnd(fe.Id);
                break;

            case ServerMessage.DirListing dl:
                DirListingReceived?.Invoke(dl.Path, dl.Entries);
                break;

            case ServerMessage.ClipboardFromTarget cb:
                if (!_reverseClipboardActive) break;
                bool isEcho = false;
                lock (_clipboardLock)
                {
                    if (cb.Data.Text != null)
                    {
                        ulong hash = ProtocolHelpers.ComputeFnv1a64(Encoding.UTF8.GetBytes(cb.Data.Text));
                        if (hash == _lastSentTextHash)
                        {
                            isEcho = true;
                        }
                        else
                        {
                            _lastInjectedTextHash = hash;
                        }
                    }
                    if (!isEcho && cb.Data.ImagePngBytes != null && cb.Data.ImagePngBytes.Length > 0)
                    {
                        ulong hash = ProtocolHelpers.ComputeFnv1a64(cb.Data.ImagePngBytes);
                        if (hash == _lastSentImageHash)
                        {
                            isEcho = true;
                        }
                        else
                        {
                            _lastInjectedImageHash = hash;
                        }
                    }
                }
                if (!isEcho)
                {
                    ClipboardReceived?.Invoke(cb.Data);
                }
                break;

            case ServerMessage.HostDisconnected:
                SetState(ConnectionState.Disconnected);
                Disconnected?.Invoke("Host disconnected");
                break;

            case ServerMessage.ErrorMsg err:
                ErrorOccurred?.Invoke(err.Message);
                if (_state == ConnectionState.Authenticating || _state == ConnectionState.Connecting)
                {
                    SetState(ConnectionState.Error);
                }
                break;

            case ServerMessage.ForceCanvas fc:
                ForceCanvasChanged?.Invoke(fc.Enabled);
                break;

            case ServerMessage.UdpOffer offer:
                HandleUdpOffer(offer);
                break;

            case ServerMessage.UdpActive ua:
                _udpActive = ua.Enabled;
                if (!ua.Enabled)
                {
                    StopUdpReceiver();
                }
                break;

            case ServerMessage.Keepalive:
            case ServerMessage.Unknown:
                break;
        }
    }

    private void HandleUdpOffer(ServerMessage.UdpOffer offer)
    {
        var p = _params;
        if (p == null || p.Mode != ConnectMode.Direct) return;
        if (offer.Port <= 0 || offer.Port > 65535 || string.IsNullOrWhiteSpace(offer.SessionTokenHex)) return;

        byte[] token;
        try
        {
            token = Convert.FromHexString(offer.SessionTokenHex.Trim());
        }
        catch
        {
            return;
        }
        if (token.Length != 16) return;

        string host;
        try
        {
            host = p.BuildWebSocketUri().Host;
        }
        catch
        {
            return;
        }
        if (string.IsNullOrWhiteSpace(host)) return;

        StopUdpReceiver();

        var receiver = new UdpVideoReceiver();
        receiver.ConnectedChanged += connected =>
        {
            _udpActive = connected;
        };
        receiver.FrameReceived += pkt =>
        {
            Volatile.Write(ref _lastRecvTicks, Environment.TickCount64);
            Interlocked.Increment(ref _frameCount);
            Interlocked.Add(ref _bytesCount, pkt.Data.Length);
            VideoFrameReceived?.Invoke(pkt);
        };
        receiver.FrameDropped += () =>
        {
            long now = Environment.TickCount64;
            long prev = Volatile.Read(ref _lastUdpKeyframeReqTicks);
            if (now - prev >= 500 &&
                Interlocked.CompareExchange(ref _lastUdpKeyframeReqTicks, now, prev) == prev)
            {
                SendRequestKeyframe();
            }
        };

        lock (_stateLock)
        {
            if (_disposed || _intentionalClose)
            {
                receiver.Dispose();
                return;
            }
            _udpReceiver = receiver;
        }

        byte[]? aesKey = offer.Encrypted ? _e2e.RawKeyBytes : null;
        try
        {
            receiver.Start(host, offer.Port, token, aesKey);
        }
        catch
        {
            StopUdpReceiver();
        }
    }

    private void StopUdpReceiver()
    {
        UdpVideoReceiver? receiver;
        lock (_stateLock)
        {
            receiver = _udpReceiver;
            _udpReceiver = null;
        }
        _udpActive = false;
        if (receiver != null)
        {
            try { receiver.Dispose(); } catch { }
        }
    }

    private void SendDeferredAuth()
    {
        var p = _params;
        if (p == null || p.Mode != ConnectMode.Direct) return;

        if (p.AuthMethod == AuthMethod.Credentials)
        {
            EnqueueControlJson(ClientMessages.AuthCredentials(p.Username ?? "", p.Password ?? ""));
        }
        else if (p.AuthMethod == AuthMethod.Token)
        {
            EnqueueControlJson(ClientMessages.AuthToken(p.Token ?? ""));
        }
    }

    // ── LAN Subnet Detection (net_hint) ──────────────────────────────────

    private void SendNetHint()
    {
        var p = _params;
        if (p == null || p.Mode != ConnectMode.Direct) return;

        try
        {
            var uri = p.BuildWebSocketUri();
            if (!IPAddress.TryParse(uri.Host, out var targetIp) ||
                targetIp.AddressFamily != AddressFamily.InterNetwork)
            {
                return;
            }

            bool isLan = IsSameIpv4Subnet(targetIp);
            EnqueueControlJson(ClientMessages.NetHint(isLan));
        }
        catch { /* omit hint if network enumeration fails */ }
    }

    private static bool IsSameIpv4Subnet(IPAddress targetIp)
    {
        if (IPAddress.IsLoopback(targetIp))
            return true;

        uint target = IpToUInt32(targetIp);

        foreach (var nic in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (nic.OperationalStatus != OperationalStatus.Up)
                continue;

            IPInterfaceProperties props;
            try { props = nic.GetIPProperties(); }
            catch { continue; }

            foreach (var ua in props.UnicastAddresses)
            {
                if (ua.Address.AddressFamily != AddressFamily.InterNetwork)
                    continue;
                if (ua.IPv4Mask == null)
                    continue;

                uint addr = IpToUInt32(ua.Address);
                uint mask = IpToUInt32(ua.IPv4Mask);
                if (mask != 0 && (addr & mask) == (target & mask))
                    return true;
            }
        }

        return false;
    }

    private static uint IpToUInt32(IPAddress ip)
    {
        Span<byte> bytes = stackalloc byte[4];
        ip.TryWriteBytes(bytes, out _);
        return ((uint)bytes[0] << 24) | ((uint)bytes[1] << 16) | ((uint)bytes[2] << 8) | bytes[3];
    }

    // ── Public Send API (Thread-Safe, Non-Blocking) ──────────────────────

    public void SendMouseMove(double x, double y, string? dragging = null)
    {
        bool shouldQueue = false;
        lock (_coalesceLock)
        {
            _pendingMouseMove = new PendingMouseMove(x, y, dragging);
            if (!_mouseMoveQueued)
            {
                _mouseMoveQueued = true;
                shouldQueue = true;
            }
        }
        if (shouldQueue && _sendChannel?.Writer.TryWrite(new OutboundItem(OutboundKind.CoalescedMouseMove)) == true)
        {
            SignalSender();
        }
    }

    public void SendMouseButton(string button, bool down, double x, double y) =>
        EnqueueControlJson(ClientMessages.MouseButton(button, down, x, y));

    public void SendMouseDoubleClick(string button, double x, double y) =>
        EnqueueControlJson(ClientMessages.MouseDoubleClick(button, x, y));

    public void SendMouseScroll(
        int dx,
        int dy,
        int? px = null,
        int? py = null,
        bool? isPrecise = null,
        int? phase = null,
        int? momentumPhase = null)
    {
        bool shouldQueue = false;
        lock (_coalesceLock)
        {
            if (_pendingScroll.HasValue)
            {
                var cur = _pendingScroll.Value;
                cur.Dx += dx;
                cur.Dy += dy;
                if (px.HasValue) cur.Px = (cur.Px ?? 0) + px.Value;
                if (py.HasValue) cur.Py = (cur.Py ?? 0) + py.Value;
                if (isPrecise.HasValue) cur.IsPrecise = isPrecise.Value;
                if (phase.HasValue) cur.Phase = phase.Value;
                if (momentumPhase.HasValue) cur.MomentumPhase = momentumPhase.Value;
                _pendingScroll = cur;
            }
            else
            {
                _pendingScroll = new PendingScroll
                {
                    Dx = dx,
                    Dy = dy,
                    Px = px,
                    Py = py,
                    IsPrecise = isPrecise,
                    Phase = phase,
                    MomentumPhase = momentumPhase,
                };
            }

            if (!_scrollQueued)
            {
                _scrollQueued = true;
                shouldQueue = true;
            }
        }
        if (shouldQueue && _sendChannel?.Writer.TryWrite(new OutboundItem(OutboundKind.CoalescedScroll)) == true)
        {
            SignalSender();
        }
    }

    public void SendKey(string code, bool down, string[] modifiers) =>
        EnqueueControlJson(ClientMessages.Key(code, down, modifiers));

    public void SendTextInput(string text)
    {
        if (!string.IsNullOrEmpty(text))
            EnqueueControlJson(ClientMessages.TextInput(text));
    }

    public void SendClipboardText(string text)
    {
        if (!_clipboardEnabled || text == null) return;
        ulong hash = ProtocolHelpers.ComputeFnv1a64(Encoding.UTF8.GetBytes(text));
        lock (_clipboardLock)
        {
            if (hash == _lastSentTextHash || hash == _lastInjectedTextHash) return;
            _lastSentTextHash = hash;
        }
        EnqueueControlJson(ClientMessages.ClipboardSet(text));
    }

    public void SendClipboardImage(byte[] pngBytes)
    {
        if (!_clipboardEnabled || pngBytes == null || pngBytes.Length == 0) return;
        ulong hash = ProtocolHelpers.ComputeFnv1a64(pngBytes);
        lock (_clipboardLock)
        {
            if (hash == _lastSentImageHash || hash == _lastInjectedImageHash) return;
            _lastSentImageHash = hash;
        }
        EnqueueControlJson(ClientMessages.ClipboardSetImage(Convert.ToBase64String(pngBytes)));
    }

    public void SendClipboardImageBase64(string base64Png)
    {
        if (!_clipboardEnabled || string.IsNullOrEmpty(base64Png)) return;
        ulong hash;
        try
        {
            hash = ProtocolHelpers.ComputeFnv1a64(Convert.FromBase64String(base64Png));
        }
        catch
        {
            hash = ProtocolHelpers.ComputeFnv1a64(Encoding.UTF8.GetBytes(base64Png));
        }
        lock (_clipboardLock)
        {
            if (hash == _lastSentImageHash || hash == _lastInjectedImageHash) return;
            _lastSentImageHash = hash;
        }
        EnqueueControlJson(ClientMessages.ClipboardSetImage(base64Png));
    }

    public void SetClipboardSyncEnabled(bool enabled)
    {
        _clipboardEnabled = enabled;
    }

    public void SetReverseClipboardActive(bool active)
    {
        _reverseClipboardActive = active;
        EnqueueControlJson(ClientMessages.SetReverseClipboardSync(active));
    }

    public void SendFps(int fps, bool auto = false) =>
        EnqueueControlJson(ClientMessages.Fps(fps, auto));

    public void SendBitrate(int bitrateBps, bool auto = false) =>
        EnqueueControlJson(ClientMessages.Bitrate(bitrateBps, auto));

    public void SendResolution(ResolutionTier tier, int? width = null, int? height = null, double? scale = null) =>
        EnqueueControlJson(ClientMessages.Resolution(tier, width, height, scale));

    public void SendResolution(string tier, int? width = null, int? height = null, double? scale = null)
    {
        var parsed = tier?.Trim().ToLowerInvariant() switch
        {
            "match" => ResolutionTier.Match,
            "1080"  => ResolutionTier.Res1080,
            "2k"    => ResolutionTier.Res2K,
            _       => ResolutionTier.Native,
        };
        EnqueueControlJson(ClientMessages.Resolution(parsed, width, height, scale));
    }

    public void SendChroma(ChromaMode mode) =>
        EnqueueControlJson(ClientMessages.Chroma(mode));

    public void SendChroma(string mode) =>
        EnqueueControlJson(ClientMessages.Chroma(ProtocolHelpers.ParseChroma(mode)));

    public void SendHdr(bool enabled) =>
        EnqueueControlJson(ClientMessages.Hdr(enabled));

    public void SendLowLatency(bool enabled) =>
        EnqueueControlJson(ClientMessages.LowLatency(enabled));

    public void SendSetCodec(VideoCodecType codec) =>
        EnqueueControlJson(ClientMessages.SetCodec(codec));

    public void SendCodecCaps(string[] codecs) =>
        EnqueueControlJson(ClientMessages.CodecCaps(codecs));

    public void SendSetAudio(bool enabled) =>
        EnqueueControlJson(ClientMessages.SetAudio(enabled));

    public void SendSetMuted(bool muted) =>
        EnqueueControlJson(ClientMessages.SetMuted(muted));

    public void SendSetPrivacyScreen(bool enabled) =>
        EnqueueControlJson(ClientMessages.SetPrivacyScreen(enabled));

    public void SendInputLock(bool locked) =>
        EnqueueControlJson(ClientMessages.SetInputLock(locked));

    public void SendSetInputEnabled(bool enabled) =>
        EnqueueControlJson(ClientMessages.SetInputEnabled(enabled));

    public void SendSetDisplay(uint displayId) =>
        EnqueueControlJson(ClientMessages.SetDisplay(displayId));

    public void SendRequestKeyframe() =>
        EnqueueControlJson(ClientMessages.RequestKeyframe());

    public void SendCtrlAltDel() =>
        EnqueueControlJson(ClientMessages.CtrlAltDel());

    public void SendLockScreen() =>
        EnqueueControlJson(ClientMessages.LockScreen());

    public void SendLogout() =>
        EnqueueControlJson(ClientMessages.Logout());

    public void SendRestart() =>
        EnqueueControlJson(ClientMessages.Restart());

    public void SendListDir(string path) =>
        EnqueueControlJson(ClientMessages.ListDir(path));

    public void SendRequestFile(string remotePath) =>
        EnqueueControlJson(ClientMessages.RequestFile(remotePath));

    public Task UploadFileAsync(string localFilePath, CancellationToken ct = default) =>
        _fileTransfer.UploadFileAsync(localFilePath, ct);

    // ── Queue Helpers ────────────────────────────────────────────────────

    private void EnqueueControlJson(byte[] utf8Json)
    {
        if (_sendChannel?.Writer.TryWrite(new OutboundItem(OutboundKind.ControlJson, utf8Json)) == true)
        {
            SignalSender();
        }
    }

    private async ValueTask SendBinaryQueuedAsync(byte[] data, CancellationToken ct)
    {
        var writer = _bulkChannel?.Writer;
        if (writer == null)
            throw new InvalidOperationException("Not connected.");
        await writer.WriteAsync(data, ct).ConfigureAwait(false);
        SignalSender();
    }

    private void SignalSender()
    {
        var signal = _sendSignal;
        if (signal == null) return;
        try { signal.Release(); }
        catch (ObjectDisposedException) { }
        catch (SemaphoreFullException) { }
    }

    private void ClearCoalescedInput()
    {
        lock (_coalesceLock)
        {
            _pendingMouseMove = null;
            _mouseMoveQueued = false;
            _pendingScroll = null;
            _scrollQueued = false;
        }
    }

    private void SetState(ConnectionState next)
    {
        if (_state == next) return;
        _state = next;
        StateChanged?.Invoke(next);
    }
}
