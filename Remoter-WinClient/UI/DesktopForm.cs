using System.Drawing;
using System.Runtime.InteropServices;
using System.Threading.Channels;
using System.Windows.Forms;
using RemoterWinClient.Input;

namespace RemoterWinClient.UI;

/// <summary>
/// Native dark-mode remote desktop window hosting:
/// - VideoHostControl (D3D11 Flip-Model SwapChain HWND)
/// - MfVideoDecoder (GPU zero-copy NV12 / CPU NV12) + JpegDecoder fallback
/// - WasapiAudioPlayer (ADTS AAC -> WASAPI)
/// - RawInputManager (high-polling-rate mouse, Pointer Lock, smooth touchpad, Win/Alt keyboard)
/// - ClipboardSync (bidirectional text/PNG with FNV-1a anti-loop)
/// - FloatingToolbar (owned DWM-composited auto-hiding HUD &amp; control bar)
/// </summary>
public sealed class DesktopForm : Form
{
    private readonly RemoterConnection _conn;
    private readonly ConnectParams _connectParams;
    private StreamInfo _streamInfo;
    private ClientSettings _settings;

    private readonly VideoHostControl _videoHost;
    private readonly FloatingToolbar _toolbar;
    private readonly RawInputManager _inputManager;
    private readonly ClipboardSync _clipboardSync;

    private readonly D3D11Renderer _renderer = new();
    private readonly MfVideoDecoder _mfDecoder = new();
    private readonly JpegDecoder _jpegDecoder = new();
    private readonly WasapiAudioPlayer _audioPlayer = new();

    private readonly object _renderLock = new();
    private readonly object _audioLock = new();

    // Dedicated video decode/render pipeline so WebSocket receive and WinForms UI threads never block
    private readonly Channel<VideoFramePacket> _videoChannel = Channel.CreateBounded<VideoFramePacket>(
        new BoundedChannelOptions(4)
        {
            SingleReader = true,
            SingleWriter = false,
            FullMode = BoundedChannelFullMode.DropOldest,
        });
    private Task? _videoWorkerTask;
    private int _pendingResizeW;
    private int _pendingResizeH;

    private VideoCodecType _activeDecoderCodec = VideoCodecType.Jpeg;
    private int _remoteWidth;
    private int _remoteHeight;
    private bool _mfInitialized;
    private bool _rendererInitialized;
    private bool _audioOn;
    private bool _privacyOn;
    private bool _fullscreen;
    private bool _disposed;

    // Saved window geometry for fullscreen toggle
    private FormBorderStyle _savedBorderStyle;
    private FormWindowState _savedWindowState;
    private Rectangle _savedBounds;

    // Remote custom cursor handle tracking (avoid GDI icon handle leaks)
    private Cursor? _customCursor;
    private nint _customCursorIconHandle;
    private Cursor? _hiddenCursor;
    private nint _hiddenCursorIconHandle;

