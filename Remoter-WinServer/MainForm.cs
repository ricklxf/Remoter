using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace RemoterWin;

/// <summary>
/// Clean single-card control panel for Remoter-WinServer matching the Remoter login UI:
/// - Bee mascot logo + "Remoter" title + live status pill badge
/// - Teal-accented live telemetry &amp; LAN address card with one-click copy
/// - Structured settings card (PIN toggle/refresh, Web port, adaptive quality, CPU cap, open logs)
/// - Full-width primary Start/Stop button, Save/Exit secondary actions, and system tray support
/// </summary>
public partial class MainForm : Form
{
    // Shared palette matching Remoter Web & WinClient ConnectForm
    private static readonly Color BgOuter      = Color.FromArgb(241, 245, 249); // #F1F5F9
    private static readonly Color BgCard       = Color.White;                   // #FFFFFF
    private static readonly Color BgSubtle     = Color.FromArgb(241, 245, 249); // #F1F5F9
    private static readonly Color BgSection    = Color.FromArgb(248, 250, 252); // #F8FAFC
    private static readonly Color BorderSubtle = Color.FromArgb(203, 213, 225); // #CBD5E1
    private static readonly Color BorderLight  = Color.FromArgb(226, 232, 240); // #E2E8F0
    private static readonly Color Primary      = Color.FromArgb(13, 148, 136);  // #0D9488
    private static readonly Color PrimaryHover = Color.FromArgb(15, 118, 110);  // #0F766E
    private static readonly Color Danger       = Color.FromArgb(220, 38, 38);   // #DC2626
    private static readonly Color DangerHover  = Color.FromArgb(185, 28, 28);   // #B91C1C
    private static readonly Color TextDark     = Color.FromArgb(17, 24, 39);    // #111827
    private static readonly Color TextMuted    = Color.FromArgb(100, 116, 139); // #64748B
    private static readonly Color TextFaint    = Color.FromArgb(148, 163, 184); // #94A3B8
    private static readonly Color StatusRunBg  = Color.FromArgb(236, 253, 245); // #ECFDF5
    private static readonly Color StatusRunFg  = Color.FromArgb(4, 120, 87);    // #047857
    private static readonly Color StatusRunDot = Color.FromArgb(16, 185, 129);  // #10B981
    private static readonly Color StatusOffBg  = Color.FromArgb(241, 245, 249); // #F1F5F9
    private static readonly Color StatusOffDot = Color.FromArgb(239, 68, 68);   // #EF4444

    private const int DWMWA_USE_IMMERSIVE_DARK_MODE_BEFORE_20H1 = 19;
    private const int DWMWA_USE_IMMERSIVE_DARK_MODE = 20;

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(nint hwnd, int attr, ref int attrValue, int attrSize);

    private const int CardWidth = 448;
    private const int CardPadX = 28;
    private const int InnerWidth = CardWidth - CardPadX * 2; // 392
    private const int OuterMarginX = 24;
    private const int OuterMarginY = 20;

    // Services
    private WebSocketServer? _server;
    private RelayClient? _relay;
    private readonly Dictionary<IWsConn, Session> _sessions = new();

    // Configuration
    private string _pin = "";
    private ushort _port = 7788;
    private string _relayUrl = "";
    private bool _isExiting;
    private bool _isStarting;

    // Tray
    private NotifyIcon _trayIcon = null!;
    private ContextMenuStrip _trayMenu = null!;
    private ToolStripMenuItem _trayStartItem = null!;
    private ToolStripMenuItem _trayStopItem = null!;

    // UI Controls
    private RoundedPanel _card = null!;
    private StatusPillBadge _statusBadge = null!;
    private RoundedPanel _monitorCard = null!;
    private Label _lanAddressLabel = null!;
    private RoundedButton _copyAddrBtn = null!;
    private Label _connValueLabel = null!;
    private Label _uploadValueLabel = null!;
    private Label _cpuValueLabel = null!;

    private CheckBox _pinEnabledCheckBox = null!;
    private RoundedInputBox _pinInput = null!;
    private RoundedButton _refreshPinBtn = null!;
    private RoundedInputBox _webPortInput = null!;
    private CheckBox _adaptiveCheckBox = null!;
    private RoundedInputBox _maxCpuInput = null!;
    private RoundedButton _openLogsBtn = null!;

    private RoundedButton _primaryActionBtn = null!;
    private RoundedButton _applyButton = null!;
    private RoundedButton _exitButton = null!;
    private Label _toastLabel = null!;

    private System.Windows.Forms.Timer _statusTimer = null!;
    private System.Windows.Forms.Timer _toastTimer = null!;
    private Image? _logoImage;

    // Performance monitoring
    private Process _currentProcess = null!;
    private TimeSpan _lastCpuTime = TimeSpan.Zero;
    private DateTime _lastCpuCheck = DateTime.Now;
    private long _lastUploadBytes;
    private DateTime _lastUploadCheck = DateTime.Now;

    public MainForm()
    {
        InitializeComponent();
        InitializeTrayIcon();
        LoadConfiguration();
        SetupTimers();
        UpdateStatus(false);
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        EnableLightTitleBar(Handle);
    }

