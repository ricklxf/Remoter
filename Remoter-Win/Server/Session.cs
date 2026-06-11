using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;

namespace RemoterWin;

// Per-client state machine: auth → capture → stream + input handling.
// Mirrors Mac agent Session.swift (same protocol, same frame format).
sealed class Session
{
    private readonly WsConn         _conn;
    private readonly string         _pin;
    private readonly E2ECrypto      _crypto = new();

    private ScreenCapturer?   _capturer;
    private InputController?  _input;
    private FileReceiver?     _fileRecv;

    private bool   _authed    = false;
    private bool   _inputEnabled = true;
    private bool   _clipSync  = true;
    private string _lastClip  = "";
    private uint   _frameId   = 0;
    private DateTime _connectTime;

    private CancellationTokenSource? _cts;
    private System.Threading.Timer?  _clipTimer;

    public Session(WsConn conn, string pin)
    {
        _conn = conn;
        _pin  = pin;
    }

    public void Start()
    {
        Console.WriteLine($"[Session] {_conn.RemoteAddr} connected");
        // Send hello with our E2E public key so client initiates ECDH
        SendRaw(new { type = "hello", version = "1.0", os = "Windows",
                      pubkey = _crypto.PublicKeyBase64() });
    }

    public void HandleText(string text)
    {
        try
        {
            var doc = JsonDocument.Parse(text);
            Route(ClientMsg.Parse(doc.RootElement));
        }
        catch (Exception ex) { Console.WriteLine($"[Session] ParseError: {ex.Message}"); }
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
            catch (Exception ex) { Console.WriteLine($"[Session] Decrypt error: {ex.Message}"); }
            return;
        }

