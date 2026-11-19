using System.Drawing;
using System.Windows.Forms;

namespace RemoterWinClient.UI;

/// <summary>
/// Sleek native dark-mode connection window for Remoter-WinClient.
/// Supports direct Host/IP + Port (default 7788) + PIN or Username/Password auth,
/// Remember Device persistence via DeviceStore.Shared, and Saved Devices quick-connect &amp; delete.
/// </summary>
public sealed class ConnectForm : Form
{
    private readonly TextBox _hostBox;
    private readonly TextBox _portBox;
    private readonly CheckBox _tlsCheck;
    private readonly ComboBox _authModeBox;
    private readonly Label _userLabel;
    private readonly TextBox _userBox;
    private readonly Label _secretLabel;
    private readonly TextBox _secretBox;
    private readonly CheckBox _rememberCheck;
    private readonly Button _connectBtn;
    private readonly Label _statusLabel;

    private readonly ListBox _deviceList;
    private readonly Button _quickConnectBtn;
    private readonly Button _deleteDeviceBtn;

    private List<SavedDevice> _devices = new();
    private SavedDevice? _selectedDevice;
    private bool _connecting;
    private CancellationTokenSource? _connectCts;

    public ConnectForm()
    {
        Text = $"Remoter Client v{AppVersion.Current}";
        ClientSize = new Size(740, 460);
        FormBorderStyle = FormBorderStyle.FixedSingle;
        MaximizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        BackColor = DarkTheme.WindowBg;
        ForeColor = DarkTheme.TextPrimary;
        Font = new Font("Segoe UI", 9.5f, FontStyle.Regular);

        string icoPath = Path.Combine(AppContext.BaseDirectory, "Remoter.ico");
        if (File.Exists(icoPath))
        {
            try { Icon = new Icon(icoPath); } catch { }
        }

        // ── Left Panel: Connection Form ──────────────────────────────────
        var leftPanel = new Panel
        {
            Location = new Point(20, 20),
            Size = new Size(370, 420),
            BackColor = DarkTheme.SurfaceBg,
            Padding = new Padding(20),
        };
        leftPanel.Paint += (_, e) =>
        {
            using var pen = new Pen(DarkTheme.BorderColor, 1);
            e.Graphics.DrawRectangle(pen, 0, 0, leftPanel.Width - 1, leftPanel.Height - 1);
        };

        var titleLabel = new Label
        {
            Text = "Remoter",
            Location = new Point(20, 16),
            AutoSize = true,
            Font = new Font("Segoe UI", 17f, FontStyle.Bold),
            ForeColor = DarkTheme.TextPrimary,
        };
        var subtitleLabel = new Label
        {
            Text = "Native Direct3D 11 Remote Desktop",
            Location = new Point(22, 48),
            AutoSize = true,
            Font = new Font("Segoe UI", 8.5f),
            ForeColor = DarkTheme.Accent,
        };

        // Host & Port row
        var hostLabel = CreateFieldLabel("主机 / IP 地址", 20, 82);
        _hostBox = CreateTextBox(20, 102, 225, "192.168.1.100");

        var portLabel = CreateFieldLabel("端口", 255, 82);
        _portBox = CreateTextBox(255, 102, 95, "7788");

        // Auth mode & TLS row
        var authLabel = CreateFieldLabel("认证方式", 20, 138);
        _authModeBox = new ComboBox
        {
            Location = new Point(20, 158),
            Size = new Size(190, 28),
            DropDownStyle = ComboBoxStyle.DropDownList,
            BackColor = DarkTheme.InputBg,
            ForeColor = DarkTheme.TextPrimary,
            FlatStyle = FlatStyle.Flat,
        };
        _authModeBox.Items.AddRange(new object[] { "PIN 码连接", "账号密码连接" });
        _authModeBox.SelectedIndex = 0;
        _authModeBox.SelectedIndexChanged += (_, _) => UpdateAuthFieldsVisibility();

        _tlsCheck = new CheckBox
        {
            Text = "启用 TLS 加密",
            Location = new Point(225, 160),
            AutoSize = true,
            Checked = true,
            ForeColor = DarkTheme.TextPrimary,
        };

        // Username (only for Credentials mode)
        _userLabel = CreateFieldLabel("用户名", 20, 194);
        _userBox = CreateTextBox(20, 214, 330, "");
        _userLabel.Visible = false;
        _userBox.Visible = false;

        // PIN / Password
        _secretLabel = CreateFieldLabel("PIN 码 / 访问密码", 20, 194);
        _secretBox = CreateTextBox(20, 214, 330, "");
        _secretBox.UseSystemPasswordChar = true;

        _rememberCheck = new CheckBox
        {
            Text = "记住此设备 (保存至本地列表)",
            Location = new Point(20, 256),
            AutoSize = true,
            Checked = true,
            ForeColor = DarkTheme.TextMuted,
        };

        _connectBtn = new Button
        {
            Text = "连  接",
            Location = new Point(20, 294),
            Size = new Size(330, 38),
            Font = new Font("Segoe UI", 10.5f, FontStyle.Bold),
        };
        DarkTheme.StyleButton(_connectBtn, primary: true);
        _connectBtn.Click += async (_, _) => await StartConnectAsync();

        _statusLabel = new Label
        {
            Location = new Point(20, 342),
            Size = new Size(330, 46),
            ForeColor = DarkTheme.TextMuted,
            Font = new Font("Segoe UI", 8.5f),
            Text = "",
        };

        var versionLabel = new Label
        {
            Text = $"v{AppVersion.Current} · .NET 10 Native",
            Location = new Point(20, 394),
            AutoSize = true,
            ForeColor = DarkTheme.TextMuted,
            Font = new Font("Segoe UI", 8f),
        };

        leftPanel.Controls.AddRange(new Control[]
        {
            titleLabel, subtitleLabel,
            hostLabel, _hostBox, portLabel, _portBox,
            authLabel, _authModeBox, _tlsCheck,
            _userLabel, _userBox,
            _secretLabel, _secretBox,
            _rememberCheck, _connectBtn, _statusLabel, versionLabel,
        });

        // ── Right Panel: Saved Devices ───────────────────────────────────
        var rightPanel = new Panel
        {
            Location = new Point(406, 20),
            Size = new Size(314, 420),
            BackColor = DarkTheme.SurfaceBg,
        };
        rightPanel.Paint += (_, e) =>
        {
            using var pen = new Pen(DarkTheme.BorderColor, 1);
            e.Graphics.DrawRectangle(pen, 0, 0, rightPanel.Width - 1, rightPanel.Height - 1);
        };

        var savedTitle = new Label
        {
            Text = "已保存设备",
            Location = new Point(16, 16),
            AutoSize = true,
            Font = new Font("Segoe UI", 11f, FontStyle.Bold),
            ForeColor = DarkTheme.TextPrimary,
        };
        var savedHint = new Label
        {
            Text = "双击设备可快速连接",
            Location = new Point(16, 40),
            AutoSize = true,
            Font = new Font("Segoe UI", 8f),
            ForeColor = DarkTheme.TextMuted,
        };

        _deviceList = new ListBox
        {
            Location = new Point(16, 66),
            Size = new Size(282, 294),
            BackColor = DarkTheme.WindowBg,
            ForeColor = DarkTheme.TextPrimary,
            BorderStyle = BorderStyle.FixedSingle,
            DrawMode = DrawMode.OwnerDrawFixed,
            ItemHeight = 48,
        };
        _deviceList.DrawItem += OnDrawDeviceItem;
        _deviceList.SelectedIndexChanged += OnDeviceSelected;
        _deviceList.DoubleClick += async (_, _) =>
        {
            if (_selectedDevice != null && !_connecting)
                await StartConnectAsync();
        };

        _quickConnectBtn = new Button
        {
            Text = "快速连接",
            Location = new Point(16, 372),
            Size = new Size(184, 32),
            Enabled = false,
        };
        DarkTheme.StyleButton(_quickConnectBtn, primary: false);
        _quickConnectBtn.Click += async (_, _) => await StartConnectAsync();

        _deleteDeviceBtn = new Button
        {
            Text = "删除",
            Location = new Point(208, 372),
            Size = new Size(90, 32),
            Enabled = false,
        };
        DarkTheme.StyleButton(_deleteDeviceBtn, danger: true);
        _deleteDeviceBtn.Click += OnDeleteDevice;

        rightPanel.Controls.AddRange(new Control[]
        {
            savedTitle, savedHint, _deviceList, _quickConnectBtn, _deleteDeviceBtn,
        });

        Controls.Add(leftPanel);
        Controls.Add(rightPanel);

        AcceptButton = _connectBtn;

        LoadSavedDevices();
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        DarkTheme.EnableDarkTitleBar(Handle);
    }

