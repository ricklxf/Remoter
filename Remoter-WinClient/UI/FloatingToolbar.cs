using System.Drawing;
using System.Windows.Forms;

namespace RemoterWinClient.UI;

/// <summary>
/// Owned borderless DWM-composited top-edge toolbar overlay for DesktopForm.
/// Because it is a separate owned HWND rather than a GDI child of the D3D11 SwapChain HWND,
/// it never flickers or interferes with DXGI Flip-Model presentation.
/// Collapses to a small top-center pill and auto-hides after 3 seconds of inactivity.
/// </summary>
public sealed class FloatingToolbar : Form
{
    private const int PillWidth = 92;
    private const int PillHeight = 24;
    private const int BarHeight = 38;

    private readonly Form _ownerForm;
    private readonly System.Windows.Forms.Timer _autoHideTimer;
    private bool _expanded;
    private bool _menuOpen;
    private bool _shownOnce;

    // Collapsed pill button
    private readonly Button _pillBtn;

    // Expanded toolbar panel
    private readonly FlowLayoutPanel _barPanel;

    // Interactive controls
    private readonly Button _qualityBtn;
    private readonly Button _audioBtn;
    private readonly Button _micBtn;
    private readonly Button _clipboardBtn;
    private readonly Button _privacyBtn;
    private readonly Button _pointerLockBtn;
    private readonly Button _powerBtn;
    private readonly Button _displayBtn;
    private readonly Button _imeCalibrateBtn;
    private readonly Button _fullscreenBtn;
    private readonly Button _disconnectBtn;
    private readonly Button _collapseBtn;

    private readonly ContextMenuStrip _qualityMenu;
    private readonly ContextMenuStrip _displayMenu;
    private readonly ContextMenuStrip _powerMenu;

    // Current state
    private QualityPreset _qualityPreset = QualityPreset.Auto;
    private SharpnessLevel _sharpness = SharpnessLevel.Low;
    private ChromaMode _chromaMode = ChromaMode.Yuv420;
    private bool _hdrOn;
    private bool _toneMapOn;
    private bool _lowLatencyOn;
    private bool _virtualDisplayOn;
    private string _resolution = "native";
    private string _scaleMode = "fit";
    private int _fps = 60;
    private bool _fpsAuto = true;
    private int _bitrate = 8_000_000;
    private bool _bitrateAuto = true;
    private string _codec = "h264";
    private bool _audioOn;
    private bool _micOn;
    private bool _clipboardOn = true;
    private bool _privacyOn;
    private bool _pointerLocked;
    private bool _imeCalibrating;
    private bool _fullscreen;
    private bool _statsHudVisible = true;
    private int _activeDisplayId;
    private List<(int Id, string Name, int Width, int Height)> _displays = new();

    // Events wired by DesktopForm
    public event Action<QualityPreset>? QualityPresetChanged;
    public event Action<SharpnessLevel>? SharpnessChanged;
    public event Action<ChromaMode>? ChromaToggled;
    public event Action<bool>? HdrToggled;
    public event Action<bool>? ToneMapToggled;
    public event Action<bool>? LowLatencyToggled;
    public event Action<bool>? VirtualDisplayToggled;
    public event Action<bool>? StatsHudToggled;
    public event Action<string>? ResolutionChanged;
    public event Action<string>? ScaleModeChanged;
    public event Action<int, bool>? FpsChanged;
    public event Action<int, bool>? BitrateChanged;
    public event Action<string>? CodecChanged;
    public event Action<bool>? AudioToggled;
    public event Action<bool>? MicToggled;
    public event Action<bool>? ClipboardToggled;
    public event Action<bool>? PrivacyToggled;
    public event Action? PointerLockToggled;
    public event Action<int>? DisplaySelected;
    public event Action? ImeCalibrateToggled;
    public event Action? FullscreenToggled;
    public event Action? DisconnectRequested;
    public event Action? CtrlAltDelRequested;
    public event Action<string>? PowerActionRequested;