        // File chunk: 0x02 | 16B id | 4B offset BE | data
        if (_authed && data[0] == FrameType.FileChunk && data.Length > 21)
        {
            var fid    = Encoding.UTF8.GetString(data, 1, 16).TrimEnd('\0');
            var offset = (long)((data[17] << 24) | (data[18] << 16) | (data[19] << 8) | data[20]);
            _fileRecv?.Receive(fid, offset, data[21..]);
        }
    }

    public void Close()
    {
        _cts?.Cancel();       // signals CaptureLoopAsync to stop
        _clipTimer?.Dispose(); // stops clipboard polling
        // _capturer is disposed in BeginCaptureAsync's finally block;
        // disposing here races with the capture loop still running
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

        // Auth
        if (msg is ClientMsg.Auth auth)
        {
            // PIN check (disabled during development — enable for production)
            // if (auth.Pin != _pin) { Send(new { type = "error", code = "bad_pin" }); return; }
            _ = auth;
            _authed = true;
            Console.WriteLine($"[Session] {_conn.RemoteAddr} authenticated");
            Send(new { type = "auth_ok" });
            _ = BeginCaptureAsync();
            return;
        }

        if (!_authed) return;

        switch (msg)
        {
            // ── Input ──────────────────────────────────────────────────
            case ClientMsg.MouseMove m when _inputEnabled:
                _input?.MouseMove(m.X, m.Y); break;

            case ClientMsg.MouseButton m when _inputEnabled:
                _input?.MouseButton(m.Button, m.Down, m.X, m.Y); break;

            case ClientMsg.MouseScroll m when _inputEnabled:
                _input?.MouseScroll(m.Dx, m.Dy); break;

            case ClientMsg.KeyEvent k when _inputEnabled:
                _input?.KeyEvent(k.Code, k.Down, k.Mods); break;

            case ClientMsg.ClipboardSet c:
                _lastClip = c.Text;
                SetClipboard(c.Text); break;

            // ── File transfer ──────────────────────────────────────────
            case ClientMsg.FileStart f:
                _fileRecv?.Start(f.Id, f.Name, f.Size); break;

            case ClientMsg.FileEnd f:
                _fileRecv?.Finish(f.Id); break;

            // ── System commands ────────────────────────────────────────
            case ClientMsg.CtrlAltDel:
                SendSAS(); break;

            case ClientMsg.SetClipboardSync sc:
                _clipSync = sc.Enabled;
                if (_clipSync) StartClipboard(); else StopClipboard();
                break;

            case ClientMsg.SetInputEnabled si:
                _inputEnabled = si.Enabled; break;

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
                _ = SendFileAsync(rf.Path); break;

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
        var c = new ScreenCapturer(jpegQuality: 65);
        try
        {
            c.Initialize();
            _capturer   = c;
            _input      = new InputController(c.Width, c.Height);
            _fileRecv   = new FileReceiver();
            _connectTime = DateTime.UtcNow;
            _cts        = new CancellationTokenSource();

            Send(new { type = "stream_started", width = c.Width, height = c.Height, codec = "jpeg" });
            StartClipboard();

            await CaptureLoopAsync(_cts.Token);
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[Session] Capture error: {ex.Message}");
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
        while (!ct.IsCancellationRequested)
        {
            var jpeg = _capturer!.CaptureJpeg(timeoutMs: 16); // blocks ≤16ms
            if (jpeg == null) { await Task.Yield(); continue; }

            var fid = _frameId++;
            var pts = (uint)(DateTime.UtcNow - _connectTime).TotalMilliseconds;
            var pkt = FrameBuilder.VideoFramePacket(jpeg, fid, pts, keyframe: true);
            _ = _conn.SendBinaryAsync(pkt);
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
            _ = _conn.SendBinaryAsync(frame);
        }
        else
        {
            _ = _conn.SendTextAsync(System.Text.Encoding.UTF8.GetString(json));
        }
    }

    // Always plaintext (hello / crypto_ok)
    private void SendRaw(object obj) =>
        _ = _conn.SendTextAsync(JsonSerializer.Serialize(obj));

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
            await _conn.SendBinaryAsync(pkt);
        }
        Send(new { type = "file_end", id = rawId });
    }

    // ── Clipboard ────────────────────────────────────────────────────────

    private void StartClipboard()
    {
        if (_clipTimer != null) return;
        _lastClip = GetClipboard();
        _clipTimer = new System.Threading.Timer(_ =>
        {
            try
            {
                if (!_clipSync) return;
                var text = GetClipboard();
                if (!string.IsNullOrEmpty(text) && text != _lastClip)
                {
                    _lastClip = text;
                    Send(new { type = "clipboard", text });
                }
            }
            catch (Exception ex)
            {
                Console.WriteLine($"[Session] Clipboard poll error: {ex.Message}");
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

    // ── System commands ───────────────────────────────────────────────────

    private static void SendSAS()
    {
        // SendSAS() in sas.dll — may require "Software\Microsoft\Windows\CurrentVersion\Policies\System"
        // AllowSoftwareSAS=1 registry key or running as SYSTEM.
        // Fallback: inject Ctrl+Alt+Del via SendInput (works for non-UAC scenarios).
        try { NativeSendSAS(false); }
        catch
        {
            // Fallback: keyboard injection (doesn't trigger SAS in secure desktops)
            var inputs = new[]
            {
                MakeKey(0xA2, down: true),   // VK_LCONTROL
                MakeKey(0xA4, down: true),   // VK_LMENU
                MakeKey(0x2E, down: true),   // VK_DELETE
                MakeKey(0x2E, down: false),
                MakeKey(0xA4, down: false),
                MakeKey(0xA2, down: false),
            };
            SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>());
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

    private static void SetMasterMute(bool muted)
    {
        // COM-based mute via IMMDevice / IAudioEndpointVolume would be ideal.
        // Simple approach: use nircmd or mute hotkey simulation.
        // For now, no-op to avoid COM complexity.
        _ = muted;
    }

    // ── P/Invoke for system commands ──────────────────────────────────────

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