    private void UpdateAuthFieldsVisibility()
    {
        bool isCreds = _authModeBox.SelectedIndex == 1;
        _userLabel.Visible = isCreds;
        _userBox.Visible = isCreds;

        if (isCreds)
        {
            _secretLabel.Location = new Point(20, 246);
            _secretLabel.Text = "密码";
            _secretBox.Location = new Point(20, 266);
            _rememberCheck.Location = new Point(20, 300);
            _connectBtn.Location = new Point(20, 328);
            _statusLabel.Location = new Point(20, 370);
        }
        else
        {
            _secretLabel.Location = new Point(20, 194);
            _secretLabel.Text = "PIN 码 / 访问密码";
            _secretBox.Location = new Point(20, 214);
            _rememberCheck.Location = new Point(20, 256);
            _connectBtn.Location = new Point(20, 294);
            _statusLabel.Location = new Point(20, 342);
        }
    }

    private void LoadSavedDevices()
    {
        _devices = DeviceStore.Shared.GetDevices();
        _deviceList.Items.Clear();
        foreach (var d in _devices)
        {
            _deviceList.Items.Add(d);
        }
        _selectedDevice = null;
        _quickConnectBtn.Enabled = false;
        _deleteDeviceBtn.Enabled = false;

        if (_devices.Count > 0 && string.IsNullOrWhiteSpace(_hostBox.Text))
        {
            _deviceList.SelectedIndex = 0;
        }
    }