    public DesktopForm(RemoterConnection conn, ConnectParams connectParams, StreamInfo initialStreamInfo)
    {
        _conn = conn ?? throw new ArgumentNullException(nameof(conn));
        _connectParams = connectParams ?? throw new ArgumentNullException(nameof(connectParams));
        _streamInfo = initialStreamInfo ?? throw new ArgumentNullException(nameof(initialStreamInfo));
        _settings = DeviceStore.Shared.GetSettings();

        _remoteWidth = Math.Max(1, initialStreamInfo.Width);
        _remoteHeight = Math.Max(1, initialStreamInfo.Height);

        string titleHost = string.IsNullOrWhiteSpace(conn.ServerComputerName)
            ? $"{connectParams.Host}:{connectParams.Port}"
            : $"{conn.ServerComputerName} ({connectParams.Host})";
        Text = $"Remoter — {titleHost}";
        BackColor = DarkTheme.VideoBg;
        ForeColor = DarkTheme.TextPrimary;
        StartPosition = FormStartPosition.CenterScreen;
        ClientSize = new Size(
            Math.Clamp(_remoteWidth, 960, Math.Max(960, Screen.PrimaryScreen?.WorkingArea.Width - 80 ?? 1280)),
            Math.Clamp(_remoteHeight, 540, Math.Max(540, Screen.PrimaryScreen?.WorkingArea.Height - 80 ?? 720)));
        MinimumSize = new Size(640, 360);

        string icoPath = Path.Combine(AppContext.BaseDirectory, "Remoter.ico");
        if (File.Exists(icoPath))
        {
            try { Icon = new Icon(icoPath); } catch { }
        }

        // ── VideoHostControl ──
        _videoHost = new VideoHostControl
        {
            Dock = DockStyle.Fill,
        };
        Controls.Add(_videoHost);

        // ── Input & Clipboard ──
        _inputManager = new RawInputManager(_videoHost);
        _inputManager.SetRemoteSize(_remoteWidth, _remoteHeight);
        WireInputEvents();

        _clipboardSync = new ClipboardSync(this)
        {
            Enabled = _settings.ClipboardSyncEnabled,
        };
        _clipboardSync.LocalTextChanged += text => _conn.SendClipboardText(text);
        _clipboardSync.LocalImageChanged += b64 => _conn.SendClipboardImageBase64(b64);

        // ── FloatingToolbar ──
        _toolbar = new FloatingToolbar(this);
        WireToolbarEvents();
        SyncToolbarFromState();

        // ── Viewport & Window lifecycle events ──
        _videoHost.ViewportResized += OnViewportResized;
        _videoHost.FilesDropped += OnFilesDropped;

        // ── Connection & Decoder events ──
        WireConnectionEvents();
        WireDecoderEvents();
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        DarkTheme.EnableDarkTitleBar(Handle);
    }

    protected override void OnShown(EventArgs e)
    {
        base.OnShown(e);

        InitializeVideoPipeline();

        _toolbar.Show();
        _toolbar.UpdatePosition();

        // Sync initial settings with server
        _conn.SendFps(_settings.Fps, _settings.AutoFps);
        _conn.SendBitrate(_settings.BitrateBps, _settings.AutoBitrate);
        _conn.SetClipboardSyncEnabled(_settings.ClipboardSyncEnabled);
        _conn.SetReverseClipboardActive(true);
        _conn.SendRequestKeyframe();

        _videoHost.Focus();
    }

    private void InitializeVideoPipeline()
    {
        lock (_renderLock)
        {
            if (_disposed || _rendererInitialized) return;
            int w = Math.Max(1, _videoHost.ClientSize.Width);
            int h = Math.Max(1, _videoHost.ClientSize.Height);

            _renderer.Initialize(_videoHost.Handle, w, h);
            _renderer.ScaleMode = _settings.ScaleMode;
            _renderer.VSyncEnabled = _settings.VSyncEnabled;
            _rendererInitialized = true;
            _videoHost.D3D11Active = true;

            if (_streamInfo.Codec != VideoCodecType.Jpeg)
            {
                try
                {
                    _mfDecoder.Initialize(_streamInfo.Codec, _remoteWidth, _remoteHeight, _renderer.Device);
                    _activeDecoderCodec = _streamInfo.Codec;
                    _mfInitialized = true;
                }
                catch
                {
                    _mfInitialized = false;
                }
            }
        }

        _conn.DecodeMsProvider = () => _mfDecoder.LastDecodeMs;
        SyncContentRect();

        _videoWorkerTask = Task.Factory.StartNew(
            VideoWorkerLoop,
            CancellationToken.None,
            TaskCreationOptions.LongRunning,
            TaskScheduler.Default);
    }

    private void VideoWorkerLoop()
    {
        var reader = _videoChannel.Reader;
        try
        {
            while (reader.WaitToReadAsync().AsTask().GetAwaiter().GetResult())
            {
                while (reader.TryRead(out var pkt))
                {
                    if (_disposed) return;
                    ProcessVideoFrame(pkt);
                }
            }
        }
        catch
        {
            // Shutdown
        }
    }