    public FloatingToolbar(Form ownerForm)
    {
        _ownerForm = ownerForm ?? throw new ArgumentNullException(nameof(ownerForm));
        Owner = ownerForm;

        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        ShowInTaskbar = false;
        BackColor = Color.White;
        Opacity = 0.96;
        DoubleBuffered = true;

        _autoHideTimer = new System.Windows.Forms.Timer { Interval = 3000 };
        _autoHideTimer.Tick += (_, _) =>
        {
            if (!_menuOpen && !Bounds.Contains(Cursor.Position))
            {
                SetExpanded(false);
            }
        };

        // ── Collapsed top pill ──
        _pillBtn = new Button
        {
            Text = "▼  控制栏",
            Dock = DockStyle.Fill,
            FlatStyle = FlatStyle.Flat,
            BackColor = Color.White,
            ForeColor = DarkTheme.TextMuted,
            Font = new Font("Segoe UI", 8.0f, FontStyle.Regular),
            Cursor = Cursors.Hand,
            TabStop = false,
        };
        _pillBtn.FlatAppearance.BorderColor = DarkTheme.BorderColor;
        _pillBtn.FlatAppearance.BorderSize = 1;
        _pillBtn.FlatAppearance.MouseOverBackColor = DarkTheme.HoverBg;
        _pillBtn.Click += (_, _) => SetExpanded(true);
        _pillBtn.MouseEnter += (_, _) => SetExpanded(true);

        // ── Expanded bar container ──
        _barPanel = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            FlowDirection = FlowDirection.LeftToRight,
            WrapContents = false,
            AutoSize = false,
            Padding = new Padding(8, 5, 8, 4),
            BackColor = Color.FromArgb(250, 251, 253),
            Visible = false,
        };
        _barPanel.Paint += (_, e) =>
        {
            using var pen = new Pen(DarkTheme.BorderColor, 1);
            e.Graphics.DrawRectangle(pen, 0, 0, _barPanel.Width - 1, _barPanel.Height - 1);
        };

        // Context menus
        _qualityMenu = CreateDarkMenu();
        _displayMenu = CreateDarkMenu();
        _powerMenu   = CreateDarkMenu();
        RebuildQualityMenu();
        RebuildPowerMenu();

        // Buttons
        _qualityBtn     = CreateBarButton("画质 ▾", 68);
        _displayBtn     = CreateBarButton("显示器 ▾", 78);
        _displayBtn.Visible = false;
        _audioBtn       = CreateBarButton("声音: 关", 72);
        _micBtn         = CreateBarButton("麦克风: 关", 82);
        _clipboardBtn   = CreateBarButton("剪贴板: 开", 82);
        SetToggleStyle(_clipboardBtn, _clipboardOn);
        _privacyBtn     = CreateBarButton("隐私屏", 64);
        _pointerLockBtn = CreateBarButton("游戏鼠标", 74);
        _powerBtn       = CreateBarButton("电源 ▾", 68);
        _imeCalibrateBtn = CreateBarButton("输入法位置", 82);
        _fullscreenBtn  = CreateBarButton("全屏", 52);
        _disconnectBtn  = CreateBarButton("断开", 52, danger: true);
        _collapseBtn    = CreateBarButton("▲", 28);

        _qualityBtn.Click += (_, _) => ShowMenuUnder(_qualityMenu, _qualityBtn);
        _displayBtn.Click += (_, _) => ShowMenuUnder(_displayMenu, _displayBtn);
        _powerBtn.Click += (_, _) => ShowMenuUnder(_powerMenu, _powerBtn);
        _audioBtn.Click += (_, _) => AudioToggled?.Invoke(!_audioOn);
        _micBtn.Click += (_, _) => MicToggled?.Invoke(!_micOn);
        _clipboardBtn.Click += (_, _) => ClipboardToggled?.Invoke(!_clipboardOn);
        _privacyBtn.Click += (_, _) => PrivacyToggled?.Invoke(!_privacyOn);
        _pointerLockBtn.Click += (_, _) => PointerLockToggled?.Invoke();
        _imeCalibrateBtn.Click += (_, _) => ImeCalibrateToggled?.Invoke();
        _fullscreenBtn.Click += (_, _) => FullscreenToggled?.Invoke();
        _disconnectBtn.Click += (_, _) => DisconnectRequested?.Invoke();
        _collapseBtn.Click += (_, _) => SetExpanded(false);

