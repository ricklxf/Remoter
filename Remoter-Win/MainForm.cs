using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Windows.Forms;
using System.IO;

namespace RemoterWin;

public partial class MainForm : Form
{
    // Services
    private WebSocketServer? _server;
    private AdminServer? _admin;
    private RelayClient? _relay;
    private Dictionary<IWsConn, Session> _sessions = new();
    
    // Configuration
    private string _pin = "";
    private ushort _port = 7788;
    private string _relayUrl = "";
    private bool _isExiting = false;
    
    // UI Controls
    private NotifyIcon _trayIcon = null!;
    private ContextMenuStrip _trayMenu = null!;
    private Label _statusLabel = null!;
    private Panel _statusIndicator = null!;
    private Label _statusDetailLabel = null!;
    private TextBox _webPortTextBox = null!;
    private TextBox _adminPortTextBox = null!;
    private Button _startButton = null!;
    private Button _stopButton = null!;
    private Button _refreshButton = null!;
    private Button _applyButton = null!;
    private Button _cancelButton = null!;
    private TextBox _pinTextBox = null!;
    private System.Windows.Forms.Timer _statusTimer = null!;
    
    // Adaptive quality controls
    private CheckBox _adaptiveCheckBox = null!;
    private TextBox _maxCpuTextBox = null!;
    private Label _maxCpuLabel = null!;
    
    // PIN controls
    private CheckBox _pinEnabledCheckBox = null!;
    
    // Performance monitoring
    private Label _uploadSpeedLabel = null!;
    private Label _cpuUsageLabel = null!;
    private Label _connectionCountLabel = null!;
    private Process _currentProcess = null!;
    private TimeSpan _lastCpuTime = TimeSpan.Zero;
    private DateTime _lastCpuCheck = DateTime.Now;
    private long _lastUploadBytes = 0;
    private DateTime _lastUploadCheck = DateTime.Now;
    
    public MainForm()
    {
        InitializeComponent();
        InitializeTrayIcon();
        LoadConfiguration();
        SetupStatusTimer();
    }
    