    private void OnDeviceSelected(object? sender, EventArgs e)
    {
        if (_deviceList.SelectedIndex < 0 || _deviceList.SelectedIndex >= _devices.Count)
        {
            _selectedDevice = null;
            _quickConnectBtn.Enabled = false;
            _deleteDeviceBtn.Enabled = false;
            return;
        }

        var dev = _devices[_deviceList.SelectedIndex];
        _selectedDevice = dev;
        _hostBox.Text = dev.Host;
        _portBox.Text = dev.Port.ToString();
        _tlsCheck.Checked = dev.UseTls;

        if (dev.AuthMethod == AuthMethod.Credentials || dev.AuthMethod == AuthMethod.Token)
        {
            _authModeBox.SelectedIndex = 1;
            _userBox.Text = dev.Username ?? "";
            _secretBox.Text = "";
        }
        else
        {
            _authModeBox.SelectedIndex = 0;
            _secretBox.Text = dev.Pin ?? "";
        }

        _quickConnectBtn.Enabled = true;
        _deleteDeviceBtn.Enabled = true;
    }

    private void OnDeleteDevice(object? sender, EventArgs e)
    {
        if (_selectedDevice == null) return;
        DeviceStore.Shared.RemoveDevice(_selectedDevice.Id);
        LoadSavedDevices();
    }