    private void ProcessVideoFrame(VideoFramePacket pkt)
    {
        lock (_renderLock)
        {
            if (_disposed || !_rendererInitialized) return;

            // Apply any pending viewport resize queued by the UI thread
            int rw = Interlocked.Exchange(ref _pendingResizeW, 0);
            int rh = Interlocked.Exchange(ref _pendingResizeH, 0);
            if (rw > 0 && rh > 0)
            {
                _renderer.Resize(rw, rh);
            }

            if (pkt.Codec == VideoCodecType.Jpeg)
            {
                _jpegDecoder.DecodeAndRender(pkt.Data, _renderer);
                UpdateContentRectFromRendererUnsafe();
            }
            else
            {
                if (!_mfInitialized || _activeDecoderCodec != pkt.Codec)
                {
                    try
                    {
                        _mfDecoder.Initialize(pkt.Codec, _remoteWidth, _remoteHeight, _renderer.Device);
                        _activeDecoderCodec = pkt.Codec;
                        _mfInitialized = true;
                    }
                    catch
                    {
                        _mfInitialized = false;
                        return;
                    }
                }
                _mfDecoder.Decode(pkt.Data, pkt.IsKeyframe, (long)pkt.PtsMs * 1000L);
            }
        }
    }

    private void WireDecoderEvents()
    {
        _mfDecoder.OnGpuNv12Frame = (tex, subIdx, w, h) =>
        {
            // Called synchronously inside _mfDecoder.Decode which already holds _renderLock
            if (_disposed || !_rendererInitialized) return;
            _renderer.RenderNv12Texture(tex, subIdx, w, h);
            UpdateContentRectFromRendererUnsafe();
        };

        _mfDecoder.OnCpuNv12Frame = (ptr, stride, w, h) =>
        {
            if (_disposed || !_rendererInitialized) return;
            _renderer.RenderNv12Cpu(ptr, stride, w, h);
            UpdateContentRectFromRendererUnsafe();
        };

        _mfDecoder.OnResolutionChanged = (w, h) =>
        {
            _remoteWidth = w;
            _remoteHeight = h;
            SafeBeginInvoke(() =>
            {
                _inputManager.SetRemoteSize(w, h);
                SyncContentRect();
            });
        };

        _mfDecoder.OnKeyframeNeeded = () =>
        {
            _conn.SendRequestKeyframe();
        };
    }

    private void WireInputEvents()
    {
        _inputManager.MouseMove += (nx, ny, drag) => _conn.SendMouseMove(nx, ny, drag);
        _inputManager.MouseButton += (btn, down, nx, ny) => _conn.SendMouseButton(btn, down, nx, ny);
        _inputManager.MouseDoubleClick += (btn, nx, ny) => _conn.SendMouseDoubleClick(btn, nx, ny);
        _inputManager.MouseScroll += (lx, ly, px, py, precise) => _conn.SendMouseScroll(lx, ly, px, py, precise);
        _inputManager.KeyEvent += (code, down, mods) => _conn.SendKey(code, down, mods);
        _inputManager.TextInput += text => _conn.SendTextInput(text);
        _inputManager.PointerLockChanged += locked =>
        {
            SafeBeginInvoke(() => _toolbar.UpdateState(pointerLocked: locked));
        };
        _inputManager.ToggleFullscreenRequested += () =>
        {
            SafeBeginInvoke(ToggleFullscreen);
        };
    }

