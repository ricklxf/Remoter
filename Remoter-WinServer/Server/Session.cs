using System.Collections.Specialized;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;

namespace RemoterWin;

// Per-client state machine: auth → capture → stream + input handling.
// Mirrors Mac agent Session.swift (same protocol, same frame format).
sealed class Session
{
    private readonly IWsConn         _conn;
    private readonly string         _pin;
    private readonly E2ECrypto      _crypto = new();
    private readonly string         _id     = Guid.NewGuid().ToString();

    private ScreenCapturer?   _capturer;
    private InputController?  _input;
    private FileReceiver?     _fileRecv;
    private H264Encoder?      _encoder;       // null ⇒ JPEG fallback (init failed or unsupported)
    private int               _targetBitrateBps = 8_000_000;
    private WinVideoCodec     _preferredCodec = WinVideoCodec.H264;
    private bool              _manualCodecSelected = false;
    private bool              _useJpeg = false;
    private bool              _lowLatencyZeroBuffer = false;

    private static readonly int[] AutoFpsTiers     = [30, 60, 90, 120];
    private static readonly int[] AutoBitrateTiers = [2_000_000, 4_000_000, 8_000_000, 15_000_000, 25_000_000];

    // Scroll bitrate boost (matches Remoter-MacServer: 1.5x up to 37.5 Mbps for 1.2s)
    private readonly object _scrollBoostLock = new();
    private int  _scrollBoostGen = 0;
    private bool _scrollBoostActive = false;

    private AudioCapturer?    _audioCapturer;
    private AudioEncoder?     _audioEncoder;
    private bool              _audioEnabled = false;
    private bool              _privacyEnabled = false;

    private bool   _authed    = false;
    private bool   _inputEnabled = true;
    private bool   _debugInputLog = true;
    private int    _textCount  = 0;
    private int    _inputLogCount = 0;
    private int    _routeLogCount = 0;
    private uint   _frameId   = 0;
    private DateTime _connectTime;
    private long   _bytesSent = 0;
    private long   _bytesRecv = 0;

    private CancellationTokenSource? _cts;

    // Reverse clipboard sync (Windows host → client)
    private readonly object _clipboardLock = new();
    private System.Threading.Timer? _clipboardTimer;
    private bool  _reverseClipboardEnabled = false;
    private bool  _clipboardBaselineCaptured = false;
    private uint  _lastClipboardSeq = 0;
    private ulong _lastClipboardTextHash = 0;
    private bool  _hasLastClipboardTextHash = false;
    private ulong _lastClipboardImageHash = 0;
    private bool  _hasLastClipboardImageHash = false;
    private string? _lastSentClipboardFilesSig = null;
    private int   _clipboardPollRunning = 0;
    private const int MaxReverseClipboardImageBytes = 4 * 1024 * 1024;

    // Adaptive quality control - 延迟优先配置
    private int    _currentFps = 60;  // 提高默认FPS到60，最大限度减少延迟
    private int    _currentQuality = 50;  // 降低质量到50，提高编码速度
    private long   _lastBytesSent = 0;
    private DateTime _lastCheckTime = DateTime.UtcNow;
    private const long TARGET_BANDWIDTH = 10L * 1024 * 1024; // 提高到10MB/s，适应更高速网络
    private const int MIN_FPS = 30;  // 提高最低FPS到30，确保流畅度
    private const int MAX_FPS = 120;
    private const int MIN_QUALITY = 30;  // 降低最低质量到30，在带宽不足时优先保证低延迟
    private const int MAX_QUALITY = 80;  // 降低最高质量到80，避免过度消耗带宽
    private bool   _cpuLimitReached = false;
    private bool   _adaptiveEnabled = true;
    // Client pinned a fixed fps/bitrate from the quality menu — the built-in
    // bandwidth-adaptive logic must not fight it. Auto mode re-enables it.
    private bool   _manualFps = false;
    private bool   _manualBitrate = false;
    // Triggers encoder rebuild on the capture-loop thread (e.g. H.264 <-> H.265 / JPEG switch).
    private volatile bool _rebuildEncoder = false;

    // Direct UDP 7789 video & input transport state (parity with Remoter-MacServer)
    private byte[]?       _udpSessionToken;
    private volatile bool _usingUdpVideo = false;
    private volatile bool _isClientLan = false;
    private int           _udpCleanBitrateStreak = 0;
    private int           _udpStableAtCapStreak = 0;
    private int?          _udpLearnedCeilingBps = null;
    private long          _udpLossCapSetAtTicks = 0;
    private double        _udpLastLossRatio = 0;
    private int           _udpSevereLossStreak = 0;
    private int           _udpCleanFpsRestoreStreak = 0;
    private int?          _udpSavedFpsBeforeSevere = null;
    private int           _udpDelayOveruseStreak = 0;
    private int           _udpDelayCleanStreak = 0;
    private long          _udpLastGccAdjustTicks = 0;
    private long          _lastKeyframeReqTicks = 0;
    private long          _lastInboundTicks = Environment.TickCount64;
    private int           _sentFrames5s = 0;
    private int           _kfForced5s = 0;
    private int           _kfReq5s = 0;
    private long          _lastSent5sLogTicks = Environment.TickCount64;
    
    // Statistics for overlay
    private int    _frameCount = 0;
    private DateTime _fpsCalcTime = DateTime.UtcNow;
    private double _currentFpsDisplay = 0;
    
    // Active authenticated session registry: immediately reap stale zombie sessions (>=3s idle)
    // on reconnect so old half-open TCP sessions never overlap and compete for bandwidth.
    private static readonly object ActiveSessionsLock = new();
    private static readonly Dictionary<string, Session> ActiveSessions = new(StringComparer.Ordinal);

    private static void RegisterAndReapStaleSessions(Session newSession)
    {
        long nowTicks = Environment.TickCount64;
        List<(Session Stale, double IdleSec)>? staleList = null;
        lock (ActiveSessionsLock)
        {
            ActiveSessions[newSession._id] = newSession;
            List<string>? toRemove = null;
            foreach (var kvp in ActiveSessions)
            {
                if (kvp.Key == newSession._id) continue;
                var existing = kvp.Value;
                double idleSec = (nowTicks - Volatile.Read(ref existing._lastInboundTicks)) / 1000.0;
                if (existing._authed && idleSec >= 3.0)
                {
                    staleList ??= new List<(Session, double)>();
                    staleList.Add((existing, idleSec));
                    toRemove ??= new List<string>();
                    toRemove.Add(kvp.Key);
                }
            }
            if (toRemove != null)
            {
                foreach (var key in toRemove) ActiveSessions.Remove(key);
            }
        }
        if (staleList != null)
        {
            foreach (var (stale, idleSec) in staleList)
            {
                AppLog.Write($"[Session] session_zombie_reaped_on_reconnect idleSec={idleSec:F1} replacedBy={newSession._id[..Math.Min(8, newSession._id.Length)]}");
                try { stale.Close(); } catch { }
            }
        }
    }

    private static void UnregisterActiveSession(string id)
    {
        lock (ActiveSessionsLock)
        {
            ActiveSessions.Remove(id);
        }
    }

    // PIN enabled flag (static, shared across all sessions)
    private static bool _pinEnabled = true;
    
    public Session(IWsConn conn, string pin)
    {
        _conn = conn;
        _pin  = pin;
    }
    
    // Update PIN enabled flag (called by MainForm)
    public static void SetPinEnabled(bool enabled)
    {
        _pinEnabled = enabled;
    }

    public void Start()
    {
        AppLog.Write($"[Session] {_conn.RemoteAddr} connected");
        ConnectionLogger.Shared.LogClientConnected(_id, _conn.RemoteAddr);
        // Send hello with our E2E public key so client initiates ECDH
        SendRaw(new { type = "hello", version = "1.0", os = "Windows",
                      pubkey = _crypto.PublicKeyBase64() });
    }

    public void HandleText(string text)
    {
        Volatile.Write(ref _lastInboundTicks, Environment.TickCount64);
        if (_textCount++ < 5)
            AppLog.Write($"[Session] Rx#{_textCount} {text[..Math.Min(40, text.Length)]}");
        try
        {
            var doc = JsonDocument.Parse(text);
            Route(ClientMsg.Parse(doc.RootElement));
        }
        catch (Exception ex) { AppLog.Write($"[Session] ParseError: {ex.Message}"); }
    }

    public void HandleBinary(byte[] data)
    {
        Volatile.Write(ref _lastInboundTicks, Environment.TickCount64);
        if (data.Length == 0) return;

        // 0xE0 = E2E-encrypted JSON
        if (data[0] == FrameType.Encrypted)
        {
            try
            {
                var plain = _crypto.Decrypt(data[1..]);
                var doc   = JsonDocument.Parse(plain);
                Route(ClientMsg.Parse(doc.RootElement));
            }
            catch (Exception ex) { AppLog.Write($"[Session] Decrypt error: {ex.Message}"); }
            return;
        }

        // File chunk: 0x02 | 16B id | 4B offset BE | data
        if (_authed && data[0] == FrameType.FileChunk && data.Length > 21)
        {
            _bytesRecv += data.Length;
            var fid    = Encoding.UTF8.GetString(data, 1, 16).TrimEnd('\0');
            var offset = (long)((data[17] << 24) | (data[18] << 16) | (data[19] << 8) | data[20]);
            _fileRecv?.Receive(fid, offset, data[21..]);
        }
    }

    public void Close()
    {
        UnregisterActiveSession(_id);
        _cts?.Cancel();
        UnregisterUdpSession();
        StopClipboardMonitor(flush: false);
        StopAudioStream();
        if (_privacyEnabled)
        {
            _privacyEnabled = false;
            PrivacyScreen.SetEnabled(false);
        }

        // 主动断开WebSocket连接
        try
        {
            _conn.Disconnect();
        }
        catch
        {
            // 忽略断开连接时的错误
        }
        
        if (_connectTime != default)
        {
            var secs = (int)(DateTime.UtcNow - _connectTime).TotalSeconds;
            ConnectionLogger.Shared.LogDisconnected(
                _id, secs,
                _bytesSent / 1_048_576.0,
                _bytesRecv / 1_048_576.0);
        }
    }

    // ── Message routing ─────────────────────────────────────────────────