    private void InitializeComponent()
    {
        Text = $"Remoter Server v{AppVersion.Current}";
        FormBorderStyle = FormBorderStyle.FixedSingle;
        MaximizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        BackColor = BgOuter;
        ForeColor = TextDark;
        Font = new Font("Microsoft YaHei UI", 9.5f, FontStyle.Regular);
        DoubleBuffered = true;

        try
        {
            var iconPath = Path.Combine(AppContext.BaseDirectory, "Remoter.ico");
            if (File.Exists(iconPath))
            {
                using var fs = new FileStream(iconPath, FileMode.Open, FileAccess.Read);
                Icon = new Icon(fs);
            }
            else
            {
                Icon = SystemIcons.Application;
            }
        }
        catch (Exception ex)
        {
            AppLog.Write($"[Main] Failed to load icon: {ex.Message}");
            Icon = SystemIcons.Application;
        }

        _logoImage = LoadLogoImage();

        // ── Main white rounded card ──
        _card = new RoundedPanel
        {
            Location = new Point(OuterMarginX, OuterMarginY),
            Width = CardWidth,
            BackColor = BgCard,
            BorderColor = BorderLight,
            CornerRadius = 16,
        };

        int y = 28;

        // ── Header: Bee logo + Title + Status pill ──
        var logoBox = new PictureBox
        {
            Location = new Point(CardPadX, y + 2),
            Size = new Size(34, 34),
            SizeMode = PictureBoxSizeMode.Zoom,
            BackColor = Color.Transparent,
            Image = _logoImage,
        };

        var titleLabel = new Label
        {
            Text = "Remoter",
            Location = new Point(CardPadX + 42, y - 2),
            AutoSize = true,
            Font = new Font("Segoe UI", 20f, FontStyle.Bold),
            ForeColor = TextDark,
            BackColor = Color.Transparent,
        };

        _statusBadge = new StatusPillBadge
        {
            Size = new Size(86, 26),
            Location = new Point(CardWidth - CardPadX - 86, y + 6),
        };

        var subtitleLabel = new Label
        {
            Text = "Windows 被控端服务 · 超清 2K · 60fps",
            Location = new Point(CardPadX, y + 42),
            AutoSize = true,
            Font = new Font("Microsoft YaHei UI", 9f),
            ForeColor = TextMuted,
            BackColor = Color.Transparent,
        };

        _card.Controls.AddRange(new Control[] { logoBox, titleLabel, _statusBadge, subtitleLabel });
        y += 74;

        // ── Live Monitor & LAN Address Card ──
        _monitorCard = new RoundedPanel
        {
            Location = new Point(CardPadX, y),
            Size = new Size(InnerWidth, 108),
            BackColor = BgSection,
            BorderColor = BorderSubtle,
            CornerRadius = 10,
        };

        _lanAddressLabel = new Label
        {
            Location = new Point(14, 10),
            Size = new Size(InnerWidth - 90, 24),
            Font = new Font("Consolas", 10f, FontStyle.Bold),
            ForeColor = TextDark,
            BackColor = Color.Transparent,
            TextAlign = ContentAlignment.MiddleLeft,
            AutoEllipsis = true,
            Text = "ws://127.0.0.1:7788",
        };

        _copyAddrBtn = new RoundedButton
        {
            Text = "复制",
            Location = new Point(InnerWidth - 68, 9),
            Size = new Size(54, 26),
            CornerRadius = 6,
            Font = new Font("Microsoft YaHei UI", 8.5f),
            FillColor = BgCard,
            HoverFillColor = BgSubtle,
            TextColor = TextMuted,
            BorderColor = BorderSubtle,
            BorderWidth = 1f,
        };
        _copyAddrBtn.Click += (_, _) => CopyLanAddress();

        var monitorDivider = new Panel
        {
            Location = new Point(14, 42),
            Size = new Size(InnerWidth - 28, 1),
            BackColor = BorderLight,
        };

        int colW = (InnerWidth - 28) / 3;
        _connValueLabel = AddMetricColumn(_monitorCard, 14, 52, colW, "连接数", "0");
        _uploadValueLabel = AddMetricColumn(_monitorCard, 14 + colW, 52, colW, "上传速度", "0 B/s");
        _cpuValueLabel = AddMetricColumn(_monitorCard, 14 + colW * 2, 52, InnerWidth - 28 - colW * 2, "CPU 占用", "0.0%");

        _monitorCard.Controls.AddRange(new Control[] { _lanAddressLabel, _copyAddrBtn, monitorDivider });
        _card.Controls.Add(_monitorCard);
        y += _monitorCard.Height + 16;

        // ── Settings Card ──
        var settingsCard = new RoundedPanel
        {
            Location = new Point(CardPadX, y),
            Size = new Size(InnerWidth, 186),
            BackColor = BgSection,
            BorderColor = BorderLight,
            CornerRadius = 10,
        };

        var settingsTitle = new Label
        {
            Text = "服务设置",
            Location = new Point(14, 11),
            AutoSize = true,
            Font = new Font("Microsoft YaHei UI", 8.8f, FontStyle.Bold),
            ForeColor = TextMuted,
            BackColor = Color.Transparent,
        };
        settingsCard.Controls.Add(settingsTitle);

        // Row 1: PIN toggle + PIN display + Refresh button
        _pinEnabledCheckBox = new CheckBox
        {
            Text = "启用 PIN 码",
            Location = new Point(14, 42),
            AutoSize = true,
            Checked = true,
            Font = new Font("Microsoft YaHei UI", 9f),
            ForeColor = TextDark,
            BackColor = Color.Transparent,
            Cursor = Cursors.Hand,
        };
        _pinEnabledCheckBox.CheckedChanged += (_, _) => UpdatePinEnabled();

        _refreshPinBtn = new RoundedButton
        {
            Text = "刷新",
            Location = new Point(InnerWidth - 14 - 58, 37),
            Size = new Size(58, 32),
            CornerRadius = 6,
            Font = new Font("Microsoft YaHei UI", 8.5f),
            FillColor = BgCard,
            HoverFillColor = BgSubtle,
            TextColor = TextMuted,
            BorderColor = BorderSubtle,
            BorderWidth = 1f,
        };
        _refreshPinBtn.Click += (_, _) => GenerateNewPin();

        int pinBoxLeft = 122;
        _pinInput = new RoundedInputBox
        {
            Location = new Point(pinBoxLeft, 36),
            Size = new Size(_refreshPinBtn.Left - pinBoxLeft - 8, 34),
            ReadOnly = true,
        };
        _pinInput.InnerTextBox.Font = new Font("Consolas", 11f, FontStyle.Bold);
        _pinInput.InnerTextBox.TextAlign = HorizontalAlignment.Center;

        // Row 2: Web Port & Max CPU % (clean 2-column grid)
        int halfColW = (InnerWidth - 28 - 12) / 2;
        var webPortLabel = CreateSmallLabel("Web / 直连端口", 14, 80);
        _webPortInput = new RoundedInputBox
        {
            Location = new Point(14, 100),
            Size = new Size(halfColW, 34),
            InputText = "7788",
            Placeholder = "7788",
        };

        var maxCpuLabel = CreateSmallLabel("最大 CPU (%)", 14 + halfColW + 12, 80);
        _maxCpuInput = new RoundedInputBox
        {
            Location = new Point(14 + halfColW + 12, 100),
            Size = new Size(InnerWidth - 28 - halfColW - 12, 34),
            InputText = "80",
            Placeholder = "80",
        };
        _maxCpuInput.InnerTextBox.TextAlign = HorizontalAlignment.Center;

        // Row 3: Adaptive checkbox + Open Log Folder button
        _adaptiveCheckBox = new CheckBox
        {
            Text = "画面自适应",
            Location = new Point(14, 149),
            AutoSize = true,
            Checked = true,
            Font = new Font("Microsoft YaHei UI", 9f),
            ForeColor = TextDark,
            BackColor = Color.Transparent,
            Cursor = Cursors.Hand,
        };
        _adaptiveCheckBox.CheckedChanged += (_, _) =>
        {
            lock (_sessions)
            {
                foreach (var session in _sessions.Values)
                {
                    session.SetAdaptiveEnabled(_adaptiveCheckBox.Checked);
                }
            }
        };

        _openLogsBtn = new RoundedButton
        {
            Text = "打开日志",
            Location = new Point(InnerWidth - 14 - 96, 143),
            Size = new Size(96, 32),
            CornerRadius = 6,
            Font = new Font("Microsoft YaHei UI", 8.5f),
            FillColor = BgCard,
            HoverFillColor = BgSubtle,
            TextColor = TextDark,
            BorderColor = BorderSubtle,
            BorderWidth = 1f,
        };
        _openLogsBtn.Click += (_, _) => OpenLogFolder();

        settingsCard.Controls.AddRange(new Control[]
        {
            _pinEnabledCheckBox, _pinInput, _refreshPinBtn,
            webPortLabel, _webPortInput, maxCpuLabel, _maxCpuInput,
            _adaptiveCheckBox, _openLogsBtn,
        });
        _card.Controls.Add(settingsCard);
        y += settingsCard.Height + 14;

        // ── Inline feedback toast (replaces intrusive popups) ──
        _toastLabel = new Label
        {
            Location = new Point(CardPadX, y),
            Size = new Size(InnerWidth, 20),
            TextAlign = ContentAlignment.MiddleCenter,
            Font = new Font("Microsoft YaHei UI", 8.5f),
            ForeColor = Primary,
            BackColor = Color.Transparent,
            Text = "",
        };
        _card.Controls.Add(_toastLabel);
        y += 24;

        // ── Primary Start / Stop Button ──
        _primaryActionBtn = new RoundedButton
        {
            Text = "启动服务",
            Location = new Point(CardPadX, y),
            Size = new Size(InnerWidth, 44),
            CornerRadius = 8,
            Font = new Font("Microsoft YaHei UI", 10.5f, FontStyle.Bold),
            FillColor = Primary,
            HoverFillColor = PrimaryHover,
            TextColor = Color.White,
            BorderColor = Color.Transparent,
        };
        _primaryActionBtn.Click += (_, _) =>
        {
            if (_server != null) StopServices();
            else StartServices();
        };
        _card.Controls.Add(_primaryActionBtn);
        y += 54;

        // ── Secondary Buttons: Save Settings + Exit ──
        int secBtnW = (InnerWidth - 10) / 2;
        _applyButton = new RoundedButton
        {
            Text = "保存设置",
            Location = new Point(CardPadX, y),
            Size = new Size(secBtnW, 36),
            CornerRadius = 8,
            Font = new Font("Microsoft YaHei UI", 9.2f),
            FillColor = BgSubtle,
            HoverFillColor = BorderLight,
            TextColor = TextDark,
            BorderColor = BorderSubtle,
            BorderWidth = 1f,
        };
        _applyButton.Click += OnApplyButtonClick;

        _exitButton = new RoundedButton
        {
            Text = "退出程序",
            Location = new Point(CardPadX + secBtnW + 10, y),
            Size = new Size(InnerWidth - secBtnW - 10, 36),
            CornerRadius = 8,
            Font = new Font("Microsoft YaHei UI", 9.2f),
            FillColor = BgSubtle,
            HoverFillColor = Color.FromArgb(254, 226, 226),
            TextColor = TextMuted,
            BorderColor = BorderSubtle,
            BorderWidth = 1f,
        };
        _exitButton.Click += OnCancelButtonClick;

        _card.Controls.AddRange(new Control[] { _applyButton, _exitButton });
        y += 46;

        // ── Version Footer ──
        var versionLabel = new Label
        {
            Text = $"v{AppVersion.Current}",
            Location = new Point(CardPadX, y),
            Size = new Size(InnerWidth, 20),
            TextAlign = ContentAlignment.MiddleCenter,
            Font = new Font("Segoe UI", 8.5f),
            ForeColor = TextFaint,
            BackColor = Color.Transparent,
        };
        _card.Controls.Add(versionLabel);
        y += 30;

        _card.Height = y;
        ClientSize = new Size(CardWidth + OuterMarginX * 2, _card.Height + OuterMarginY * 2);
        Controls.Add(_card);
    }

