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
            // Drop remote echo of content we ourselves sent, or duplicate remote injection
            if (_hasSentTextHash && _lastSentTextHash == hash) return;
            if (_hasInjectedTextHash && _lastInjectedTextHash == hash) return;

            try
            {
                _lastInjectedTextHash = hash;
                _hasInjectedTextHash = true;
                Clipboard.SetText(text, TextDataFormat.UnicodeText);
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
            if (_hasInjectedImageHash && _lastInjectedImageHash == hash) return;

            try
            {
                using var ms = new MemoryStream(pngBytes);
                using var img = Image.FromStream(ms);
                _lastInjectedImageHash = hash;
                _hasInjectedImageHash = true;
                Clipboard.SetImage(img);
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

    private void OnClipboardUpdate()
    {
        if (_disposed || !_enabled) return;

        uint seq = GetClipboardSequenceNumber();
        if (seq == _lastSequenceNumber) return;
        _lastSequenceNumber = seq;

        try
        {
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
                        LocalTextChanged?.Invoke(text);
                    }
                }
                return;
            }

            if (Clipboard.ContainsImage())
            {
                using var img = Clipboard.GetImage();
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