    private void InitializeComponent()
    {
        this.Text = "Remoter-Win";
        this.ClientSize = new Size(600, 550);
        this.MinimumSize = new Size(600, 550);
        this.FormBorderStyle = FormBorderStyle.FixedDialog;
        this.MaximizeBox = false;
        this.StartPosition = FormStartPosition.CenterScreen;
        
        // Load custom icon if exists, otherwise use application icon
        try
        {
            var iconPath = Path.Combine(AppContext.BaseDirectory, "Remoter.ico");
            if (File.Exists(iconPath))
            {
                using (var fs = new FileStream(iconPath, FileMode.Open, FileAccess.Read))
                {
                    this.Icon = new Icon(fs);
                }
            }
            else
                this.Icon = SystemIcons.Application;
        }
        catch (Exception ex)
        {
            AppLog.Write($"[Main] Failed to load icon: {ex.Message}");
            this.Icon = SystemIcons.Application;
        }
        
        this.BackColor = Color.White;
        this.Font = new Font("Segoe UI", 9F);
        
        // Title bar (modern dark style)
        var titleBar = new Panel
        {
            Location = new Point(0, 0),
            Size = new Size(600, 48),
            BackColor = Color.FromArgb(32, 32, 32)
        };
        
        var titleLabel = new Label
        {
            Location = new Point(16, 12),
            Size = new Size(200, 24),
            Text = "Remoter-Win",
            Font = new Font("Segoe UI", 11F, FontStyle.Regular),
            ForeColor = Color.White,
            BackColor = Color.Transparent
        };
        titleBar.Controls.Add(titleLabel);
        
        // Status indicator in title bar
        _statusIndicator = new Panel
        {
            Location = new Point(560, 18),
            Size = new Size(12, 12),
            BackColor = Color.FromArgb(220, 50, 50) // Red for stopped
        };
        titleBar.Controls.Add(_statusIndicator);
        
        var statusTextLabel = new Label
        {
            Location = new Point(578, 14),
            Size = new Size(50, 20),
            Text = "已停止",
            Font = new Font("Segoe UI", 8F),
            ForeColor = Color.FromArgb(180, 180, 180),
            BackColor = Color.Transparent
        };
        titleBar.Controls.Add(statusTextLabel);
        
        this.Controls.Add(titleBar);
        
        // Main content area
        var contentPanel = new Panel
        {
            Location = new Point(0, 48),
            Size = new Size(600, 502),
            BackColor = Color.FromArgb(245, 245, 245)
        };
        
        // Status display section
        var statusSection = new Panel
        {
            Location = new Point(16, 12),
            Size = new Size(568, 56),
            BackColor = Color.White
        };
        statusSection.Paint += (s, e) =>
        {
            var rect = statusSection.ClientRectangle;
            using var pen = new Pen(Color.FromArgb(230, 230, 230), 1);
            e.Graphics.DrawRectangle(pen, rect.X, rect.Y, rect.Width - 1, rect.Height - 1);
        };
        
        _statusLabel = new Label
        {
            Location = new Point(12, 8),
            Size = new Size(544, 40),
            Text = "服务已停止\n点击启动按钮开始服务",
            Font = new Font("Segoe UI", 9F),
            ForeColor = Color.FromArgb(120, 120, 120)
        };
        statusSection.Controls.Add(_statusLabel);
        
        contentPanel.Controls.Add(statusSection);
        
        // Performance monitoring section
        var perfSection = new Panel
        {
            Location = new Point(16, 76),
            Size = new Size(568, 80),
            BackColor = Color.White
        };
        perfSection.Paint += (s, e) =>
        {
            var rect = perfSection.ClientRectangle;
            using var pen = new Pen(Color.FromArgb(230, 230, 230), 1);
            e.Graphics.DrawRectangle(pen, rect.X, rect.Y, rect.Width - 1, rect.Height - 1);
        };
        
        var perfTitleLabel = new Label
        {
            Location = new Point(12, 8),
            Size = new Size(400, 18),
            Text = "实时监控",
            Font = new Font("Segoe UI", 8.5F),
            ForeColor = Color.FromArgb(100, 100, 100)
        };
        perfSection.Controls.Add(perfTitleLabel);
        
        _connectionCountLabel = new Label
        {
            Location = new Point(12, 30),
            Size = new Size(120, 20),
            Text = "连接数：0",
            Font = new Font("Segoe UI", 9F, FontStyle.Regular),
            ForeColor = Color.FromArgb(50, 50, 50)
        };
        perfSection.Controls.Add(_connectionCountLabel);
        
        _uploadSpeedLabel = new Label
        {
            Location = new Point(140, 30),
            Size = new Size(120, 20),
            Text = "上传：0 KB/s",
            Font = new Font("Segoe UI", 9F, FontStyle.Regular),
            ForeColor = Color.FromArgb(50, 50, 50)
        };
        perfSection.Controls.Add(_uploadSpeedLabel);
        
        _cpuUsageLabel = new Label
        {
            Location = new Point(280, 30),
            Size = new Size(120, 20),
            Text = "CPU：0%",
            Font = new Font("Segoe UI", 9F, FontStyle.Regular),
            ForeColor = Color.FromArgb(50, 50, 50)
        };
        perfSection.Controls.Add(_cpuUsageLabel);
        
        _statusDetailLabel = new Label
        {
            Location = new Point(12, 54),
            Size = new Size(544, 18),
            Text = "端口：7788 | 管理端口：7790",
            Font = new Font("Segoe UI", 8F),
            ForeColor = Color.FromArgb(150, 150, 150)
        };
        perfSection.Controls.Add(_statusDetailLabel);
        
        contentPanel.Controls.Add(perfSection);
        
        // Settings section
        var settingsSection = new Panel
        {
            Location = new Point(16, 152),
            Size = new Size(568, 140),
            BackColor = Color.White
        };
        settingsSection.Paint += (s, e) =>
        {
            var rect = settingsSection.ClientRectangle;
            using var pen = new Pen(Color.FromArgb(230, 230, 230), 1);
            e.Graphics.DrawRectangle(pen, rect.X, rect.Y, rect.Width - 1, rect.Height - 1);
        };
        
        var settingsTitleLabel = new Label
        {
            Location = new Point(12, 8),
            Size = new Size(400, 18),
            Text = "设置",
            Font = new Font("Segoe UI", 8.5F),
            ForeColor = Color.FromArgb(100, 100, 100)
        };
        settingsSection.Controls.Add(settingsTitleLabel);
        
        // PIN enable checkbox
        _pinEnabledCheckBox = new CheckBox
        {
            Location = new Point(12, 30),
            Size = new Size(100, 20),
            Text = "启用PIN码",
            Checked = true,
            Font = new Font("Segoe UI", 8.5F),
            ForeColor = Color.FromArgb(60, 60, 60)
        };
        _pinEnabledCheckBox.CheckedChanged += (s, e) => UpdatePinEnabled();
        settingsSection.Controls.Add(_pinEnabledCheckBox);
        
        // PIN display
        _pinTextBox = new TextBox
        {
            Location = new Point(118, 28),
            Size = new Size(100, 22),
            ReadOnly = true,
            BackColor = Color.FromArgb(250, 250, 250),
            Font = new Font("Consolas", 10F, FontStyle.Bold),
            BorderStyle = BorderStyle.FixedSingle,
            TextAlign = HorizontalAlignment.Center
        };
        settingsSection.Controls.Add(_pinTextBox);
        
        var refreshPinButton = new Button
        {
            Location = new Point(224, 27),
            Size = new Size(50, 24),
            Text = "刷新",
            FlatStyle = FlatStyle.Flat,
            BackColor = Color.FromArgb(240, 240, 240),
            ForeColor = Color.FromArgb(60, 60, 60),
            Font = new Font("Segoe UI", 8F),
            Cursor = Cursors.Hand
        };
        refreshPinButton.FlatAppearance.BorderColor = Color.FromArgb(200, 200, 200);
        refreshPinButton.Click += (s, e) => GenerateNewPin();
        settingsSection.Controls.Add(refreshPinButton);
        
        // Web port
        var webPortLabel = new Label
        {
            Location = new Point(12, 58),
            Size = new Size(60, 20),
            Text = "Web端口",
            TextAlign = ContentAlignment.MiddleRight,
            Font = new Font("Segoe UI", 8.5F)
        };
        settingsSection.Controls.Add(webPortLabel);
        
        _webPortTextBox = new TextBox
        {
            Location = new Point(78, 57),
            Size = new Size(60, 22),
            Text = "7788",
            BorderStyle = BorderStyle.FixedSingle,
            Font = new Font("Segoe UI", 9F)
        };
        settingsSection.Controls.Add(_webPortTextBox);
        
        // Adaptive checkbox
        _adaptiveCheckBox = new CheckBox
        {
            Location = new Point(150, 58),
            Size = new Size(90, 20),
            Text = "画面自适应",
            Checked = true,
            Font = new Font("Segoe UI", 8.5F),
            ForeColor = Color.FromArgb(60, 60, 60)
        };
        settingsSection.Controls.Add(_adaptiveCheckBox);
        
        // Max CPU
        _maxCpuLabel = new Label
        {
            Location = new Point(245, 60),
            Size = new Size(60, 18),
            Text = "最大CPU",
            TextAlign = ContentAlignment.MiddleRight,
            Font = new Font("Segoe UI", 8F)
        };
        settingsSection.Controls.Add(_maxCpuLabel);
        
        _maxCpuTextBox = new TextBox
        {
            Location = new Point(310, 58),
            Size = new Size(40, 22),
            Text = "80",
            BorderStyle = BorderStyle.FixedSingle,
            Font = new Font("Segoe UI", 9F)
        };
        settingsSection.Controls.Add(_maxCpuTextBox);
        
        var cpuPercentLabel = new Label
        {
            Location = new Point(355, 60),
            Size = new Size(18, 18),
            Text = "%",
            Font = new Font("Segoe UI", 8.5F)
        };
        settingsSection.Controls.Add(cpuPercentLabel);
        
        // Admin port (read-only display)
        var adminPortLabel = new Label
        {
            Location = new Point(380, 60),
            Size = new Size(72, 18),
            Text = "管理端口",
            TextAlign = ContentAlignment.MiddleRight,
            Font = new Font("Segoe UI", 8F)
        };
        settingsSection.Controls.Add(adminPortLabel);
        
        _adminPortTextBox = new TextBox
        {
            Location = new Point(458, 58),
            Size = new Size(60, 22),
            Text = "7790",
            Enabled = false,
            BackColor = Color.FromArgb(245, 245, 245),
            BorderStyle = BorderStyle.FixedSingle,
            Font = new Font("Segoe UI", 9F)
        };
        settingsSection.Controls.Add(_adminPortTextBox);
        
        contentPanel.Controls.Add(settingsSection);
        
        // Button section - 确保在设置区域下方（设置区域结束于292，加上间距16 = 308）
        var buttonSection = new Panel
        {
            Location = new Point(16, 308),
            Size = new Size(568, 50),
            BackColor = Color.Transparent
        };
        
        _startButton = new Button
        {
            Location = new Point(0, 9),
            Size = new Size(120, 36),
            Text = "启动服务",
            BackColor = Color.FromArgb(0, 135, 80),
            ForeColor = Color.White,
            FlatStyle = FlatStyle.Flat,
            Font = new Font("Segoe UI", 9.5F, FontStyle.Regular),
            Cursor = Cursors.Hand
        };
        _startButton.FlatAppearance.BorderSize = 0;
        _startButton.Click += OnStartButtonClick;
        buttonSection.Controls.Add(_startButton);
        
        _stopButton = new Button
        {
            Location = new Point(130, 9),
            Size = new Size(120, 36),
            Text = "停止服务",
            BackColor = Color.FromArgb(200, 50, 50),
            ForeColor = Color.White,
            FlatStyle = FlatStyle.Flat,
            Font = new Font("Segoe UI", 9.5F, FontStyle.Regular),
            Cursor = Cursors.Hand,
            Enabled = false
        };
        _stopButton.FlatAppearance.BorderSize = 0;
        _stopButton.Click += OnStopButtonClick;
        buttonSection.Controls.Add(_stopButton);
        
        _refreshButton = new Button
        {
            Location = new Point(260, 9),
            Size = new Size(100, 36),
            Text = "刷新",
            BackColor = Color.FromArgb(240, 240, 240),
            ForeColor = Color.FromArgb(60, 60, 60),
            FlatStyle = FlatStyle.Flat,
            Font = new Font("Segoe UI", 9.5F, FontStyle.Regular),
            Cursor = Cursors.Hand
        };
        _refreshButton.FlatAppearance.BorderColor = Color.FromArgb(200, 200, 200);
        _refreshButton.FlatAppearance.BorderSize = 1;
        _refreshButton.Click += OnRefreshButtonClick;
        buttonSection.Controls.Add(_refreshButton);
        
        // Exit button - 现代化UI设计，使用灰色调
        var exitButton = new Button
        {
            Location = new Point(370, 9),
            Size = new Size(100, 36),
            Text = "退出",
            BackColor = Color.FromArgb(120, 120, 120),
            ForeColor = Color.White,
            FlatStyle = FlatStyle.Flat,
            Font = new Font("Segoe UI", 9.5F, FontStyle.Regular),
            Cursor = Cursors.Hand
        };
        exitButton.FlatAppearance.BorderSize = 0;
        exitButton.Click += (s, e) => 
        {
            _isExiting = true;
            Application.Exit();
        };
        buttonSection.Controls.Add(exitButton);
        
        contentPanel.Controls.Add(buttonSection);
        
        // Bottom buttons
        _applyButton = new Button
        {
            Location = new Point(16, 320),
            Size = new Size(260, 36),
            Text = "应用设置",
            BackColor = Color.FromArgb(0, 120, 215),
            ForeColor = Color.White,
            FlatStyle = FlatStyle.Flat,
            Font = new Font("Segoe UI", 9.5F, FontStyle.Regular),
            Cursor = Cursors.Hand
        };
        _applyButton.FlatAppearance.BorderSize = 0;
        _applyButton.Click += OnApplyButtonClick;
        contentPanel.Controls.Add(_applyButton);
        
        _cancelButton = new Button
        {
            Location = new Point(292, 320),
            Size = new Size(260, 36),
            Text = "退出程序",
            BackColor = Color.FromArgb(240, 240, 240),
            ForeColor = Color.FromArgb(60, 60, 60),
            FlatStyle = FlatStyle.Flat,
            Font = new Font("Segoe UI", 9.5F, FontStyle.Regular),
            Cursor = Cursors.Hand
        };
        _cancelButton.FlatAppearance.BorderColor = Color.FromArgb(200, 200, 200);
        _cancelButton.FlatAppearance.BorderSize = 1;
        _cancelButton.Click += OnCancelButtonClick;
        contentPanel.Controls.Add(_cancelButton);
        
        this.Controls.Add(contentPanel);
    }
    