    private void WireToolbarEvents()
    {
        _toolbar.ResolutionChanged += tierStr =>
        {
            var tier = ParseResolutionTier(tierStr);
            _settings.ResolutionTier = tier;
            DeviceStore.Shared.SaveSettings(_settings);
            _toolbar.UpdateState(resolution: tierStr);

            if (tier == ResolutionTier.Match)
            {
                var screen = Screen.FromControl(this);
                int w = screen.Bounds.Width & ~1;
                int h = screen.Bounds.Height & ~1;
                double scale = DeviceDpi / 96.0;
                _conn.SendResolution(tier, w, h, scale);
            }
            else
            {
                _conn.SendResolution(tier);
            }
        };

        _toolbar.ScaleModeChanged += modeStr =>
        {
            var mode = ParseScaleMode(modeStr);
            _settings.ScaleMode = mode;
            DeviceStore.Shared.SaveSettings(_settings);
            _toolbar.UpdateState(scaleMode: modeStr);

            _renderer.ScaleMode = mode;
            SyncContentRect();
        };

        _toolbar.FpsChanged += (fps, auto) =>
        {
            _settings.Fps = fps;
            _settings.AutoFps = auto;
            DeviceStore.Shared.SaveSettings(_settings);
            _toolbar.UpdateState(fps: fps, fpsAuto: auto);
            _conn.SendFps(fps, auto);
        };

        _toolbar.BitrateChanged += (bps, auto) =>
        {
            _settings.BitrateBps = bps;
            _settings.AutoBitrate = auto;
            DeviceStore.Shared.SaveSettings(_settings);
            _toolbar.UpdateState(bitrate: bps, bitrateAuto: auto);
            _conn.SendBitrate(bps, auto);
        };

        _toolbar.CodecChanged += codecStr =>
        {
            var codec = codecStr == "h265" ? VideoCodecType.H265 : VideoCodecType.H264;
            _settings.PreferredCodec = codec;
            DeviceStore.Shared.SaveSettings(_settings);
            _toolbar.UpdateState(codec: codecStr);
            _conn.SendSetCodec(codec);
        };

        _toolbar.AudioToggled += enable =>
        {
            _audioOn = enable;
            _settings.AudioEnabled = enable;
            DeviceStore.Shared.SaveSettings(_settings);
            _toolbar.UpdateState(audioOn: enable);

            lock (_audioLock)
            {
                if (enable)
                {
                    try { _audioPlayer.Start(48000, 2); } catch { }
                }
                else
                {
                    _audioPlayer.Stop();
                }
            }
            _conn.SendSetAudio(enable);
        };

        _toolbar.PrivacyToggled += enable =>
        {
            _privacyOn = enable;
            _toolbar.UpdateState(privacyOn: enable);
            _conn.SendSetPrivacyScreen(enable);
        };

        _toolbar.PointerLockToggled += () => _inputManager.TogglePointerLock();

        _toolbar.DisplaySelected += id =>
        {
            _conn.SendSetDisplay((uint)id);
        };

        _toolbar.FullscreenToggled += ToggleFullscreen;
        _toolbar.CtrlAltDelRequested += () => _conn.SendCtrlAltDel();
        _toolbar.DisconnectRequested += () => Close();
    }

    private void WireConnectionEvents()
    {
        _conn.VideoFrameReceived += OnVideoFrameReceived;
        _conn.AudioFrameReceived += OnAudioFrameReceived;
        _conn.StreamStarted += OnStreamUpdated;
        _conn.CodecChanged += OnCodecChanged;
        _conn.QualityActiveChanged += OnQualityActiveChanged;
        _conn.CursorShapeReceived += OnCursorShapeReceived;
        _conn.ClipboardReceived += OnClipboardReceived;
        _conn.StatsUpdated += OnStatsUpdated;
        _conn.AuthSucceeded += OnAuthSucceeded;
        _conn.ServerHelloReceived += OnServerHelloReceived;
        _conn.Disconnected += OnDisconnected;
    }