    private void OnDrawDeviceItem(object? sender, DrawItemEventArgs e)
    {
        if (e.Index < 0 || e.Index >= _devices.Count) return;
        var dev = _devices[e.Index];
        bool selected = (e.State & DrawItemState.Selected) != 0;

        using var bg = new SolidBrush(selected ? DarkTheme.HoverBg : DarkTheme.WindowBg);
        e.Graphics.FillRectangle(bg, e.Bounds);

        if (selected)
        {
            using var accent = new SolidBrush(DarkTheme.Accent);
            e.Graphics.FillRectangle(accent, e.Bounds.Left, e.Bounds.Top + 4, 3, e.Bounds.Height - 8);
        }

        using var titleFont = new Font("Segoe UI", 9.5f, FontStyle.Bold);
        using var subFont = new Font("Segoe UI", 8f);
        using var titleBrush = new SolidBrush(DarkTheme.TextPrimary);
        using var subBrush = new SolidBrush(DarkTheme.TextMuted);

        string name = string.IsNullOrWhiteSpace(dev.DisplayName) ? dev.Host : dev.DisplayName;
        string sub = $"{dev.Host}:{dev.Port}" + (string.IsNullOrWhiteSpace(dev.ServerOs) ? "" : $" · {dev.ServerOs}");

        e.Graphics.DrawString(name, titleFont, titleBrush, e.Bounds.Left + 12, e.Bounds.Top + 6);
        e.Graphics.DrawString(sub, subFont, subBrush, e.Bounds.Left + 12, e.Bounds.Top + 26);

        using var sepPen = new Pen(DarkTheme.BorderColor, 1);
        e.Graphics.DrawLine(sepPen, e.Bounds.Left + 8, e.Bounds.Bottom - 1, e.Bounds.Right - 8, e.Bounds.Bottom - 1);
    }

    private async Task StartConnectAsync()
    {
        if (_connecting) return;

        string host = _hostBox.Text.Trim();
        if (string.IsNullOrWhiteSpace(host))
        {
            SetStatus("请输入主机 IP 或地址", isError: true);
            _hostBox.Focus();
            return;
        }

        if (!int.TryParse(_portBox.Text.Trim(), out int port) || port <= 0 || port > 65535)
        {
            SetStatus("端口号无效 (1 - 65535)", isError: true);
            _portBox.Focus();
            return;
        }

        bool isCreds = _authModeBox.SelectedIndex == 1;
        string secret = _secretBox.Text.Trim();
        string username = _userBox.Text.Trim();

        var existing = DeviceStore.Shared.FindByHost(host, port);
        AuthMethod method;
        string token = "";
        if (isCreds)
        {
            if (string.IsNullOrEmpty(secret) && existing != null && !string.IsNullOrEmpty(existing.Token))
            {
                method = AuthMethod.Token;
                token = existing.Token;
            }
            else
            {
                method = AuthMethod.Credentials;
            }
        }
        else
        {
            method = AuthMethod.Pin;
        }

        var connectParams = new ConnectParams
        {
            Mode = ConnectMode.Direct,
            Host = host,
            Port = port,
            UseTls = _tlsCheck.Checked,
            AuthMethod = method,
            Pin = method == AuthMethod.Pin ? secret : "",
            Username = username,
            Password = method == AuthMethod.Credentials ? secret : "",
            Token = token,
            RememberDevice = _rememberCheck.Checked,
        };

        SetConnectingState(true, $"正在连接 {host}:{port} ...");
        _connectCts = new CancellationTokenSource(TimeSpan.FromSeconds(15));

        var settings = DeviceStore.Shared.GetSettings();
        var conn = new RemoterConnection(settings.DownloadDirectory);
        var tcs = new TaskCompletionSource<StreamInfo>(TaskCreationOptions.RunContinuationsAsynchronously);

        void OnStreamStarted(StreamInfo info) => tcs.TrySetResult(info);
        void OnError(string err) => tcs.TrySetException(new InvalidOperationException(err));
        void OnDisconnected(string reason) => tcs.TrySetException(new InvalidOperationException(string.IsNullOrWhiteSpace(reason) ? "连接已断开" : reason));

        conn.StreamStarted += OnStreamStarted;
        conn.ErrorOccurred += OnError;
        conn.Disconnected += OnDisconnected;

        try
        {
            using var reg = _connectCts.Token.Register(() => tcs.TrySetException(new TimeoutException("连接超时，请检查主机地址、端口或防火墙")));

            await conn.ConnectAsync(connectParams, CancellationToken.None);
            StreamInfo streamInfo = await tcs.Task;

            conn.StreamStarted -= OnStreamStarted;
            conn.ErrorOccurred -= OnError;
            conn.Disconnected -= OnDisconnected;

            if (connectParams.RememberDevice)
            {
                var saved = existing ?? new SavedDevice
                {
                    Id = Guid.NewGuid().ToString("N"),
                    Name = string.IsNullOrWhiteSpace(conn.ServerComputerName) ? host : conn.ServerComputerName,
                    Host = host,
                    Port = port,
                };
                saved.Host = host;
                saved.Port = port;
                saved.UseTls = connectParams.UseTls;
                saved.AuthMethod = connectParams.AuthMethod;
                if (connectParams.AuthMethod == AuthMethod.Pin) saved.Pin = connectParams.Pin;
                if (!string.IsNullOrWhiteSpace(connectParams.Username)) saved.Username = connectParams.Username;
                if (!string.IsNullOrWhiteSpace(conn.ServerComputerName)) saved.ComputerName = conn.ServerComputerName;
                if (!string.IsNullOrWhiteSpace(conn.ServerModelId)) saved.ModelId = conn.ServerModelId;
                if (!string.IsNullOrWhiteSpace(conn.ServerOs)) saved.ServerOs = conn.ServerOs;
                saved.LastConnectedUtc = DateTime.UtcNow;
                DeviceStore.Shared.UpsertDevice(saved);
            }

            SetConnectingState(false, "");

            DesktopForm? desktopForm = null;
            try
            {
                desktopForm = new DesktopForm(conn, connectParams, streamInfo);
                desktopForm.FormClosed += (_, _) =>
                {
                    if (!IsDisposed)
                    {
                        LoadSavedDevices();
                        Show();
                        Activate();
                    }
                };

                desktopForm.Show();
                Hide();
            }
            catch
            {
                try { desktopForm?.Dispose(); } catch { }
                if (!Visible && !IsDisposed) Show();
                throw;
            }
        }
        catch (Exception ex)
        {
            conn.StreamStarted -= OnStreamStarted;
            conn.ErrorOccurred -= OnError;
            conn.Disconnected -= OnDisconnected;
            conn.Dispose();
            TryWriteErrorLog(ex);
            string site = ex.TargetSite != null
                ? $" [{ex.TargetSite.DeclaringType?.Name}.{ex.TargetSite.Name}]"
                : "";
            SetConnectingState(false, $"连接失败: {ex.Message}{site}", isError: true);
        }
        finally
        {
            _connectCts?.Dispose();
            _connectCts = null;
        }
    }