    private void SetupStatusTimer()
    {
        _statusTimer = new System.Windows.Forms.Timer();
        _statusTimer.Interval = 2000; // Check every 2 seconds for more responsive updates
        _statusTimer.Tick += (s, e) => UpdateStatusDisplay();
        
        // Initialize process for CPU monitoring
        _currentProcess = Process.GetCurrentProcess();
        _lastCpuTime = _currentProcess.TotalProcessorTime;
        _lastCpuCheck = DateTime.Now;
    }
    
    private void UpdateStatusDisplay()
    {
        // Update connection count
        int connectionCount = _sessions?.Count ?? 0;
        _connectionCountLabel.Text = $"连接数：{connectionCount}";
        
        if (_server != null)
        {
            _statusIndicator.BackColor = Color.FromArgb(50, 180, 50); // Green for running
            _statusLabel.Text = "服务状态：运行中";
            _statusDetailLabel.Text = $"Web端口：{_port} | 管理端口：{_port + 2} | 连接数：{connectionCount}";
        }
        else
        {
            _statusIndicator.BackColor = Color.FromArgb(220, 50, 50); // Red for stopped
            _statusLabel.Text = "服务状态：已停止";
            _statusDetailLabel.Text = "点击\"启动远控\"开始服务";
        }
        
        // Update upload speed
        UpdateUploadSpeed();
        
        // Update CPU usage
        UpdateCpuUsage();
    }
    