    private static Label AddMetricColumn(Control parent, int x, int y, int width, string title, string initialValue)
    {
        var titleLbl = new Label
        {
            Text = title,
            Location = new Point(x, y),
            Size = new Size(width, 18),
            Font = new Font("Microsoft YaHei UI", 8f),
            ForeColor = TextMuted,
            BackColor = Color.Transparent,
            TextAlign = ContentAlignment.MiddleCenter,
        };
        var valueLbl = new Label
        {
            Text = initialValue,
            Location = new Point(x, y + 20),
            Size = new Size(width, 24),
            Font = new Font("Segoe UI", 11f, FontStyle.Bold),
            ForeColor = TextDark,
            BackColor = Color.Transparent,
            TextAlign = ContentAlignment.MiddleCenter,
        };
        parent.Controls.Add(titleLbl);
        parent.Controls.Add(valueLbl);
        return valueLbl;
    }

    private static Label CreateSmallLabel(string text, int x, int y) => new()
    {
        Text = text,
        Location = new Point(x, y),
        AutoSize = true,
        Font = new Font("Microsoft YaHei UI", 8.5f),
        ForeColor = TextMuted,
        BackColor = Color.Transparent,
    };

    private void SetupTimers()
    {
        _statusTimer = new System.Windows.Forms.Timer { Interval = 2000 };
        _statusTimer.Tick += (_, _) => UpdateStatusDisplay();

        _toastTimer = new System.Windows.Forms.Timer { Interval = 2800 };
        _toastTimer.Tick += (_, _) =>
        {
            _toastTimer.Stop();
            _toastLabel.Text = "";
        };

        _currentProcess = Process.GetCurrentProcess();
        _lastCpuTime = _currentProcess.TotalProcessorTime;
        _lastCpuCheck = DateTime.Now;
    }