    private void Route(ClientMsg msg)
    {
        // E2E handshake (pre-auth)
        if (msg is ClientMsg.CryptoHello ch)
        {
            try
            {
                _crypto.DeriveSharedKey(ch.Pubkey);
                SendRaw(new { type = "crypto_ok" });
            }
            catch (Exception ex)
            {
                SendRaw(new { type = "error", code = "crypto_failed", message = ex.Message });
            }
            return;
        }

        // PIN auth
        if (msg is ClientMsg.Auth auth)
        {
            // Check if PIN is required
            if (_pinEnabled && auth.Pin != _pin)
            {
                Send(new { type = "error", code = "bad_pin", message = "PIN码错误" });
                return;
            }
            
            _ = auth;
            var pinToken = TokenStore.Generate("__pin__");
            _authed = true;
            AppLog.Write($"[Session] {_conn.RemoteAddr} authenticated (PIN)");
            ConnectionLogger.Shared.LogAuthSuccess(_id);
            Send(new { type = "auth_ok", token = pinToken, username = "__pin__" });
            _ = BeginCaptureAsync().ContinueWith(t =>
            {
                if (t.Exception != null)
                {
                    AppLog.Write($"[Session] Capture task failed: {t.Exception.InnerException?.Message ?? t.Exception.Message}");
                }
            }, TaskScheduler.Default);
            return;
        }

        // OS credential auth
        if (msg is ClientMsg.AuthCredentials creds)
        {
            if (ValidateOsCredentials(creds.Username, creds.Password))
            {
                var token = TokenStore.Generate(creds.Username);
                _authed = true;
                AppLog.Write($"[Session] {_conn.RemoteAddr} authenticated as {creds.Username}");
                ConnectionLogger.Shared.LogAuthSuccess(_id);
                Send(new { type = "auth_ok", token, username = creds.Username });
                _ = BeginCaptureAsync().ContinueWith(t =>
                {
                    if (t.Exception != null)
                    {
                        AppLog.Write($"[Session] Capture task failed: {t.Exception.InnerException?.Message ?? t.Exception.Message}");
                    }
                }, TaskScheduler.Default);
            }
            else
            {
                AppLog.Write($"[Session] {_conn.RemoteAddr} credential auth failed for {creds.Username}");
                Send(new { type = "error", code = "bad_credentials", message = "用户名或密码错误" });
            }
            return;
        }

        // Token auth
        if (msg is ClientMsg.AuthToken tok)
        {
            var username = TokenStore.Lookup(tok.Token);
            if (username != null)
            {
                _authed = true;
                AppLog.Write($"[Session] {_conn.RemoteAddr} token auth as {username}");
                ConnectionLogger.Shared.LogAuthSuccess(_id);
                Send(new { type = "auth_ok" });
                _ = BeginCaptureAsync().ContinueWith(t =>
                {
                    if (t.Exception != null)
                    {
                        AppLog.Write($"[Session] Capture task failed: {t.Exception.InnerException?.Message ?? t.Exception.Message}");
                    }
                }, TaskScheduler.Default);
            }
            else
            {
                Send(new { type = "error", code = "bad_token", message = "Token 无效，请重新登录" });
            }
            return;
        }

        if (!_authed) return;

        // 诊断：记录前 10 条已鉴权消息的类型，确认路由正常工作
        if (_debugInputLog && _routeLogCount++ < 10)
            AppLog.Write($"[Route] #{_routeLogCount} {msg.GetType().Name}");

        switch (msg)
        {
            // ── Input ──────────────────────────────────────────────────
            case ClientMsg.MouseMove m when _inputEnabled:
                if (_debugInputLog && _inputLogCount++ < 3)
                    AppLog.Write($"[Input] MouseMove ({m.X:F3}, {m.Y:F3}) [first {_inputLogCount}/3]");
                _input?.MouseMove(m.X, m.Y); break;

            case ClientMsg.MouseButton m when _inputEnabled:
                AppLog.Write($"[Input] MouseButton {m.Button} down={m.Down}");
                _input?.MouseButton(m.Button, m.Down, m.X, m.Y); break;

            case ClientMsg.MouseDoubleClick m when _inputEnabled:
                AppLog.Write($"[Input] MouseDblClick {m.Button}");
                _input?.MouseDoubleClick(m.Button, m.X, m.Y); break;

            case ClientMsg.MouseScroll m when _inputEnabled:
                if (m.Px is int px && m.Py is int py) _input?.MouseScrollPixels(px, py);
                else _input?.MouseScroll(m.Dx, m.Dy);
                BoostBitrateWhileScrolling();
                break;

            case ClientMsg.KeyEvent k when _inputEnabled:
                AppLog.Write($"[Input] Key {k.Code} down={k.Down}");
                _input?.KeyEvent(k.Code, k.Down, k.Mods); break;

            case ClientMsg.ClipboardSet c:
                lock (_clipboardLock)
                {
                    _lastClipboardTextHash = ComputeFnv1a64(c.Text);
                    _hasLastClipboardTextHash = true;
                }
                SetClipboard(_id, c.Text);
                lock (_clipboardLock)
                {
                    _lastClipboardSeq = GetClipboardSequenceNumber();
                }
                break;

            case ClientMsg.ClipboardSetImage ci:
                if (!string.IsNullOrEmpty(ci.Data))
                {
                    try
                    {
                        var png = Convert.FromBase64String(ci.Data);
                        if (SetClipboardImageFromPng(_id, png, dibHash =>
                        {
                            lock (_clipboardLock)
                            {
                                _lastClipboardImageHash = dibHash;
                                _hasLastClipboardImageHash = true;
                            }
                        }))
                        {
                            lock (_clipboardLock)
                            {
                                _lastClipboardSeq = GetClipboardSequenceNumber();
                            }
                        }
                    }
                    catch { }
                }
                break;

            case ClientMsg.SetReverseClipboardSync r:
                if (r.Enabled) StartClipboardMonitor();
                else StopClipboardMonitor(flush: true);
                break;

            case ClientMsg.ClipboardSetFiles cf:
                HandleClipboardSetFiles(cf.Paths);
                break;

            // ── File transfer ──────────────────────────────────────────
            case ClientMsg.FileStart f:
                if (_fileRecv != null)
                {
                    var (offset, resumed) = _fileRecv.Start(
                        f.Id, f.Name, f.Size, f.RelPath, f.DestDir, f.Resume, f.Purpose);
                    Send(new { type = "file_ack", id = f.Id, offset, resumed });
                }
                break;

            case ClientMsg.FileEnd f:
                if (_fileRecv != null)
                {
                    var finalPath = _fileRecv.Finish(f.Id);
                    Send(new { type = "file_done", id = f.Id, path = finalPath ?? "" });
                }
                break;

            // ── System commands ────────────────────────────────────────
            case ClientMsg.CtrlAltDel:
                AppLog.Write("[Input] CtrlAltDel received");
                SendSAS(); break;

            // 注释掉SetInputEnabled处理，防止Web端禁用输入控制
            // case ClientMsg.SetInputEnabled si:
            //     _inputEnabled = si.Enabled; break;

            case ClientMsg.LockScreen:
                LockWorkStation(); break;

            case ClientMsg.Logout:
                ExitWindowsEx(0x0004, 0); break; // EWX_LOGOFF

            case ClientMsg.Restart:
                AdjustPrivilege();
                ExitWindowsEx(0x0002, 0); break; // EWX_REBOOT

            case ClientMsg.PowerAction pa:
                HandlePowerAction(pa.Action);
                break;

            case ClientMsg.SetMuted m:
                SetMasterMute(m.Muted); break;

            case ClientMsg.SetAudio a:
                if (a.Enabled) StartAudioStream();
                else StopAudioStream();
                break;

            case ClientMsg.SetPrivacyScreen p:
                _privacyEnabled = p.Enabled;
                PrivacyScreen.SetEnabled(p.Enabled);
                break;

            // ── Misc ───────────────────────────────────────────────────
            case ClientMsg.Ping:
                Send(new { type = "pong" }); break;

            case ClientMsg.RequestKeyframe:
                Interlocked.Increment(ref _kfReq5s);
                if (_usingUdpVideo)
                {
                    long nowTicks = Environment.TickCount64;
                    long cooldownMs = _udpLastLossRatio >= 0.03 ? 800 : 400;
                    if (nowTicks - _lastKeyframeReqTicks < cooldownMs) break;
                    _lastKeyframeReqTicks = nowTicks;
                }
                Interlocked.Increment(ref _kfForced5s);
                _encoder?.ForceKeyframe();
                break;

            case ClientMsg.NetHint nh:
                _isClientLan = nh.Lan;
                if (_udpSessionToken is { } tok)
                {
                    UdpVideoServer.Shared.SetFecSuppressionAllowed(tok, nh.Lan);
                }
                AppLog.Write($"[Session] net_hint lan={nh.Lan} (UDP FEC suppression {(nh.Lan ? "allowed" : "disabled for WAN")})");
                break;

            case ClientMsg.QualitySet q:   // legacy clients (≤ v1.0.204) sent fps+bitrate bundled
                _manualFps = true;
                _manualBitrate = true;
                _currentFps = Math.Clamp(q.Fps, 1, MAX_FPS);
                _encoder?.SetFps(_currentFps);
                if (q.Bitrate > 0 && q.Bitrate != _targetBitrateBps)
                {
                    _targetBitrateBps = Math.Clamp(q.Bitrate, 500_000, 50_000_000);
                    _encoder?.SetBitrate(_targetBitrateBps);
                }
                Send(new { type = "quality_active", fps = _currentFps, bitrate = _targetBitrateBps });
                break;

            case ClientMsg.FpsSet f:
                _manualFps = !f.Auto;
                _currentFps = f.Auto ? AutoFpsTiers[^1] : Math.Clamp(f.Fps, 1, MAX_FPS);
                _encoder?.SetFps(_currentFps);
                Send(new { type = "quality_active", fps = _currentFps, bitrate = _targetBitrateBps });
                break;

            case ClientMsg.BitrateSet b:
                _manualBitrate = !b.Auto;
                if (!b.Auto && b.Bitrate > 0)
                {
                    _targetBitrateBps = Math.Clamp(b.Bitrate, 500_000, 50_000_000);
                    _encoder?.SetBitrate(_targetBitrateBps);
                }
                else if (b.Auto)
                {
                    _targetBitrateBps = AutoBitrateTiers[^1];
                    _encoder?.SetBitrate(_targetBitrateBps);
                }
                Send(new { type = "quality_active", fps = _currentFps, bitrate = _targetBitrateBps });
                break;

            case ClientMsg.ResolutionSet r:
                // The Windows capture path (DXGI/GDI) grabs native resolution
                // with no scaler in front of the encoder — honestly unsupported
                // rather than silently wrong.
                AppLog.Write($"[Session] resolution tier '{r.Tier}' (scale={r.Scale}) ignored — Windows agent captures native resolution only");
                break;

            case ClientMsg.ChromaSet:
                // Windows Media Foundation path currently encodes NV12 4:2:0
                Send(new { type = "chroma_active", mode = "420" });
                break;

            case ClientMsg.HdrSet:
                // Windows DXGI capture path is currently SDR
                Send(new { type = "hdr_active", enabled = false });
                break;

            case ClientMsg.LowLatencySet ll:
                _lowLatencyZeroBuffer = ll.Enabled;
                Send(new { type = "force_canvas", enabled = _lowLatencyZeroBuffer });
                if (_lowLatencyZeroBuffer) _encoder?.ForceKeyframe();
                break;

            case ClientMsg.CodecCaps caps:
                if (!_manualCodecSelected && !_useJpeg &&
                    caps.Codecs.Any(c => c.Equals("h265", StringComparison.OrdinalIgnoreCase) ||
                                         c.Equals("hevc", StringComparison.OrdinalIgnoreCase)))
                {
                    if (_preferredCodec != WinVideoCodec.H265)
                    {
                        _preferredCodec = WinVideoCodec.H265;
                        _rebuildEncoder = true;
                        ConnectionLogger.Shared.LogStep(_id, "codec_auto_negotiated", "requested=h265");
                    }
                }
                break;

            case ClientMsg.SetCodec sc:
                _manualCodecSelected = true;
                var reqCodec = sc.Codec.ToLowerInvariant();
                if (reqCodec == "jpeg")
                {
                    if (!_useJpeg)
                    {
                        _useJpeg = true;
                        _rebuildEncoder = true;
                    }
                }
                else
                {
                    var targetCodec = (reqCodec == "h265" || reqCodec == "hevc")
                        ? WinVideoCodec.H265
                        : WinVideoCodec.H264;
                    if (_useJpeg || _preferredCodec != targetCodec)
                    {
                        _useJpeg = false;
                        _preferredCodec = targetCodec;
                        _rebuildEncoder = true;
                    }
                }
                break;

            case ClientMsg.ListDir ld:
                HandleListDir(ld.Path); break;

            case ClientMsg.ListDirRecursive ldr:
                HandleListDirRecursive(ldr.Path); break;

            case ClientMsg.RequestFile rf:
                _ = SendFileAsync(rf.Path, rf.Offset).ContinueWith(t =>
                {
                    if (t.Exception != null)
                    {
                        AppLog.Write($"[Session] SendFileAsync failed: {t.Exception.InnerException?.Message ?? t.Exception.Message}");
                    }
                }, TaskScheduler.Default); break;

            // WebRTC: accept offer but don't set up DataChannel yet
            case ClientMsg.WebRtcOffer:
            case ClientMsg.WebRtcIce:
            case ClientMsg.ClientStats:
                break;
        }
    }