    private void UnwireConnectionEvents()
    {
        _conn.VideoFrameReceived -= OnVideoFrameReceived;
        _conn.AudioFrameReceived -= OnAudioFrameReceived;
        _conn.StreamStarted -= OnStreamUpdated;
        _conn.CodecChanged -= OnCodecChanged;
        _conn.QualityActiveChanged -= OnQualityActiveChanged;
        _conn.CursorShapeReceived -= OnCursorShapeReceived;
        _conn.ClipboardReceived -= OnClipboardReceived;
        _conn.StatsUpdated -= OnStatsUpdated;
        _conn.AuthSucceeded -= OnAuthSucceeded;
        _conn.ServerHelloReceived -= OnServerHelloReceived;
        _conn.Disconnected -= OnDisconnected;
    }

    // ── Connection event handlers (called from background thread) ────────

    private void OnVideoFrameReceived(VideoFramePacket pkt)
    {
        if (_disposed || !_rendererInitialized) return;
        // Non-blocking enqueue to dedicated video worker so WebSocket receive loop never stalls
        _videoChannel.Writer.TryWrite(pkt);
    }

    private void OnAudioFrameReceived(AudioFramePacket pkt)
    {
        if (!_audioOn) return;
        lock (_audioLock)
        {
            if (!_disposed && _audioPlayer.IsRunning)
            {
                _audioPlayer.PushAdtsAac(pkt.Data);
            }
        }
    }

    private void OnStreamUpdated(StreamInfo info)
    {
        _streamInfo = info;
        _remoteWidth = Math.Max(1, info.Width);
        _remoteHeight = Math.Max(1, info.Height);

        SafeBeginInvoke(() =>
        {
            _inputManager.SetRemoteSize(_remoteWidth, _remoteHeight);
            SyncToolbarDisplays();
            SyncContentRect();
        });
    }

    private void OnCodecChanged(VideoCodecType codec)
    {
        SafeBeginInvoke(() =>
        {
            string s = codec == VideoCodecType.H265 ? "h265" : "h264";
            _toolbar.UpdateState(codec: s);
        });
    }

    private void OnQualityActiveChanged(int fps, int bitrate)
    {
        SafeBeginInvoke(() => _toolbar.UpdateState(fps: fps, bitrate: bitrate));
    }

    private void OnCursorShapeReceived(CursorShapeInfo info)
    {
        SafeBeginInvoke(() => ApplyRemoteCursor(info));
    }

    private void OnClipboardReceived(ClipboardData data)
    {
        if (!string.IsNullOrEmpty(data.Text))
        {
            _clipboardSync.ApplyRemoteText(data.Text);
        }
        else if (!string.IsNullOrEmpty(data.ImageBase64))
        {
            _clipboardSync.ApplyRemoteImageBase64(data.ImageBase64);
        }
    }

    private void OnStatsUpdated(ClientStats stats)
    {
        double renderFps = _renderer.RenderedFps > 0 ? _renderer.RenderedFps : stats.Fps;
        double mbps = stats.BitrateKbps / 1000.0;
        string codec = stats.Codec switch
        {
            VideoCodecType.H265 => "H.265",
            VideoCodecType.Jpeg => "JPEG",
            _ => "H.264",
        };
        bool hw = stats.Codec != VideoCodecType.Jpeg && _mfDecoder.IsHardware;

        SafeBeginInvoke(() => _toolbar.UpdateHud(renderFps, mbps, stats.RttMs, codec, hw));
    }

    private void OnAuthSucceeded(string username, string token)
    {
        if (_connectParams.RememberDevice && !string.IsNullOrEmpty(token))
        {
            DeviceStore.Shared.UpdateToken(_connectParams.Host, _connectParams.Port, username, token);
        }
    }

    private void OnServerHelloReceived(string os, string computerName, string modelId)
    {
        if (_connectParams.RememberDevice)
        {
            DeviceStore.Shared.UpdateMachineInfo(_connectParams.Host, _connectParams.Port, computerName, modelId, os);
        }
    }