    private void ShowToast(string message, bool isError = false)
    {
        _toastLabel.ForeColor = isError ? Danger : Primary;
        _toastLabel.Text = message;
        _toastTimer.Stop();
        _toastTimer.Start();
    }

    private void CopyLanAddress()
    {
        try
        {
            if (!string.IsNullOrWhiteSpace(_lanAddressLabel.Text))
            {
                Clipboard.SetText(_lanAddressLabel.Text);
                ShowToast("已复制局域网连接地址");
            }
        }
        catch { }
    }

    private void OpenLogFolder()
    {
        try
        {
            Directory.CreateDirectory(AppLog.LogDir);
            Process.Start(new ProcessStartInfo
            {
                FileName = "explorer.exe",
                Arguments = $"\"{AppLog.LogDir}\"",
                UseShellExecute = true,
            });
        }
        catch (Exception ex)
        {
            ShowToast($"打开日志目录失败：{ex.Message}", isError: true);
        }
    }

    private void UpdateLanAddressDisplay()
    {
        var ips = GetLocalIPs();
        string ip = ips.FirstOrDefault() ?? "127.0.0.1";
        _lanAddressLabel.Text = $"ws://{ip}:{_port}";
    }

    private void UpdateStatusDisplay()
    {
        int connectionCount;
        lock (_sessions) connectionCount = _sessions.Count;
        _connValueLabel.Text = connectionCount.ToString();
        UpdateUploadSpeed();
        UpdateCpuUsage();
    }

    private void UpdateUploadSpeed()
    {
        if (_server != null)
        {
            long currentUploadBytes = 0;
            lock (_sessions)
            {
                foreach (var session in _sessions.Values)
                {
                    currentUploadBytes += session.GetTotalBytesSent();
                }
            }

            var now = DateTime.Now;
            var timeDiff = (now - _lastUploadCheck).TotalSeconds;
            if (timeDiff > 0)
            {
                var bytesPerSecond = Math.Max(0, (currentUploadBytes - _lastUploadBytes) / timeDiff);
                if (bytesPerSecond < 1024)
                    _uploadValueLabel.Text = $"{bytesPerSecond:F0} B/s";
                else if (bytesPerSecond < 1024 * 1024)
                    _uploadValueLabel.Text = $"{bytesPerSecond / 1024:F1} KB/s";
                else
                    _uploadValueLabel.Text = $"{bytesPerSecond / (1024 * 1024):F1} MB/s";
            }

            _lastUploadBytes = currentUploadBytes;
            _lastUploadCheck = now;
        }
        else
        {
            _uploadValueLabel.Text = "0 B/s";
            _lastUploadBytes = 0;
        }
    }

