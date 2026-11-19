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
    private const int PillWidth = 64;
    private const int PillHeight = 16;
    private const int BarHeight = 38;

    private readonly Form _ownerForm;
    private readonly System.Windows.Forms.Timer _autoHideTimer;
    private bool _expanded;
    private bool _menuOpen;

    // Collapsed pill button
    private readonly Button _pillBtn;

    // Expanded toolbar panel
    private readonly FlowLayoutPanel _barPanel;

    // Live HUD label
    private readonly Label _hudLabel;
    private readonly Label _codecBadge;
    private readonly Label _decoderBadge;

    // Interactive controls
    private readonly Button _qualityBtn;
    private readonly Button _audioBtn;
    private readonly Button _privacyBtn;
    private readonly Button _pointerLockBtn;
    private readonly Button _displayBtn;
    private readonly Button _fullscreenBtn;
    private readonly Button _disconnectBtn;
    private readonly Button _collapseBtn;

    private readonly ContextMenuStrip _qualityMenu;
    private readonly ContextMenuStrip _displayMenu;

    // Current state
    private string _resolution = "native";
    private string _scaleMode = "fit";
    private int _fps = 60;
    private bool _fpsAuto = true;
    private int _bitrate = 8_000_000;
    private bool _bitrateAuto = true;
    private string _codec = "h264";
    private bool _audioOn;
    private bool _privacyOn;
    private bool _pointerLocked;
    private bool _fullscreen;
    private int _activeDisplayId;
    private List<(int Id, string Name, int Width, int Height)> _displays = new();

    // Events wired by DesktopForm
    public event Action<string>? ResolutionChanged;
    public event Action<string>? ScaleModeChanged;
    public event Action<int, bool>? FpsChanged;
    public event Action<int, bool>? BitrateChanged;
    public event Action<string>? CodecChanged;
    public event Action<bool>? AudioToggled;
    public event Action<bool>? PrivacyToggled;
    public event Action? PointerLockToggled;
    public event Action<int>? DisplaySelected;
    public event Action? FullscreenToggled;
    public event Action? DisconnectRequested;
    public event Action? CtrlAltDelRequested;

    public FloatingToolbar(Form ownerForm)
    {
        _ownerForm = ownerForm ?? throw new ArgumentNullException(nameof(ownerForm));
        Owner = ownerForm;

        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        ShowInTaskbar = false;
        BackColor = Color.FromArgb(20, 24, 31);
        Opacity = 0.94;
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
            Text = "▼",
            Dock = DockStyle.Fill,
            FlatStyle = FlatStyle.Flat,
            BackColor = Color.FromArgb(28, 34, 44),
            ForeColor = DarkTheme.TextMuted,
            Font = new Font("Segoe UI", 7.5f, FontStyle.Bold),
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
            BackColor = Color.FromArgb(22, 26, 34),
            Visible = false,
        };
        _barPanel.Paint += (_, e) =>
        {
            using var pen = new Pen(DarkTheme.BorderColor, 1);
            e.Graphics.DrawRectangle(pen, 0, 0, _barPanel.Width - 1, _barPanel.Height - 1);
        };

        // HUD metrics
        _hudLabel = new Label
        {
            AutoSize = true,
            ForeColor = DarkTheme.TextPrimary,
            Font = new Font("Consolas", 8.5f, FontStyle.Regular),
            Text = "0 fps · 0.0 Mbps · -- ms",
            Margin = new Padding(2, 6, 6, 0),
        };

        _codecBadge = CreateBadge("H.264", Color.FromArgb(30, 56, 78), Color.FromArgb(110, 200, 255));
        _decoderBadge = CreateBadge("HW", Color.FromArgb(22, 64, 58), DarkTheme.Accent);

        // Context menus
        _qualityMenu = CreateDarkMenu();
        _displayMenu = CreateDarkMenu();
        RebuildQualityMenu();

        // Buttons
        _qualityBtn     = CreateBarButton("画质 ▾", 68);
        _displayBtn     = CreateBarButton("显示器 ▾", 78);
        _displayBtn.Visible = false;
        _audioBtn       = CreateBarButton("声音: 关", 72);
        _privacyBtn     = CreateBarButton("隐私屏", 64);
        _pointerLockBtn = CreateBarButton("游戏鼠标", 74);
        _fullscreenBtn  = CreateBarButton("全屏", 52);
        _disconnectBtn  = CreateBarButton("断开", 52, danger: true);
        _collapseBtn    = CreateBarButton("▲", 28);

        _qualityBtn.Click += (_, _) => ShowMenuUnder(_qualityMenu, _qualityBtn);
        _displayBtn.Click += (_, _) => ShowMenuUnder(_displayMenu, _displayBtn);
        _audioBtn.Click += (_, _) => AudioToggled?.Invoke(!_audioOn);
        _privacyBtn.Click += (_, _) => PrivacyToggled?.Invoke(!_privacyOn);
        _pointerLockBtn.Click += (_, _) => PointerLockToggled?.Invoke();
        _fullscreenBtn.Click += (_, _) => FullscreenToggled?.Invoke();
        _disconnectBtn.Click += (_, _) => DisconnectRequested?.Invoke();
        _collapseBtn.Click += (_, _) => SetExpanded(false);

        _barPanel.Controls.Add(_hudLabel);
        _barPanel.Controls.Add(_codecBadge);
        _barPanel.Controls.Add(_decoderBadge);
        _barPanel.Controls.Add(CreateSeparator());
        _barPanel.Controls.Add(_qualityBtn);
        _barPanel.Controls.Add(_displayBtn);
        _barPanel.Controls.Add(_audioBtn);
        _barPanel.Controls.Add(_privacyBtn);
        _barPanel.Controls.Add(_pointerLockBtn);
        _barPanel.Controls.Add(CreateSeparator());
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

    public void UpdatePosition()
    {
        if (_ownerForm.IsDisposed || !_ownerForm.IsHandleCreated) return;
        if (_ownerForm.WindowState == FormWindowState.Minimized)
        {
            Visible = false;
            return;
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
        return Math.Max(680, total);
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

    public void UpdateHud(double fps, double bitrateMbps, int rttMs, string codec, bool hardwareDecode)
    {
        if (IsDisposed) return;
        _hudLabel.Text = $"{fps:F0} fps · {bitrateMbps:F1} Mbps · {(rttMs >= 0 ? $"{rttMs} ms" : "-- ms")}";
        _codecBadge.Text = codec.ToUpperInvariant();
        _decoderBadge.Text = hardwareDecode ? "HW" : "SW";
        _decoderBadge.ForeColor = hardwareDecode ? DarkTheme.Accent : Color.FromArgb(245, 180, 65);
        if (_expanded) UpdatePosition();
    }

    public void UpdateState(
        string? resolution = null,
        string? scaleMode = null,
        int? fps = null,
        bool? fpsAuto = null,
        int? bitrate = null,
        bool? bitrateAuto = null,
        string? codec = null,
        bool? audioOn = null,
        bool? privacyOn = null,
        bool? pointerLocked = null,
        bool? fullscreen = null)
    {
        bool rebuildMenu = false;
        if (resolution != null) { _resolution = resolution; rebuildMenu = true; }
        if (scaleMode != null)  { _scaleMode = scaleMode;   rebuildMenu = true; }
        if (fps.HasValue)       { _fps = fps.Value;         rebuildMenu = true; }
        if (fpsAuto.HasValue)   { _fpsAuto = fpsAuto.Value; rebuildMenu = true; }
        if (bitrate.HasValue)   { _bitrate = bitrate.Value; rebuildMenu = true; }
        if (bitrateAuto.HasValue) { _bitrateAuto = bitrateAuto.Value; rebuildMenu = true; }
        if (codec != null)      { _codec = codec;           rebuildMenu = true; }

        if (audioOn.HasValue)
        {
            _audioOn = audioOn.Value;
            _audioBtn.Text = _audioOn ? "声音: 开" : "声音: 关";
            SetToggleStyle(_audioBtn, _audioOn);
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
        if (_expanded) UpdatePosition();
    }

    private void RebuildQualityMenu()
    {
        _qualityMenu.Items.Clear();

        // Resolution
        var resMenu = new ToolStripMenuItem("分辨率");
        AddCheckItem(resMenu, "自适应屏幕 (Match)", _resolution == "match", () => ResolutionChanged?.Invoke("match"));
        AddCheckItem(resMenu, "原生 (Native)",      _resolution == "native", () => ResolutionChanged?.Invoke("native"));
        AddCheckItem(resMenu, "1080p",              _resolution == "1080", () => ResolutionChanged?.Invoke("1080"));
        AddCheckItem(resMenu, "2K",                 _resolution == "2k", () => ResolutionChanged?.Invoke("2k"));
        _qualityMenu.Items.Add(resMenu);

        // Scale Mode
        var scaleMenu = new ToolStripMenuItem("缩放模式");
        AddCheckItem(scaleMenu, "等比缩放 (Fit)",      _scaleMode == "fit", () => ScaleModeChanged?.Invoke("fit"));
        AddCheckItem(scaleMenu, "拉伸铺满 (Stretch)",  _scaleMode == "stretch", () => ScaleModeChanged?.Invoke("stretch"));
        AddCheckItem(scaleMenu, "原始 1:1 (Original)", _scaleMode == "original", () => ScaleModeChanged?.Invoke("original"));
        _qualityMenu.Items.Add(scaleMenu);

        // FPS
        var fpsMenu = new ToolStripMenuItem($"帧率 ({(_fpsAuto ? "自动" : $"{_fps}fps")})");
        AddCheckItem(fpsMenu, $"自动 ({_fps}fps)", _fpsAuto, () => FpsChanged?.Invoke(_fps, true));
        foreach (int f in new[] { 30, 60, 90, 120 })
        {
            int val = f;
            AddCheckItem(fpsMenu, $"{val} fps", !_fpsAuto && _fps == val, () => FpsChanged?.Invoke(val, false));
        }
        _qualityMenu.Items.Add(fpsMenu);

        // Bitrate
        var brMenu = new ToolStripMenuItem($"码率 ({(_bitrateAuto ? "自动" : $"{_bitrate / 1_000_000}Mbps")})");
        AddCheckItem(brMenu, $"自动 ({_bitrate / 1_000_000}Mbps)", _bitrateAuto, () => BitrateChanged?.Invoke(_bitrate, true));
        foreach (int b in new[] { 2_000_000, 4_000_000, 8_000_000, 15_000_000, 25_000_000 })
        {
            int val = b;
            AddCheckItem(brMenu, $"{val / 1_000_000} Mbps", !_bitrateAuto && _bitrate == val, () => BitrateChanged?.Invoke(val, false));
        }
        _qualityMenu.Items.Add(brMenu);

        // Codec
        var codecMenu = new ToolStripMenuItem($"编码 ({_codec.ToUpperInvariant()})");
        AddCheckItem(codecMenu, "H.264 (AVC)",  _codec == "h264", () => CodecChanged?.Invoke("h264"));
        AddCheckItem(codecMenu, "H.265 (HEVC)", _codec == "h265", () => CodecChanged?.Invoke("h265"));
        _qualityMenu.Items.Add(codecMenu);

        _qualityMenu.Items.Add(new ToolStripSeparator());
        var cadItem = new ToolStripMenuItem("发送 Ctrl + Alt + Delete");
        cadItem.Click += (_, _) => CtrlAltDelRequested?.Invoke();
        _qualityMenu.Items.Add(cadItem);
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

    private static Label CreateBadge(string text, Color bg, Color fg)
    {
        return new Label
        {
            Text = text,
            AutoSize = true,
            BackColor = bg,
            ForeColor = fg,
            Font = new Font("Segoe UI", 7.5f, FontStyle.Bold),
            Padding = new Padding(5, 2, 5, 2),
            Margin = new Padding(2, 5, 2, 0),
        };
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
            btn.BackColor = Color.FromArgb(18, 72, 68);
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
