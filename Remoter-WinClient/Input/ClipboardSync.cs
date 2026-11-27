using System.Collections.Specialized;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

namespace RemoterWinClient.Input;

/// <summary>
/// Bidirectional native Win32 clipboard synchronizer using AddClipboardFormatListener (WM_CLIPBOARDUPDATE)
/// and GetClipboardSequenceNumber() fast-skip.
/// Uses UU-Remote's dual 64-bit FNV-1a hash design (lastInjectedHash + lastSentHash) to completely eliminate
/// bidirectional clipboard echo storms without relying on fragile timer suppression alone.
/// Must be created and disposed on the WinForms STA UI thread.
/// </summary>
public sealed class ClipboardSync : IDisposable
{
    private const int WM_CLIPBOARDUPDATE = 0x031D;
    private const int MaxImageBytes = 10 * 1024 * 1024; // 10 MB safety cap

    private readonly ClipboardListenerWindow? _window;
    private readonly Control _uiInvoker;
    private bool _enabled = true;
    private bool _disposed;

    // UU-Remote dual-hash echo-storm protection (separate injected vs sent hashes)
    private ulong _lastInjectedTextHash;
    private ulong _lastSentTextHash;
    private bool _hasInjectedTextHash;
    private bool _hasSentTextHash;

    private ulong _lastInjectedImageHash;
    private ulong _lastSentImageHash;
    private bool _hasInjectedImageHash;
    private bool _hasSentImageHash;

    // Echo guard for bidirectional clipboard file drop lists
    private string? _lastAppliedRemoteClipboardFilesSig;
    private string? _lastSentFilesSig;

    // Win32 clipboard sequence counter for zero-allocation fast-skip after our own writes
    private uint _lastSequenceNumber;

    public bool Enabled
    {
        get => _enabled;
        set => _enabled = value;
    }

    /// <summary>Fired on the UI thread when local clipboard text changes.</summary>
    public event Action<string>? LocalTextChanged;

    /// <summary>Fired on the UI thread when local clipboard image changes (PNG base64).</summary>
    public event Action<string>? LocalImageChanged;

    /// <summary>Fired on the UI thread when local clipboard file drop list changes.</summary>
    public event Action<string[]>? LocalFilesChanged;

    [DllImport("user32.dll")]
    private static extern uint GetClipboardSequenceNumber();

    public ClipboardSync(Control uiInvoker)
    {
        _uiInvoker = uiInvoker ?? throw new ArgumentNullException(nameof(uiInvoker));
        _lastSequenceNumber = GetClipboardSequenceNumber();
        try
        {
            _window = new ClipboardListenerWindow(OnClipboardUpdate);
        }
        catch
        {
            _window = null;
        }
    }

    /// <summary>
    /// Applies clipboard text received from the remote host without echoing it back.
    /// Safe to call from any thread.
    /// </summary>
    public void ApplyRemoteText(string text)
    {
        if (_disposed || !_enabled || string.IsNullOrEmpty(text)) return;

        ulong hash = ComputeFnv1a64(Encoding.UTF8.GetBytes(text));

        void Apply()
        {
            if (_disposed) return;
            // Skip only if the local clipboard already holds this exact text (prevents echo
            // without dropping legitimate re-copies after the user copied something else locally).
            try
            {
                if (Clipboard.ContainsText(TextDataFormat.UnicodeText) &&
                    string.Equals(Clipboard.GetText(TextDataFormat.UnicodeText), text, StringComparison.Ordinal))
                {
                    _lastInjectedTextHash = hash;
                    _hasInjectedTextHash = true;
                    return;
                }
            }
            catch
            {
                // Proceed to write with retries below
            }

            try
            {
                _lastInjectedTextHash = hash;
                _hasInjectedTextHash = true;
                _hasSentTextHash = false;
                Clipboard.SetDataObject(text, true, 5, 25);
                _lastSequenceNumber = GetClipboardSequenceNumber();
            }
            catch
            {
                // Clipboard remained locked after retries
            }
        }

        if (_uiInvoker.InvokeRequired)
        {
            if (!_uiInvoker.IsDisposed && _uiInvoker.IsHandleCreated)
                _uiInvoker.BeginInvoke(Apply);
        }
        else
        {
            Apply();
        }
    }