    // ── Capture loop ─────────────────────────────────────────────────────

    private async Task BeginCaptureAsync()
    {
        // 使用更高的初始质量以减少延迟感（客户端解码更快）
        var c = new ScreenCapturer(jpegQuality: _currentQuality);
        try
        {
            c.Initialize();
            _capturer   = c;
            _input      = new InputController(c.Width, c.Height);
            RegisterAndReapStaleSessions(this);
            _fileRecv   = new FileReceiver();
            _connectTime = DateTime.UtcNow;
            _cts        = new CancellationTokenSource();

            string codec = "jpeg";
            if (!_useJpeg)
            {
                try
                {
                    var enc = new H264Encoder();
                    enc.Initialize(c.Width, c.Height, _currentFps, _targetBitrateBps, _preferredCodec, d3d11Device: c.D3D11Device);
                    _encoder = enc;
                    codec = enc.ActiveCodec == WinVideoCodec.H265 ? "h265" : "h264";
                    AppLog.Write($"[Session] H264Encoder ready (hardware={enc.IsHardware}, gpuZeroCopy={enc.IsGpuZeroCopy}, activeCodec={codec})");
                }
                catch (Exception ex)
                {
                    AppLog.Write($"[Session] H264Encoder init failed, falling back to jpeg: {ex.Message}");
                    _encoder = null;
                }
            }

            Send(new { type = "stream_started", width = c.Width, height = c.Height, codec, fps = _currentFps });
            ConnectionLogger.Shared.LogConnected(_id, codec, _crypto.IsReady);

            // Offer direct UDP 7789 video channel (with AES-256-GCM + adaptive XOR-FEC + NACK)
            RegisterUdpSession();

            await CaptureLoopAsync(_cts.Token);
        }
        catch (Exception ex)
        {
            AppLog.Write($"[Session] Capture error: {ex.Message}");
            ConnectionLogger.Shared.LogCaptureError(_id, ex.Message);
            try { Send(new { type = "error", code = "capture_failed", message = ex.Message }); } catch { }
        }
        finally
        {
            // Always dispose here — Close() only cancels the token, never disposes directly
            UnregisterUdpSession();
            c.Dispose();
            _capturer = null;
            _encoder?.Dispose();
            _encoder = null;
        }
    }

    private void RegisterUdpSession()
    {
        var udp = UdpVideoServer.Shared;
        if (udp.ListeningPort <= 0) return;

        UnregisterUdpSession();

        var token = RandomNumberGenerator.GetBytes(UdpVideoServer.TokenLength);
        var keyBytes = _crypto.RawKeyBytes;
        _udpSessionToken = token;
        _usingUdpVideo = false;
        _udpCleanBitrateStreak = 0;

        udp.RegisterSession(
            token: token,
            aesKey: keyBytes,
            onActivated: active =>
            {
                _usingUdpVideo = active;
                Send(new { type = "udp_active", enabled = active });
                if (active)
                {
                    UdpVideoServer.Shared.UpdatePacingBitrate(token, _targetBitrateBps);
                    _encoder?.ForceKeyframe();
                }
                else
                {
                    ScheduleUdpReoffer(8000);
                }
                AppLog.Write($"[Session] Direct UDP video {(active ? "activated" : "deactivated (falling back to WS)")}");
            },
            onLossFeedback: HandleUdpLossFeedback,
            onTransportFeedback: HandleUdpTransportFeedback,
            onInputMessage: HandleUdpInputMessage);

        udp.SetFecSuppressionAllowed(token, _isClientLan);

        SendCurrentUdpOffer();
    }

    private void SendCurrentUdpOffer()
    {
        var udp = UdpVideoServer.Shared;
        var token = _udpSessionToken;
        if (udp.ListeningPort <= 0 || token == null) return;
        string tokenHex = Convert.ToHexString(token).ToLowerInvariant();
        Send(new
        {
            type = "udp_offer",
            port = udp.ListeningPort,
            session_token = tokenHex,
            encrypted = _crypto.RawKeyBytes != null
        });
        AppLog.Write($"[Session] Sent udp_offer port={udp.ListeningPort} encrypted={_crypto.RawKeyBytes != null}");
    }

    private void ScheduleUdpReoffer(int delayMs)
    {
        var ct = _cts?.Token ?? CancellationToken.None;
        _ = Task.Delay(delayMs, ct).ContinueWith(t =>
        {
            if (t.IsCanceled || !_authed || _usingUdpVideo || _udpSessionToken == null) return;
            AppLog.Write($"[Session] udp_reoffer_sent delay={delayMs}ms");
            SendCurrentUdpOffer();
            ScheduleUdpReoffer(20_000);
        }, TaskScheduler.Default);
    }

    private void UnregisterUdpSession()
    {
        var token = Interlocked.Exchange(ref _udpSessionToken, null);
        _usingUdpVideo = false;
        if (token != null)
        {
            UdpVideoServer.Shared.UnregisterSession(token);
        }
    }

    private void HandleUdpInputMessage(string json)
    {
        Volatile.Write(ref _lastInboundTicks, Environment.TickCount64);
        if (!_authed) return;
        try
        {
            using var doc = JsonDocument.Parse(json);
            Route(ClientMsg.Parse(doc.RootElement));
        }
        catch (Exception ex)
        {
            AppLog.Write($"[Session] UDP input parse error: {ex.Message}");
        }
    }

    private void CancelScrollBoost()
    {
        lock (_scrollBoostLock)
        {
            _scrollBoostGen++;
            _scrollBoostActive = false;
        }
    }

    private void ApplyUdpBitrate(int nextBps)
    {
        _targetBitrateBps = nextBps;
        _encoder?.SetBitrate(nextBps);
        if (_udpSessionToken is { } tok)
        {
            UdpVideoServer.Shared.UpdatePacingBitrate(tok, nextBps);
        }
    }

