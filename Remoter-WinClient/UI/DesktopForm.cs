using System.Drawing;
using System.Runtime.InteropServices;
using System.Threading.Channels;
using System.Windows.Forms;
using RemoterWinClient.Input;
using Vortice.MediaFoundation;

namespace RemoterWinClient.UI;

/// <summary>
/// Native dark-mode remote desktop window hosting:
/// - VideoHostControl (D3D11 Flip-Model SwapChain HWND)
/// - MfVideoDecoder (GPU zero-copy NV12 / CPU NV12) + JpegDecoder fallback
/// - WasapiAudioPlayer (ADTS AAC -> WASAPI)
/// - RawInputManager (high-polling-rate mouse, Pointer Lock, smooth touchpad, Win/Alt keyboard)
/// - ClipboardSync (bidirectional text/PNG with FNV-1a anti-loop)
/// - FloatingToolbar (owned DWM-composited auto-hiding control bar)
/// - StatsHudOverlay (owned click-through translucent black bottom-right performance HUD)
/// </summary>
public sealed class DesktopForm : Form
{
    private readonly RemoterConnection _conn;
    private readonly ConnectParams _connectParams;
    private StreamInfo _streamInfo;
    private ClientSettings _settings;

    private readonly VideoHostControl _videoHost;
    private readonly Label _imeEchoLabel;
    private readonly Label _dropHintLabel;
    private readonly System.Windows.Forms.Timer _dropToastTimer;
    private readonly FloatingToolbar _toolbar;
    private readonly StatsHudOverlay _statsHud;
    private readonly RawInputManager _inputManager;
    private readonly ClipboardSync _clipboardSync;

    private readonly D3D11Renderer _renderer = new();
    private readonly FfmpegVideoDecoder _ffmpegDecoder = new();
    private readonly MfVideoDecoder _mfDecoder = new();
    private readonly JpegDecoder _jpegDecoder = new();
    private readonly WasapiAudioPlayer _audioPlayer = new();
    private bool _useFfmpeg;

    private readonly object _renderLock = new();
    private readonly object _audioLock = new();

    // Dedicated MTA video thread owns D3D11Renderer & MfVideoDecoder init, decode, render & dispose.
    // Unbounded channel ensures we NEVER randomly drop an H.264/H.265 P-frame mid-GOP.
    private readonly Channel<VideoFramePacket> _videoChannel = Channel.CreateUnbounded<VideoFramePacket>(
        new UnboundedChannelOptions
        {
            SingleReader = true,
            SingleWriter = false,
        });
    private Thread? _videoThread;
    private nint _videoHostHwnd;
    private int _initWidth;
    private int _initHeight;
    private int _pendingResizeW;
    private int _pendingResizeH;
    private bool _firstFrameLogged;
    private long _videoRecvCount;
    private long _lastStatsLogTick;

    private VideoCodecType _activeDecoderCodec = VideoCodecType.Jpeg;
    private int _remoteWidth;
    private int _remoteHeight;
    private bool _mfInitialized;
    private bool _rendererInitialized;
    private bool _audioOn;
    private bool _privacyOn;
    private bool _virtualDisplayOn;
    private bool _fullscreen;
    private bool _imeCalibrating;
    private bool _imeDragging;
    private Point _imeDragStartScreen;
    private int _imeDragStartOffsetX;
    private int _imeDragStartOffsetY;
    private string _lastImeCompText = "";
    private bool _statsHudVisible = true;
    private bool _codecCapsSent;
    private bool _hevcFallbackRequested;
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
        // 启动后默认最大化窗口（铺满工作区并保留顶部标题栏与 Windows 任务栏/控制栏）
        WindowState = FormWindowState.Maximized;

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

        // ── Draggable IME composition echo pill (hidden when empty & not calibrating) ──
        _imeEchoLabel = new Label
        {
            AutoSize = true,
            MinimumSize = new Size(56, 28),
            Visible = false,
            BackColor = Color.White,
            ForeColor = Color.FromArgb(17, 17, 17),
            Font = new Font("Microsoft YaHei UI", 11f, FontStyle.Regular),
            Padding = new Padding(8, 4, 8, 4),
            BorderStyle = BorderStyle.FixedSingle,
            TextAlign = ContentAlignment.MiddleLeft,
            Cursor = Cursors.SizeAll,
            TabStop = false,
        };
        _imeEchoLabel.MouseDown += OnImeEchoMouseDown;
        _imeEchoLabel.MouseMove += OnImeEchoMouseMove;
        _imeEchoLabel.MouseUp += OnImeEchoMouseUp;
        _videoHost.Controls.Add(_imeEchoLabel);
        _videoHost.ImeTextCommitted += text => _conn?.SendTextInput(text);
        _videoHost.ImeCompositionChanged += UpdateImeEcho;