    /// <summary>
    /// Applies a clipboard PNG image (base64) received from the remote host without echoing it back.
    /// Safe to call from any thread.
    /// </summary>
    public void ApplyRemoteImageBase64(string base64Png)
    {
        if (_disposed || !_enabled || string.IsNullOrEmpty(base64Png)) return;

        byte[] pngBytes;
        try
        {
            pngBytes = Convert.FromBase64String(base64Png);
        }
        catch
        {
            return;
        }

        if (pngBytes.Length == 0 || pngBytes.Length > MaxImageBytes) return;

        ulong hash = ComputeFnv1a64(pngBytes);

        void Apply()
        {
            if (_disposed) return;
            if (_hasSentImageHash && _lastSentImageHash == hash) return;

            try
            {
                using var ms = new MemoryStream(pngBytes);
                using var img = Image.FromStream(ms);
                _lastInjectedImageHash = hash;
                _hasInjectedImageHash = true;
                _hasSentImageHash = false;
                Clipboard.SetDataObject(img, true, 5, 25);
                _lastSequenceNumber = GetClipboardSequenceNumber();
            }
            catch
            {
                // Clipboard may be locked transiently or invalid image
            }
        }

        if (_uiInvoker.InvokeRequired)
        {
            if (!_uiInvoker.IsDisposed && _uiInvoker.IsHandleCreated)
                _uiInvoker.BeginInvoke(Apply);
        }
        else
        {
            Apply();
        }
    }

    /// <summary>
    /// Places downloaded remote clipboard files into the local Windows clipboard on the UI STA thread,
    /// recording their signature in _lastAppliedRemoteClipboardFilesSig to prevent echo-back loops.
    /// Safe to call from any thread.
    /// </summary>
    public void ApplyRemoteFiles(string[] localPaths)
    {
        if (_disposed || !_enabled || localPaths == null || localPaths.Length == 0) return;

        var valid = new List<string>(localPaths.Length);
        foreach (var raw in localPaths)
        {
            if (string.IsNullOrWhiteSpace(raw)) continue;
            if (File.Exists(raw) || Directory.Exists(raw))
                valid.Add(raw);
        }
        if (valid.Count == 0) return;

        string sig = ComputeFilesSignature(valid);

        void Apply()
        {
            if (_disposed) return;
            try
            {
                var col = new StringCollection();
                foreach (var p in valid) col.Add(p);

                _lastAppliedRemoteClipboardFilesSig = sig;
                Clipboard.SetFileDropList(col);
                _lastSequenceNumber = GetClipboardSequenceNumber();
            }
            catch
            {
                // Clipboard may be locked transiently by another process
            }
        }

        if (_uiInvoker.InvokeRequired)
        {
            if (!_uiInvoker.IsDisposed && _uiInvoker.IsHandleCreated)
                _uiInvoker.BeginInvoke(Apply);
        }
        else
        {
            Apply();
        }
    }

    /// <summary>
    /// Immediately inspects the local Windows clipboard and pushes any new text/image/files
    /// to the remote host (e.g. on connect or window activation). Protected by dual FNV-1a
    /// hash deduplication so previously synced or remote-injected content never echoes.
    /// </summary>
    public void SyncNow()
    {
        if (_disposed || !_enabled) return;
        if (_uiInvoker.InvokeRequired)
        {
            if (!_uiInvoker.IsDisposed && _uiInvoker.IsHandleCreated)
                _uiInvoker.BeginInvoke(SyncNow);
            return;
        }

        _lastSequenceNumber = GetClipboardSequenceNumber();
        ReadAndEmitLocalClipboard();
    }

    private void OnClipboardUpdate()
    {
        if (_disposed || !_enabled) return;

        uint seq = GetClipboardSequenceNumber();
        if (seq == _lastSequenceNumber) return;
        _lastSequenceNumber = seq;

        ReadAndEmitLocalClipboard();
    }