    private void SetConnectingState(bool connecting, string status, bool isError = false)
    {
        _connecting = connecting;
        _connectBtn.Enabled = !connecting;
        _connectBtn.Text = connecting ? "连接中..." : "连  接";
        _hostBox.Enabled = !connecting;
        _portBox.Enabled = !connecting;
        _secretBox.Enabled = !connecting;
        _userBox.Enabled = !connecting;
        _authModeBox.Enabled = !connecting;
        _deviceList.Enabled = !connecting;
        _quickConnectBtn.Enabled = !connecting && _selectedDevice != null;
        _deleteDeviceBtn.Enabled = !connecting && _selectedDevice != null;
        SetStatus(status, isError);
    }

    private void SetStatus(string text, bool isError)
    {
        _statusLabel.Text = text;
        _statusLabel.ForeColor = isError ? DarkTheme.Danger : DarkTheme.TextMuted;
    }

    private static Label CreateFieldLabel(string text, int x, int y) => new()
    {
        Text = text,
        Location = new Point(x, y),
        AutoSize = true,
        Font = new Font("Segoe UI", 8.5f),
        ForeColor = DarkTheme.TextMuted,
    };

    private static TextBox CreateTextBox(int x, int y, int width, string defaultText) => new()
    {
        Location = new Point(x, y),
        Size = new Size(width, 26),
        Text = defaultText,
        BackColor = DarkTheme.InputBg,
        ForeColor = DarkTheme.TextPrimary,
        BorderStyle = BorderStyle.FixedSingle,
        Font = new Font("Segoe UI", 9.5f),
    };

    private static void TryWriteErrorLog(Exception ex)
    {
        try
        {
            string dir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "RemoterWinClient");
            Directory.CreateDirectory(dir);
            string logPath = Path.Combine(dir, "last_error.log");
            File.WriteAllText(logPath, $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}]\r\n{ex}\r\n");
        }
        catch { }
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        _connectCts?.Cancel();
        base.OnFormClosing(e);
    }
}