    private void UpdateCpuUsage()
    {
        try
        {
            var currentCpuTime = _currentProcess.TotalProcessorTime;
            var currentTime = DateTime.Now;
            var cpuTimeDiff = currentCpuTime - _lastCpuTime;
            var timeDiff = currentTime - _lastCpuCheck;

            if (timeDiff.TotalMilliseconds > 0)
            {
                var cpuUsage = Math.Clamp(
                    (cpuTimeDiff.TotalSeconds / (Environment.ProcessorCount * timeDiff.TotalSeconds)) * 100.0,
                    0.0, 100.0);
                _cpuValueLabel.Text = $"{cpuUsage:F1}%";

                if (int.TryParse(_maxCpuInput.InputText.Trim(), out int maxCpu) && maxCpu > 0)
                {
                    bool cpuLimitReached = cpuUsage > maxCpu;
                    lock (_sessions)
                    {
                        foreach (var session in _sessions.Values)
                        {
                            session.SetCpuLimitReached(cpuLimitReached);
                        }
                    }
                }

                _lastCpuTime = currentCpuTime;
                _lastCpuCheck = currentTime;
            }
        }
        catch
        {
            _cpuValueLabel.Text = "N/A";
        }
    }

    private void InitializeTrayIcon()
    {
        _trayMenu = new ContextMenuStrip();
        _trayMenu.Items.Add("显示主窗口", null, (_, _) => ShowMainWindow());
        _trayMenu.Items.Add("打开日志文件夹", null, (_, _) => OpenLogFolder());
        _trayMenu.Items.Add("-");
        _trayStartItem = new ToolStripMenuItem("启动服务", null, OnTrayStartClick);
        _trayStopItem = new ToolStripMenuItem("停止服务", null, OnTrayStopClick);
        _trayMenu.Items.Add(_trayStartItem);
        _trayMenu.Items.Add(_trayStopItem);
        _trayMenu.Items.Add("-");
        _trayMenu.Items.Add("退出", null, OnTrayExitClick);

        Icon? trayIcon = null;
        try
        {
            var iconPath = Path.Combine(AppContext.BaseDirectory, "Remoter.ico");
            if (File.Exists(iconPath))
            {
                using var fs = new FileStream(iconPath, FileMode.Open, FileAccess.Read);
                trayIcon = new Icon(fs);
            }
            else
            {
                trayIcon = SystemIcons.Application;
            }
        }
        catch (Exception ex)
        {
            AppLog.Write($"[Main] Failed to load tray icon: {ex.Message}");
            trayIcon = SystemIcons.Application;
        }

        _trayIcon = new NotifyIcon
        {
            Icon = trayIcon,
            Text = "Remoter Server",
            ContextMenuStrip = _trayMenu,
            Visible = false,
        };
        _trayIcon.MouseClick += OnTrayIconMouseClick;
    }

    private void LoadConfiguration()
    {
        var cfg = AgentConfig.Load();
        _pin = cfg.Pin.Length > 0 ? cfg.Pin : Random.Shared.Next(100_000, 999_999).ToString();
        _port = cfg.Port > 0 ? cfg.Port : (ushort)7788;
        _relayUrl = cfg.RelayUrl ?? "";

        _pinInput.InputText = _pin;
        _pinEnabledCheckBox.Checked = cfg.PinEnabled;
        _pinInput.Enabled = cfg.PinEnabled;
        _webPortInput.InputText = _port.ToString();
        UpdateLanAddressDisplay();
    }

    private void GenerateNewPin()
    {
        _pin = Random.Shared.Next(100_000, 999_999).ToString();
        _pinInput.InputText = _pin;

        var cfg = AgentConfig.Load();
        cfg.Pin = _pin;
        cfg.Save();

        AppLog.Write($"[Main] PIN已刷新：{_pin}");
        ShowToast($"已刷新 PIN 码：{_pin}");
    }

    private void UpdatePinEnabled()
    {
        bool enabled = _pinEnabledCheckBox.Checked;
        _pinInput.Enabled = enabled;

        var cfg = AgentConfig.Load();
        cfg.PinEnabled = enabled;
        cfg.Save();

        Session.SetPinEnabled(enabled);
        AppLog.Write($"[Main] PIN {(enabled ? "已启用" : "已禁用")}");
    }

