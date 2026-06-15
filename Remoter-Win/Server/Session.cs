using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;

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

    private bool   _authed    = false;
    private bool   _inputEnabled = true;
    private bool   _debugInputLog = true;
    private int    _textCount  = 0;
    private int    _inputLogCount = 0;
    private int    _routeLogCount = 0;
    private bool   _clipSync  = true;
    private string _lastClip  = "";
    private int    _lastClipImgSize = -1;
    private uint   _frameId   = 0;
    private DateTime _connectTime;
    private long   _bytesSent = 0;
    private long   _bytesRecv = 0;

    private CancellationTokenSource? _cts;
    private System.Threading.Timer?  _clipTimer;
    
    // Adaptive quality control - 延迟优先配置
    private int    _currentFps = 60;  // 提高默认FPS到60，最大限度减少延迟
    private int    _currentQuality = 50;  // 降低质量到50，提高编码速度
    private long   _lastBytesSent = 0;
    private DateTime _lastCheckTime = DateTime.UtcNow;
    private const long TARGET_BANDWIDTH = 10L * 1024 * 1024; // 提高到10MB/s，适应更高速网络
    private const int MIN_FPS = 30;  // 提高最低FPS到30，确保流畅度
    private const int MAX_FPS = 60;
    private const int MIN_QUALITY = 30;  // 降低最低质量到30，在带宽不足时优先保证低延迟
    private const int MAX_QUALITY = 80;  // 降低最高质量到80，避免过度消耗带宽
    private bool   _cpuLimitReached = false;
    private bool   _adaptiveEnabled = true;
    
    // Statistics for overlay
    private int    _frameCount = 0;
    private DateTime _fpsCalcTime = DateTime.UtcNow;
    private double _currentFpsDisplay = 0;
    
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
        _cts?.Cancel();
        _clipTimer?.Dispose();
        
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
                AppLog.Write($"[Input] MouseScroll dx={m.Dx} dy={m.Dy}");
                _input?.MouseScroll(m.Dx, m.Dy); break;

            case ClientMsg.KeyEvent k when _inputEnabled:
                AppLog.Write($"[Input] Key {k.Code} down={k.Down}");
                _input?.KeyEvent(k.Code, k.Down, k.Mods); break;

            case ClientMsg.ClipboardSet c:
                _lastClip = c.Text;
                SetClipboard(c.Text); break;

            case ClientMsg.ClipboardSetImage ci:
                if (!string.IsNullOrEmpty(ci.Data))
                {
                    try
                    {
                        var png = Convert.FromBase64String(ci.Data);
                        if (SetClipboardImageFromPng(png))
                        {
                            var readback = GetClipboardImageBytes();
                            _lastClipImgSize = readback?.Length ?? png.Length;
                        }
                    }
                    catch { }
                }
                break;

            // ── File transfer ──────────────────────────────────────────
            case ClientMsg.FileStart f:
                _fileRecv?.Start(f.Id, f.Name, f.Size); break;

            case ClientMsg.FileEnd f:
                _fileRecv?.Finish(f.Id); break;

            // ── System commands ────────────────────────────────────────
            case ClientMsg.CtrlAltDel:
                AppLog.Write("[Input] CtrlAltDel received");
                SendSAS(); break;

            case ClientMsg.SetClipboardSync sc:
                _clipSync = sc.Enabled;
                if (_clipSync) StartClipboard(); else StopClipboard();
                break;

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

            case ClientMsg.SetMuted m:
                SetMasterMute(m.Muted); break;

            // ── Misc ───────────────────────────────────────────────────
            case ClientMsg.Ping:
                Send(new { type = "pong" }); break;

            case ClientMsg.QualitySet q:
                // TODO: adjust capture FPS
                _ = q; break;

            case ClientMsg.ListDir ld:
                HandleListDir(ld.Path); break;

            case ClientMsg.RequestFile rf:
                _ = SendFileAsync(rf.Path).ContinueWith(t =>
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
            case ClientMsg.SetCodec:
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
            _fileRecv   = new FileReceiver();
            _connectTime = DateTime.UtcNow;
            _cts        = new CancellationTokenSource();

            Send(new { type = "stream_started", width = c.Width, height = c.Height, codec = "jpeg", fps = _currentFps });
            ConnectionLogger.Shared.LogConnected(_id, "jpeg", _crypto.IsReady);
            StartClipboard();

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
            c.Dispose();
            _capturer = null;
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
            
            // Calculate FPS for overlay
            _frameCount++;
            var now = DateTime.UtcNow;
            if ((now - _fpsCalcTime).TotalSeconds >= 1.0)
            {
                _currentFpsDisplay = _frameCount / (now - _fpsCalcTime).TotalSeconds;
                _frameCount = 0;
                _fpsCalcTime = now;
            }
            
            // Check if capturer is available
            if (_capturer == null)
            {
                AppLog.Write("[Session] Capturer is null, exiting capture loop");
                break;
            }
            
            byte[]? jpeg;
            try
            {
                jpeg = _capturer.CaptureJpeg(timeoutMs: 1);
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

            if (jpeg == null) continue;

            var fid = _frameId++;
            var pts = (uint)(DateTime.UtcNow - _connectTime).TotalMilliseconds;
            var pkt = FrameBuilder.VideoFramePacket(jpeg, fid, pts, keyframe: true);
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
            if (_currentFps < 30)
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
                AppLog.Write($"[Session] Quality increased to {_currentQuality}");
            }
            else if (_currentFps < MAX_FPS)
            {
                _currentFps += 2; // Increase by 2 each time
                if (_currentFps > MAX_FPS) _currentFps = MAX_FPS;
                AppLog.Write($"[Session] FPS increased to {_currentFps}");
            }
        }
        else if (currentBandwidth > TARGET_BANDWIDTH * 1.3)
        {
            // Bandwidth usage is high, gradually decrease (reverse order)
            if (_currentFps > 30)
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
                AppLog.Write($"[Session] Quality decreased to {_currentQuality}");
            }
            else if (_currentFps > MIN_FPS)
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

    // ── File send (Win → client) ─────────────────────────────────────────

    private async Task SendFileAsync(string path)
    {
        byte[] data;
        try   { data = await File.ReadAllBytesAsync(path); }
        catch { return; }

        var rawId = Guid.NewGuid().ToString("N")[..16];
        var name  = Path.GetFileName(path);
        Send(new { type = "file_start", id = rawId, name, size = data.Length });

        const int CHUNK = 64 * 1024;
        for (int offset = 0; offset < data.Length; offset += CHUNK)
        {
            int len    = Math.Min(CHUNK, data.Length - offset);
            var idBytes = new byte[16];
            var idData  = System.Text.Encoding.UTF8.GetBytes(rawId);
            Buffer.BlockCopy(idData, 0, idBytes, 0, Math.Min(idData.Length, 16));

            var pkt = new byte[1 + 16 + 4 + len];
            pkt[0]  = FrameType.FileChunk;
            Buffer.BlockCopy(idBytes, 0, pkt, 1, 16);
            pkt[17] = (byte)(offset >> 24); pkt[18] = (byte)(offset >> 16);
            pkt[19] = (byte)(offset >> 8);  pkt[20] = (byte)(offset);
            Buffer.BlockCopy(data, offset, pkt, 21, len);
            _bytesSent += pkt.Length;
            await _conn.SendBinaryAsync(pkt);
        }
        Send(new { type = "file_end", id = rawId });
    }

    // ── Clipboard ────────────────────────────────────────────────────────

    private void StartClipboard()
    {
        if (_clipTimer != null) return;
        _lastClip = GetClipboard();
        var initImg = GetClipboardImageBytes();
        _lastClipImgSize = initImg?.Length ?? -1;

        _clipTimer = new System.Threading.Timer(_ =>
        {
            try
            {
                if (!_clipSync) return;
                // Text
                var text = GetClipboard();
                if (!string.IsNullOrEmpty(text) && text != _lastClip)
                {
                    _lastClip = text;
                    Send(new { type = "clipboard", text });
                }
                // Image
                var pngBytes = GetClipboardImageBytes();
                if (pngBytes != null && pngBytes.Length != _lastClipImgSize)
                {
                    _lastClipImgSize = pngBytes.Length;
                    if (pngBytes.Length <= 4 * 1024 * 1024)
                        Send(new { type = "clipboard", image = Convert.ToBase64String(pngBytes) });
                }
            }
            catch (Exception ex)
            {
                AppLog.Write($"[Session] Clipboard poll error: {ex.Message}");
            }
        }, null, 500, 500);
    }

    private void StopClipboard() { _clipTimer?.Dispose(); _clipTimer = null; }

    private static string GetClipboard()
    {
        if (!OpenClipboard(0)) return "";
        try
        {
            var h = GetClipboardData(CF_UNICODETEXT);
            if (h == 0) return "";
            var p = GlobalLock(h);
            if (p == 0) return "";
            try { return Marshal.PtrToStringUni((nint)p) ?? ""; }
            finally { GlobalUnlock(h); }
        }
        finally { CloseClipboard(); }
    }

    private static void SetClipboard(string text)
    {
        if (!OpenClipboard(0)) return;
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
        }
        finally { CloseClipboard(); }
    }

    private static byte[]? GetClipboardImageBytes()
    {
        if (!OpenClipboard(0)) return null;
        try
        {
            var h = GetClipboardData(CF_DIB);
            if (h == 0) return null;
            var size = (int)GlobalSize(h);
            if (size == 0) return null;
            var p = GlobalLock(h);
            if (p == 0) return null;
            try
            {
                var dib = new byte[size];
                Marshal.Copy((nint)p, dib, 0, size);

                // Reconstruct BITMAPFILEHEADER (14 bytes) and prepend to DIB
                var dibHeaderSize  = BitConverter.ToUInt32(dib, 0);
                var bitCount       = BitConverter.ToUInt16(dib, 14);
                var colorsUsed     = BitConverter.ToUInt32(dib, 32);
                uint colorEntries  = colorsUsed != 0 ? colorsUsed
                                   : bitCount  <= 8 ? (uint)(1 << bitCount) : 0u;
                uint offBits       = 14 + dibHeaderSize + colorEntries * 4;

                var bmpData = new byte[14 + size];
                bmpData[0] = (byte)'B'; bmpData[1] = (byte)'M';
                Buffer.BlockCopy(BitConverter.GetBytes((uint)(14 + size)), 0, bmpData,  2, 4);
                Buffer.BlockCopy(BitConverter.GetBytes(offBits),            0, bmpData, 10, 4);
                Buffer.BlockCopy(dib, 0, bmpData, 14, size);

                using var ms    = new MemoryStream(bmpData);
                using var bmp   = new System.Drawing.Bitmap(ms);
                using var pngMs = new MemoryStream();
                bmp.Save(pngMs, System.Drawing.Imaging.ImageFormat.Png);
                return pngMs.ToArray();
            }
            finally { GlobalUnlock(h); }
        }
        catch { return null; }
        finally { CloseClipboard(); }
    }

    private static bool SetClipboardImageFromPng(byte[] pngBytes)
    {
        try
        {
            using var pngMs  = new MemoryStream(pngBytes);
            using var bmp    = new System.Drawing.Bitmap(pngMs);
            using var bmpMs  = new MemoryStream();
            bmp.Save(bmpMs, System.Drawing.Imaging.ImageFormat.Bmp);
            var dib = bmpMs.ToArray()[14..]; // strip 14-byte BMP file header

            if (!OpenClipboard(0)) return false;
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
                return true;
            }
            finally { CloseClipboard(); }
        }
        catch { return false; }
    }

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

    [DllImport("user32.dll")] private static extern bool LockWorkStation();
    [DllImport("user32.dll")] private static extern bool ExitWindowsEx(uint uFlags, uint dwReason);

    // SendSAS is in sas.dll (Windows 7+)
    [DllImport("sas.dll", EntryPoint = "SendSAS", SetLastError = false)]
    private static extern void NativeSendSAS(bool asUser);

    [DllImport("user32.dll")] private static extern bool OpenClipboard(nint hWnd);
    [DllImport("user32.dll")] private static extern bool CloseClipboard();
    [DllImport("user32.dll")] private static extern bool EmptyClipboard();
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