        // ── Centered Drag & Drop hint / upload progress toast ──
        AllowDrop = true;
        _dropHintLabel = new Label
        {
            AutoSize = true,
            Visible = false,
            BackColor = Color.FromArgb(24, 30, 42),
            ForeColor = Color.White,
            Font = new Font("Microsoft YaHei UI", 12f, FontStyle.Bold),
            Padding = new Padding(18, 10, 18, 10),
            BorderStyle = BorderStyle.FixedSingle,
            Text = "📁 松开即上传文件到远端",
            TabStop = false,
        };
        _videoHost.Controls.Add(_dropHintLabel);
        _dropToastTimer = new System.Windows.Forms.Timer { Interval = 2500 };
        _dropToastTimer.Tick += (_, _) =>
        {
            _dropToastTimer.Stop();
            if (!_dropHintLabel.IsDisposed) _dropHintLabel.Visible = false;
        };

        DragEnter += (_, e) =>
        {
            if (e.Data?.GetDataPresent(DataFormats.FileDrop) == true)
            {
                e.Effect = DragDropEffects.Copy;
                SetDropOverlayVisible(true);
            }
            else
            {
                e.Effect = DragDropEffects.None;
            }
        };
        DragLeave += (_, _) => SetDropOverlayVisible(false);
        DragDrop += (_, e) =>
        {
            SetDropOverlayVisible(false);
            if (e.Data?.GetData(DataFormats.FileDrop) is string[] dropped && dropped.Length > 0)
            {
                OnFilesDropped(dropped);
            }
        };
        _videoHost.ImeEchoBoundsProvider = () =>
        {
            if (_disposed || _imeEchoLabel.IsDisposed) return null;
            if (_imeEchoLabel.Visible && _imeEchoLabel.Width > 0 && _imeEchoLabel.Height > 0)
                return _imeEchoLabel.Bounds;
            // Even before the echo pill becomes visible (WM_IME_STARTCOMPOSITION),
            // anchor the OS candidate window directly at the calibrated per-resolution offset.
            return ComputeCalibratedImeAnchorRect();
        };

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

        // ── FloatingToolbar & StatsHudOverlay ──
        _toolbar = new FloatingToolbar(this);
        _statsHud = new StatsHudOverlay(this);
        WireToolbarEvents();
        SyncToolbarFromState();

        // ── Viewport & Window lifecycle events ──
        _videoHost.ViewportResized += OnViewportResized;
        _videoHost.FileDragHoverChanged += SetDropOverlayVisible;
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

        _statsHud.SetHudVisible(_statsHudVisible);
        _statsHud.UpdatePosition();

        // Sync initial settings with server
        if (_settings.QualityPreset == QualityPreset.Auto)
        {
            _conn.SendFps(_settings.Fps, _settings.AutoFps);
            _conn.SendBitrate(_settings.BitrateBps, _settings.AutoBitrate);
        }
        else
        {
            ApplyQualityPreset(_settings.QualityPreset, persist: false);
        }
        if (_settings.ChromaMode == ChromaMode.Yuv444)
        {
            _conn.SendChroma(ChromaMode.Yuv444);
        }
        if (_settings.HdrEnabled)
        {
            _conn.SendHdr(true);
        }
        if (_settings.LowLatencyEnabled)
        {
            _conn.SendLowLatency(true);
        }
        _conn.SetClipboardSyncEnabled(_settings.ClipboardSyncEnabled);
        _conn.SetReverseClipboardActive(_settings.ClipboardSyncEnabled);
        if (_settings.ClipboardSyncEnabled)
        {
            _clipboardSync.SyncNow();
        }
        _conn.SendRequestKeyframe();
        SendCodecCapsOnce();