    private void UpdateStatus(bool isRunning)
    {
        _statusBadge.IsRunning = isRunning;
        _monitorCard.BorderColor = isRunning ? Primary : BorderSubtle;
        _monitorCard.Invalidate();

        if (isRunning)
        {
            _primaryActionBtn.Text = "停止服务";
            _primaryActionBtn.FillColor = Danger;
            _primaryActionBtn.HoverFillColor = DangerHover;
            _primaryActionBtn.Enabled = true;
            _webPortInput.Enabled = false;

            _statusTimer.Start();
            _trayStartItem.Enabled = false;
            _trayStopItem.Enabled = true;
        }
        else
        {
            _primaryActionBtn.Text = "启动服务";
            _primaryActionBtn.FillColor = Primary;
            _primaryActionBtn.HoverFillColor = PrimaryHover;
            _primaryActionBtn.Enabled = true;
            _webPortInput.Enabled = true;

            _statusTimer.Stop();
            _connValueLabel.Text = "0";
            _uploadValueLabel.Text = "0 B/s";
            _cpuValueLabel.Text = "0.0%";
            _trayStartItem.Enabled = true;
            _trayStopItem.Enabled = false;
        }
        _primaryActionBtn.Invalidate();
        UpdateLanAddressDisplay();
    }

    private async void StartServices()
    {
        if (_isStarting || _server != null) return;

        try
        {
            if (!ushort.TryParse(_webPortInput.InputText.Trim(), out _port) || _port == 0)
            {
                ShowToast("请输入有效的 Web 端口号 (1-65535)", isError: true);
                return;
            }

            _isStarting = true;
            _primaryActionBtn.Enabled = false;
            _primaryActionBtn.Text = "正在启动…";

            Session.SetPinEnabled(_pinEnabledCheckBox.Checked);
            bool adaptiveEnabled = _adaptiveCheckBox.Checked;

            await Task.Run(() =>
            {
                lock (_sessions) _sessions.Clear();
                _server = new WebSocketServer();
                _relay = string.IsNullOrEmpty(_relayUrl) ? null : new RelayClient(_relayUrl, _pin);

                _server.OnConnect = conn =>
                {
                    var s = new Session(conn, _pin);
                    s.SetAdaptiveEnabled(adaptiveEnabled);
                    int count;
                    lock (_sessions)
                    {
                        _sessions[conn] = s;
                        count = _sessions.Count;
                    }
                    s.Start();
                    AppLog.Write($"[Agent] {conn.RemoteAddr} connected ({count} active)");
                };

                _server.OnText = (conn, text) =>
                {
                    Session? s;
                    lock (_sessions) _sessions.TryGetValue(conn, out s);
                    s?.HandleText(text);
                };

                _server.OnBinary = (conn, data) =>
                {
                    Session? s;
                    lock (_sessions) _sessions.TryGetValue(conn, out s);
                    s?.HandleBinary(data);
                };

                _server.OnDisconnect = conn =>
                {
                    Session? s;
                    int count;
                    lock (_sessions)
                    {
                        _sessions.TryGetValue(conn, out s);
                        _sessions.Remove(conn);
                        count = _sessions.Count;
                    }
                    s?.Close();
                    AppLog.Write($"[Agent] {conn.RemoteAddr} disconnected ({count} active)");
                };

                _server.Start(_port);
                _relay?.Start();
            });

            var ips = GetLocalIPs();
            AppLog.Write("╔══════════════════════════════════╗");
            AppLog.Write("║        Remoter Windows           ║");
            AppLog.Write("╚══════════════════════════════════╝");
            AppLog.Write($"  PIN : {_pin}");
            AppLog.Write($"  Port: {_port}");
            foreach (var ip in ips)
                AppLog.Write($"  LAN : ws://{ip}:{_port}");
            AppLog.Write($"  Logs: {AppLog.LogDir}");
            var webDir = Path.Combine(AppContext.BaseDirectory, "web");
            if (Directory.Exists(webDir))
                foreach (var ip in ips)
                    AppLog.Write($"  Web : http://{ip}:{_port}/");
            if (_relay != null)
                AppLog.Write($"  Relay: {_relayUrl} (session ID printed on connect)");
            AppLog.Write("Ready. Waiting for connections…");

            var cfg = AgentConfig.Load();
            cfg.Pin = _pin;
            cfg.Port = _port;
            cfg.Save();

            UpdateStatus(true);
            ShowToast($"服务已启动，监听端口 {_port}");
        }
        catch (Exception ex)
        {
            AppLog.Write($"[Main] 启动失败：{ex.Message}");
            UpdateStatus(false);
            ShowToast($"启动失败：{ex.Message}", isError: true);
        }
        finally
        {
            _isStarting = false;
        }
    }

    private void StopServices()
    {
        try
        {
            lock (_sessions)
            {
                foreach (var session in _sessions.Values)
                {
                    session.Close();
                }
                _sessions.Clear();
            }

            _server?.Stop();
            _relay?.Stop();

            _server = null;
            _relay = null;

            if (!IsDisposed)
            {
                UpdateStatus(false);
                ShowToast("服务已停止");
            }
            AppLog.Write("[Main] 服务已停止");
        }
        catch (Exception ex)
        {
            ShowToast($"停止服务失败：{ex.Message}", isError: true);
        }
    }

    private static List<string> GetLocalIPs()
    {
        var ips = new List<string>();
        foreach (var ni in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (ni.OperationalStatus != OperationalStatus.Up) continue;
            foreach (var ua in ni.GetIPProperties().UnicastAddresses)
            {
                if (ua.Address.AddressFamily == AddressFamily.InterNetwork && !IPAddress.IsLoopback(ua.Address))
                    ips.Add(ua.Address.ToString());
            }
        }
        return ips;
    }