    private void ReadAndEmitLocalClipboard()
    {
        try
        {
            // Check file drop list first so Explorer file copies sync as files, not plain text paths.
            if (Clipboard.ContainsFileDropList())
            {
                var drop = Clipboard.GetFileDropList();
                if (drop != null && drop.Count > 0)
                {
                    var paths = new List<string>(drop.Count);
                    foreach (string? item in drop)
                    {
                        if (!string.IsNullOrWhiteSpace(item) && (File.Exists(item) || Directory.Exists(item)))
                            paths.Add(item);
                    }
                    if (paths.Count > 0)
                    {
                        string sig = ComputeFilesSignature(paths);
                        if (sig != _lastAppliedRemoteClipboardFilesSig && sig != _lastSentFilesSig)
                        {
                            _lastSentFilesSig = sig;
                            LocalFilesChanged?.Invoke(paths.ToArray());
                        }
                    }
                }
                return;
            }

            if (Clipboard.ContainsText(TextDataFormat.UnicodeText))
            {
                string text = Clipboard.GetText(TextDataFormat.UnicodeText);
                if (!string.IsNullOrEmpty(text))
                {
                    ulong hash = ComputeFnv1a64(Encoding.UTF8.GetBytes(text));
                    if ((!_hasInjectedTextHash || _lastInjectedTextHash != hash) &&
                        (!_hasSentTextHash || _lastSentTextHash != hash))
                    {
                        _lastSentTextHash = hash;
                        _hasSentTextHash = true;
                        _hasInjectedTextHash = false;
                        LocalTextChanged?.Invoke(text);
                    }
                }
                return;
            }

            if (Clipboard.ContainsImage())
            {
                // Prefer the app's own "PNG" clipboard format: Clipboard.GetImage() goes through
                // the DIB conversion, which mangles 32bpp/alpha images from some apps (DingTalk
                // images came out with the lower half blank while Paint showed them whole).
                Image? img = null;
                try
                {
                    if (Clipboard.GetData("PNG") is MemoryStream pngStream)
                    {
                        pngStream.Position = 0;
                        img = Image.FromStream(pngStream);
                    }
                }
                catch { img?.Dispose(); img = null; }
                img ??= Clipboard.GetImage();
                using var imgOwner = img;
                if (img != null)
                {
                    using var ms = new MemoryStream();
                    img.Save(ms, ImageFormat.Png);
                    if (ms.Length > 0 && ms.Length <= MaxImageBytes)
                    {
                        byte[] bytes = ms.ToArray();
                        ulong hash = ComputeFnv1a64(bytes);
                        if ((!_hasInjectedImageHash || _lastInjectedImageHash != hash) &&
                            (!_hasSentImageHash || _lastSentImageHash != hash))
                        {
                            _lastSentImageHash = hash;
                            _hasSentImageHash = true;
                            _hasInjectedImageHash = false;
                            LocalImageChanged?.Invoke(Convert.ToBase64String(bytes));
                        }
                    }
                }
            }
        }
        catch
        {
            // Ignore transient ExternalException when another app holds clipboard open
        }
    }

    public static ulong ComputeFnv1a64(ReadOnlySpan<byte> data)
    {
        const ulong offsetBasis = 14695981039346656037UL;
        const ulong prime = 1099511628211UL;
        ulong hash = offsetBasis;
        foreach (byte b in data)
        {
            hash ^= b;
            hash *= prime;
        }
        return hash;
    }

    public static string ComputeFilesSignature(IEnumerable<string> paths)
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

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _window?.Dispose();
    }

    private sealed class ClipboardListenerWindow : NativeWindow, IDisposable
    {
        private readonly Action _onUpdate;
        private bool _listening;

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool AddClipboardFormatListener(nint hwnd);

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool RemoveClipboardFormatListener(nint hwnd);

        public ClipboardListenerWindow(Action onUpdate)
        {
            _onUpdate = onUpdate;
            // Message-only window (HWND_MESSAGE = -3)
            var cp = new CreateParams
            {
                Caption = "RemoterClipboardListener",
                Parent = (nint)(-3),
            };
            CreateHandle(cp);
            if (Handle != nint.Zero)
            {
                _listening = AddClipboardFormatListener(Handle);
            }
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == WM_CLIPBOARDUPDATE)
            {
                _onUpdate();
                return;
            }
            base.WndProc(ref m);
        }

        public void Dispose()
        {
            if (Handle != nint.Zero)
            {
                if (_listening)
                {
                    RemoveClipboardFormatListener(Handle);
                    _listening = false;
                }
                DestroyHandle();
            }
        }
    }
}