    private void HandleUdpLossFeedback(double lossRatio, ulong sentPackets)
    {
        _udpLastLossRatio = lossRatio;
        if (_encoder == null) return;

        // Extreme-congestion FPS survival mode (6s of >=15% loss -> 30fps; 6s clean -> restore)
        if (!_manualFps)
        {
            if (lossRatio >= 0.15 && sentPackets >= 120)
            {
                _udpCleanFpsRestoreStreak = 0;
                _udpSevereLossStreak++;
                if (_udpSevereLossStreak >= 3 && _currentFps > 30 && _udpSavedFpsBeforeSevere == null)
                {
                    _udpSevereLossStreak = 0;
                    _udpSavedFpsBeforeSevere = _currentFps;
                    int prevFps = _currentFps;
                    _currentFps = 30;
                    _encoder.SetFps(30);
                    AppLog.Write($"[Session] udp_severe_fps dir=down fps=30 prevFps={prevFps} loss={lossRatio:F3} sent={sentPackets}");
                }
            }
            else if (lossRatio < 0.02)
            {
                _udpSevereLossStreak = 0;
                if (_udpSavedFpsBeforeSevere is int saved)
                {
                    _udpCleanFpsRestoreStreak++;
                    if (_udpCleanFpsRestoreStreak >= 3)
                    {
                        _udpCleanFpsRestoreStreak = 0;
                        _udpSavedFpsBeforeSevere = null;
                        _currentFps = saved;
                        _encoder.SetFps(saved);
                        AppLog.Write($"[Session] udp_severe_fps dir=up fps={saved} loss={lossRatio:F3} sent={sentPackets}");
                    }
                }
            }
            else
            {
                _udpSevereLossStreak = 0;
                _udpCleanFpsRestoreStreak = 0;
            }
        }

        if (_manualBitrate) return;

        bool wan = !_isClientLan;
        int hardCeilingBps = wan ? 8_000_000 : 25_000_000;
        int width = _capturer?.Width ?? 1920;
        int floorBps = wan
            ? (width >= 2560 ? 2_500_000 : 2_000_000)
            : (width >= 2560 ? 5_000_000 : 4_000_000);
        ulong minLossPackets = wan ? 120UL : 400UL;
        double lossThreshold = wan ? 0.05 : 0.08;
        long nowTicks = Environment.TickCount64;

        if (lossRatio >= lossThreshold && sentPackets >= minLossPackets)
        {
            CancelScrollBoost();
            _udpCleanBitrateStreak = 0;
            _udpStableAtCapStreak = 0;
            int nextBps = Math.Clamp((int)Math.Round(_targetBitrateBps * 0.75), floorBps, hardCeilingBps);
            int learnedCap = Math.Clamp((int)Math.Round(_targetBitrateBps * 0.80), floorBps, hardCeilingBps);
            _udpLearnedCeilingBps = Math.Max(floorBps, Math.Min(_udpLearnedCeilingBps ?? hardCeilingBps, learnedCap));
            _udpLossCapSetAtTicks = nowTicks;
            ApplyUdpBitrate(nextBps);
            AppLog.Write($"[Session] udp_bitrate_adapt dir=down loss={lossRatio:F3} sent={sentPackets} br={nextBps / 1000}k cap={(_udpLearnedCeilingBps ?? hardCeilingBps) / 1000}k");
        }
        else if (lossRatio < 0.01)
        {
            bool boosting;
            lock (_scrollBoostLock) { boosting = _scrollBoostActive; }
            if (boosting) return;

            ulong minRampPackets = _targetBitrateBps < 4_000_000 ? 10UL : 60UL;
            if (sentPackets < minRampPackets) return;
            int effectiveCeiling = Math.Clamp(_udpLearnedCeilingBps ?? hardCeilingBps, floorBps, hardCeilingBps);

            if (_targetBitrateBps < effectiveCeiling)
            {
                _udpStableAtCapStreak = 0;
                _udpCleanBitrateStreak++;
                if (_udpCleanBitrateStreak >= 3)
                {
                    _udpCleanBitrateStreak = 0;
                    int nextBps = Math.Clamp((int)Math.Round(_targetBitrateBps * 1.20), floorBps, effectiveCeiling);
                    if (nextBps > _targetBitrateBps)
                    {
                        ApplyUdpBitrate(nextBps);
                        AppLog.Write($"[Session] udp_bitrate_adapt dir=up loss={lossRatio:F3} sent={sentPackets} br={nextBps / 1000}k cap={effectiveCeiling / 1000}k");
                    }
                }
            }
            else if (_udpLearnedCeilingBps is int cap)
            {
                _udpCleanBitrateStreak = 0;
                if (nowTicks - _udpLossCapSetAtTicks < 12_000) return;
                _udpStableAtCapStreak++;
                if (_udpStableAtCapStreak >= 3)
                {
                    _udpStableAtCapStreak = 0;
                    int probedCap = Math.Min(hardCeilingBps, (int)Math.Round(cap * 1.25));
                    _udpLearnedCeilingBps = probedCap >= hardCeilingBps ? null : probedCap;
                    if (probedCap > _targetBitrateBps)
                    {
                        ApplyUdpBitrate(probedCap);
                        AppLog.Write($"[Session] udp_bitrate_adapt dir=probe_up loss={lossRatio:F3} sent={sentPackets} br={probedCap / 1000}k cap={(_udpLearnedCeilingBps ?? hardCeilingBps) / 1000}k");
                    }
                }
            }
        }
        else
        {
            _udpCleanBitrateStreak = 0;
            _udpStableAtCapStreak = 0;
        }
    }

    private void HandleUdpTransportFeedback(double delayGradientMs, double lossRatio, double jitterMs, int recvBps)
    {
        Volatile.Write(ref _lastInboundTicks, Environment.TickCount64);
        if (_encoder == null || _manualBitrate) return;

        bool wan = !_isClientLan;
        int hardCeilingBps = wan ? 8_000_000 : 25_000_000;
        int width = _capturer?.Width ?? 1920;
        int floorBps = wan
            ? (width >= 2560 ? 2_500_000 : 2_000_000)
            : (width >= 2560 ? 5_000_000 : 4_000_000);
        long nowTicks = Environment.TickCount64;

        if (delayGradientMs >= 12.0 && recvBps >= 1_000_000)
        {
            _udpDelayCleanStreak = 0;
            _udpDelayOveruseStreak++;
            if (_udpDelayOveruseStreak >= 2 && (nowTicks - _udpLastGccAdjustTicks) >= 1200)
            {
                _udpDelayOveruseStreak = 0;
                _udpLastGccAdjustTicks = nowTicks;
                CancelScrollBoost();
                int nextBps = Math.Clamp((int)Math.Round(_targetBitrateBps * 0.90), floorBps, hardCeilingBps);
                if (nextBps != _targetBitrateBps)
                {
                    ApplyUdpBitrate(nextBps);
                    AppLog.Write($"[Session] udp_gcc_delay dir=down gradMs={delayGradientMs:F1} jitterMs={jitterMs:F1} recvKbps={recvBps / 1000} br={nextBps / 1000}k");
                }
            }
        }
        else if (delayGradientMs < 4.0 && lossRatio < 0.005)
        {
            _udpDelayOveruseStreak = 0;
            if (recvBps < 800_000) return;
            bool boosting;
            lock (_scrollBoostLock) { boosting = _scrollBoostActive; }
            if (boosting) return;
            _udpDelayCleanStreak++;
            int effectiveCeiling = Math.Clamp(_udpLearnedCeilingBps ?? hardCeilingBps, floorBps, hardCeilingBps);
            if (_udpDelayCleanStreak >= 8 && _targetBitrateBps < effectiveCeiling && (nowTicks - _udpLastGccAdjustTicks) >= 1500)
            {
                _udpDelayCleanStreak = 0;
                _udpLastGccAdjustTicks = nowTicks;
                int nextBps = Math.Clamp((int)Math.Round(_targetBitrateBps * 1.08), floorBps, effectiveCeiling);
                if (nextBps != _targetBitrateBps)
                {
                    ApplyUdpBitrate(nextBps);
                    AppLog.Write($"[Session] udp_gcc_delay dir=up gradMs={delayGradientMs:F1} jitterMs={jitterMs:F1} recvKbps={recvBps / 1000} br={nextBps / 1000}k");
                }
            }
        }
        else
        {
            _udpDelayOveruseStreak = 0;
            _udpDelayCleanStreak = 0;
        }
    }