    private void OnDisconnected(string reason)
    {
        SafeBeginInvoke(() =>
        {
            if (_disposed) return;
            if (!string.IsNullOrWhiteSpace(reason))
            {
                MessageBox.Show(this, $"远端连接已断开: {reason}", "Remoter", MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
            Close();
        });
    }

    // ── Viewport, Layout & Fullscreen ────────────────────────────────────

    private void OnViewportResized(int width, int height)
    {
        if (_disposed || !_rendererInitialized) return;

        // Never block the WinForms UI thread on _renderLock (prevents DXGI Present AB-BA deadlock).
        // Try immediate resize only if the video thread is idle; otherwise queue it for the next frame.
        if (Monitor.TryEnter(_renderLock, 0))
        {
            try
            {
                Interlocked.Exchange(ref _pendingResizeW, 0);
                Interlocked.Exchange(ref _pendingResizeH, 0);
                _renderer.Resize(width, height);
            }
            finally
            {
                Monitor.Exit(_renderLock);
            }
        }
        else
        {
            Volatile.Write(ref _pendingResizeW, width);
            Volatile.Write(ref _pendingResizeH, height);
        }

        SyncContentRect();
        _toolbar?.UpdatePosition();
        _inputManager?.UpdateClipCursor();
    }

    private void OnFilesDropped(string[] files)
    {
        foreach (string path in files)
        {
            if (File.Exists(path))
            {
                _ = _conn.UploadFileAsync(path);
            }
        }
    }

    protected override void OnMove(EventArgs e)
    {
        base.OnMove(e);
        _toolbar?.UpdatePosition();
        _inputManager?.UpdateClipCursor();
    }

    protected override void OnResize(EventArgs e)
    {
        base.OnResize(e);
        _toolbar?.UpdatePosition();
        _inputManager?.UpdateClipCursor();
    }

    protected override void OnActivated(EventArgs e)
    {
        base.OnActivated(e);
        _inputManager?.SetWindowActive(true);
        _conn?.SetReverseClipboardActive(true);
    }

    protected override void OnDeactivate(EventArgs e)
    {
        base.OnDeactivate(e);
        // Ignore transient deactivation caused by clicking our own FloatingToolbar
        if (_toolbar != null && Form.ActiveForm == _toolbar) return;
        _inputManager?.SetWindowActive(false);
    }

    private void ToggleFullscreen()
    {
        if (!_fullscreen)
        {
            _savedBorderStyle = FormBorderStyle;
            _savedWindowState = WindowState;
            _savedBounds = Bounds;

            FormBorderStyle = FormBorderStyle.None;
            WindowState = FormWindowState.Normal;
            Bounds = Screen.FromControl(this).Bounds;
            _fullscreen = true;
        }
        else
        {
            FormBorderStyle = _savedBorderStyle;
            Bounds = _savedBounds;
            WindowState = _savedWindowState;
            _fullscreen = false;
        }

        _toolbar.UpdateState(fullscreen: _fullscreen);
        _toolbar.UpdatePosition();
        _inputManager.UpdateClipCursor();
        _videoHost.Focus();
    }

    private void SyncContentRect()
    {
        Rectangle rect;
        var cr = _renderer.ContentRect;
        if (cr.Width > 1 && cr.Height > 1)
        {
            rect = new Rectangle(
                (int)Math.Round(cr.X),
                (int)Math.Round(cr.Y),
                Math.Max(1, (int)Math.Round(cr.Width)),
                Math.Max(1, (int)Math.Round(cr.Height)));
        }
        else
        {
            rect = RawInputManager.ComputeContentRect(
                _videoHost.ClientSize.Width,
                _videoHost.ClientSize.Height,
                _remoteWidth,
                _remoteHeight,
                FormatScaleMode(_settings.ScaleMode));
        }
        _inputManager.SetContentRect(rect);
    }

    private void UpdateContentRectFromRendererUnsafe()
    {
        var cr = _renderer.ContentRect;
        if (cr.Width > 1 && cr.Height > 1)
        {
            _inputManager.SetContentRect(new Rectangle(
                (int)Math.Round(cr.X),
                (int)Math.Round(cr.Y),
                Math.Max(1, (int)Math.Round(cr.Width)),
                Math.Max(1, (int)Math.Round(cr.Height))));
        }
    }

    private void SyncToolbarFromState()
    {
        _toolbar.UpdateState(
            resolution: FormatResolutionTier(_settings.ResolutionTier),
            scaleMode: FormatScaleMode(_settings.ScaleMode),
            fps: _settings.Fps,
            fpsAuto: _settings.AutoFps,
            bitrate: _settings.BitrateBps,
            bitrateAuto: _settings.AutoBitrate,
            codec: _settings.PreferredCodec == VideoCodecType.H265 ? "h265" : "h264",
            audioOn: _audioOn,
            privacyOn: _privacyOn,
            pointerLocked: _inputManager.IsPointerLocked,
            fullscreen: _fullscreen);
        SyncToolbarDisplays();
    }

    private void SyncToolbarDisplays()
    {
        var displays = _streamInfo.Displays ?? Array.Empty<DisplayInfo>();
        var list = displays
            .Select(d => ((int)d.Id, d.Name ?? "", d.Width, d.Height))
            .ToList();
        _toolbar.SetDisplays(list, (int)_streamInfo.ActiveDisplayId);
    }

    // ── Custom remote cursor ─────────────────────────────────────────────

    private void ApplyRemoteCursor(CursorShapeInfo info)
    {
        // UU-Remote Section 15 parity: empty PNG indicates remote OS hid the cursor (e.g. fullscreen video/game)
        // Note: Remoter-Mac/Win cursor_shape omits width/height, so check PngBytes only (never info.Width/Height).
        if (info.PngBytes == null || info.PngBytes.Length == 0)
        {
            ApplyHiddenCursor();
            return;
        }

        try
        {
            using var ms = new MemoryStream(info.PngBytes);
            using var bmp = new Bitmap(ms);
            nint hIcon = bmp.GetHicon();
            if (GetIconInfo(hIcon, out var iconInfo))
            {
                iconInfo.xHotspot = Math.Clamp(info.HotX, 0, Math.Max(0, bmp.Width - 1));
                iconInfo.yHotspot = Math.Clamp(info.HotY, 0, Math.Max(0, bmp.Height - 1));
                iconInfo.fIcon = false;
                nint hCursor = CreateIconIndirect(ref iconInfo);
                if (iconInfo.hbmColor != nint.Zero) DeleteObject(iconInfo.hbmColor);
                if (iconInfo.hbmMask != nint.Zero) DeleteObject(iconInfo.hbmMask);
                DestroyIcon(hIcon);

                if (hCursor != nint.Zero)
                {
                    var nextCursor = new Cursor(hCursor);
                    _videoHost.Cursor = nextCursor;
                    DisposeCustomCursor();
                    _customCursor = nextCursor;
                    _customCursorIconHandle = hCursor;
                }
            }
            else
            {
                DestroyIcon(hIcon);
            }
        }
        catch
        {
            // Keep existing cursor on malformed PNG
        }
    }

    private void ApplyHiddenCursor()
    {
        if (_hiddenCursor == null)
        {
            try
            {
                using var bmp = new Bitmap(1, 1);
                bmp.SetPixel(0, 0, Color.Transparent);
                nint hIcon = bmp.GetHicon();
                if (GetIconInfo(hIcon, out var iconInfo))
                {
                    iconInfo.xHotspot = 0;
                    iconInfo.yHotspot = 0;
                    iconInfo.fIcon = false;
                    nint hCursor = CreateIconIndirect(ref iconInfo);
                    if (iconInfo.hbmColor != nint.Zero) DeleteObject(iconInfo.hbmColor);
                    if (iconInfo.hbmMask != nint.Zero) DeleteObject(iconInfo.hbmMask);
                    DestroyIcon(hIcon);
                    if (hCursor != nint.Zero)
                    {
                        _hiddenCursorIconHandle = hCursor;
                        _hiddenCursor = new Cursor(hCursor);
                    }
                }
                else
                {
                    DestroyIcon(hIcon);
                }
            }
            catch { }
        }

        if (_hiddenCursor != null)
        {
            _videoHost.Cursor = _hiddenCursor;
        }
    }

    private void DisposeCustomCursor()
    {
        _customCursor?.Dispose();
        _customCursor = null;
        if (_customCursorIconHandle != nint.Zero)
        {
            DestroyIcon(_customCursorIconHandle);
            _customCursorIconHandle = nint.Zero;
        }
    }

    private void DisposeHiddenCursor()
    {
        _hiddenCursor?.Dispose();
        _hiddenCursor = null;
        if (_hiddenCursorIconHandle != nint.Zero)
        {
            DestroyIcon(_hiddenCursorIconHandle);
            _hiddenCursorIconHandle = nint.Zero;
        }
    }

    // ── Helpers & Shutdown ───────────────────────────────────────────────

    private void SafeBeginInvoke(Action action)
    {
        if (_disposed || IsDisposed || !IsHandleCreated) return;
        try
        {
            if (InvokeRequired) BeginInvoke(action);
            else action();
        }
        catch (ObjectDisposedException) { }
        catch (InvalidOperationException) { }
    }

    private static ResolutionTier ParseResolutionTier(string s) => s switch
    {
        "match" => ResolutionTier.Match,
        "1080"  => ResolutionTier.Res1080,
        "2k"    => ResolutionTier.Res2K,
        _       => ResolutionTier.Native,
    };

    private static string FormatResolutionTier(ResolutionTier t) => t switch
    {
        ResolutionTier.Match   => "match",
        ResolutionTier.Res1080 => "1080",
        ResolutionTier.Res2K   => "2k",
        _                      => "native",
    };

    private static ScaleMode ParseScaleMode(string s) => s switch
    {
        "stretch"  => ScaleMode.Stretch,
        "original" => ScaleMode.Original,
        _          => ScaleMode.Fit,
    };

    private static string FormatScaleMode(ScaleMode m) => m switch
    {
        ScaleMode.Stretch  => "stretch",
        ScaleMode.Original => "original",
        _                  => "fit",
    };

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (!_disposed)
        {
            _disposed = true;
            UnwireConnectionEvents();
            _videoChannel.Writer.TryComplete();
            try { _videoWorkerTask?.Wait(400); } catch { }

            _inputManager.Dispose();
            _clipboardSync.Dispose();

            if (!_toolbar.IsDisposed)
            {
                _toolbar.Close();
                _toolbar.Dispose();
            }

            lock (_audioLock)
            {
                _audioPlayer.Dispose();
            }

            lock (_renderLock)
            {
                _mfDecoder.Dispose();
                _jpegDecoder.Dispose();
                _renderer.Dispose();
            }

            _videoHost.Cursor = Cursors.Default;
            DisposeCustomCursor();
            DisposeHiddenCursor();

            _ = Task.Run(async () =>
            {
                try { await _conn.DisconnectAsync(); } catch { }
                _conn.Dispose();
            });
        }

        base.OnFormClosing(e);
    }

    // ── Win32 Cursor P/Invoke ────────────────────────────────────────────

    [StructLayout(LayoutKind.Sequential)]
    private struct ICONINFO
    {
        [MarshalAs(UnmanagedType.Bool)] public bool fIcon;
        public int xHotspot;
        public int yHotspot;
        public nint hbmMask;
        public nint hbmColor;
    }

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetIconInfo(nint hIcon, out ICONINFO piconinfo);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern nint CreateIconIndirect(ref ICONINFO piconinfo);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyIcon(nint hIcon);

    [DllImport("gdi32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DeleteObject(nint hObject);
}