    private void OnApplyButtonClick(object? sender, EventArgs e)
    {
        if (!ushort.TryParse(_webPortInput.InputText.Trim(), out var newPort) || newPort == 0)
        {
            ShowToast("请输入有效的 Web 端口号 (1-65535)", isError: true);
            return;
        }

        _port = newPort;
        UpdateLanAddressDisplay();

        var cfg = AgentConfig.Load();
        cfg.Port = _port;
        cfg.Save();

        ShowToast(_server != null ? "设置已保存，重启服务后生效" : "设置已保存");
    }

    private void OnCancelButtonClick(object? sender, EventArgs e)
    {
        if (MessageBox.Show("确定要退出 Remoter 服务吗？", "确认退出", MessageBoxButtons.YesNo, MessageBoxIcon.Question) == DialogResult.Yes)
        {
            _isExiting = true;
            Close();
        }
    }

    private void ShowMainWindow()
    {
        Show();
        WindowState = FormWindowState.Normal;
        Activate();
    }

    private void OnTrayIconMouseClick(object? sender, MouseEventArgs e)
    {
        if (e.Button == MouseButtons.Left) ShowMainWindow();
    }

    private void OnTrayStartClick(object? sender, EventArgs e) => StartServices();
    private void OnTrayStopClick(object? sender, EventArgs e) => StopServices();