    private async Task CaptureLoopAsync(CancellationToken ct)
    {
        int consecutiveErrors = 0;
        var lastFrameTime = DateTime.UtcNow;
        
        while (!ct.IsCancellationRequested)
        {
            // Adaptive control: adjust FPS and quality based on bandwidth
            AdjustQualityAndFps();
            
            // Calculate frame interval based on current FPS
            var frameInterval = TimeSpan.FromMilliseconds(1000.0 / Math.Max(_currentFps, 1));
            
            // Wait for next frame
            var elapsed = DateTime.UtcNow - lastFrameTime;
            if (elapsed < frameInterval)
            {
                await Task.Delay(frameInterval - elapsed, ct).ConfigureAwait(false);
            }
            lastFrameTime = DateTime.UtcNow;
            
            // Calculate FPS for overlay + 5s telemetry + 15s zombie TCP session reaper
            _frameCount++;
            _sentFrames5s++;
            var now = DateTime.UtcNow;
            if ((now - _fpsCalcTime).TotalSeconds >= 1.0)
            {
                _currentFpsDisplay = _frameCount / (now - _fpsCalcTime).TotalSeconds;
                _frameCount = 0;
                _fpsCalcTime = now;
            }
            long nowTicks5s = Environment.TickCount64;
            if (nowTicks5s - _lastSent5sLogTicks >= 5000)
            {
                double dtSec = Math.Max(0.1, (nowTicks5s - _lastSent5sLogTicks) / 1000.0);
                _lastSent5sLogTicks = nowTicks5s;
                int frames = _sentFrames5s; _sentFrames5s = 0;
                int kfForced = Interlocked.Exchange(ref _kfForced5s, 0);
                int kfReq = Interlocked.Exchange(ref _kfReq5s, 0);
                int capKbps = (_udpLearnedCeilingBps ?? (!_isClientLan ? 8_000_000 : 25_000_000)) / 1000;
                AppLog.Write($"[Session] sent_5s sent={frames} fps={frames / dtSec:F0} transport={(_usingUdpVideo ? "udp" : "ws")} br={_targetBitrateBps / 1000}k cap={capKbps}k loss={_udpLastLossRatio * 100:F1}% kfForced={kfForced} kfReq={kfReq}");

                if (_authed && (nowTicks5s - Volatile.Read(ref _lastInboundTicks)) > 15_000)
                {
                    AppLog.Write("[Session] session_zombie_reaped: no inbound WS/UDP activity for >15s, closing half-open session");
                    Close();
                    break;
                }
            }
            
            // Check if capturer is available
            if (_capturer == null)
            {
                AppLog.Write("[Session] Capturer is null, exiting capture loop");
                break;
            }
            
            // Rebuild encoder on the capture-loop thread that owns it when
            // codec changes (H.264 <-> H.265 or JPEG fallback).
            if (_rebuildEncoder)
            {
                _rebuildEncoder = false;
                if (_capturer != null)
                {
                    if (_useJpeg)
                    {
                        _encoder?.Dispose();
                        _encoder = null;
                        AppLog.Write("[Session] switched to JPEG fallback");
                        Send(new { type = "codec_changed", codec = "jpeg" });
                    }
                    else
                    {
                        try
                        {
                            _encoder?.Dispose();
                            var enc = new H264Encoder();
                            enc.Initialize(_capturer.Width, _capturer.Height, _currentFps, _targetBitrateBps, _preferredCodec, d3d11Device: _capturer.D3D11Device);
                            _encoder = enc;
                            var activeCodec = enc.ActiveCodec == WinVideoCodec.H265 ? "h265" : "h264";
                            AppLog.Write($"[Session] encoder rebuilt: codec={activeCodec} hw={enc.IsHardware} gpuZeroCopy={enc.IsGpuZeroCopy} bitrate={_targetBitrateBps}");
                            Send(new { type = "codec_changed", codec = activeCodec });
                        }
                        catch (Exception ex)
                        {
                            AppLog.Write($"[Session] encoder rebuild failed: {ex.Message} — falling back to JPEG");
                            _encoder = null;
                            Send(new { type = "codec_changed", codec = "jpeg" });
                        }
                    }
                }
            }

            byte[]? payload;
            bool keyframe = true; // every JPEG is a full frame; H.264/HEVC overrides below
            var pts = (uint)(DateTime.UtcNow - _connectTime).TotalMilliseconds;
            try
            {
                if (_encoder != null)
                {
                    if (_encoder.IsGpuZeroCopy)
                    {
                        var gpuTex = _capturer.CaptureGpuTexture(timeoutMs: 1);
                        if (gpuTex != null)
                        {
                            payload = _encoder.EncodeGpuTexture(gpuTex, pts, out keyframe);
                        }
                        else if (_capturer.ShouldEmitStaticGpuRefinement(out var staticTex) && staticTex != null)
                        {
                            payload = _encoder.EncodeGpuRefinementFrame(staticTex, pts, out keyframe);
                        }
                        else
                        {
                            payload = null;
                        }
                    }
                    else
                    {
                        var bgra = _capturer.CaptureBgra(timeoutMs: 1);
                        if (bgra != null)
                        {
                            payload = _encoder.Encode(bgra, pts, out keyframe);
                        }
                        else if (_capturer.ShouldEmitStaticRefinement(out var staticBgra) && staticBgra != null)
                        {
                            payload = _encoder.EncodeRefinementFrame(staticBgra, pts, out keyframe);
                        }
                        else
                        {
                            payload = null;
                        }
                    }
                }
                else
                {
                    payload = _capturer.CaptureJpeg(timeoutMs: 1);
                }
                consecutiveErrors = 0;
            }
            catch (OperationCanceledException)
            {
                // Task was cancelled, exit loop
                break;
            }
            catch (Exception ex)
            {
                consecutiveErrors++;
                AppLog.Write($"[Session] Capture error (x{consecutiveErrors}): {ex.Message}");
                if (consecutiveErrors > 30)
                {
                    AppLog.Write("[Session] Too many consecutive errors, exiting capture loop");
                    break;
                }
                await Task.Delay(200, ct).ConfigureAwait(false);
                continue;
            }

            if (payload == null) continue;

            var fid = _frameId++;
            if (fid == 0) AppLog.Write($"[Session] first frame sent: {payload.Length}B keyframe={keyframe} codec={(_encoder != null ? (_encoder.ActiveCodec == WinVideoCodec.H265 ? "h265" : "h264") : "jpeg")} gpuZeroCopy={_encoder?.IsGpuZeroCopy == true}");

            // Prefer direct UDP 7789 video channel when active (H.264/H.265); falls back to WS if unavailable
            if (_usingUdpVideo && _encoder != null && _udpSessionToken is { } udpTok &&
                UdpVideoServer.Shared.SendVideoFrame(
                    udpTok, fid, pts, payload, keyframe, _encoder.ActiveCodec == WinVideoCodec.H265))
            {
                _bytesSent += payload.Length;
                SendOverlayInfo();
                continue;
            }

            var pkt = FrameBuilder.VideoFramePacket(payload, fid, pts, keyframe);
            _bytesSent += pkt.Length;

            // Send overlay info to client (embedded in frame metadata)
            SendOverlayInfo();

            _ = _conn.SendBinaryAsync(pkt).ContinueWith(
                _ => _cts?.Cancel(),
                CancellationToken.None,
                TaskContinuationOptions.OnlyOnFaulted,
                TaskScheduler.Default);
        }
    }
    
    private void SendOverlayInfo()
    {
        // Send statistics to client for overlay display
        var uploadSpeed = CalculateUploadSpeed();
        Send(new
        {
            type = "stats",
            fps = (int)_currentFpsDisplay,
            uploadSpeed = uploadSpeed,
            quality = _currentQuality
        });
    }
    
    private string CalculateUploadSpeed()
    {
        var now = DateTime.UtcNow;
        var timeDiff = (now - _lastCheckTime).TotalSeconds;
        if (timeDiff <= 0) return "0 KB/s";
        
        var bytesPerSecond = (_bytesSent - _lastBytesSent) / timeDiff;
        _lastBytesSent = _bytesSent;
        _lastCheckTime = now;
        
        if (bytesPerSecond < 1024)
            return $"{bytesPerSecond:F0} B/s";
        else if (bytesPerSecond < 1024 * 1024)
            return $"{bytesPerSecond / 1024:F1} KB/s";
        else
            return $"{bytesPerSecond / (1024 * 1024):F1} MB/s";
    }
    
    // Maps the existing JPEG-quality knob (30..80) onto the AutoBitrateTiers
    // range (2..25 Mbps) unless the client manually pinned a bitrate.
    private void ApplyBitrateFromQuality()
    {
        if (_encoder == null || _manualBitrate) return;
        double t = (double)(_currentQuality - MIN_QUALITY) / (MAX_QUALITY - MIN_QUALITY);
        int minBps = AutoBitrateTiers[0];
        int maxBps = AutoBitrateTiers[^1];
        _targetBitrateBps = (int)(minBps + t * (maxBps - minBps));
        _encoder.SetBitrate(_targetBitrateBps);
    }

    /// Temporarily boosts encoder bitrate by 1.5x (capped at 37.5 Mbps) until
    /// 1.2s after the last scroll event so scrolling text stays crisp (matches
    /// Remoter-MacServer's boostBitrateWhileScrolling).
    private void BoostBitrateWhileScrolling()
    {
        if (_encoder == null) return;
        if (_udpLastLossRatio >= 0.02) return;
        if (!_isClientLan && _udpLearnedCeilingBps != null) return;

        int gen;
        bool starting;
        lock (_scrollBoostLock)
        {
            _scrollBoostGen++;
            gen = _scrollBoostGen;
            starting = !_scrollBoostActive;
            _scrollBoostActive = true;
        }

        if (starting)
        {
            long maxCap = _udpLearnedCeilingBps ?? (!_isClientLan ? 8_000_000L : 37_500_000L);
            int boosted = (int)Math.Min((long)(_targetBitrateBps * 1.5), maxCap);
            if (boosted > _targetBitrateBps)
            {
                _encoder.SetBitrate(boosted);
                if (_udpSessionToken is { } tok) UdpVideoServer.Shared.UpdatePacingBitrate(tok, boosted);
            }
        }

        _ = Task.Delay(1200).ContinueWith(_ =>
        {
            lock (_scrollBoostLock)
            {
                if (gen != _scrollBoostGen) return;
                _scrollBoostActive = false;
            }
            _encoder?.SetBitrate(_targetBitrateBps);
            if (_udpSessionToken is { } tok) UdpVideoServer.Shared.UpdatePacingBitrate(tok, _targetBitrateBps);
        }, TaskScheduler.Default);
    }

    private void AdjustQualityAndFps()
    {
        // 检查CPU限制
        if (_cpuLimitReached)
            return;
        
        var now = DateTime.UtcNow;
        var timeDiff = (now - _lastCheckTime).TotalSeconds;
        if (timeDiff < 3.0) return; // Check every 3 seconds for more stable adjustment
        
        // Calculate current bandwidth
        var bytesDiff = _bytesSent - _lastBytesSent;
        var currentBandwidth = (long)(bytesDiff / timeDiff);
        
        _lastBytesSent = _bytesSent;
        _lastCheckTime = now;
        
        // Adaptive logic: follow user's specified order
        // 1. Increase FPS to 30
        // 2. Increase quality
        // 3. Increase FPS to 60
        // 4. Increase quality to original (100)
        if (currentBandwidth < TARGET_BANDWIDTH * 0.7)
        {
            // Bandwidth usage is low, gradually increase following the specified order
            if (!_manualFps && _currentFps < 30)
            {
                _currentFps += 2; // Increase by 2 each time for faster adaptation
                if (_currentFps > 30) _currentFps = 30;
                AppLog.Write($"[Session] FPS increased to {_currentFps}");
            }
            else if (_currentQuality < MAX_QUALITY)
            {
                _currentQuality += 2; // Increase by 2 each time
                if (_currentQuality > MAX_QUALITY) _currentQuality = MAX_QUALITY;
                _capturer?.SetQuality(_currentQuality);
                ApplyBitrateFromQuality();
                AppLog.Write($"[Session] Quality increased to {_currentQuality}");
            }
            else if (!_manualFps && _currentFps < MAX_FPS)
            {
                _currentFps += 2; // Increase by 2 each time
                if (_currentFps > MAX_FPS) _currentFps = MAX_FPS;
                AppLog.Write($"[Session] FPS increased to {_currentFps}");
            }
        }
        else if (currentBandwidth > TARGET_BANDWIDTH * 1.3)
        {
            // Bandwidth usage is high, gradually decrease (reverse order)
            if (!_manualFps && _currentFps > 30)
            {
                _currentFps -= 2; // Decrease by 2 each time
                if (_currentFps < 30) _currentFps = 30;
                AppLog.Write($"[Session] FPS decreased to {_currentFps}");
            }
            else if (_currentQuality > 50)
            {
                _currentQuality -= 2; // Decrease by 2 each time
                if (_currentQuality < 50) _currentQuality = 50;
                _capturer?.SetQuality(_currentQuality);
                ApplyBitrateFromQuality();
                AppLog.Write($"[Session] Quality decreased to {_currentQuality}");
            }
            else if (!_manualFps && _currentFps > MIN_FPS)
            {
                _currentFps -= 2; // Decrease by 2 each time
                if (_currentFps < MIN_FPS) _currentFps = MIN_FPS;
                AppLog.Write($"[Session] FPS decreased to {_currentFps}");
            }
        }
    }

    // ── JSON helpers ─────────────────────────────────────────────────────