        _videoHost.Focus();
    }

    private void SendCodecCapsOnce()
    {
        if (_codecCapsSent || _disposed) return;
        _codecCapsSent = true;
        bool hevcAvailable = FfmpegVideoDecoder.IsAvailable || ProbeHevcDecoderAvailable();
        string[] caps = hevcAvailable ? new[] { "h265", "h264" } : new[] { "h264" };
        LogVideo($"Advertising codec_caps: [{string.Join(", ", caps)}] (ffmpeg={FfmpegVideoDecoder.IsAvailable})");
        _conn.SendCodecCaps(caps);
    }

    private static bool ProbeHevcDecoderAvailable()
    {
        try
        {
            MfVideoDecoder.EnsureMediaFoundationStarted();
            var categoryVideoDecoder = new Guid("d6c02d4b-6833-45b4-971a-05a4b04bab91");
            var majorVideo = new Guid("73646976-0000-0010-8000-00aa00389b71");
            var subtypeHevc = new Guid("43564548-0000-0010-8000-00aa00389b71");
            const uint syncAndSort = 0x00000001 | 0x00000040;

            MediaFactory.MFTEnumEx(
                categoryVideoDecoder,
                syncAndSort,
                inputType: new RegisterTypeInfo { GuidMajorType = majorVideo, GuidSubtype = subtypeHevc },
                outputType: null,
                out nint pppActivate,
                out uint count);

            if (pppActivate != nint.Zero)
            {
                try
                {
                    for (uint i = 0; i < count; i++)
                    {
                        nint pAct = Marshal.ReadIntPtr(pppActivate, (int)i * IntPtr.Size);
                        if (pAct != nint.Zero)
                        {
                            Marshal.Release(pAct);
                        }
                    }
                }
                finally
                {
                    Marshal.FreeCoTaskMem(pppActivate);
                }
            }

            return count > 0;
        }
        catch
        {
            return false;
        }
    }

    private void InitializeVideoPipeline()
    {
        if (_disposed || _videoThread != null) return;

        _videoHostHwnd = _videoHost.Handle;
        _initWidth = Math.Max(1, _videoHost.ClientSize.Width);
        _initHeight = Math.Max(1, _videoHost.ClientSize.Height);
        _conn.DecodeMsProvider = () => _useFfmpeg ? _ffmpegDecoder.LastDecodeMs : _mfDecoder.LastDecodeMs;
        SyncContentRect();

        _videoThread = new Thread(VideoWorkerLoop)
        {
            Name = "RemoterVideoPipeline",
            IsBackground = true,
            Priority = ThreadPriority.AboveNormal,
        };
        _videoThread.SetApartmentState(ApartmentState.MTA);
        _videoThread.Start();
    }

    private void VideoWorkerLoop()
    {
        try
        {
            LogVideo($"MTA video thread starting: hwnd=0x{_videoHostHwnd:X} size={_initWidth}x{_initHeight} codec={_streamInfo.Codec} remote={_remoteWidth}x{_remoteHeight}");

            lock (_renderLock)
            {
                if (_disposed) return;

                _renderer.Initialize(_videoHostHwnd, _initWidth, _initHeight);
                _renderer.ScaleMode = _settings.ScaleMode;
                _renderer.VSyncEnabled = _settings.VSyncEnabled;
                _renderer.SharpnessLevel = _settings.Sharpness;
                _renderer.ToneMap = _settings.ToneMapEnabled;
                _rendererInitialized = true;
                SafeBeginInvoke(() => { _videoHost.D3D11Active = true; });

                LogVideo($"D3D11 ready: tearing={_renderer.AllowTearingSupported} vsync={_renderer.VSyncEnabled}");

                if (_streamInfo.Codec != VideoCodecType.Jpeg)
                {
                    InitActiveVideoDecoder(_streamInfo.Codec);
                }
            }

            // Ask host for a fresh keyframe once our decoder is ready
            _conn.SendRequestKeyframe();

            var reader = _videoChannel.Reader;
            while (!_disposed && reader.WaitToReadAsync().AsTask().GetAwaiter().GetResult())
            {
                while (!_disposed && reader.TryRead(out var pkt))
                {
                    ProcessVideoFrame(pkt);
                }
            }
        }
        catch (Exception ex)
        {
            LogVideo($"VideoWorkerLoop exception: {ex}");
        }
        finally
        {
            // Dispose COM/D3D11 objects on the same MTA thread that created them
            lock (_renderLock)
            {
                _rendererInitialized = false;
                _mfInitialized = false;
                _useFfmpeg = false;
                try { _ffmpegDecoder.Dispose(); } catch { }
                try { _mfDecoder.Dispose(); } catch { }
                try { _jpegDecoder.Dispose(); } catch { }
                try { _renderer.Dispose(); } catch { }
            }
            LogVideo("MTA video thread exited cleanly");
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
                if (!_firstFrameLogged)
                {
                    _firstFrameLogged = true;
                    LogVideo($"First JPEG frame rendered ({pkt.Data.Length} bytes)");
                }
            }
            else
            {
                if (!_mfInitialized || _activeDecoderCodec != pkt.Codec)
                {
                    if (!InitActiveVideoDecoder(pkt.Codec))
                    {
                        if (pkt.Codec == VideoCodecType.H265 && !_hevcFallbackRequested)
                        {
                            _hevcFallbackRequested = true;
                            LogVideo("Falling back from H.265 to H.264");
                            _conn.SendSetCodec(VideoCodecType.H264);
                        }
                        return;
                    }
                }
                bool decoded = _useFfmpeg
                    ? _ffmpegDecoder.Decode(pkt.Data, pkt.IsKeyframe, (long)pkt.PtsMs * 1000L)
                    : _mfDecoder.Decode(pkt.Data, pkt.IsKeyframe, (long)pkt.PtsMs * 1000L);
                double lastDecMs = _useFfmpeg ? _ffmpegDecoder.LastDecodeMs : _mfDecoder.LastDecodeMs;
                if (decoded && !_firstFrameLogged)
                {
                    _firstFrameLogged = true;
                    LogVideo($"First {pkt.Codec} frame decoded & rendered via {(_useFfmpeg ? "FFmpeg-D3D11VA" : "MF")} (kf={pkt.IsKeyframe}, len={pkt.Data.Length}, decodeMs={lastDecMs:F1})");
                }

                long nowTick = Environment.TickCount64;
                if (nowTick - _lastStatsLogTick >= 3000)
                {
                    _lastStatsLogTick = nowTick;
                    long decCnt = _useFfmpeg ? _ffmpegDecoder.DecodedFrames : _mfDecoder.DecodedFrames;
                    long dropCnt = _useFfmpeg ? _ffmpegDecoder.DroppedFrames : _mfDecoder.DroppedFrames;
                    string errStr = _useFfmpeg ? _ffmpegDecoder.LastError : _mfDecoder.LastError;
                    LogVideo($"Stats ({(_useFfmpeg ? "FFmpeg" : "MF")}): recv={Interlocked.Read(ref _videoRecvCount)} decoded={decCnt} dropped={dropCnt} renderFps={_renderer.RenderedFps:F1} err='{errStr}'");
                }
            }
        }
    }

    private static void LogVideo(string msg)
    {
        try
        {
            string dir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "RemoterWinClient");
            Directory.CreateDirectory(dir);
            File.AppendAllText(
                Path.Combine(dir, "video.log"),
                $"[{DateTime.Now:HH:mm:ss.fff}] {msg}\r\n");
        }
        catch { }
    }

    private bool InitActiveVideoDecoder(VideoCodecType codec)
    {
        // 1. Prefer FFmpeg 7.x D3D11VA zero-copy hardware decoder (H.264 + H.265/HEVC, zero MF MFT quirks)
        if (FfmpegVideoDecoder.IsAvailable)
        {
            try
            {
                _ffmpegDecoder.Initialize(codec, _remoteWidth, _remoteHeight, _renderer.Device);
                _useFfmpeg = true;
                _activeDecoderCodec = codec;
                _mfInitialized = true;
                LogVideo($"FfmpegVideoDecoder ready: codec={codec} fmt={_ffmpegDecoder.OutputFormat} hw={_ffmpegDecoder.IsHardware} zeroCopy={_ffmpegDecoder.IsGpuZeroCopy}");
                return true;
            }
            catch (Exception ex)
            {
                _useFfmpeg = false;
                LogVideo($"FfmpegVideoDecoder init failed ({ex.Message}), falling back to MfVideoDecoder");
            }
        }

        // 2. Fallback to Media Foundation
        try
        {
            _mfDecoder.PreferHdr = _settings.HdrEnabled;
            _mfDecoder.Prefer444 = _settings.ChromaMode == ChromaMode.Yuv444;
            var hwDevice = _settings.HardwareDecode ? _renderer.Device : null;
            _mfDecoder.Initialize(codec, _remoteWidth, _remoteHeight, hwDevice);
            _useFfmpeg = false;
            _activeDecoderCodec = codec;
            _mfInitialized = true;
            LogVideo($"MfVideoDecoder ready: codec={codec} fmt={_mfDecoder.OutputFormat} hw={_mfDecoder.IsHardware} zeroCopy={_mfDecoder.IsGpuZeroCopy}");
            return true;
        }
        catch (Exception ex)
        {
            _mfInitialized = false;
            LogVideo($"MfVideoDecoder init failed: {ex.Message}");
            return false;
        }
    }

    private void WireDecoderEvents()
    {
        _ffmpegDecoder.OnGpuFrame = (tex, subIdx, w, h, fmt) =>
        {
            if (_disposed || !_rendererInitialized) return;
            switch (fmt)
            {
                case DecodedPixelFormat.P010:
                    _renderer.RenderP010Texture(tex, subIdx, w, h);
                    break;
                case DecodedPixelFormat.Ayuv:
                    _renderer.RenderAyuvTexture(tex, subIdx, w, h);
                    break;
                default:
                    _renderer.RenderNv12Texture(tex, subIdx, w, h);
                    break;
            }
            UpdateContentRectFromRendererUnsafe();
        };

        _ffmpegDecoder.OnCpuNv12Frame = (ptr, stride, w, h) =>
        {
            if (_disposed || !_rendererInitialized) return;
            _renderer.RenderNv12Cpu(ptr, stride, w, h);
            UpdateContentRectFromRendererUnsafe();
        };

        _ffmpegDecoder.OnKeyframeNeeded = () =>
        {
            _conn.SendRequestKeyframe();
        };

        _mfDecoder.OnGpuFrame = (tex, subIdx, w, h, fmt) =>
        {
            // Called synchronously inside _mfDecoder.Decode which already holds _renderLock
            if (_disposed || !_rendererInitialized) return;
            switch (fmt)
            {
                case DecodedPixelFormat.P010:
                    _renderer.RenderP010Texture(tex, subIdx, w, h);
                    break;
                case DecodedPixelFormat.Ayuv:
                    _renderer.RenderAyuvTexture(tex, subIdx, w, h);
                    break;
                default:
                    _renderer.RenderNv12Texture(tex, subIdx, w, h);
                    break;
            }
            UpdateContentRectFromRendererUnsafe();
        };

        _mfDecoder.OnCpuFrame = (ptr, byteLen, stride, w, h, fmt) =>
        {
            if (_disposed || !_rendererInitialized) return;
            switch (fmt)
            {
                case DecodedPixelFormat.P010:
                    if (byteLen >= (long)stride * (h + h / 2))
                        _renderer.RenderP010(ptr, w, h, stride);
                    break;
                case DecodedPixelFormat.Ayuv:
                    if (byteLen >= (long)stride * h)
                        _renderer.RenderAyuv(ptr, w, h, stride);
                    break;
                default:
                    _renderer.RenderNv12Cpu(ptr, stride, w, h);
                    break;
            }
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

        _mfDecoder.OnColorRangeChanged = fullRange =>
        {
            if (_disposed || !_rendererInitialized) return;
            _renderer.FullRangeColor = fullRange;
            LogVideo($"Color range synced from decoder: fullRange={fullRange}");
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

    private void ApplyQualityPreset(QualityPreset preset, bool persist = true)
    {
        _settings.QualityPreset = preset;
        switch (preset)
        {
            case QualityPreset.Auto:
                _settings.AutoFps = true;
                _settings.AutoBitrate = true;
                _settings.Sharpness = SharpnessLevel.Low;
                break;

            case QualityPreset.Smooth:
                _settings.Fps = 30;
                _settings.AutoFps = false;
                _settings.BitrateBps = 4_000_000;
                _settings.AutoBitrate = false;
                _settings.Sharpness = SharpnessLevel.Off;
                break;

            case QualityPreset.Hd:
                _settings.Fps = 60;
                _settings.AutoFps = false;
                _settings.BitrateBps = 8_000_000;
                _settings.AutoBitrate = false;
                _settings.Sharpness = SharpnessLevel.Low;
                break;

            case QualityPreset.Original:
                _settings.Fps = 120;
                _settings.AutoFps = false;
                _settings.BitrateBps = 25_000_000;
                _settings.AutoBitrate = false;
                _settings.Sharpness = SharpnessLevel.Medium;
                break;
        }

        if (persist)
        {
            DeviceStore.Shared.SaveSettings(_settings);
        }

        _renderer.SharpnessLevel = _settings.Sharpness;
        _toolbar.UpdateState(
            qualityPreset: preset,
            fps: _settings.Fps,
            fpsAuto: _settings.AutoFps,
            bitrate: _settings.BitrateBps,
            bitrateAuto: _settings.AutoBitrate,
            sharpness: _settings.Sharpness);

        _conn.SendFps(_settings.Fps, _settings.AutoFps);
        _conn.SendBitrate(_settings.BitrateBps, _settings.AutoBitrate);
    }

    private void WireToolbarEvents()
    {
        _toolbar.QualityPresetChanged += preset => ApplyQualityPreset(preset);

        _toolbar.SharpnessChanged += level =>
        {
            _settings.Sharpness = level;
            DeviceStore.Shared.SaveSettings(_settings);
            _renderer.SharpnessLevel = level;
            _toolbar.UpdateState(sharpness: level);
        };

        _toolbar.ChromaToggled += mode =>
        {
            _settings.ChromaMode = mode;
            _mfDecoder.Prefer444 = mode == ChromaMode.Yuv444;
            DeviceStore.Shared.SaveSettings(_settings);
            _toolbar.UpdateState(chromaMode: mode);
            _conn.SendChroma(mode);
        };

        _toolbar.HdrToggled += enable =>
        {
            _settings.HdrEnabled = enable;
            _settings.ToneMapEnabled = enable;
            _mfDecoder.PreferHdr = enable;
            DeviceStore.Shared.SaveSettings(_settings);
            _renderer.ToneMap = enable;
            _toolbar.UpdateState(hdrOn: enable, toneMapOn: enable);
            _conn.SendHdr(enable);
        };

        _toolbar.ToneMapToggled += enable =>
        {
            _settings.ToneMapEnabled = enable;
            DeviceStore.Shared.SaveSettings(_settings);
            _renderer.ToneMap = enable;
            _toolbar.UpdateState(toneMapOn: enable);
        };

        _toolbar.LowLatencyToggled += enable =>
        {
            _settings.LowLatencyEnabled = enable;
            DeviceStore.Shared.SaveSettings(_settings);
            _toolbar.UpdateState(lowLatencyOn: enable);
            _conn.SendLowLatency(enable);
        };

        _toolbar.VirtualDisplayToggled += enable =>
        {
            _virtualDisplayOn = enable;
            _toolbar.UpdateState(virtualDisplayOn: enable);
            _conn.SendVirtualDisplay(enable ? "create" : "destroy");
        };

        _toolbar.ResolutionChanged += tierStr =>
        {
            var tier = ParseResolutionTier(tierStr);
            _settings.ResolutionTier = tier;
            DeviceStore.Shared.SaveSettings(_settings);
            _toolbar.UpdateState(resolution: tierStr);

            if (tier == ResolutionTier.Match)
            {
                var screen = Screen.FromControl(this);
                double scale = Math.Max(1.0, DeviceDpi / 96.0);
                int w = (int)Math.Round(screen.Bounds.Width / scale) & ~1;
                int h = (int)Math.Round(screen.Bounds.Height / scale) & ~1;
                _conn.SendResolution(tier, Math.Max(2, w), Math.Max(2, h), scale);
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

        _toolbar.ClipboardToggled += enable =>
        {
            _settings.ClipboardSyncEnabled = enable;
            DeviceStore.Shared.SaveSettings(_settings);
            _clipboardSync.Enabled = enable;
            _conn.SetClipboardSyncEnabled(enable);
            _conn.SetReverseClipboardActive(enable);
            _toolbar.UpdateState(clipboardOn: enable);
            if (enable)
            {
                _clipboardSync.SyncNow();
            }
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

        _toolbar.StatsHudToggled += visible =>
        {
            _statsHudVisible = visible;
            _toolbar.UpdateState(statsHudVisible: visible);
            _statsHud.SetHudVisible(visible);
        };

        _toolbar.ImeCalibrateToggled += ToggleImeCalibration;
        _toolbar.FullscreenToggled += ToggleFullscreen;
        _toolbar.CtrlAltDelRequested += () => _conn.SendCtrlAltDel();
        _toolbar.PowerActionRequested += action =>
        {
            if (action == "lock")
            {
                _conn.SendPowerAction("lock");
            }
            else if (action == "sleep")
            {
                if (MessageBox.Show(this, "确定让远程电脑进入休眠吗？", "远程电源控制", MessageBoxButtons.YesNo, MessageBoxIcon.Question) == DialogResult.Yes)
                {
                    _conn.SendPowerAction("sleep");
                }
            }
            else if (action == "restart")
            {
                if (MessageBox.Show(this, "确定重启远程电脑吗？", "远程电源控制", MessageBoxButtons.YesNo, MessageBoxIcon.Warning) == DialogResult.Yes)
                {
                    _conn.SendPowerAction("restart");
                }
            }
        };
        _toolbar.DisconnectRequested += () => Close();
    }

    private void WireConnectionEvents()
    {
        _conn.VideoFrameReceived += OnVideoFrameReceived;
        _conn.AudioFrameReceived += OnAudioFrameReceived;
        _conn.StreamStarted += OnStreamUpdated;
        _conn.CodecChanged += OnCodecChanged;
        _conn.QualityActiveChanged += OnQualityActiveChanged;
        _conn.ChromaActiveChanged += OnChromaActiveChanged;
        _conn.HdrActiveChanged += OnHdrActiveChanged;
        _conn.VirtualDisplayActiveChanged += OnVirtualDisplayActiveChanged;
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
        _conn.ChromaActiveChanged -= OnChromaActiveChanged;
        _conn.HdrActiveChanged -= OnHdrActiveChanged;
        _conn.VirtualDisplayActiveChanged -= OnVirtualDisplayActiveChanged;
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
        if (_disposed) return;
        Interlocked.Increment(ref _videoRecvCount);
        // Non-blocking enqueue to dedicated MTA video thread (never stalls WebSocket receive loop)
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

    private void OnChromaActiveChanged(ChromaMode mode)
    {
        SafeBeginInvoke(() =>
        {
            _settings.ChromaMode = mode;
            _mfDecoder.Prefer444 = mode == ChromaMode.Yuv444;
            _toolbar.UpdateState(chromaMode: mode);
        });
    }

    private void OnHdrActiveChanged(bool enabled)
    {
        SafeBeginInvoke(() =>
        {
            _settings.HdrEnabled = enabled;
            _settings.ToneMapEnabled = enabled;
            _mfDecoder.PreferHdr = enabled;
            _renderer.ToneMap = enabled;
            _toolbar.UpdateState(hdrOn: enabled, toneMapOn: enabled);
        });
    }

    private void OnVirtualDisplayActiveChanged(bool enabled, int? displayId)
    {
        SafeBeginInvoke(() =>
        {
            _virtualDisplayOn = enabled;
            _toolbar.UpdateState(virtualDisplayOn: enabled);
        });
    }

    private void OnCursorShapeReceived(CursorShapeInfo info)
    {
        // Keep local controller's native Windows cursor — do not overlay remote cursor shapes.
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
        double activeDecodeMs = _useFfmpeg ? _ffmpegDecoder.LastDecodeMs : _mfDecoder.LastDecodeMs;
        double decodeMs = (stats.Codec != VideoCodecType.Jpeg && activeDecodeMs > 0)
            ? activeDecodeMs
            : stats.DecodeMs;
        double frameMs = Math.Max(0, stats.EncodeMs) + Math.Max(0.0, decodeMs);
        bool isRelay = _connectParams.Mode == ConnectMode.Relay;
        string transport = stats.Transport;

        SafeBeginInvoke(() => _statsHud.UpdateStats(
            renderFps,
            stats.BitrateKbps,
            stats.RttMs,
            frameMs,
            transport,
            isRelay,
            packetLossPct: 0.0,
            width: _remoteWidth,
            height: _remoteHeight));
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
        if (_disposed) return;

        // Always queue resize for the MTA video thread — UI thread NEVER touches D3D11 or _renderLock.
        Volatile.Write(ref _pendingResizeW, width);
        Volatile.Write(ref _pendingResizeH, height);

        SyncContentRect();
        PositionImeEchoLabel();
        PositionDropHintLabel();
        if (_videoHost.IsImeComposing)
        {
            _videoHost.PositionImeWindow();
        }
        _toolbar?.UpdatePosition();
        _statsHud?.UpdatePosition();
        _inputManager?.UpdateClipCursor();
    }

    private string CurrentResolutionKey() => $"{_remoteWidth}x{_remoteHeight}";

    private ImeOffset GetCurrentImeOffset()
    {
        _settings.ImeOffsets ??= new Dictionary<string, ImeOffset>();
        string key = CurrentResolutionKey();
        if (_settings.ImeOffsets.TryGetValue(key, out var off)) return off;
        if (_settings.ImeOffsets.TryGetValue("*", out var fallback))
            return new ImeOffset { X = fallback.X, Y = fallback.Y };
        return new ImeOffset { X = -120, Y = 120 };
    }

    private void SetCurrentImeOffset(int x, int y, bool save)
    {
        _settings.ImeOffsets ??= new Dictionary<string, ImeOffset>();
        _settings.ImeOffsets[CurrentResolutionKey()] = new ImeOffset { X = x, Y = Math.Max(80, y) };
        if (save)
        {
            DeviceStore.Shared.SaveSettings(_settings);
        }
    }

    private void ToggleImeCalibration()
    {
        _imeCalibrating = !_imeCalibrating;
        _toolbar.UpdateState(imeCalibrating: _imeCalibrating);
        RefreshImeEchoVisibility();
        if (_imeCalibrating)
        {
            _videoHost.PositionImeWindow();
        }
        else
        {
            _videoHost.Focus();
        }
    }

    private void UpdateImeEcho(string compText)
    {
        if (_disposed || _imeEchoLabel.IsDisposed) return;
        _lastImeCompText = compText ?? "";
        RefreshImeEchoVisibility();
    }

    private void RefreshImeEchoVisibility()
    {
        if (_disposed || _imeEchoLabel.IsDisposed) return;
        bool hasComp = !string.IsNullOrEmpty(_lastImeCompText);
        if (!hasComp && !_imeCalibrating)
        {
            _imeEchoLabel.Visible = false;
            _imeEchoLabel.Text = "";
            return;
        }
        _imeEchoLabel.Text = hasComp ? _lastImeCompText : "拖动调整输入法位置";
        _imeEchoLabel.Visible = true;
        _imeEchoLabel.BringToFront();
        PositionImeEchoLabel();
    }

    private void OnImeEchoMouseDown(object? sender, MouseEventArgs e)
    {
        if (e.Button != MouseButtons.Left) return;
        _imeDragging = true;
        _imeDragStartScreen = Control.MousePosition;
        var off = GetCurrentImeOffset();
        _imeDragStartOffsetX = off.X;
        _imeDragStartOffsetY = off.Y;
        _imeEchoLabel.Capture = true;
    }

    private void OnImeEchoMouseMove(object? sender, MouseEventArgs e)
    {
        if (!_imeDragging) return;
        double scale = Math.Max(1.0, (_videoHost.IsHandleCreated ? _videoHost.DeviceDpi : DeviceDpi) / 96.0);
        Point now = Control.MousePosition;
        int dxLogical = (int)Math.Round((now.X - _imeDragStartScreen.X) / scale);
        int dyLogical = (int)Math.Round((now.Y - _imeDragStartScreen.Y) / scale);

        int halfW = (int)Math.Round(_videoHost.ClientSize.Width / (2.0 * scale));
        int labelW = Math.Max(56, (int)Math.Round(_imeEchoLabel.Width / scale));
        int minX = -halfW + 8;
        int maxX = Math.Max(minX, halfW - labelW - 8);
        int maxY = Math.Max(80, (int)Math.Round((_videoHost.ClientSize.Height - _imeEchoLabel.Height) / scale) - 12);

        int newX = Math.Clamp(_imeDragStartOffsetX + dxLogical, minX, maxX);
        int newY = Math.Clamp(_imeDragStartOffsetY - dyLogical, 80, maxY);

        SetCurrentImeOffset(newX, newY, save: false);
        PositionImeEchoLabel();
        _videoHost.PositionImeWindow();
    }

    private void OnImeEchoMouseUp(object? sender, MouseEventArgs e)
    {
        if (!_imeDragging) return;
        _imeDragging = false;
        _imeEchoLabel.Capture = false;
        var off = GetCurrentImeOffset();
        SetCurrentImeOffset(off.X, off.Y, save: true);
        _videoHost.PositionImeWindow();
        if (!_imeCalibrating)
        {
            _videoHost.Focus();
        }
    }

    private Rectangle ComputeCalibratedImeAnchorRect()
    {
        int w = _videoHost.ClientSize.Width;
        int h = _videoHost.ClientSize.Height;
        double scale = Math.Max(1.0, (_videoHost.IsHandleCreated ? _videoHost.DeviceDpi : DeviceDpi) / 96.0);
        int margin = (int)Math.Round(8 * scale);
        int estW = _imeEchoLabel.Width > 0 ? _imeEchoLabel.Width : (int)Math.Round(56 * scale);
        int estH = _imeEchoLabel.Height > 0 ? _imeEchoLabel.Height : (int)Math.Round(28 * scale);
        var off = GetCurrentImeOffset();
        int offsetX = (int)Math.Round(off.X * scale);
        int bottomClearance = (int)Math.Round(Math.Max(80, off.Y) * scale);

        // Pin LEFT edge at (w / 2 + offsetX) so typing longer pinyin grows purely to the right
        // (matching Web's `left: calc(50% + offset.x)` and keeping the OS candidate window anchored).
        int targetX = w / 2 + offsetX;
        int targetY = h - estH - bottomClearance;
        int maxX = Math.Max(margin, w - estW - margin);
        int maxY = Math.Max(margin, h - estH - margin);

        return new Rectangle(
            Math.Clamp(targetX, margin, maxX),
            Math.Clamp(targetY, margin, maxY),
            estW,
            estH);
    }

    private void PositionImeEchoLabel()
    {
        if (_imeEchoLabel == null || _imeEchoLabel.IsDisposed || !_imeEchoLabel.Visible) return;
        var rect = ComputeCalibratedImeAnchorRect();
        _imeEchoLabel.Location = new Point(rect.Left, rect.Top);
    }

    private void SetDropOverlayVisible(bool visible)
    {
        if (_disposed || _dropHintLabel.IsDisposed) return;
        _dropToastTimer.Stop();
        if (visible)
        {
            _dropHintLabel.Text = "📁 松开即上传文件到远端";
            _dropHintLabel.Visible = true;
            _dropHintLabel.BringToFront();
            PositionDropHintLabel();
        }
        else
        {
            _dropHintLabel.Visible = false;
        }
    }

    private void ShowUploadToast(string text, bool autoHide = false)
    {
        SafeBeginInvoke(() =>
        {
            if (_disposed || _dropHintLabel.IsDisposed) return;
            _dropToastTimer.Stop();
            _dropHintLabel.Text = text;
            _dropHintLabel.Visible = true;
            _dropHintLabel.BringToFront();
            PositionDropHintLabel();
            if (autoHide)
            {
                _dropToastTimer.Start();
            }
        });
    }

    private void PositionDropHintLabel()
    {
        if (_dropHintLabel == null || _dropHintLabel.IsDisposed || !_dropHintLabel.Visible) return;
        int w = _videoHost.ClientSize.Width;
        int h = _videoHost.ClientSize.Height;
        _dropHintLabel.Location = new Point(
            Math.Max(8, (w - _dropHintLabel.Width) / 2),
            Math.Max(8, (h - _dropHintLabel.Height) / 2));
    }

    private void OnFilesDropped(string[] files)
    {
        var validFiles = files.Where(File.Exists).ToList();
        if (validFiles.Count == 0) return;

        _ = Task.Run(async () =>
        {
            int uploaded = 0;
            for (int i = 0; i < validFiles.Count; i++)
            {
                if (_disposed) return;
                string path = validFiles[i];
                string name = Path.GetFileName(path);
                ShowUploadToast($"📁 正在上传 ({i + 1}/{validFiles.Count}): {name}");
                try
                {
                    await _conn.UploadFileAsync(path).ConfigureAwait(false);
                    uploaded++;
                }
                catch (Exception ex)
                {
                    LogVideo($"File upload failed ({name}): {ex.Message}");
                }
            }
            if (!_disposed)
            {
                ShowUploadToast(
                    uploaded > 0 ? $"✓ 已上传 {uploaded}/{validFiles.Count} 个文件到远端" : "✕ 文件上传失败",
                    autoHide: true);
            }
        });
    }

    protected override void OnMove(EventArgs e)
    {
        base.OnMove(e);
        _toolbar?.UpdatePosition();
        _statsHud?.UpdatePosition();
        _inputManager?.UpdateClipCursor();
    }

    protected override void OnResize(EventArgs e)
    {
        base.OnResize(e);
        _toolbar?.UpdatePosition();
        _statsHud?.UpdatePosition();
        _inputManager?.UpdateClipCursor();
    }

    protected override void OnActivated(EventArgs e)
    {
        base.OnActivated(e);
        _inputManager?.SetWindowActive(true);
        _conn?.SetReverseClipboardActive(_settings.ClipboardSyncEnabled);
        if (_settings.ClipboardSyncEnabled)
        {
            _clipboardSync?.SyncNow();
        }
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
        _statsHud.UpdatePosition();
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
            qualityPreset: _settings.QualityPreset,
            sharpness: _settings.Sharpness,
            chromaMode: _settings.ChromaMode,
            hdrOn: _settings.HdrEnabled,
            toneMapOn: _settings.ToneMapEnabled,
            lowLatencyOn: _settings.LowLatencyEnabled,
            virtualDisplayOn: _virtualDisplayOn,
            resolution: FormatResolutionTier(_settings.ResolutionTier),
            scaleMode: FormatScaleMode(_settings.ScaleMode),
            fps: _settings.Fps,
            fpsAuto: _settings.AutoFps,
            bitrate: _settings.BitrateBps,
            bitrateAuto: _settings.AutoBitrate,
            codec: _settings.PreferredCodec == VideoCodecType.H265 ? "h265" : "h264",
            audioOn: _audioOn,
            clipboardOn: _settings.ClipboardSyncEnabled,
            privacyOn: _privacyOn,
            pointerLocked: _inputManager.IsPointerLocked,
            fullscreen: _fullscreen,
            statsHudVisible: _statsHudVisible);
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

            _inputManager.Dispose();
            _clipboardSync.Dispose();
            _dropToastTimer.Stop();
            _dropToastTimer.Dispose();

            if (!_toolbar.IsDisposed)
            {
                _toolbar.Close();
                _toolbar.Dispose();
            }

            if (!_statsHud.IsDisposed)
            {
                _statsHud.Close();
                _statsHud.Dispose();
            }

            // Never block the WinForms UI thread on _renderLock or long thread joins;
            // the MTA video thread disposes D3D11Renderer & MfVideoDecoder in its finally block.
            try { _videoThread?.Join(250); } catch { }

            _ = Task.Run(() =>
            {
                lock (_audioLock)
                {
                    try { _audioPlayer.Dispose(); } catch { }
                }
            });

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