    private void UpdateUploadSpeed()
    {
        if (_server != null && _sessions != null)
        {
            long currentUploadBytes = 0;
            // Calculate total bytes sent from all sessions
            lock (_sessions)
            {
                foreach (var session in _sessions.Values)
                {
                    // Get upload bytes from session (we'll add this property to Session class)
                    currentUploadBytes += session.GetTotalBytesSent();
                }
            }
            
            var now = DateTime.Now;
            var timeDiff = (now - _lastUploadCheck).TotalSeconds;
            
            if (timeDiff > 0)
            {
                var bytesPerSecond = (currentUploadBytes - _lastUploadBytes) / timeDiff;
                string speedText;
                
                if (bytesPerSecond < 1024)
                    speedText = $"{bytesPerSecond:F0} B/s";
                else if (bytesPerSecond < 1024 * 1024)
                    speedText = $"{bytesPerSecond / 1024:F1} KB/s";
                else
                    speedText = $"{bytesPerSecond / (1024 * 1024):F1} MB/s";
                
                _uploadSpeedLabel.Text = $"上传速度：{speedText}";
            }
            
            _lastUploadBytes = currentUploadBytes;
            _lastUploadCheck = now;
        }
        else
        {
            _uploadSpeedLabel.Text = "上传速度：0 KB/s";
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
                // 修正CPU计算：使用百分比公式
                var cpuUsage = (cpuTimeDiff.TotalSeconds / (Environment.ProcessorCount * timeDiff.TotalSeconds)) * 100.0;
                _cpuUsageLabel.Text = $"CPU：{cpuUsage:F1}%";
                
                // Check if CPU usage exceeds limit and notify sessions
                if (int.TryParse(_maxCpuTextBox.Text, out int maxCpu) && maxCpu > 0)
                {
                    bool cpuLimitReached = cpuUsage > maxCpu;
                    // Notify all sessions about CPU limit
                    if (_sessions != null)
                    {
                        lock (_sessions)
                        {
                            foreach (var session in _sessions.Values)
                            {
                                session.SetCpuLimitReached(cpuLimitReached);
                            }
                        }
                    }
                }
                
                // Update for next calculation
                _lastCpuTime = currentCpuTime;
                _lastCpuCheck = currentTime;
            }
        }
        catch
        {
            _cpuUsageLabel.Text = "CPU：N/A";
        }
    }
    
    private void InitializeTrayIcon()
    {
        _trayMenu = new ContextMenuStrip();
        _trayMenu.Items.Add("显示主窗口", null, (s, e) => ShowMainWindow());
        _trayMenu.Items.Add("-");
        _trayMenu.Items.Add("启动服务", null, OnTrayStartClick);
        _trayMenu.Items.Add("停止服务", null, OnTrayStopClick);
        _trayMenu.Items.Add("-");
        _trayMenu.Items.Add("退出", null, OnTrayExitClick);
        
        // Load custom icon for tray
        Icon? trayIcon = null;
        try
        {
            var iconPath = Path.Combine(AppContext.BaseDirectory, "Remoter.ico");
            if (File.Exists(iconPath))
            {
                using (var fs = new FileStream(iconPath, FileMode.Open, FileAccess.Read))
                {
                    trayIcon = new Icon(fs);
                }
            }
            else
                trayIcon = SystemIcons.Application;
        }
        catch (Exception ex)
        {
            AppLog.Write($"[Main] Failed to load tray icon: {ex.Message}");
            trayIcon = SystemIcons.Application;
        }
        
        _trayIcon = new NotifyIcon
        {
            Icon = trayIcon,
            Text = "Remoter-Win",
            ContextMenuStrip = _trayMenu,
            Visible = false
        };
        
        _trayIcon.MouseClick += OnTrayIconMouseClick;
    }
    
    private void LoadConfiguration()
    {
        var cfg = AgentConfig.Load();
        _pin = cfg.Pin.Length > 0 ? cfg.Pin : Random.Shared.Next(100_000, 999_999).ToString();
        _port = cfg.Port > 0 ? cfg.Port : (ushort)7788;
        _relayUrl = cfg.RelayUrl ?? "";
        
        _pinTextBox.Text = _pin;
        _pinEnabledCheckBox.Checked = cfg.PinEnabled;
        _webPortTextBox.Text = _port.ToString();
        _adminPortTextBox.Text = (_port + 2).ToString();
        
        // Update PIN textbox enabled state
        _pinTextBox.Enabled = cfg.PinEnabled;
    }
    
    private void GenerateNewPin()
    {
        _pin = Random.Shared.Next(100_000, 999_999).ToString();
        _pinTextBox.Text = _pin;
        
        // Save to config
        var cfg = AgentConfig.Load();
        cfg.Pin = _pin;
        cfg.Save();
        
        // Update running admin server
        if (_admin != null)
        {
            _admin.UpdatePin(_pin);
        }
        
        AppLog.Write($"[Main] PIN已刷新：{_pin}");
        MessageBox.Show($"新PIN：{_pin}\n重启服务后新连接将使用此PIN", "PIN已刷新", MessageBoxButtons.OK, MessageBoxIcon.Information);
    }
    
    private void UpdatePinEnabled()
    {
        bool enabled = _pinEnabledCheckBox.Checked;
        _pinTextBox.Enabled = enabled;
        
        // Save to config
        var cfg = AgentConfig.Load();
        cfg.PinEnabled = enabled;
        cfg.Save();
        
        // Update running sessions
        Session.SetPinEnabled(enabled);
        
        AppLog.Write($"[Main] PIN {(enabled ? "已启用" : "已禁用")}");
    }
    
    private void UpdateStatus(bool isRunning)
    {
        if (isRunning)
        {
            _statusIndicator.BackColor = Color.FromArgb(50, 180, 50); // Green for running
            _statusLabel.Text = "服务运行中\n点击停止按钮禁用服务";
            _statusDetailLabel.Text = $"Web端口：{_port} | 管理端口：{_port + 2} | 连接数：{_sessions.Count}";
            _startButton.Enabled = false;
            _stopButton.Enabled = true;
            
            // Start timer
            _statusTimer.Start();
            
            // Update tray menu
            _trayMenu.Items[2].Enabled = false;  // 启动远控
            _trayMenu.Items[3].Enabled = true;   // 禁用远控
        }
        else
        {
            _statusIndicator.BackColor = Color.FromArgb(220, 50, 50); // Red for stopped
            _statusLabel.Text = "服务已停止\n点击启动按钮开始服务";
            _statusDetailLabel.Text = $"端口：{_port} | 管理端口：{_port + 2}";
            _startButton.Enabled = true;
            _stopButton.Enabled = false;
            
            // Stop timer
            _statusTimer.Stop();
            
            // Update tray menu
            _trayMenu.Items[2].Enabled = true;   // 启动远控
            _trayMenu.Items[3].Enabled = false;  // 禁用远控
        }
    }
    
    private async void StartServices()
    {
        try
        {
            // Parse port
            if (!ushort.TryParse(_webPortTextBox.Text, out _port))
            {
                MessageBox.Show("请输入有效的Web端口号", "错误", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }
            
            // Disable button to prevent double-click
            _startButton.Enabled = false;
            _statusLabel.Text = "正在启动服务...";
            
            // Update PIN enabled state
            Session.SetPinEnabled(_pinEnabledCheckBox.Checked);
            
            // Run service startup in background task
            await Task.Run(() =>
            {
                // Initialize services
                _sessions.Clear();
                _server = new WebSocketServer();
                _admin = new AdminServer(_port, _pin, _relayUrl);
                _relay = string.IsNullOrEmpty(_relayUrl) ? null : new RelayClient(_relayUrl, _pin);
                
                // Route logs
                AppLog.OnLog += _admin.Log;
                
                // PIN change handler
                _admin.OnPinChange = newPin =>
                {
                    _pin = newPin;
                    _relay?.UpdatePin(newPin);
                    var cfg = AgentConfig.Load();
                    cfg.Pin = newPin;
                    cfg.Save();
                    Invoke(() => _pinTextBox.Text = newPin);
                    AppLog.Write($"[Agent] PIN updated to {newPin}");
                };
                
                // Relay change handler
                _admin.OnRelayChange = newRelay =>
                {
                    _relay?.Stop();
                    _relay = null;
                    _relayUrl = newRelay;
                    var cfg = AgentConfig.Load();
                    cfg.RelayUrl = newRelay;
                    cfg.Save();
                    if (!string.IsNullOrEmpty(newRelay))
                    {
                        _relay = new RelayClient(newRelay, _pin);
                        _relay.Start();
                        AppLog.Write($"[Agent] Relay URL updated to {newRelay}");
                    }
                    else
                    {
                        AppLog.Write("[Agent] Relay disabled");
                    }
                };
                
                // Session management
                _server.OnConnect = (conn) =>
                {
                    var s = new Session(conn, _pin);
                    // Set adaptive quality based on UI setting
                    s.SetAdaptiveEnabled(_adaptiveCheckBox.Checked);
                    lock (_sessions) _sessions[conn] = s;
                    s.Start();
                    AppLog.Write($"[Agent] {conn.RemoteAddr} connected ({_sessions.Count} active)");
                    _admin.SetConnCount(_sessions.Count);
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
                
                _server.OnDisconnect = (conn) =>
                {
                    Session? s;
                    lock (_sessions)
                    {
                        _sessions.TryGetValue(conn, out s);
                        _sessions.Remove(conn);
                    }
                    s?.Close();
                    AppLog.Write($"[Agent] {conn.RemoteAddr} disconnected ({_sessions.Count} active)");
                    _admin.SetConnCount(_sessions.Count);
                };
                
                // Start services
                _server.Start(_port);
                _admin.Start();
                _relay?.Start();
            });
            
            // Log startup info (on UI thread)
            var ips = GetLocalIPs();
            AppLog.Write("╔══════════════════════════════════╗");
            AppLog.Write("║      Remoter Windows Agent        ║");
            AppLog.Write("╚══════════════════════════════════╝");
            AppLog.Write($"  PIN : {_pin}");
            AppLog.Write($"  Port: {_port}");
            foreach (var ip in ips)
                AppLog.Write($"  LAN : ws://{ip}:{_port}");
            AppLog.Write($"  Admin: http://localhost:{_port + 2}/");
            var webDir = Path.Combine(AppContext.BaseDirectory, "web");
            if (Directory.Exists(webDir))
                foreach (var ip in ips)
                    AppLog.Write($"  Web : http://{ip}:{_port}/");
            if (_relay != null)
                AppLog.Write($"  Relay: {_relayUrl} (session ID printed on connect)");
            AppLog.Write("Ready. Waiting for connections…");
            
            UpdateStatus(true);
            
            // Save config
            var cfg = AgentConfig.Load();
            cfg.Pin = _pin;
            cfg.Port = _port;
            cfg.Save();
        }
        catch (Exception ex)
        {
            MessageBox.Show($"启动服务失败：{ex.Message}", "错误", MessageBoxButtons.OK, MessageBoxIcon.Error);
            AppLog.Write($"[Main] 启动失败：{ex.Message}");
            _startButton.Enabled = true; // Re-enable on failure
        }
    }
    
    private void StopServices()
    {
        try
        {
            // 先断开所有活跃会话
            if (_sessions != null)
            {
                lock (_sessions)
                {
                    foreach (var session in _sessions.Values)
                    {
                        session.Close();
                    }
                    _sessions.Clear();
                }
            }
            
            // 停止服务器
            _server?.Stop();
            _admin?.Stop();
            _relay?.Stop();
            
            _server = null;
            _admin = null;
            _relay = null;
            
            UpdateStatus(false);
            AppLog.Write("[Main] 服务已停止");
        }
        catch (Exception ex)
        {
            MessageBox.Show($"停止服务失败：{ex.Message}", "错误", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }
    
    private static List<string> GetLocalIPs()
    {
        var ips = new List<string>();
        foreach (var ni in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (ni.OperationalStatus != OperationalStatus.Up) continue;
            foreach (var ua in ni.GetIPProperties().UnicastAddresses)
                if (ua.Address.AddressFamily == AddressFamily.InterNetwork
                    && !IPAddress.IsLoopback(ua.Address))
                    ips.Add(ua.Address.ToString());
        }
        return ips;
    }
    
    private void OnStartButtonClick(object? sender, EventArgs e)
    {
        StartServices();
    }
    
    private void OnStopButtonClick(object? sender, EventArgs e)
    {
        StopServices();
    }
    
    private void OnRefreshButtonClick(object? sender, EventArgs e)
    {
        UpdateStatusDisplay();
        // 不弹出对话框，只在状态面板显示
    }
    
    private void OnApplyButtonClick(object? sender, EventArgs e)
    {
        if (!ushort.TryParse(_webPortTextBox.Text, out var newPort))
        {
            MessageBox.Show("请输入有效的Web端口号", "错误", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }
        
        _port = newPort;
        _adminPortTextBox.Text = (_port + 2).ToString();
        
        // Save config
        var cfg = AgentConfig.Load();
        cfg.Port = _port;
        cfg.Save();
        
        MessageBox.Show("设置已保存，重启服务后生效", "提示", MessageBoxButtons.OK, MessageBoxIcon.Information);
    }
    
    private void OnCancelButtonClick(object? sender, EventArgs e)
    {
        if (MessageBox.Show("确定要退出程序吗？", "确认退出", MessageBoxButtons.YesNo, MessageBoxIcon.Question) == DialogResult.Yes)
        {
            _isExiting = true;
            this.Close();
        }
    }
    
    private void ShowMainWindow()
    {
        this.Show();
        this.WindowState = FormWindowState.Normal;
        this.Activate();
    }
    
    private void OnTrayIconMouseClick(object? sender, MouseEventArgs e)
    {
        if (e.Button == MouseButtons.Left)
        {
            ShowMainWindow();
        }
    }
    
    private void OnTrayStartClick(object? sender, EventArgs e)
    {
        StartServices();
    }
    
    private void OnTrayStopClick(object? sender, EventArgs e)
    {
        StopServices();
    }
    
    private void OnTrayExitClick(object? sender, EventArgs e)
    {
        if (MessageBox.Show("确定要退出程序吗？", "确认退出", MessageBoxButtons.YesNo, MessageBoxIcon.Question) == DialogResult.Yes)
        {
            _isExiting = true;
            _trayIcon.Visible = false;
            this.Close();
        }
    }
    
    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (_isExiting)
        {
            // 完全退出程序
            _trayIcon.Visible = false;
            StopServices();
            _currentProcess?.Dispose();
            return;
        }
        
        if (e.CloseReason == CloseReason.UserClosing)
        {
            e.Cancel = true;
            this.Hide();
            _trayIcon.Visible = true;
            _trayIcon.ShowBalloonTip(3000, "Remoter-Win", "程序已最小化到系统托盘", ToolTipIcon.Info);
        }
        else
        {
            // Actual exit
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
            _currentProcess?.Dispose();
            StopServices();
        }
        base.Dispose(disposing);
    }
}