    // Encrypted send (after E2E handshake); plaintext fallback before handshake
    private void Send(object obj)
    {
        var json = JsonSerializer.SerializeToUtf8Bytes(obj);
        if (_crypto.IsReady)
        {
            var enc   = _crypto.Encrypt(json);
            var frame = new byte[1 + enc.Length];
            frame[0]  = FrameType.Encrypted;
            Buffer.BlockCopy(enc, 0, frame, 1, enc.Length);
            _bytesSent += frame.Length;
            _ = _conn.SendBinaryAsync(frame);
        }
        else
        {
            var text = System.Text.Encoding.UTF8.GetString(json);
            _bytesSent += json.Length;
            _ = _conn.SendTextAsync(text);
        }
    }

    // Always plaintext (hello / crypto_ok)
    private void SendRaw(object obj)
    {
        var json = JsonSerializer.SerializeToUtf8Bytes(obj);
        _bytesSent += json.Length;
        _ = _conn.SendTextAsync(System.Text.Encoding.UTF8.GetString(json));
    }
    
    // Get total bytes sent for upload speed calculation
    public long GetTotalBytesSent() => Interlocked.Read(ref _bytesSent);
    
    // Set CPU limit reached flag (called by MainForm)
    public void SetCpuLimitReached(bool reached)
    {
        _cpuLimitReached = reached;
        if (reached)
        {
            AppLog.Write($"[Session] CPU limit reached, pausing adaptive quality increase");
        }
    }
    
    // Set adaptive quality enabled/disabled
    public void SetAdaptiveEnabled(bool enabled)
    {
        _adaptiveEnabled = enabled;
        AppLog.Write($"[Session] Adaptive quality {(enabled ? "enabled" : "disabled")}");
    }
    
    // ── Directory listing ────────────────────────────────────────────────

    private void HandleListDir(string path)
    {
        if (path == "~") path = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var dir = new DirectoryInfo(path);
        if (!dir.Exists) { Send(new { type = "dir_listing", path, entries = Array.Empty<object>() }); return; }

        var entries = dir.EnumerateFileSystemInfos()
            .OrderByDescending(x => x is DirectoryInfo)
            .ThenBy(x => x.Name)
            .Select(x => new
            {
                name     = x.Name,
                size     = x is FileInfo fi ? fi.Length : 0L,
                isDir    = x is DirectoryInfo,
                modified = ((DateTimeOffset)x.LastWriteTimeUtc).ToUnixTimeMilliseconds(),
            })
            .ToArray();
        Send(new { type = "dir_listing", path = dir.FullName, entries });
    }

    private const int MaxRecursiveDirFiles = 2000;

    private void HandleListDirRecursive(string path)
    {
        if (path == "~") path = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var rootDir = new DirectoryInfo(path);
        if (!rootDir.Exists)
        {
            Send(new { type = "dir_tree", root = path, files = Array.Empty<object>() });
            return;
        }

        var files = new List<object>();
        var stack = new Stack<DirectoryInfo>();
        stack.Push(rootDir);

        while (stack.Count > 0 && files.Count < MaxRecursiveDirFiles)
        {
            var current = stack.Pop();
            IEnumerable<FileSystemInfo> items;
            try
            {
                items = current.EnumerateFileSystemInfos();
            }
            catch (UnauthorizedAccessException) { continue; }
            catch (IOException) { continue; }

            foreach (var item in items)
            {
                if (files.Count >= MaxRecursiveDirFiles) break;
                try
                {
                    // Skip symlinks / reparse points to prevent cycles
                    if ((item.Attributes & FileAttributes.ReparsePoint) != 0) continue;

                    if (item is DirectoryInfo subDir)
                    {
                        stack.Push(subDir);
                    }
                    else if (item is FileInfo fi)
                    {
                        var relPath = Path.GetRelativePath(rootDir.FullName, fi.FullName).Replace('\\', '/');
                        files.Add(new
                        {
                            relPath,
                            path = fi.FullName,
                            size = fi.Length,
                        });
                    }
                }
                catch (UnauthorizedAccessException) { }
                catch (IOException) { }
            }
        }

        Send(new { type = "dir_tree", root = rootDir.FullName, files });
    }

    // ── File send (Win → client) ─────────────────────────────────────────

    private async Task SendFileAsync(string path, long startOffset = 0)
    {
        FileStream fs;
        try
        {
            fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite, 64 * 1024, useAsync: true);
        }
        catch { return; }