    private void OnTrayExitClick(object? sender, EventArgs e)
    {
        if (MessageBox.Show("确定要退出 Remoter 服务吗？", "确认退出", MessageBoxButtons.YesNo, MessageBoxIcon.Question) == DialogResult.Yes)
        {
            _isExiting = true;
            _trayIcon.Visible = false;
            Close();
        }
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (_isExiting)
        {
            _trayIcon.Visible = false;
            StopServices();
            _currentProcess?.Dispose();
            return;
        }

        if (e.CloseReason == CloseReason.UserClosing)
        {
            e.Cancel = true;
            Hide();
            _trayIcon.Visible = true;
            _trayIcon.ShowBalloonTip(3000, "Remoter Server", "程序已最小化到系统托盘", ToolTipIcon.Info);
        }
        else
        {
            _trayIcon.Visible = false;
            StopServices();
            _currentProcess?.Dispose();
        }
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _trayIcon?.Dispose();
            _statusTimer?.Dispose();
            _toastTimer?.Dispose();
            _currentProcess?.Dispose();
            _logoImage?.Dispose();
            _logoImage = null;
            StopServices();
        }
        base.Dispose(disposing);
    }

    // ── Helpers ──────────────────────────────────────────────────────────

    private static void EnableLightTitleBar(nint hwnd)
    {
        if (hwnd == nint.Zero) return;
        int dark = 0;
        if (DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, ref dark, sizeof(int)) != 0)
        {
            DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE_BEFORE_20H1, ref dark, sizeof(int));
        }
    }

    private static Image? LoadLogoImage()
    {
        try
        {
            string pngPath = Path.Combine(AppContext.BaseDirectory, "RemoterLogo.png");
            if (File.Exists(pngPath))
            {
                using var fs = File.OpenRead(pngPath);
                return Image.FromStream(fs);
            }
            string icoPath = Path.Combine(AppContext.BaseDirectory, "Remoter.ico");
            if (File.Exists(icoPath))
            {
                using var ico = new Icon(icoPath, 64, 64);
                return ico.ToBitmap();
            }
        }
        catch { }
        return null;
    }

    private static GraphicsPath CreateRoundRectPath(RectangleF rect, float radius)
    {
        var path = new GraphicsPath();
        float d = Math.Min(radius * 2f, Math.Min(rect.Width, rect.Height));
        if (d <= 0.5f)
        {
            path.AddRectangle(rect);
            return path;
        }
        path.AddArc(rect.X, rect.Y, d, d, 180, 90);
        path.AddArc(rect.Right - d, rect.Y, d, d, 270, 90);
        path.AddArc(rect.Right - d, rect.Bottom - d, d, d, 0, 90);
        path.AddArc(rect.X, rect.Bottom - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }

    // ── Styled Controls (matching ConnectForm) ───────────────────────────

    private sealed class RoundedPanel : Panel
    {
        [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
        public int CornerRadius { get; set; } = 12;

        [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
        public Color BorderColor { get; set; } = BorderLight;

        public RoundedPanel()
        {
            DoubleBuffered = true;
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            e.Graphics.Clear(Parent?.BackColor ?? BgOuter);
            var rect = new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f);
            using var path = CreateRoundRectPath(rect, CornerRadius);
            using var fill = new SolidBrush(BackColor);
            using var pen = new Pen(BorderColor, 1f);
            e.Graphics.FillPath(fill, path);
            e.Graphics.DrawPath(pen, path);
        }
    }

    private sealed class StatusPillBadge : Control
    {
        private bool _isRunning;

        [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
        public bool IsRunning
        {
            get => _isRunning;
            set
            {
                if (_isRunning == value) return;
                _isRunning = value;
                Invalidate();
            }
        }

        public StatusPillBadge()
        {
            DoubleBuffered = true;
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
            Font = new Font("Microsoft YaHei UI", 8.5f, FontStyle.Bold);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            e.Graphics.Clear(Parent?.BackColor ?? BgCard);

            var rect = new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f);
            using var path = CreateRoundRectPath(rect, Height / 2f);
            using var fill = new SolidBrush(_isRunning ? StatusRunBg : StatusOffBg);
            using var pen = new Pen(_isRunning ? Color.FromArgb(167, 243, 208) : BorderLight, 1f);
            e.Graphics.FillPath(fill, path);
            e.Graphics.DrawPath(pen, path);

            using var dotBrush = new SolidBrush(_isRunning ? StatusRunDot : StatusOffDot);
            e.Graphics.FillEllipse(dotBrush, 10, (Height - 8) / 2f, 8, 8);

            var textRect = new Rectangle(22, 0, Width - 26, Height);
            TextRenderer.DrawText(
                e.Graphics,
                _isRunning ? "运行中" : "已停止",
                Font,
                textRect,
                _isRunning ? StatusRunFg : TextMuted,
                TextFormatFlags.VerticalCenter | TextFormatFlags.Left | TextFormatFlags.SingleLine);
        }
    }

    private sealed class RoundedInputBox : Panel
    {
        public TextBox InnerTextBox { get; }
        private bool _focused;

        [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
        public string InputText
        {
            get => InnerTextBox.Text;
            set => InnerTextBox.Text = value;
        }

        [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
        public string Placeholder
        {
            get => InnerTextBox.PlaceholderText;
            set => InnerTextBox.PlaceholderText = value;
        }

        [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
        public bool ReadOnly
        {
            get => InnerTextBox.ReadOnly;
            set => InnerTextBox.ReadOnly = value;
        }

        public RoundedInputBox()
        {
            DoubleBuffered = true;
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
            BackColor = BgCard;
            Cursor = Cursors.IBeam;

            InnerTextBox = new TextBox
            {
                BorderStyle = BorderStyle.None,
                BackColor = BgCard,
                ForeColor = TextDark,
                Font = new Font("Segoe UI", 9.8f),
            };
            InnerTextBox.GotFocus += (_, _) => { _focused = true; Invalidate(); };
            InnerTextBox.LostFocus += (_, _) => { _focused = false; Invalidate(); };

            Controls.Add(InnerTextBox);
            Click += (_, _) => { if (Enabled) InnerTextBox.Focus(); };
        }

        protected override void OnEnabledChanged(EventArgs e)
        {
            base.OnEnabledChanged(e);
            Color bg = Enabled ? BgCard : BgSubtle;
            BackColor = bg;
            InnerTextBox.BackColor = bg;
            InnerTextBox.ForeColor = Enabled ? TextDark : TextMuted;
            Invalidate();
        }

        protected override void OnResize(EventArgs eventargs)
        {
            base.OnResize(eventargs);
            const int padX = 10;
            InnerTextBox.Width = Math.Max(30, Width - padX * 2);
            InnerTextBox.Location = new Point(padX, Math.Max(4, (Height - InnerTextBox.Height) / 2));
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            e.Graphics.Clear(Parent?.BackColor ?? BgSection);
            var rect = new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f);
            using var path = CreateRoundRectPath(rect, 7f);
            using var fill = new SolidBrush(BackColor);
            using var pen = new Pen(_focused ? Primary : BorderSubtle, _focused ? 1.5f : 1f);
            e.Graphics.FillPath(fill, path);
            e.Graphics.DrawPath(pen, path);
        }
    }

    private sealed class RoundedButton : Control
    {
        private bool _hovered;
        private bool _pressed;

        [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
        public int CornerRadius { get; set; } = 8;

        [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
        public Color FillColor { get; set; } = Primary;

        [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
        public Color HoverFillColor { get; set; } = PrimaryHover;

        [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
        public Color TextColor { get; set; } = Color.White;

        [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
        public Color BorderColor { get; set; } = Color.Transparent;

        [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
        public float BorderWidth { get; set; } = 0f;

        public RoundedButton()
        {
            DoubleBuffered = true;
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
            Cursor = Cursors.Hand;
        }

        protected override void OnMouseEnter(EventArgs e) { _hovered = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { _hovered = false; _pressed = false; Invalidate(); base.OnMouseLeave(e); }
        protected override void OnMouseDown(MouseEventArgs e) { if (e.Button == MouseButtons.Left) { _pressed = true; Invalidate(); } base.OnMouseDown(e); }
        protected override void OnMouseUp(MouseEventArgs e) { _pressed = false; Invalidate(); base.OnMouseUp(e); }
        protected override void OnEnabledChanged(EventArgs e) { Invalidate(); base.OnEnabledChanged(e); }
        protected override void OnTextChanged(EventArgs e) { Invalidate(); base.OnTextChanged(e); }

        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            e.Graphics.Clear(Parent?.BackColor ?? BgCard);

            var rect = new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f);
            using var path = CreateRoundRectPath(rect, CornerRadius);

            Color fill = _hovered || _pressed ? HoverFillColor : FillColor;
            if (!Enabled && fill != Color.Transparent)
            {
                fill = Color.FromArgb(140, fill);
            }
            if (fill != Color.Transparent)
            {
                using var brush = new SolidBrush(fill);
                e.Graphics.FillPath(brush, path);
            }

            if (BorderWidth > 0f && BorderColor != Color.Transparent)
            {
                Color bc = Enabled ? BorderColor : Color.FromArgb(110, BorderColor);
                using var pen = new Pen(bc, BorderWidth);
                e.Graphics.DrawPath(pen, path);
            }

            Color fg = Enabled ? TextColor : Color.FromArgb(140, TextColor);
            TextRenderer.DrawText(e.Graphics, Text, Font, ClientRectangle, fg,
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine);
        }
    }
}