        _barPanel.Controls.Add(_qualityBtn);
        _barPanel.Controls.Add(_displayBtn);
        _barPanel.Controls.Add(_audioBtn);
        _barPanel.Controls.Add(_micBtn);
        _barPanel.Controls.Add(_clipboardBtn);
        _barPanel.Controls.Add(_privacyBtn);
        _barPanel.Controls.Add(_pointerLockBtn);
        _barPanel.Controls.Add(_powerBtn);
        _barPanel.Controls.Add(CreateSeparator());
        _barPanel.Controls.Add(_imeCalibrateBtn);
        _barPanel.Controls.Add(_fullscreenBtn);
        _barPanel.Controls.Add(_disconnectBtn);
        _barPanel.Controls.Add(_collapseBtn);

        Controls.Add(_barPanel);
        Controls.Add(_pillBtn);

        WireHoverHandlers(this);
        SetExpanded(false);
    }

    private void WireHoverHandlers(Control root)
    {
        root.MouseEnter += (_, _) => _autoHideTimer.Stop();
        root.MouseLeave += (_, _) =>
        {
            if (_expanded && !_menuOpen) _autoHideTimer.Start();
        };
        foreach (Control child in root.Controls)
        {
            WireHoverHandlers(child);
        }
    }

    protected override void OnShown(EventArgs e)
    {
        base.OnShown(e);
        _shownOnce = true;
    }

    public void UpdatePosition()
    {
        if (_ownerForm.IsDisposed || !_ownerForm.IsHandleCreated) return;
        if (_ownerForm.WindowState == FormWindowState.Minimized)
        {
            Visible = false;
            return;
        }
        if (_shownOnce && _ownerForm.Visible && !Visible)
        {
            Visible = true;
        }

        Point clientTopLeft = _ownerForm.PointToScreen(Point.Empty);
        int ownerW = _ownerForm.ClientSize.Width;
        if (ownerW <= 0) return;

        int targetW = _expanded ? Math.Min(ownerW - 16, CalculateExpandedWidth()) : PillWidth;
        int targetH = _expanded ? BarHeight : PillHeight;
        int x = clientTopLeft.X + Math.Max(0, (ownerW - targetW) / 2);
        int y = clientTopLeft.Y;

        Bounds = new Rectangle(x, y, Math.Max(PillWidth, targetW), targetH);
    }

    private int CalculateExpandedWidth()
    {
        int total = 24;
        foreach (Control c in _barPanel.Controls)
        {
            if (c.Visible)
            {
                total += c.Width + c.Margin.Horizontal;
            }
        }
        return Math.Max(480, total);
    }

    public void SetExpanded(bool expanded)
    {
        _expanded = expanded;
        _pillBtn.Visible = !expanded;
        _barPanel.Visible = expanded;
        UpdatePosition();

        if (expanded)
        {
            _autoHideTimer.Stop();
            _autoHideTimer.Start();
        }
        else
        {
            _autoHideTimer.Stop();
        }
    }

    /// <summary>
    /// Kept for compatibility with DesktopForm stats updates (live stats HUD is rendered separately).
    /// </summary>
    public void UpdateHud(double fps, double bitrateMbps, int rttMs, string codec, bool hardwareDecode)
    {
        // No-op: toolbar no longer embeds inline HUD labels.
    }

    public void UpdateState(
        QualityPreset? qualityPreset = null,
        SharpnessLevel? sharpness = null,
        ChromaMode? chromaMode = null,
        bool? hdrOn = null,
        bool? toneMapOn = null,
        bool? lowLatencyOn = null,
        bool? virtualDisplayOn = null,
        string? resolution = null,
        string? scaleMode = null,
        int? fps = null,
        bool? fpsAuto = null,
        int? bitrate = null,
        bool? bitrateAuto = null,
        string? codec = null,
        bool? audioOn = null,
        bool? micOn = null,
        bool? clipboardOn = null,
        bool? privacyOn = null,
        bool? pointerLocked = null,
        bool? imeCalibrating = null,
        bool? fullscreen = null,
        bool? statsHudVisible = null)
    {
        bool rebuildMenu = false;
        if (qualityPreset.HasValue) { _qualityPreset = qualityPreset.Value; rebuildMenu = true; }
        if (sharpness.HasValue)     { _sharpness = sharpness.Value;         rebuildMenu = true; }
        if (chromaMode.HasValue)    { _chromaMode = chromaMode.Value;       rebuildMenu = true; }
        if (hdrOn.HasValue)         { _hdrOn = hdrOn.Value;                 rebuildMenu = true; }
        if (toneMapOn.HasValue)     { _toneMapOn = toneMapOn.Value;         rebuildMenu = true; }
        if (lowLatencyOn.HasValue)  { _lowLatencyOn = lowLatencyOn.Value;   rebuildMenu = true; }
        if (virtualDisplayOn.HasValue) { _virtualDisplayOn = virtualDisplayOn.Value; rebuildMenu = true; }
        if (resolution != null)     { _resolution = resolution;             rebuildMenu = true; }
        if (scaleMode != null)      { _scaleMode = scaleMode;               rebuildMenu = true; }
        if (fps.HasValue)           { _fps = fps.Value;                     rebuildMenu = true; }
        if (fpsAuto.HasValue)       { _fpsAuto = fpsAuto.Value;             rebuildMenu = true; }
        if (bitrate.HasValue)       { _bitrate = bitrate.Value;             rebuildMenu = true; }
        if (bitrateAuto.HasValue)   { _bitrateAuto = bitrateAuto.Value;     rebuildMenu = true; }
        if (codec != null)          { _codec = codec;                       rebuildMenu = true; }
        if (statsHudVisible.HasValue) { _statsHudVisible = statsHudVisible.Value; rebuildMenu = true; }

        if (audioOn.HasValue)
        {
            _audioOn = audioOn.Value;
            _audioBtn.Text = _audioOn ? "声音: 开" : "声音: 关";
            SetToggleStyle(_audioBtn, _audioOn);
        }
        if (micOn.HasValue)
        {
            _micOn = micOn.Value;
            _micBtn.Text = _micOn ? "麦克风: 开" : "麦克风: 关";
            SetToggleStyle(_micBtn, _micOn);
        }
        if (clipboardOn.HasValue)
        {
            _clipboardOn = clipboardOn.Value;
            _clipboardBtn.Text = _clipboardOn ? "剪贴板: 开" : "剪贴板: 关";
            SetToggleStyle(_clipboardBtn, _clipboardOn);
        }
        if (privacyOn.HasValue)
        {
            _privacyOn = privacyOn.Value;
            SetToggleStyle(_privacyBtn, _privacyOn);
        }
        if (pointerLocked.HasValue)
        {
            _pointerLocked = pointerLocked.Value;
            _pointerLockBtn.Text = _pointerLocked ? "锁定中" : "游戏鼠标";
            SetToggleStyle(_pointerLockBtn, _pointerLocked);
        }
        if (imeCalibrating.HasValue)
        {
            _imeCalibrating = imeCalibrating.Value;
            _imeCalibrateBtn.Text = _imeCalibrating ? "完成校准" : "输入法位置";
            SetToggleStyle(_imeCalibrateBtn, _imeCalibrating);
        }
        if (fullscreen.HasValue)
        {
            _fullscreen = fullscreen.Value;
            _fullscreenBtn.Text = _fullscreen ? "窗口" : "全屏";
            SetToggleStyle(_fullscreenBtn, _fullscreen);
        }

        if (rebuildMenu) RebuildQualityMenu();
    }

    public void SetDisplays(IReadOnlyList<(int Id, string Name, int Width, int Height)> displays, int activeId)
    {
        _displays = new List<(int, string, int, int)>(displays);
        _activeDisplayId = activeId;
        _displayBtn.Visible = _displays.Count > 1;
        RebuildDisplayMenu();
        RebuildQualityMenu();
        if (_expanded) UpdatePosition();
    }

    private void CycleDisplay()
    {
        if (_displays.Count <= 1) return;
        int idx = _displays.FindIndex(d => d.Id == _activeDisplayId);
        int nextIdx = (idx + 1) % _displays.Count;
        DisplaySelected?.Invoke(_displays[nextIdx].Id);
    }

    private static string FormatBitrate(int bps)
    {
        double mbps = bps / 1_000_000.0;
        return Math.Abs(mbps - Math.Round(mbps)) < 0.05
            ? $"{Math.Round(mbps):F0}Mbps"
            : $"{mbps:F1}Mbps";
    }

    private static string FormatSharpness(SharpnessLevel level) => level switch
    {
        SharpnessLevel.Off    => "关",
        SharpnessLevel.Low    => "柔和",
        SharpnessLevel.Medium => "清晰",
        SharpnessLevel.High   => "极致",
        _                     => "柔和",
    };

    private void RebuildQualityMenu()
    {
        _qualityMenu.Items.Clear();

        // 1. Multi-display picker + one-click switch (only when >1 display)
        if (_displays.Count > 1)
        {
            var dispSub = new ToolStripMenuItem("显示器");
            foreach (var d in _displays)
            {
                int id = d.Id;
                AddCheckItem(dispSub, $"{d.Name} ({d.Width}×{d.Height})", d.Id == _activeDisplayId, () => DisplaySelected?.Invoke(id));
            }
            _qualityMenu.Items.Add(dispSub);

            var cycleItem = new ToolStripMenuItem("一键切屏");
            cycleItem.Click += (_, _) => CycleDisplay();
            _qualityMenu.Items.Add(cycleItem);
            _qualityMenu.Items.Add(new ToolStripSeparator());
        }

        // 2. UU-style Quality Presets (top-level zero-knob selector)
        string autoLabel = _qualityPreset == QualityPreset.Auto
            ? $"自动 ({_fps}fps · {FormatBitrate(_bitrate)})"
            : "自动";
        AddRootCheckItem(_qualityMenu, autoLabel, _qualityPreset == QualityPreset.Auto, () => QualityPresetChanged?.Invoke(QualityPreset.Auto));
        AddRootCheckItem(_qualityMenu, "流畅 (30fps · 4Mbps)", _qualityPreset == QualityPreset.Smooth, () => QualityPresetChanged?.Invoke(QualityPreset.Smooth));
        AddRootCheckItem(_qualityMenu, "高清 (60fps · 8Mbps)", _qualityPreset == QualityPreset.Hd, () => QualityPresetChanged?.Invoke(QualityPreset.Hd));
        AddRootCheckItem(_qualityMenu, "原画 (120fps · 25Mbps)", _qualityPreset == QualityPreset.Original, () => QualityPresetChanged?.Invoke(QualityPreset.Original));

        _qualityMenu.Items.Add(new ToolStripSeparator());

        // 3. True Color 4:4:4, HDR 10-bit & Stats HUD toggles
        AddRootCheckItem(
            _qualityMenu,
            "真彩 4:4:4",
            _chromaMode == ChromaMode.Yuv444,
            () => ChromaToggled?.Invoke(_chromaMode == ChromaMode.Yuv444 ? ChromaMode.Yuv420 : ChromaMode.Yuv444));
        AddRootCheckItem(
            _qualityMenu,
            "HDR 10-bit",
            _hdrOn,
            () => HdrToggled?.Invoke(!_hdrOn));
        AddRootCheckItem(
            _qualityMenu,
            "🖥️ 虚拟扩展屏",
            _virtualDisplayOn,
            () => VirtualDisplayToggled?.Invoke(!_virtualDisplayOn));
        AddRootCheckItem(
            _qualityMenu,
            "性能浮窗",
            _statsHudVisible,
            () => StatsHudToggled?.Invoke(!_statsHudVisible));

        _qualityMenu.Items.Add(new ToolStripSeparator());

        // 4. Collapsible Advanced Settings submenu (collapsed by default)
        var advMenu = new ToolStripMenuItem("高级设置");

        // Resolution
        var resMenu = new ToolStripMenuItem("分辨率");
        AddCheckItem(resMenu, "原生 (Native)",      _resolution == "native", () => ResolutionChanged?.Invoke("native"));
        AddCheckItem(resMenu, "自适应屏幕 (Match)", _resolution == "match", () => ResolutionChanged?.Invoke("match"));
        AddCheckItem(resMenu, "1080p",              _resolution == "1080", () => ResolutionChanged?.Invoke("1080"));
        AddCheckItem(resMenu, "2K",                 _resolution == "2k", () => ResolutionChanged?.Invoke("2k"));
        advMenu.DropDownItems.Add(resMenu);

        // Scale Mode
        var scaleMenu = new ToolStripMenuItem("缩放模式");
        AddCheckItem(scaleMenu, "等比缩放 (Fit)",      _scaleMode == "fit", () => ScaleModeChanged?.Invoke("fit"));
        AddCheckItem(scaleMenu, "拉伸全屏 (Stretch)",  _scaleMode == "stretch", () => ScaleModeChanged?.Invoke("stretch"));
        AddCheckItem(scaleMenu, "原始 1:1 (Original)", _scaleMode == "original", () => ScaleModeChanged?.Invoke("original"));
        advMenu.DropDownItems.Add(scaleMenu);

        // Manual FPS
        var fpsMenu = new ToolStripMenuItem($"手动帧率 ({(_fpsAuto ? "自动" : $"{_fps}fps")})");
        AddCheckItem(fpsMenu, $"自动 ({_fps}fps)", _fpsAuto, () => FpsChanged?.Invoke(_fps, true));
        foreach (int f in new[] { 30, 60, 90, 120 })
        {
            int val = f;
            AddCheckItem(fpsMenu, $"{val} fps", !_fpsAuto && _fps == val, () => FpsChanged?.Invoke(val, false));
        }
        advMenu.DropDownItems.Add(fpsMenu);

        // Manual Bitrate
        var brMenu = new ToolStripMenuItem($"手动码率 ({(_bitrateAuto ? "自动" : FormatBitrate(_bitrate))})");
        AddCheckItem(brMenu, $"自动 ({FormatBitrate(_bitrate)})", _bitrateAuto, () => BitrateChanged?.Invoke(_bitrate, true));
        foreach (int b in new[] { 2_000_000, 4_000_000, 8_000_000, 15_000_000, 25_000_000 })
        {
            int val = b;
            AddCheckItem(brMenu, $"{val / 1_000_000} Mbps", !_bitrateAuto && _bitrate == val, () => BitrateChanged?.Invoke(val, false));
        }
        advMenu.DropDownItems.Add(brMenu);

        // CAS Sharpness
        var sharpMenu = new ToolStripMenuItem($"锐化强度 ({FormatSharpness(_sharpness)})");
        AddCheckItem(sharpMenu, "关",   _sharpness == SharpnessLevel.Off,    () => SharpnessChanged?.Invoke(SharpnessLevel.Off));
        AddCheckItem(sharpMenu, "柔和", _sharpness == SharpnessLevel.Low,    () => SharpnessChanged?.Invoke(SharpnessLevel.Low));
        AddCheckItem(sharpMenu, "清晰", _sharpness == SharpnessLevel.Medium, () => SharpnessChanged?.Invoke(SharpnessLevel.Medium));
        AddCheckItem(sharpMenu, "极致", _sharpness == SharpnessLevel.High,   () => SharpnessChanged?.Invoke(SharpnessLevel.High));
        advMenu.DropDownItems.Add(sharpMenu);

        // Codec
        var codecMenu = new ToolStripMenuItem($"编解码器 ({_codec.ToUpperInvariant()})");
        AddCheckItem(codecMenu, "H.264 (AVC)",  _codec == "h264", () => CodecChanged?.Invoke("h264"));
        AddCheckItem(codecMenu, "H.265 (HEVC)", _codec == "h265", () => CodecChanged?.Invoke("h265"));
        advMenu.DropDownItems.Add(codecMenu);

        advMenu.DropDownItems.Add(new ToolStripSeparator());

        // Zero-buffer low latency & ACES SDR tone-mapping
        AddCheckItem(advMenu, "零缓冲极速", _lowLatencyOn, () => LowLatencyToggled?.Invoke(!_lowLatencyOn));
        AddCheckItem(advMenu, "SDR 色调映射 (ACES)", _toneMapOn, () => ToneMapToggled?.Invoke(!_toneMapOn));

        _qualityMenu.Items.Add(advMenu);

        _qualityMenu.Items.Add(new ToolStripSeparator());
        var cadItem = new ToolStripMenuItem("发送 Ctrl + Alt + Delete");
        cadItem.Click += (_, _) => CtrlAltDelRequested?.Invoke();
        _qualityMenu.Items.Add(cadItem);
    }

    private void RebuildPowerMenu()
    {
        _powerMenu.Items.Clear();

        var lockItem = new ToolStripMenuItem("🔒 锁屏");
        lockItem.Click += (_, _) => PowerActionRequested?.Invoke("lock");
        _powerMenu.Items.Add(lockItem);

        var sleepItem = new ToolStripMenuItem("🌙 休眠");
        sleepItem.Click += (_, _) => PowerActionRequested?.Invoke("sleep");
        _powerMenu.Items.Add(sleepItem);

        var restartItem = new ToolStripMenuItem("🔄 重启");
        restartItem.Click += (_, _) => PowerActionRequested?.Invoke("restart");
        _powerMenu.Items.Add(restartItem);
    }

    private void RebuildDisplayMenu()
    {
        _displayMenu.Items.Clear();
        foreach (var d in _displays)
        {
            int id = d.Id;
            var item = new ToolStripMenuItem($"{d.Name} ({d.Width}×{d.Height})")
            {
                Checked = d.Id == _activeDisplayId,
            };
            item.Click += (_, _) => DisplaySelected?.Invoke(id);
            _displayMenu.Items.Add(item);
        }
        if (_displays.Count > 1)
        {
            _displayMenu.Items.Add(new ToolStripSeparator());
            var cycleItem = new ToolStripMenuItem("一键切屏");
            cycleItem.Click += (_, _) => CycleDisplay();
            _displayMenu.Items.Add(cycleItem);
        }
    }

    private static void AddRootCheckItem(ContextMenuStrip menu, string text, bool isChecked, Action onClick)
    {
        var item = new ToolStripMenuItem(text) { Checked = isChecked };
        item.Click += (_, _) => onClick();
        menu.Items.Add(item);
    }

    private static void AddCheckItem(ToolStripMenuItem parent, string text, bool isChecked, Action onClick)
    {
        var item = new ToolStripMenuItem(text) { Checked = isChecked };
        item.Click += (_, _) => onClick();
        parent.DropDownItems.Add(item);
    }

    private void ShowMenuUnder(ContextMenuStrip menu, Control anchor)
    {
        _menuOpen = true;
        _autoHideTimer.Stop();
        menu.Show(anchor, new Point(0, anchor.Height + 2));
    }

    private ContextMenuStrip CreateDarkMenu()
    {
        var menu = new ContextMenuStrip
        {
            Renderer = new DarkMenuRenderer(),
            BackColor = DarkTheme.SurfaceBg,
            ForeColor = DarkTheme.TextPrimary,
            ShowImageMargin = true,
        };
        menu.Closed += (_, _) =>
        {
            _menuOpen = false;
            if (_expanded) _autoHideTimer.Start();
        };
        return menu;
    }

    private static Panel CreateSeparator()
    {
        return new Panel
        {
            Width = 1,
            Height = 20,
            BackColor = DarkTheme.BorderColor,
            Margin = new Padding(5, 4, 5, 0),
        };
    }

    private static Button CreateBarButton(string text, int width, bool danger = false)
    {
        var btn = new Button
        {
            Text = text,
            Width = width,
            Height = 26,
            Font = new Font("Segoe UI", 8.5f, FontStyle.Regular),
            Margin = new Padding(2, 1, 2, 0),
            TabStop = false,
        };
        DarkTheme.StyleButton(btn, primary: false, danger: danger);
        return btn;
    }

    private static void SetToggleStyle(Button btn, bool active)
    {
        if (active)
        {
            btn.BackColor = Color.FromArgb(204, 251, 241);
            btn.ForeColor = DarkTheme.Accent;
            btn.FlatAppearance.BorderColor = DarkTheme.Accent;
        }
        else
        {
            btn.BackColor = DarkTheme.InputBg;
            btn.ForeColor = DarkTheme.TextPrimary;
            btn.FlatAppearance.BorderColor = DarkTheme.BorderColor;
        }
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _autoHideTimer.Dispose();
            _qualityMenu.Dispose();
            _displayMenu.Dispose();
            _powerMenu.Dispose();
        }
        base.Dispose(disposing);
    }

    private sealed class DarkMenuRenderer : ToolStripProfessionalRenderer
    {
        public DarkMenuRenderer() : base(new DarkColorTable()) { }

        protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e)
        {
            e.TextColor = DarkTheme.TextPrimary;
            base.OnRenderItemText(e);
        }
    }

    private sealed class DarkColorTable : ProfessionalColorTable
    {
        public override Color ToolStripDropDownBackground => DarkTheme.SurfaceBg;
        public override Color MenuBorder => DarkTheme.BorderColor;
        public override Color MenuItemBorder => DarkTheme.Accent;
        public override Color MenuItemSelected => DarkTheme.HoverBg;
        public override Color ImageMarginGradientBegin => DarkTheme.SurfaceBg;
        public override Color ImageMarginGradientMiddle => DarkTheme.SurfaceBg;
        public override Color ImageMarginGradientEnd => DarkTheme.SurfaceBg;
        public override Color SeparatorDark => DarkTheme.BorderColor;
        public override Color SeparatorLight => DarkTheme.BorderColor;
    }
}