        await using (fs)
        {
            long totalSize = fs.Length;
            long offset = (startOffset > 0 && startOffset <= totalSize) ? startOffset : 0;
            if (offset > 0)
            {
                fs.Seek(offset, SeekOrigin.Begin);
            }

            var rawId = Guid.NewGuid().ToString("N")[..16];
            var name  = Path.GetFileName(path);
            Send(new { type = "file_start", id = rawId, name, size = totalSize, offset });

            var idBytes = new byte[16];
            var idData  = Encoding.UTF8.GetBytes(rawId);
            Buffer.BlockCopy(idData, 0, idBytes, 0, Math.Min(idData.Length, 16));

            const int CHUNK = 64 * 1024;
            var buf = new byte[CHUNK];
            while (offset < totalSize)
            {
                int read = await fs.ReadAsync(buf, 0, CHUNK);
                if (read <= 0) break;

                uint chunkOffset = (uint)offset;
                var pkt = new byte[1 + 16 + 4 + read];
                pkt[0]  = FrameType.FileChunk;
                Buffer.BlockCopy(idBytes, 0, pkt, 1, 16);
                pkt[17] = (byte)(chunkOffset >> 24);
                pkt[18] = (byte)(chunkOffset >> 16);
                pkt[19] = (byte)(chunkOffset >> 8);
                pkt[20] = (byte)(chunkOffset);
                Buffer.BlockCopy(buf, 0, pkt, 21, read);
                _bytesSent += pkt.Length;
                offset += read;
                await _conn.SendBinaryAsync(pkt);
            }
            Send(new { type = "file_end", id = rawId });
        }
    }

    // ── Clipboard ────────────────────────────────────────────────────────

    // OpenClipboard fails transiently whenever another process (clipboard
    // history, antivirus scanning what just got copied, even Explorer
    // itself) happens to have it open at that instant — this is normal,
    // well-documented Windows behavior, not an error condition. The
    // original code called OpenClipboard once and silently gave up on
    // failure: no retry, no log, paste just silently kept whatever was
    // there before ("还是老的" — still the old content), with nothing in
    // the logs to show a paste was even attempted. Retrying a handful of
    // times with a short sleep is the standard, documented workaround.
    private static bool TryOpenClipboardWithRetry(int attempts = 8, int delayMs = 20)
    {
        for (var i = 0; i < attempts; i++)
        {
            if (OpenClipboard(0)) return true;
            Thread.Sleep(delayMs);
        }
        return false;
    }

    private static void SetClipboard(string sessionId, string text)
    {
        if (!TryOpenClipboardWithRetry())
        {
            ConnectionLogger.Shared.LogStep(sessionId, "clipboard_set_open_failed");
            return;
        }
        try
        {
            EmptyClipboard();
            var bytes = System.Text.Encoding.Unicode.GetBytes(text + "\0");
            var h = GlobalAlloc(GMEM_MOVEABLE, (nuint)bytes.Length);
            if (h == 0) return;
            var p = GlobalLock(h);
            if (p == 0) { GlobalFree(h); return; }
            Marshal.Copy(bytes, 0, (nint)p, bytes.Length);
            GlobalUnlock(h);
            SetClipboardData(CF_UNICODETEXT, h);
            ConnectionLogger.Shared.LogStep(sessionId, "clipboard_set_applied", $"len={text.Length}");
        }
        finally { CloseClipboard(); }
    }

    private static bool SetClipboardImageFromPng(string sessionId, byte[] pngBytes, Action<ulong>? onDibHashReady = null)
    {
        try
        {
            using var pngMs  = new MemoryStream(pngBytes);
            using var bmp    = new System.Drawing.Bitmap(pngMs);
            using var bmpMs  = new MemoryStream();
            bmp.Save(bmpMs, System.Drawing.Imaging.ImageFormat.Bmp);
            var dib = bmpMs.ToArray()[14..]; // strip 14-byte BMP file header
            onDibHashReady?.Invoke(ComputeFnv1a64(dib));

            if (!TryOpenClipboardWithRetry())
            {
                ConnectionLogger.Shared.LogStep(sessionId, "clipboard_set_image_open_failed");
                return false;
            }
            try
            {
                EmptyClipboard();
                var h = GlobalAlloc(GMEM_MOVEABLE, (nuint)dib.Length);
                if (h == 0) return false;
                var p = GlobalLock(h);
                if (p == 0) { GlobalFree(h); return false; }
                Marshal.Copy(dib, 0, (nint)p, dib.Length);
                GlobalUnlock(h);
                SetClipboardData(CF_DIB, h);
                ConnectionLogger.Shared.LogStep(sessionId, "clipboard_set_image_applied", $"bytes={dib.Length}");
                return true;
            }
            finally { CloseClipboard(); }
        }
        catch { return false; }
    }

    // ── Reverse clipboard sync (Windows host → client) ────────────────────

    private void StartClipboardMonitor()
    {
        bool started = false;
        bool needBaseline = false;
        lock (_clipboardLock)
        {
            _reverseClipboardEnabled = true;
            if (_clipboardTimer == null)
            {
                if (!_clipboardBaselineCaptured)
                {
                    _clipboardBaselineCaptured = true;
                    needBaseline = true;
                }
                started = true;
            }
        }

        if (!started) return;

        if (needBaseline)
        {
            var seq = GetClipboardSequenceNumber();
            string? baseFilesSig = null;
            if (IsClipboardFormatAvailable(CF_HDROP) &&
                TryReadClipboardFileDropList(out var baseFiles) &&
                baseFiles.Count > 0)
            {
                baseFilesSig = ComputeClipboardFilesSignature(baseFiles);
            }
            TryReadClipboardSnapshot(out var baseText, out var baseDib);
            lock (_clipboardLock)
            {
                _lastClipboardSeq = seq;
                if (baseFilesSig != null)
                {
                    _lastSentClipboardFilesSig = baseFilesSig;
                }
                if (!string.IsNullOrEmpty(baseText))
                {
                    _lastClipboardTextHash = ComputeFnv1a64(baseText);
                    _hasLastClipboardTextHash = true;
                }
                if (baseDib != null && baseDib.Length > 0)
                {
                    _lastClipboardImageHash = ComputeFnv1a64(baseDib);
                    _hasLastClipboardImageHash = true;
                }
            }
        }

        lock (_clipboardLock)
        {
            if (_reverseClipboardEnabled && _clipboardTimer == null)
            {
                _clipboardTimer = new System.Threading.Timer(
                    _ => CheckAndSendClipboardChanges(),
                    null,
                    dueTime: 500,
                    period: 500);
            }
        }
        ConnectionLogger.Shared.LogStep(_id, "clipboard_monitor_started");
    }

    private void StopClipboardMonitor(bool flush)
    {
        System.Threading.Timer? timerToDispose;
        bool wasEnabled;
        lock (_clipboardLock)
        {
            wasEnabled = _reverseClipboardEnabled;
            timerToDispose = _clipboardTimer;
        }

        if (flush && wasEnabled)
        {
            CheckAndSendClipboardChanges();
        }

        lock (_clipboardLock)
        {
            _reverseClipboardEnabled = false;
            timerToDispose = _clipboardTimer;
            _clipboardTimer = null;
        }

        if (timerToDispose != null)
        {
            try { timerToDispose.Dispose(); } catch { }
            ConnectionLogger.Shared.LogStep(_id, "clipboard_monitor_stopped");
        }
    }

    private void CheckAndSendClipboardChanges()
    {
        if (!_authed) return;
        if (Interlocked.CompareExchange(ref _clipboardPollRunning, 1, 0) != 0) return;
        try
        {
            var seq = GetClipboardSequenceNumber();
            lock (_clipboardLock)
            {
                if (!_reverseClipboardEnabled || seq == _lastClipboardSeq) return;
            }

            // Check for file drop list (CF_HDROP) first so Explorer file copies
            // trigger clipboard_files_from_target instead of plain text/image sync.
            if (IsClipboardFormatAvailable(CF_HDROP))
            {
                if (!TryReadClipboardFileDropList(out var filePaths))
                {
                    // Transient clipboard contention — retry on next poll tick.
                    return;
                }

                var existingPaths = filePaths
                    .Where(p => !string.IsNullOrWhiteSpace(p) && (File.Exists(p) || Directory.Exists(p)))
                    .ToList();

                if (existingPaths.Count > 0)
                {
                    var sig = ComputeClipboardFilesSignature(existingPaths);
                    bool sendFiles = false;
                    lock (_clipboardLock)
                    {
                        if (!_reverseClipboardEnabled) return;
                        _lastClipboardSeq = seq;
                        if (sig != _lastSentClipboardFilesSig)
                        {
                            _lastSentClipboardFilesSig = sig;
                            sendFiles = true;
                        }
                    }

                    if (sendFiles)
                    {
                        var files = existingPaths.Select(p =>
                        {
                            bool isDir = Directory.Exists(p);
                            long size = 0;
                            if (!isDir)
                            {
                                try { size = new FileInfo(p).Length; } catch { }
                            }
                            return new
                            {
                                name = Path.GetFileName(p.TrimEnd('\\', '/')),
                                path = p,
                                size,
                                isDir,
                            };
                        }).ToArray();

                        ConnectionLogger.Shared.LogStep(_id, "clipboard_files_reverse_sent", $"count={files.Length}");
                        Send(new { type = "clipboard_files_from_target", files });
                    }
                    return;
                }
            }

            if (!TryReadClipboardSnapshot(out var text, out var dib))
            {
                // Transient OpenClipboard contention — leave _lastClipboardSeq unchanged so next tick retries.
                return;
            }

            bool sendText = false;
            bool sendImage = false;
            lock (_clipboardLock)
            {
                if (!_reverseClipboardEnabled) return;
                _lastClipboardSeq = seq;

                if (!string.IsNullOrEmpty(text))
                {
                    var textHash = ComputeFnv1a64(text);
                    if (!_hasLastClipboardTextHash || textHash != _lastClipboardTextHash)
                    {
                        _lastClipboardTextHash = textHash;
                        _hasLastClipboardTextHash = true;
                        sendText = true;
                    }
                }
                else if (dib != null && dib.Length > 0)
                {
                    var dibHash = ComputeFnv1a64(dib);
                    if (!_hasLastClipboardImageHash || dibHash != _lastClipboardImageHash)
                    {
                        _lastClipboardImageHash = dibHash;
                        _hasLastClipboardImageHash = true;
                        sendImage = true;
                    }
                }
            }

            if (sendText && text != null)
            {
                ConnectionLogger.Shared.LogStep(_id, "clipboard_reverse_sent", $"len={text.Length}");
                Send(new { type = "clipboard_from_target", text });
            }
            else if (sendImage && dib != null)
            {
                var png = ConvertDibToPng(dib);
                if (png != null && png.Length <= MaxReverseClipboardImageBytes)
                {
                    ConnectionLogger.Shared.LogStep(_id, "clipboard_reverse_sent", $"image bytes={png.Length}");
                    Send(new { type = "clipboard_from_target", image = Convert.ToBase64String(png) });
                }
            }
        }
        catch (Exception ex)
        {
            AppLog.Write($"[Session] Reverse clipboard poll error: {ex.Message}");
        }
        finally
        {
            Interlocked.Exchange(ref _clipboardPollRunning, 0);
        }
    }

    private void HandleClipboardSetFiles(string[] paths)
    {
        var col = new StringCollection();
        var validPaths = new List<string>();
        foreach (var raw in paths)
        {
            if (string.IsNullOrWhiteSpace(raw)) continue;
            string p;
            try { p = Path.GetFullPath(raw); }
            catch { continue; }
            if (File.Exists(p) || Directory.Exists(p))
            {
                col.Add(p);
                validPaths.Add(p);
            }
        }

        if (col.Count > 0)
        {
            var sig = ComputeClipboardFilesSignature(validPaths);
            lock (_clipboardLock)
            {
                _lastSentClipboardFilesSig = sig;
            }

            var ok = RunOnStaThread(() =>
            {
                for (int attempt = 0; attempt < 6; attempt++)
                {
                    try
                    {
                        System.Windows.Forms.Clipboard.SetFileDropList(col);
                        return true;
                    }
                    catch (ExternalException)
                    {
                        if (attempt + 1 < 6) Thread.Sleep(20);
                    }
                }
                return false;
            });

            if (ok)
            {
                lock (_clipboardLock)
                {
                    _lastClipboardSeq = GetClipboardSequenceNumber();
                }
                AppLog.Write($"[Session] Clipboard SetFileDropList succeeded: {col.Count} item(s)");
            }
            else
            {
                AppLog.Write($"[Session] Clipboard SetFileDropList failed for {col.Count} item(s)");
            }
        }

        Send(new { type = "clipboard_files_ready", count = col.Count });
    }

    private static bool TryReadClipboardFileDropList(out List<string> paths)
    {
        paths = new List<string>();
        if (!IsClipboardFormatAvailable(CF_HDROP)) return true;

        var result = RunOnStaThread<(bool ok, List<string> list)>(() =>
        {
            try
            {
                var list = new List<string>();
                if (System.Windows.Forms.Clipboard.ContainsFileDropList())
                {
                    var drop = System.Windows.Forms.Clipboard.GetFileDropList();
                    if (drop != null)
                    {
                        foreach (string? item in drop)
                        {
                            if (!string.IsNullOrWhiteSpace(item))
                            {
                                list.Add(item);
                            }
                        }
                    }
                }
                return (true, list);
            }
            catch (ExternalException)
            {
                return (false, new List<string>());
            }
            catch
            {
                return (true, new List<string>());
            }
        });

        if (!result.ok) return false;
        paths = result.list;
        return true;
    }

    private static T RunOnStaThread<T>(Func<T> func, int timeoutMs = 3000)
    {
        T result = default!;
        Exception? error = null;
        var thread = new Thread(() =>
        {
            try { result = func(); }
            catch (Exception ex) { error = ex; }
        })
        {
            IsBackground = true,
            Name = "Remoter-Clipboard-STA",
        };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        if (!thread.Join(timeoutMs))
        {
            AppLog.Write("[Session] STA clipboard operation timed out");
            return default!;
        }
        if (error != null)
        {
            AppLog.Write($"[Session] STA clipboard error: {error.Message}");
            return default!;
        }
        return result;
    }

    private static string ComputeClipboardFilesSignature(IEnumerable<string> paths)
    {
        var entries = new List<string>();
        foreach (var raw in paths)
        {
            string full;
            try { full = Path.GetFullPath(raw); }
            catch { full = raw; }

            long size = 0;
            long mtime = 0;
            try
            {
                if (Directory.Exists(full))
                {
                    mtime = Directory.GetLastWriteTimeUtc(full).Ticks;
                }
                else if (File.Exists(full))
                {
                    var fi = new FileInfo(full);
                    size = fi.Length;
                    mtime = fi.LastWriteTimeUtc.Ticks;
                }
            }
            catch { }
            entries.Add($"{full}|{size}|{mtime}");
        }
        entries.Sort(StringComparer.Ordinal);
        return string.Join("\n", entries);
    }

    private static bool TryReadClipboardSnapshot(out string? text, out byte[]? dib)
    {
        text = null;
        dib = null;

        bool hasText = IsClipboardFormatAvailable(CF_UNICODETEXT);
        bool hasDib  = !hasText && IsClipboardFormatAvailable(CF_DIB);
        if (!hasText && !hasDib) return true;

        if (!TryOpenClipboardWithRetry(attempts: 4, delayMs: 10)) return false;
        try
        {
            if (hasText)
            {
                var h = GetClipboardData(CF_UNICODETEXT);
                if (h != 0)
                {
                    var p = GlobalLock(h);
                    if (p != 0)
                    {
                        try { text = Marshal.PtrToStringUni((nint)p); }
                        finally { GlobalUnlock(h); }
                    }
                }
            }
            else if (hasDib)
            {
                var h = GetClipboardData(CF_DIB);
                if (h != 0)
                {
                    var rawSize = GlobalSize(h);
                    const nuint maxDibBytes = 32 * 1024 * 1024;
                    if (rawSize > 40 && rawSize <= maxDibBytes)
                    {
                        int size = (int)rawSize;
                        var p = GlobalLock(h);
                        if (p != 0)
                        {
                            try
                            {
                                dib = new byte[size];
                                Marshal.Copy((nint)p, dib, 0, size);
                            }
                            finally { GlobalUnlock(h); }
                        }
                    }
                }
            }
            return true;
        }
        finally
        {
            CloseClipboard();
        }
    }

    private static byte[]? ConvertDibToPng(byte[] dib)
    {
        if (dib.Length <= 40) return null;
        try
        {
            uint biSize        = BitConverter.ToUInt32(dib, 0);
            ushort biBitCount  = BitConverter.ToUInt16(dib, 14);
            uint biCompression = BitConverter.ToUInt32(dib, 16);
            uint biClrUsed     = BitConverter.ToUInt32(dib, 32);

            uint colorTableBytes;
            if (biClrUsed > 0)
                colorTableBytes = biClrUsed * 4u;
            else if (biBitCount <= 8)
                colorTableBytes = (1u << biBitCount) * 4u;
            else if (biCompression == 3u /* BI_BITFIELDS */ && biSize == 40u)
                colorTableBytes = 12u;
            else
                colorTableBytes = 0u;

            uint fileSize = (uint)(14 + dib.Length);
            uint offBits  = 14u + biSize + colorTableBytes;
            if (offBits > fileSize) offBits = 14u + biSize;

            using var bmpMs = new MemoryStream(14 + dib.Length);
            bmpMs.WriteByte((byte)'B');
            bmpMs.WriteByte((byte)'M');
            bmpMs.Write(BitConverter.GetBytes(fileSize), 0, 4);
            bmpMs.Write(BitConverter.GetBytes(0u), 0, 4);
            bmpMs.Write(BitConverter.GetBytes(offBits), 0, 4);
            bmpMs.Write(dib, 0, dib.Length);
            bmpMs.Position = 0;

            using var bmp = new System.Drawing.Bitmap(bmpMs);
            using var pngMs = new MemoryStream();
            bmp.Save(pngMs, System.Drawing.Imaging.ImageFormat.Png);
            return pngMs.ToArray();
        }
        catch
        {
            return null;
        }
    }

    private static ulong ComputeFnv1a64(ReadOnlySpan<byte> data)
    {
        const ulong offsetBasis = 14695981039346656037UL;
        const ulong prime = 1099511628211UL;
        ulong hash = offsetBasis;
        for (int i = 0; i < data.Length; i++)
        {
            hash ^= data[i];
            hash *= prime;
        }
        return hash;
    }

    private static ulong ComputeFnv1a64(string text) =>
        ComputeFnv1a64(Encoding.UTF8.GetBytes(text));

    // ── System commands ───────────────────────────────────────────────────

    private static void SendSAS()
    {
        // SendSAS() in sas.dll — may require AllowSoftwareSAS=1 registry key or SYSTEM privileges.
        // Fallback: inject Ctrl+Alt+Del via SendInput (works for non-UAC scenarios).
        try
        {
            NativeSendSAS(false);
            AppLog.Write("[Input] SendSAS via sas.dll OK");
        }
        catch (Exception ex)
        {
            AppLog.Write($"[Input] sas.dll failed ({ex.Message}), falling back to SendInput");
            var inputs = new[]
            {
                MakeKey(0xA2, down: true),   // VK_LCONTROL
                MakeKey(0xA4, down: true),   // VK_LMENU
                MakeKey(0x2E, down: true),   // VK_DELETE
                MakeKey(0x2E, down: false),
                MakeKey(0xA4, down: false),
                MakeKey(0xA2, down: false),
            };
            var sent = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>());
            AppLog.Write($"[Input] SendInput CtrlAltDel sent={sent} lastErr=0x{Marshal.GetLastWin32Error():X8}");
        }
    }

    private static INPUT MakeKey(ushort vk, bool down)
    {
        var i = new INPUT { type = 1 }; // IT_KEYBOARD
        i.ki = new KEYBDINPUT { wVk = vk, dwFlags = down ? 0u : 0x0002u };
        return i;
    }

    private static void AdjustPrivilege()
    {
        if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, out var hToken)) return;
        var tp = new TOKEN_PRIVILEGES { PrivilegeCount = 1 };
        LookupPrivilegeValue(null, "SeShutdownPrivilege", out tp.Privileges.Luid);
        tp.Privileges.Attributes = SE_PRIVILEGE_ENABLED;
        AdjustTokenPrivileges(hToken, false, ref tp, 0, nint.Zero, nint.Zero);
        CloseHandle(hToken);
    }

    private static void SetMasterMute(bool muted) => AudioController.SetMasterMute(muted);

    private void StartAudioStream()
    {
        if (_audioEnabled) return;
        _audioEnabled = true;

        try
        {
            _audioEncoder ??= new AudioEncoder();
            _audioEncoder.Initialize(sampleRate: 48000, channels: 2, bitrateBps: 128_000);
            _audioEncoder.OnEncodedFrame = adtsPacket =>
            {
                if (!_audioEnabled) return;
                var pkt = new byte[1 + adtsPacket.Length];
                pkt[0] = FrameType.AudioFrame;
                Buffer.BlockCopy(adtsPacket, 0, pkt, 1, adtsPacket.Length);
                _bytesSent += pkt.Length;
                _ = _conn.SendBinaryAsync(pkt);
            };

            _audioCapturer ??= new AudioCapturer();
            _audioCapturer.OnPcmData = (pcm, len) =>
            {
                if (!_audioEnabled) return;
                _audioEncoder.EncodePcm(pcm, len);
            };
            _audioCapturer.Start();
            AppLog.Write("[Session] Windows audio capture & AAC streaming started");
        }
        catch (Exception ex)
        {
            AppLog.Write($"[Session] Failed to start audio stream: {ex.Message}");
            StopAudioStream();
        }
    }

    private void StopAudioStream()
    {
        _audioEnabled = false;
        try { _audioCapturer?.Stop(); } catch { }
        try { _audioCapturer?.Dispose(); } catch { }
        _audioCapturer = null;

        try { _audioEncoder?.Dispose(); } catch { }
        _audioEncoder = null;
        AppLog.Write("[Session] Windows audio streaming stopped");
    }

    // ── P/Invoke for system commands ──────────────────────────────────────

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool LogonUser(string user, string domain, string pass,
        int logonType, int logonProvider, out nint token);

    private static bool ValidateOsCredentials(string username, string password)
    {
        var ok = LogonUser(username, ".", password, 2 /* INTERACTIVE */, 0 /* DEFAULT */, out var token);
        if (ok) CloseHandle(token);
        return ok;
    }

    private void HandlePowerAction(string action)
    {
        var normalized = (action ?? "").Trim().ToLowerInvariant();
        AppLog.Write($"[Session] PowerAction: {normalized}");
        ConnectionLogger.Shared.LogStep(_id, "power_action", $"action={normalized}");
        try
        {
            switch (normalized)
            {
                case "lock":
                    LockWorkStation();
                    break;
                case "sleep":
                    SetSuspendState(hibernate: false, forceCritical: false, disableWakeEvent: false);
                    break;
                case "restart":
                    System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("shutdown", "/r /t 0")
                    {
                        CreateNoWindow = true,
                        UseShellExecute = false,
                    });
                    break;
            }
        }
        catch (Exception ex)
        {
            AppLog.Write($"[Session] PowerAction '{normalized}' failed: {ex.Message}");
        }
    }

    [DllImport("user32.dll")] private static extern bool LockWorkStation();
    [DllImport("user32.dll")] private static extern bool ExitWindowsEx(uint uFlags, uint dwReason);
    [DllImport("powrprof.dll", SetLastError = true)]
    private static extern bool SetSuspendState(bool hibernate, bool forceCritical, bool disableWakeEvent);

    // SendSAS is in sas.dll (Windows 7+)
    [DllImport("sas.dll", EntryPoint = "SendSAS", SetLastError = false)]
    private static extern void NativeSendSAS(bool asUser);

    [DllImport("user32.dll")] private static extern bool OpenClipboard(nint hWnd);
    [DllImport("user32.dll")] private static extern bool CloseClipboard();
    [DllImport("user32.dll")] private static extern bool EmptyClipboard();
    [DllImport("user32.dll")] private static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll")] private static extern bool IsClipboardFormatAvailable(uint format);
    [DllImport("user32.dll")] private static extern nuint GetClipboardData(uint uFormat);
    [DllImport("user32.dll")] private static extern nuint SetClipboardData(uint uFormat, nuint hMem);
    [DllImport("kernel32.dll")] private static extern nuint GlobalAlloc(uint uFlags, nuint dwBytes);
    [DllImport("kernel32.dll")] private static extern nuint GlobalLock(nuint hMem);
    [DllImport("kernel32.dll")] private static extern bool  GlobalUnlock(nuint hMem);
    [DllImport("kernel32.dll")] private static extern nuint GlobalFree(nuint hMem);
    [DllImport("kernel32.dll")] private static extern nuint GlobalSize(nuint hMem);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool OpenProcessToken(nint ProcessHandle, uint DesiredAccess, out nint TokenHandle);
    [DllImport("kernel32.dll")] private static extern nint GetCurrentProcess();
    [DllImport("advapi32.dll", CharSet = CharSet.Auto)]
    private static extern bool LookupPrivilegeValue(string? lpSystemName, string lpName, out LUID lpLuid);
    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool AdjustTokenPrivileges(nint TokenHandle, bool DisableAllPrivileges,
        ref TOKEN_PRIVILEGES NewState, uint BufferLength, nint PreviousState, nint ReturnLength);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(nint hObject);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    private const uint CF_UNICODETEXT = 13;
    private const uint CF_DIB         = 8;
    private const uint CF_HDROP       = 15;
    private const uint GMEM_MOVEABLE  = 0x0002;
    private const uint TOKEN_ADJUST_PRIVILEGES = 0x0020;
    private const uint TOKEN_QUERY             = 0x0008;
    private const uint SE_PRIVILEGE_ENABLED    = 0x0002;

    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT { public uint type; public InputUnion U;
        public KEYBDINPUT ki { get => U.ki; set => U.ki = value; } }
    [StructLayout(LayoutKind.Explicit)]
    private struct InputUnion { [FieldOffset(0)] public KEYBDINPUT ki; }
    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public nint dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)]
    private struct TOKEN_PRIVILEGES { public uint PrivilegeCount; public LUID_AND_ATTRIBUTES Privileges; }
    [StructLayout(LayoutKind.Sequential)]
    private struct LUID_AND_ATTRIBUTES { public LUID Luid; public uint Attributes; }
    [StructLayout(LayoutKind.Sequential)]
    private struct LUID { public uint LowPart; public int HighPart; }
}
