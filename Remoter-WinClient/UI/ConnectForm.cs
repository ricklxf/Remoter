using System.ComponentModel;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace RemoterWinClient.UI;

/// <summary>
/// Clean single-card login window matching the Remoter Web client UI:
/// - Bee mascot logo + "Remoter" title + "远程控制 · 超清 2K · 60fps" subtitle
/// - Direct (LAN) / Relay (WAN) segmented mode tabs
/// - Rounded address input (auto-parses wss://host:port or bare IP)
/// - Teal-bordered saved device &amp; account card with model badge, dropdown switcher, inline Note &amp; Forget
/// - PIN / Credentials auth tabs with Remember Device toggle &amp; token persistence
/// </summary>
public sealed class ConnectForm : Form
{
    // Palette matching Web ConnectPage
    private static readonly Color BgOuter      = Color.FromArgb(241, 245, 249); // #F1F5F9
    private static readonly Color BgCard       = Color.White;                   // #FFFFFF
    private static readonly Color BgSubtle     = Color.FromArgb(241, 245, 249); // #F1F5F9
    private static readonly Color BgSavedCard  = Color.FromArgb(248, 250, 252); // #F8FAFC
    private static readonly Color BorderSubtle = Color.FromArgb(203, 213, 225); // #CBD5E1
    private static readonly Color BorderLight  = Color.FromArgb(226, 232, 240); // #E2E8F0
    private static readonly Color Primary      = Color.FromArgb(13, 148, 136);  // #0D9488
    private static readonly Color PrimaryHover = Color.FromArgb(15, 118, 110);  // #0F766E
    private static readonly Color TextDark     = Color.FromArgb(17, 24, 39);    // #111827
    private static readonly Color TextMuted    = Color.FromArgb(100, 116, 139); // #64748B
    private static readonly Color ErrorBg      = Color.FromArgb(254, 242, 242); // #FEF2F2
    private static readonly Color ErrorBorder  = Color.FromArgb(254, 202, 202); // #FECACA
    private static readonly Color ErrorText    = Color.FromArgb(220, 38, 38);   // #DC2626

    private const int CardWidth = 420;
    private const int CardPadX = 34;
    private const int InnerWidth = CardWidth - CardPadX * 2; // 352
    private const int OuterMarginX = 28;
    private const int OuterMarginY = 24;

    // Layout root
    private readonly RoundedCardPanel _card;
    private readonly PictureBox _logoBox;
    private readonly Label _titleLabel;
    private readonly Label _subtitleLabel;

    // Mode tabs
    private readonly RoundedButton _directTabBtn;
    private readonly RoundedButton _relayTabBtn;

    // Direct address
    private readonly Label _directAddrLabel;
    private readonly RoundedInputBox _directAddrInput;

    // Relay inputs
    private readonly Label _relayAddrLabel;
    private readonly RoundedInputBox _relayAddrInput;
    private readonly Label _sessionIdLabel;
    private readonly RoundedInputBox _sessionIdInput;

    // Saved device card (Direct mode, shown when saved devices exist)
    private readonly SavedDeviceCardPanel _savedCard;
    private readonly Label _machineNameLabel;
    private readonly RoundedBadgeLabel _modelBadgeLabel;
    private readonly Panel _savedDivider;
    private readonly PictureBox _userIconBox;
    private readonly ComboBox _accountCombo;
    private readonly RoundedButton _noteBtn;
    private readonly RoundedButton _forgetBtn;
    private readonly TextBox _noteEditBox;
    private readonly RoundedButton _noteDoneBtn;

    // Auth tabs (Direct mode)
    private readonly RoundedButton _pinTabBtn;
    private readonly RoundedButton _credsTabBtn;

    // PIN input
    private readonly Label _pinLabel;
    private readonly RoundedInputBox _pinInput;

    // Credentials inputs
    private readonly Label _userLabel;
    private readonly RoundedInputBox _userInput;
    private readonly Label _passLabel;
    private readonly RoundedInputBox _passInput;

    // Remember checkbox
    private readonly CheckBox _rememberCheck;

    // Error banner
    private readonly RoundedErrorBanner _errorBanner;

    // Primary connect button & footer version
    private readonly RoundedButton _connectBtn;
    private readonly Label _versionLabel;

    // State
    private ConnectMode _mode = ConnectMode.Direct;
    private AuthMethod _authMode = AuthMethod.Pin;
    private List<SavedDevice> _devices = new();
    private SavedDevice? _selectedSaved;
    private bool _isEditingNote;
    private bool _suppressComboEvent;
    private bool _suppressAddressEvent;
    private bool _connecting;
    private CancellationTokenSource? _connectCts;
    private Image? _logoImage;

    public ConnectForm()
    {
        Text = $"Remoter v{AppVersion.Current}";
        FormBorderStyle = FormBorderStyle.FixedSingle;
        MaximizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        BackColor = BgOuter;
        ForeColor = TextDark;
        Font = new Font("Microsoft YaHei UI", 9.5f, FontStyle.Regular);
        DoubleBuffered = true;

        string icoPath = Path.Combine(AppContext.BaseDirectory, "Remoter.ico");
        if (File.Exists(icoPath))
        {
            try { Icon = new Icon(icoPath); } catch { }
        }

        _logoImage = LoadLogoImage();

        // ── Main white rounded card ──
        _card = new RoundedCardPanel
        {
            Location = new Point(OuterMarginX, OuterMarginY),
            Width = CardWidth,
            BackColor = BgCard,
            CornerRadius = 16,
            BorderColor = BorderLight,
        };

        // ── Logo + Title + Subtitle ──
        _logoBox = new PictureBox
        {
            Location = new Point(CardPadX, 34),
            Size = new Size(34, 34),
            SizeMode = PictureBoxSizeMode.Zoom,
            BackColor = Color.Transparent,
            Image = _logoImage,
        };

        _titleLabel = new Label
        {
            Text = "Remoter",
            Location = new Point(CardPadX + 44, 30),
            AutoSize = true,
            Font = new Font("Segoe UI", 21f, FontStyle.Bold),
            ForeColor = TextDark,
            BackColor = Color.Transparent,
        };

        _subtitleLabel = new Label
        {
            Text = "远程控制 · 超清 2K · 60fps",
            Location = new Point(CardPadX, 74),
            AutoSize = true,
            Font = new Font("Microsoft YaHei UI", 9.5f),
            ForeColor = TextMuted,
            BackColor = Color.Transparent,
        };

        // ── Mode Tabs ──
        int halfBtnW = (InnerWidth - 10) / 2;
        _directTabBtn = new RoundedButton
        {
            Text = "直连 (局域网)",
            Location = new Point(CardPadX, 106),
            Size = new Size(halfBtnW, 38),
            CornerRadius = 8,
            Font = new Font("Microsoft YaHei UI", 9.5f, FontStyle.Bold),
        };
        _directTabBtn.Click += (_, _) => SwitchMode(ConnectMode.Direct);

        _relayTabBtn = new RoundedButton
        {
            Text = "中继 (公网)",
            Location = new Point(CardPadX + halfBtnW + 10, 106),
            Size = new Size(InnerWidth - halfBtnW - 10, 38),
            CornerRadius = 8,
            Font = new Font("Microsoft YaHei UI", 9.5f, FontStyle.Bold),
        };
        _relayTabBtn.Click += (_, _) => SwitchMode(ConnectMode.Relay);

        // ── Direct Address ──
        _directAddrLabel = CreateFieldLabel("被控端地址");
        _directAddrInput = new RoundedInputBox
        {
            Width = InnerWidth,
            Height = 42,
            Placeholder = "wss://192.168.1.144:7788",
            InputText = "wss://192.168.1.144:7788",
        };
        _directAddrInput.InnerTextBox.TextChanged += OnDirectAddressChanged;

        // ── Relay Address & Session ID ──
        _relayAddrLabel = CreateFieldLabel("中继服务器地址");
        _relayAddrInput = new RoundedInputBox
        {
            Width = InnerWidth,
            Height = 42,
            Placeholder = "wss://your-relay:7789",
            InputText = "wss://your-relay:7789",
        };

        _sessionIdLabel = CreateFieldLabel("会话 ID");
        _sessionIdInput = new RoundedInputBox
        {
            Width = InnerWidth,
            Height = 42,
            Placeholder = "A1B2C3",
        };
        _sessionIdInput.InnerTextBox.CharacterCasing = CharacterCasing.Upper;
        _sessionIdInput.InnerTextBox.MaxLength = 12;

        // ── Saved Device Banner Card (teal border) ──
        _savedCard = new SavedDeviceCardPanel
        {
            Width = InnerWidth,
            BackColor = BgSavedCard,
            BorderColor = Primary,
            CornerRadius = 10,
        };

        _machineNameLabel = new Label
        {
            AutoSize = false,
            AutoEllipsis = true,
            Font = new Font("Segoe UI", 10.5f, FontStyle.Bold),
            ForeColor = TextDark,
            BackColor = Color.Transparent,
            TextAlign = ContentAlignment.MiddleLeft,
        };

        _modelBadgeLabel = new RoundedBadgeLabel
        {
            Font = new Font("Segoe UI", 8.5f),
            ForeColor = TextMuted,
            BadgeFill = BgCard,
            BadgeBorder = BorderSubtle,
            AutoSize = true,
            Padding = new Padding(7, 2, 7, 2),
        };

        _savedDivider = new Panel
        {
            Height = 1,
            BackColor = BorderLight,
        };

        _userIconBox = new PictureBox
        {
            Size = new Size(18, 18),
            SizeMode = PictureBoxSizeMode.CenterImage,
            BackColor = Color.Transparent,
            Image = CreateUserAvatarBitmap(),
        };

        _accountCombo = new ComboBox
        {
            DropDownStyle = ComboBoxStyle.DropDownList,
            FlatStyle = FlatStyle.Flat,
            BackColor = BgSavedCard,
            ForeColor = TextDark,
            Font = new Font("Segoe UI", 9.5f, FontStyle.Bold),
        };
        _accountCombo.SelectedIndexChanged += OnAccountComboChanged;

        _noteBtn = new RoundedButton
        {
            Text = "备注",
            Size = new Size(48, 28),
            CornerRadius = 6,
            Font = new Font("Microsoft YaHei UI", 8.5f),
            FillColor = Color.Transparent,
            HoverFillColor = BgSubtle,
            TextColor = TextMuted,
            BorderColor = BorderSubtle,
            BorderWidth = 1f,
        };
        _noteBtn.Click += (_, _) => BeginEditNote();

        _forgetBtn = new RoundedButton
        {
            Text = "忘记",
            Size = new Size(48, 28),
            CornerRadius = 6,
            Font = new Font("Microsoft YaHei UI", 8.5f),
            FillColor = Color.Transparent,
            HoverFillColor = ErrorBg,
            TextColor = TextMuted,
            BorderColor = BorderSubtle,
            BorderWidth = 1f,
        };
        _forgetBtn.Click += (_, _) => ForgetSelectedDevice();

        _noteEditBox = new TextBox
        {
            BorderStyle = BorderStyle.FixedSingle,
            BackColor = BgCard,
            ForeColor = TextDark,
            Font = new Font("Microsoft YaHei UI", 9.5f),
            PlaceholderText = "输入备注名称…",
            Visible = false,
        };
        _noteEditBox.KeyDown += (_, e) =>
        {
            if (e.KeyCode == Keys.Enter)
            {
                e.SuppressKeyPress = true;
                CommitEditNote();
            }
            else if (e.KeyCode == Keys.Escape)
            {
                e.SuppressKeyPress = true;
                _isEditingNote = false;
                Relayout();
            }
        };

        _noteDoneBtn = new RoundedButton
        {
            Text = "完成",
            Size = new Size(52, 28),
            CornerRadius = 6,
            Font = new Font("Microsoft YaHei UI", 8.5f),
            FillColor = Primary,
            HoverFillColor = PrimaryHover,
            TextColor = Color.White,
            BorderColor = Color.Transparent,
            Visible = false,
        };
        _noteDoneBtn.Click += (_, _) => CommitEditNote();

        _savedCard.Controls.AddRange(new Control[]
        {
            _machineNameLabel, _modelBadgeLabel, _savedDivider,
            _userIconBox, _accountCombo, _noteBtn, _forgetBtn,
            _noteEditBox, _noteDoneBtn,
        });

        // ── Auth Mode Tabs ──
        int authHalfW = (InnerWidth - 8) / 2;
        _pinTabBtn = new RoundedButton
        {
            Text = "PIN 码",
            Size = new Size(authHalfW, 34),
            CornerRadius = 7,
            Font = new Font("Microsoft YaHei UI", 9f),
        };
        _pinTabBtn.Click += (_, _) =>
        {
            _selectedSaved = null;
            _authMode = AuthMethod.Pin;
            SyncAccountComboSelection();
            Relayout();
        };

        _credsTabBtn = new RoundedButton
        {
            Text = "账户密码",
            Size = new Size(InnerWidth - authHalfW - 8, 34),
            CornerRadius = 7,
            Font = new Font("Microsoft YaHei UI", 9f),
        };
        _credsTabBtn.Click += (_, _) =>
        {
            _selectedSaved = null;
            _authMode = AuthMethod.Credentials;
            SyncAccountComboSelection();
            Relayout();
        };

        // ── PIN / Credentials Inputs ──
        _pinLabel = CreateFieldLabel("PIN 码");
        _pinInput = new RoundedInputBox
        {
            Width = InnerWidth,
            Height = 42,
            Placeholder = "输入 6 位 PIN",
        };

        _userLabel = CreateFieldLabel("用户名");
        _userInput = new RoundedInputBox
        {
            Width = InnerWidth,
            Height = 42,
            Placeholder = "Windows / macOS 账户名",
        };

        _passLabel = CreateFieldLabel("密码");
        _passInput = new RoundedInputBox
        {
            Width = InnerWidth,
            Height = 42,
            Placeholder = "账户密码",
            UsePasswordMask = true,
        };

        // ── Remember Device ──
        _rememberCheck = new CheckBox
        {
            Text = "记住登录状态",
            AutoSize = true,
            Checked = true,
            ForeColor = TextMuted,
            BackColor = Color.Transparent,
            Font = new Font("Microsoft YaHei UI", 9f),
            Cursor = Cursors.Hand,
        };

        // ── Error Banner ──
        _errorBanner = new RoundedErrorBanner
        {
            Width = InnerWidth,
            Visible = false,
        };

        // ── Connect Button ──
        _connectBtn = new RoundedButton
        {
            Text = "连接",
            Size = new Size(InnerWidth, 46),
            CornerRadius = 8,
            Font = new Font("Microsoft YaHei UI", 11f, FontStyle.Bold),
            FillColor = Primary,
            HoverFillColor = PrimaryHover,
            TextColor = Color.White,
            BorderColor = Color.Transparent,
        };
        _connectBtn.Click += async (_, _) => await StartConnectAsync();

        // ── Version Footer ──
        _versionLabel = new Label
        {
            Text = $"v{AppVersion.Current}",
            Size = new Size(InnerWidth, 20),
            TextAlign = ContentAlignment.MiddleCenter,
            Font = new Font("Segoe UI", 8.5f),
            ForeColor = Color.FromArgb(148, 163, 184), // #94A3B8
            BackColor = Color.Transparent,
        };

        _card.Controls.AddRange(new Control[]
        {
            _logoBox, _titleLabel, _subtitleLabel,
            _directTabBtn, _relayTabBtn,
            _directAddrLabel, _directAddrInput,
            _relayAddrLabel, _relayAddrInput, _sessionIdLabel, _sessionIdInput,
            _savedCard,
            _pinTabBtn, _credsTabBtn,
            _pinLabel, _pinInput,
            _userLabel, _userInput, _passLabel, _passInput,
            _rememberCheck,
            _errorBanner,
            _connectBtn,
            _versionLabel,
        });

        Controls.Add(_card);

        // Enter key triggers Connect unless editing note
        KeyPreview = true;
        KeyDown += async (_, e) =>
        {
            if (e.KeyCode == Keys.Enter && !_isEditingNote && !_connecting)
            {
                e.SuppressKeyPress = true;
                await StartConnectAsync();
            }
        };

        LoadSavedDevices(selectFirst: true);
        Relayout();
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        DarkTheme.EnableDarkTitleBar(Handle);
    }

    // ── Mode & Device Selection Logic ────────────────────────────────────

    private void SwitchMode(ConnectMode mode)
    {
        if (_mode == mode) return;
        _mode = mode;
        _isEditingNote = false;
        ClearError();
        if (_mode == ConnectMode.Direct)
        {
            LoadSavedDevices(selectFirst: _selectedSaved == null);
        }
        Relayout();
    }

    private void LoadSavedDevices(bool selectFirst)
    {
        _devices = DeviceStore.Shared.GetDevices();
        _suppressComboEvent = true;
        try
        {
            _accountCombo.Items.Clear();
            foreach (var d in _devices)
            {
                _accountCombo.Items.Add(new AccountComboItem(d, FormatAccountLabel(d)));
            }
            _accountCombo.Items.Add(new AccountComboItem(null, "+ 使用其他账户…"));

            if (selectFirst && _devices.Count > 0)
            {
                SelectSavedDevice(_devices[0]);
            }
            else if (_selectedSaved != null)
            {
                var stillThere = _devices.FirstOrDefault(d => d.Id == _selectedSaved.Id);
                if (stillThere != null)
                {
                    SelectSavedDevice(stillThere);
                }
                else
                {
                    _selectedSaved = null;
                    _authMode = AuthMethod.Pin;
                    SyncAccountComboSelection();
                }
            }
            else
            {
                SyncAccountComboSelection();
            }
        }
        finally
        {
            _suppressComboEvent = false;
        }
    }

    private void SelectSavedDevice(SavedDevice dev)
    {
        _selectedSaved = dev;
        _isEditingNote = false;

        _suppressAddressEvent = true;
        try
        {
            _directAddrInput.InputText = BuildAddressString(dev);
        }
        finally
        {
            _suppressAddressEvent = false;
        }

        if (!string.IsNullOrWhiteSpace(dev.Token))
        {
            _authMode = AuthMethod.Token;
        }
        else if (dev.AuthMethod == AuthMethod.Credentials)
        {
            _authMode = AuthMethod.Credentials;
            _userInput.InputText = dev.Username ?? "";
            _passInput.InputText = "";
        }
        else
        {
            _authMode = AuthMethod.Pin;
            _pinInput.InputText = dev.Pin ?? "";
        }

        SyncAccountComboSelection();
    }

    private void SyncAccountComboSelection()
    {
        _suppressComboEvent = true;
        try
        {
            if (_selectedSaved != null)
            {
                int idx = _devices.FindIndex(d => d.Id == _selectedSaved.Id);
                if (idx >= 0 && idx < _accountCombo.Items.Count)
                {
                    _accountCombo.SelectedIndex = idx;
                    return;
                }
            }
            if (_accountCombo.Items.Count > 0)
            {
                _accountCombo.SelectedIndex = _accountCombo.Items.Count - 1;
            }
        }
        finally
        {
            _suppressComboEvent = false;
        }
    }

    private void OnAccountComboChanged(object? sender, EventArgs e)
    {
        if (_suppressComboEvent) return;
        if (_accountCombo.SelectedItem is not AccountComboItem item) return;

        ClearError();
        if (item.Device == null)
        {
            _selectedSaved = null;
            _authMode = AuthMethod.Pin;
            _isEditingNote = false;
        }
        else
        {
            SelectSavedDevice(item.Device);
        }
        Relayout();
    }

    private void OnDirectAddressChanged(object? sender, EventArgs e)
    {
        if (_suppressAddressEvent || _mode != ConnectMode.Direct) return;
        if (TryParseDirectAddress(_directAddrInput.InputText, out string host, out int port, out _))
        {
            var matched = _devices.FirstOrDefault(d =>
                string.Equals(d.Host, host, StringComparison.OrdinalIgnoreCase) && d.Port == port);
            if (matched != null && matched.Id != _selectedSaved?.Id)
            {
                _selectedSaved = matched;
                if (!string.IsNullOrWhiteSpace(matched.Token))
                    _authMode = AuthMethod.Token;
                SyncAccountComboSelection();
                Relayout();
            }
            else if (matched == null && _selectedSaved != null)
            {
                _selectedSaved = null;
                if (_authMode == AuthMethod.Token) _authMode = AuthMethod.Pin;
                SyncAccountComboSelection();
                Relayout();
            }
        }
    }

    private void BeginEditNote()
    {
        if (_selectedSaved == null) return;
        _isEditingNote = true;
        _noteEditBox.Text = _selectedSaved.Name;
        Relayout();
        _noteEditBox.Focus();
        _noteEditBox.SelectAll();
    }

    private void CommitEditNote()
    {
        if (_selectedSaved != null)
        {
            _selectedSaved.Name = _noteEditBox.Text.Trim();
            DeviceStore.Shared.UpsertDevice(_selectedSaved);
        }
        _isEditingNote = false;
        LoadSavedDevices(selectFirst: false);
        Relayout();
    }

    private void ForgetSelectedDevice()
    {
        if (_selectedSaved == null) return;
        string removedId = _selectedSaved.Id;
        DeviceStore.Shared.RemoveDevice(removedId);
        _selectedSaved = null;
        _isEditingNote = false;
        LoadSavedDevices(selectFirst: true);
        if (_devices.Count == 0)
        {
            _authMode = AuthMethod.Pin;
        }
        Relayout();
    }

    // ── Dynamic Vertical Layout ──────────────────────────────────────────

    private void Relayout()
    {
        SuspendLayout();
        _card.SuspendLayout();

        // Style mode tabs
        StyleModeTab(_directTabBtn, active: _mode == ConnectMode.Direct);
        StyleModeTab(_relayTabBtn, active: _mode == ConnectMode.Relay);

        // Style auth tabs (when Token mode with saved device, both appear unselected just like Web)
        StyleAuthTab(_pinTabBtn, active: _authMode == AuthMethod.Pin);
        StyleAuthTab(_credsTabBtn, active: _authMode == AuthMethod.Credentials);

        int y = 160;

        bool isDirect = _mode == ConnectMode.Direct;
        _directAddrLabel.Visible = isDirect;
        _directAddrInput.Visible = isDirect;
        _relayAddrLabel.Visible = !isDirect;
        _relayAddrInput.Visible = !isDirect;
        _sessionIdLabel.Visible = !isDirect;
        _sessionIdInput.Visible = !isDirect;

        if (isDirect)
        {
            _directAddrLabel.Location = new Point(CardPadX, y);
            y += 22;
            _directAddrInput.Location = new Point(CardPadX, y);
            y += _directAddrInput.Height + 14;
        }
        else
        {
            _relayAddrLabel.Location = new Point(CardPadX, y);
            y += 22;
            _relayAddrInput.Location = new Point(CardPadX, y);
            y += _relayAddrInput.Height + 12;

            _sessionIdLabel.Location = new Point(CardPadX, y);
            y += 22;
            _sessionIdInput.Location = new Point(CardPadX, y);
            y += _sessionIdInput.Height + 12;
        }

        // Saved device banner card (Direct mode & has saved devices)
        bool showSavedCard = isDirect && _devices.Count > 0;
        _savedCard.Visible = showSavedCard;
        if (showSavedCard)
        {
            LayoutSavedDeviceCard();
            _savedCard.Location = new Point(CardPadX, y);
            y += _savedCard.Height + 14;
        }

        // Auth mode tabs (Direct mode)
        _pinTabBtn.Visible = isDirect;
        _credsTabBtn.Visible = isDirect;
        if (isDirect)
        {
            int authHalfW = (InnerWidth - 8) / 2;
            _pinTabBtn.Location = new Point(CardPadX, y);
            _credsTabBtn.Location = new Point(CardPadX + authHalfW + 8, y);
            y += _pinTabBtn.Height + 14;
        }

        // Auth inputs
        bool showPin = !isDirect || _authMode == AuthMethod.Pin;
        bool showCreds = isDirect && _authMode == AuthMethod.Credentials;

        _pinLabel.Visible = showPin;
        _pinInput.Visible = showPin;
        if (showPin)
        {
            _pinLabel.Location = new Point(CardPadX, y);
            y += 22;
            _pinInput.Location = new Point(CardPadX, y);
            y += _pinInput.Height + 12;
        }

        _userLabel.Visible = showCreds;
        _userInput.Visible = showCreds;
        _passLabel.Visible = showCreds;
        _passInput.Visible = showCreds;
        if (showCreds)
        {
            _userLabel.Location = new Point(CardPadX, y);
            y += 22;
            _userInput.Location = new Point(CardPadX, y);
            y += _userInput.Height + 12;

            _passLabel.Location = new Point(CardPadX, y);
            y += 22;
            _passInput.Location = new Point(CardPadX, y);
            y += _passInput.Height + 12;
        }

        // Remember device checkbox (Direct + non-Token)
        bool showRemember = isDirect && _authMode != AuthMethod.Token;
        _rememberCheck.Visible = showRemember;
        if (showRemember)
        {
            _rememberCheck.Location = new Point(CardPadX, y);
            y += 28;
        }

        // Error banner
        if (_errorBanner.Visible)
        {
            _errorBanner.Location = new Point(CardPadX, y);
            y += _errorBanner.Height + 12;
        }

        // Primary Connect button
        _connectBtn.Location = new Point(CardPadX, y + 2);
        y += _connectBtn.Height + 14;

        // Footer version
        _versionLabel.Location = new Point(CardPadX, y);
        y += 28;

        _card.Height = y + 8;
        ClientSize = new Size(CardWidth + OuterMarginX * 2, _card.Height + OuterMarginY * 2);

        _card.ResumeLayout(true);
        ResumeLayout(true);
        _card.Invalidate();
    }

    private void LayoutSavedDeviceCard()
    {
        const int padX = 12;
        int cy = 10;

        bool hasMachineHeader = _selectedSaved != null &&
            (!string.IsNullOrWhiteSpace(_selectedSaved.ComputerName) ||
             !string.IsNullOrWhiteSpace(_selectedSaved.ModelId));

        _machineNameLabel.Visible = hasMachineHeader;
        _modelBadgeLabel.Visible = hasMachineHeader && !string.IsNullOrWhiteSpace(_selectedSaved?.ModelId);
        _savedDivider.Visible = hasMachineHeader;

        if (hasMachineHeader && _selectedSaved != null)
        {
            _machineNameLabel.Text = !string.IsNullOrWhiteSpace(_selectedSaved.ComputerName)
                ? _selectedSaved.ComputerName
                : _selectedSaved.DisplayName;

            int badgeW = 0;
            if (_modelBadgeLabel.Visible)
            {
                _modelBadgeLabel.Text = _selectedSaved.ModelId!;
                var pref = _modelBadgeLabel.GetPreferredSize(Size.Empty);
                _modelBadgeLabel.Size = pref;
                badgeW = pref.Width + 8;
                _modelBadgeLabel.Location = new Point(InnerWidth - padX - pref.Width, cy + 1);
            }

            _machineNameLabel.Location = new Point(padX, cy);
            _machineNameLabel.Size = new Size(InnerWidth - padX * 2 - badgeW, 24);
            cy += 30;

            _savedDivider.Location = new Point(padX, cy);
            _savedDivider.Width = InnerWidth - padX * 2;
            cy += 10;
        }

        // Account row or inline note editor
        _userIconBox.Visible = !_isEditingNote;
        _accountCombo.Visible = !_isEditingNote;
        _noteBtn.Visible = !_isEditingNote;
        _forgetBtn.Visible = !_isEditingNote;
        _noteEditBox.Visible = _isEditingNote;
        _noteDoneBtn.Visible = _isEditingNote;

        if (_isEditingNote)
        {
            _noteDoneBtn.Location = new Point(InnerWidth - padX - _noteDoneBtn.Width, cy);
            _noteEditBox.Location = new Point(padX, cy + 2);
            _noteEditBox.Width = InnerWidth - padX * 2 - _noteDoneBtn.Width - 8;
        }
        else
        {
            _userIconBox.Location = new Point(padX, cy + 5);
            _forgetBtn.Location = new Point(InnerWidth - padX - _forgetBtn.Width, cy);
            _noteBtn.Location = new Point(_forgetBtn.Left - 6 - _noteBtn.Width, cy);
            _noteBtn.Enabled = _selectedSaved != null;
            _forgetBtn.Enabled = _selectedSaved != null;

            int comboLeft = padX + 24;
            _accountCombo.Location = new Point(comboLeft, cy + 2);
            _accountCombo.Width = Math.Max(80, _noteBtn.Left - comboLeft - 8);
        }

        cy += 38;
        _savedCard.Height = cy;
    }

    // ── Connection Execution ─────────────────────────────────────────────

    private async Task StartConnectAsync()
    {
        if (_connecting) return;
        ClearError();

        ConnectParams connectParams;
        string displayTarget;
        SavedDevice? existing = null;

        if (_mode == ConnectMode.Direct)
        {
            string rawAddr = _directAddrInput.InputText.Trim();
            if (!TryParseDirectAddress(rawAddr, out string host, out int port, out bool useTls))
            {
                ShowError("请输入有效的被控端地址，例如 wss://192.168.1.144:7788");
                _directAddrInput.FocusInput();
                return;
            }

            existing = _selectedSaved ?? DeviceStore.Shared.FindByHost(host, port);

            AuthMethod method;
            string token = "";
            string username = "";
            string password = "";
            string pin = "";

            if (_authMode == AuthMethod.Token && existing != null && !string.IsNullOrWhiteSpace(existing.Token))
            {
                method = AuthMethod.Token;
                token = existing.Token;
                username = existing.Username ?? "";
            }
            else if (_authMode == AuthMethod.Credentials)
            {
                username = _userInput.InputText.Trim();
                password = _passInput.InputText;
                if (string.IsNullOrWhiteSpace(username))
                {
                    ShowError("请输入账户用户名");
                    _userInput.FocusInput();
                    return;
                }
                if (string.IsNullOrEmpty(password))
                {
                    ShowError("请输入账户密码");
                    _passInput.FocusInput();
                    return;
                }
                method = AuthMethod.Credentials;
            }
            else
            {
                pin = _pinInput.InputText.Trim();
                method = AuthMethod.Pin;
            }

            connectParams = new ConnectParams
            {
                Mode = ConnectMode.Direct,
                Host = host,
                Port = port,
                UseTls = useTls,
                DirectUrl = $"{(useTls ? "wss" : "ws")}://{host}:{port}",
                AuthMethod = method,
                Pin = pin,
                Username = username,
                Password = password,
                Token = token,
                Label = existing?.Name,
                RememberDevice = method == AuthMethod.Token || _rememberCheck.Checked,
            };
            displayTarget = $"{host}:{port}";
        }
        else
        {
            string relayUrl = _relayAddrInput.InputText.Trim();
            string sessionId = _sessionIdInput.InputText.Trim().ToUpperInvariant();
            string pin = _pinInput.InputText.Trim();

            if (string.IsNullOrWhiteSpace(relayUrl))
            {
                ShowError("请输入中继服务器地址");
                _relayAddrInput.FocusInput();
                return;
            }
            if (string.IsNullOrWhiteSpace(sessionId))
            {
                ShowError("请输入 6 位会话 ID");
                _sessionIdInput.FocusInput();
                return;
            }

            connectParams = new ConnectParams
            {
                Mode = ConnectMode.Relay,
                RelayUrl = relayUrl,
                SessionId = sessionId,
                Pin = pin,
                AuthMethod = AuthMethod.Pin,
                RememberDevice = false,
            };
            displayTarget = $"Relay ({sessionId})";
        }

        SetConnectingState(true);
        _connectCts = new CancellationTokenSource(TimeSpan.FromSeconds(15));

        var settings = DeviceStore.Shared.GetSettings();
        var conn = new RemoterConnection(settings.DownloadDirectory);
        var tcs = new TaskCompletionSource<StreamInfo>(TaskCreationOptions.RunContinuationsAsynchronously);

        string? issuedToken = null;
        string? issuedUsername = null;

        void OnAuthSucceeded(string user, string tok)
        {
            issuedUsername = user;
            issuedToken = tok;
        }
        void OnStreamStarted(StreamInfo info) => tcs.TrySetResult(info);
        void OnError(string err) => tcs.TrySetException(new InvalidOperationException(err));
        void OnDisconnected(string reason) => tcs.TrySetException(new InvalidOperationException(string.IsNullOrWhiteSpace(reason) ? "连接已断开" : reason));

        conn.AuthSucceeded += OnAuthSucceeded;
        conn.StreamStarted += OnStreamStarted;
        conn.ErrorOccurred += OnError;
        conn.Disconnected += OnDisconnected;

        try
        {
            using var reg = _connectCts.Token.Register(() =>
                tcs.TrySetException(new TimeoutException($"连接 {displayTarget} 超时，请检查地址、端口或防火墙")));

            await conn.ConnectAsync(connectParams, CancellationToken.None);
            StreamInfo streamInfo = await tcs.Task;

            conn.AuthSucceeded -= OnAuthSucceeded;
            conn.StreamStarted -= OnStreamStarted;
            conn.ErrorOccurred -= OnError;
            conn.Disconnected -= OnDisconnected;

            if (connectParams.Mode == ConnectMode.Direct && connectParams.RememberDevice)
            {
                var saved = existing ?? new SavedDevice
                {
                    Id = Guid.NewGuid().ToString("N"),
                    Name = !string.IsNullOrWhiteSpace(conn.ServerComputerName) ? conn.ServerComputerName : connectParams.Host,
                    Host = connectParams.Host,
                    Port = connectParams.Port,
                };
                saved.Host = connectParams.Host;
                saved.Port = connectParams.Port;
                saved.UseTls = connectParams.UseTls;
                saved.AuthMethod = !string.IsNullOrWhiteSpace(issuedToken) ? AuthMethod.Token : connectParams.AuthMethod;
                if (connectParams.AuthMethod == AuthMethod.Pin) saved.Pin = connectParams.Pin;
                if (!string.IsNullOrWhiteSpace(issuedUsername)) saved.Username = issuedUsername;
                else if (!string.IsNullOrWhiteSpace(connectParams.Username)) saved.Username = connectParams.Username;
                if (!string.IsNullOrWhiteSpace(issuedToken)) saved.Token = issuedToken;
                if (!string.IsNullOrWhiteSpace(conn.ServerComputerName)) saved.ComputerName = conn.ServerComputerName;
                if (!string.IsNullOrWhiteSpace(conn.ServerModelId)) saved.ModelId = conn.ServerModelId;
                if (!string.IsNullOrWhiteSpace(conn.ServerOs)) saved.ServerOs = conn.ServerOs;
                saved.LastConnectedUtc = DateTime.UtcNow;
                DeviceStore.Shared.UpsertDevice(saved);
                _selectedSaved = saved;
            }

            SetConnectingState(false);

            DesktopForm? desktopForm = null;
            try
            {
                desktopForm = new DesktopForm(conn, connectParams, streamInfo);
                desktopForm.FormClosed += (_, _) =>
                {
                    if (!IsDisposed)
                    {
                        LoadSavedDevices(selectFirst: false);
                        Relayout();
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
            conn.AuthSucceeded -= OnAuthSucceeded;
            conn.StreamStarted -= OnStreamStarted;
            conn.ErrorOccurred -= OnError;
            conn.Disconnected -= OnDisconnected;
            conn.Dispose();
            TryWriteErrorLog(ex);
            SetConnectingState(false);
            ShowError($"连接失败: {ex.Message}");
        }
        finally
        {
            _connectCts?.Dispose();
            _connectCts = null;
        }
    }

    private void SetConnectingState(bool connecting)
    {
        _connecting = connecting;
        _connectBtn.Enabled = !connecting;
        _connectBtn.Text = connecting ? "连接中…" : "连接";
        _directTabBtn.Enabled = !connecting;
        _relayTabBtn.Enabled = !connecting;
        _directAddrInput.Enabled = !connecting;
        _relayAddrInput.Enabled = !connecting;
        _sessionIdInput.Enabled = !connecting;
        _pinTabBtn.Enabled = !connecting;
        _credsTabBtn.Enabled = !connecting;
        _pinInput.Enabled = !connecting;
        _userInput.Enabled = !connecting;
        _passInput.Enabled = !connecting;
        _accountCombo.Enabled = !connecting;
        _noteBtn.Enabled = !connecting && _selectedSaved != null;
        _forgetBtn.Enabled = !connecting && _selectedSaved != null;
        _rememberCheck.Enabled = !connecting;
    }

    private void ShowError(string message)
    {
        _errorBanner.SetMessage(message);
        _errorBanner.Visible = true;
        Relayout();
    }

    private void ClearError()
    {
        if (!_errorBanner.Visible) return;
        _errorBanner.Visible = false;
        Relayout();
    }

    // ── Helpers ──────────────────────────────────────────────────────────

    private static void StyleModeTab(RoundedButton btn, bool active)
    {
        if (active)
        {
            btn.FillColor = Primary;
            btn.HoverFillColor = PrimaryHover;
            btn.TextColor = Color.White;
            btn.BorderColor = Color.Transparent;
            btn.BorderWidth = 0f;
        }
        else
        {
            btn.FillColor = BgSubtle;
            btn.HoverFillColor = Color.FromArgb(226, 232, 240);
            btn.TextColor = TextMuted;
            btn.BorderColor = Color.Transparent;
            btn.BorderWidth = 0f;
        }
        btn.Invalidate();
    }

    private static void StyleAuthTab(RoundedButton btn, bool active)
    {
        if (active)
        {
            btn.FillColor = BgCard;
            btn.HoverFillColor = BgSavedCard;
            btn.TextColor = TextDark;
            btn.BorderColor = Primary;
            btn.BorderWidth = 1.2f;
        }
        else
        {
            btn.FillColor = BgSubtle;
            btn.HoverFillColor = Color.FromArgb(226, 232, 240);
            btn.TextColor = TextMuted;
            btn.BorderColor = Color.Transparent;
            btn.BorderWidth = 0f;
        }
        btn.Invalidate();
    }

    private static Label CreateFieldLabel(string text) => new()
    {
        Text = text,
        AutoSize = true,
        Font = new Font("Microsoft YaHei UI", 9f),
        ForeColor = TextMuted,
        BackColor = Color.Transparent,
    };

    private static string BuildAddressString(SavedDevice dev)
    {
        string scheme = dev.UseTls ? "wss" : "ws";
        return $"{scheme}://{dev.Host}:{dev.Port}";
    }

    private static string FormatAccountLabel(SavedDevice dev)
    {
        string label = !string.IsNullOrWhiteSpace(dev.Name)
            ? dev.Name
            : (!string.IsNullOrWhiteSpace(dev.Username) && dev.Username != "__pin__"
                ? dev.Username!
                : "PIN 码");
        return $"{label} ({dev.Host})";
    }

    private static bool TryParseDirectAddress(string input, out string host, out int port, out bool useTls)
    {
        host = "";
        port = 7788;
        useTls = true;

        string s = input.Trim();
        if (string.IsNullOrWhiteSpace(s)) return false;

        if (!s.Contains("://", StringComparison.Ordinal))
        {
            s = "wss://" + s;
        }
        if (!Uri.TryCreate(s, UriKind.Absolute, out var uri)) return false;
        if (string.IsNullOrWhiteSpace(uri.Host)) return false;

        useTls = !string.Equals(uri.Scheme, "ws", StringComparison.OrdinalIgnoreCase) &&
                 !string.Equals(uri.Scheme, "http", StringComparison.OrdinalIgnoreCase);
        host = uri.Host;
        port = uri.IsDefaultPort ? 7788 : uri.Port;
        return port is >= 1 and <= 65535;
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

    private static Bitmap CreateUserAvatarBitmap()
    {
        var bmp = new Bitmap(18, 18);
        using var g = Graphics.FromImage(bmp);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using var brush = new SolidBrush(Color.FromArgb(91, 63, 140)); // soft purple silhouette matching screenshot
        g.FillEllipse(brush, 5, 2, 8, 8);
        g.FillPie(brush, 2, 10, 14, 12, 180, 180);
        return bmp;
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

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _logoImage?.Dispose();
            _logoImage = null;
        }
        base.Dispose(disposing);
    }

    // ── Nested Lightweight Styled Controls ───────────────────────────────

    private sealed class AccountComboItem
    {
        public SavedDevice? Device { get; }
        public string Label { get; }

        public AccountComboItem(SavedDevice? device, string label)
        {
            Device = device;
            Label = label;
        }

        public override string ToString() => Label;
    }

    private sealed class RoundedCardPanel : Panel
    {
        [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
        public int CornerRadius { get; set; } = 16;
        [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
        public Color BorderColor { get; set; } = BorderLight;

        public RoundedCardPanel()
        {
            DoubleBuffered = true;
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            var rect = new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f);
            using var path = CreateRoundRectPath(rect, CornerRadius);
            using var fill = new SolidBrush(BackColor);
            using var pen = new Pen(BorderColor, 1f);
            e.Graphics.Clear(Parent?.BackColor ?? BgOuter);
            e.Graphics.FillPath(fill, path);
            e.Graphics.DrawPath(pen, path);
        }
    }

    private sealed class SavedDeviceCardPanel : Panel
    {
        [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
        public int CornerRadius { get; set; } = 10;
        [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
        public Color BorderColor { get; set; } = Primary;

        public SavedDeviceCardPanel()
        {
            DoubleBuffered = true;
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            var rect = new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f);
            using var path = CreateRoundRectPath(rect, CornerRadius);
            using var fill = new SolidBrush(BackColor);
            using var pen = new Pen(BorderColor, 1f);
            e.Graphics.Clear(Parent?.BackColor ?? BgCard);
            e.Graphics.FillPath(fill, path);
            e.Graphics.DrawPath(pen, path);
        }
    }

    private sealed class RoundedBadgeLabel : Label
    {
        [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
        public Color BadgeFill { get; set; } = Color.White;
        [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
        public Color BadgeBorder { get; set; } = BorderSubtle;

        public RoundedBadgeLabel()
        {
            DoubleBuffered = true;
            BackColor = Color.Transparent;
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            var rect = new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f);
            using var path = CreateRoundRectPath(rect, 5f);
            using var fill = new SolidBrush(BadgeFill);
            using var pen = new Pen(BadgeBorder, 1f);
            e.Graphics.FillPath(fill, path);
            e.Graphics.DrawPath(pen, path);
            TextRenderer.DrawText(e.Graphics, Text, Font, ClientRectangle, ForeColor,
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine);
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
        public bool UsePasswordMask
        {
            get => InnerTextBox.UseSystemPasswordChar;
            set => InnerTextBox.UseSystemPasswordChar = value;
        }

        public RoundedInputBox()
        {
            DoubleBuffered = true;
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
            BackColor = BgSubtle;
            Cursor = Cursors.IBeam;

            InnerTextBox = new TextBox
            {
                BorderStyle = BorderStyle.None,
                BackColor = BgSubtle,
                ForeColor = TextDark,
                Font = new Font("Segoe UI", 10.5f),
            };
            InnerTextBox.GotFocus += (_, _) => { _focused = true; Invalidate(); };
            InnerTextBox.LostFocus += (_, _) => { _focused = false; Invalidate(); };

            Controls.Add(InnerTextBox);
            Click += (_, _) => InnerTextBox.Focus();
        }

        public void FocusInput() => InnerTextBox.Focus();

        protected override void OnResize(EventArgs eventargs)
        {
            base.OnResize(eventargs);
            const int padX = 12;
            InnerTextBox.Width = Math.Max(40, Width - padX * 2);
            InnerTextBox.Location = new Point(padX, Math.Max(4, (Height - InnerTextBox.Height) / 2));
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            var rect = new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f);
            using var path = CreateRoundRectPath(rect, 8f);
            using var fill = new SolidBrush(BackColor);
            using var pen = new Pen(_focused ? Primary : BorderSubtle, _focused ? 1.5f : 1f);
            e.Graphics.Clear(Parent?.BackColor ?? BgCard);
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

    private sealed class RoundedErrorBanner : Panel
    {
        private readonly Label _label;

        public RoundedErrorBanner()
        {
            DoubleBuffered = true;
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
            BackColor = ErrorBg;
            _label = new Label
            {
                Location = new Point(12, 8),
                AutoSize = false,
                ForeColor = ErrorText,
                BackColor = Color.Transparent,
                Font = new Font("Microsoft YaHei UI", 8.8f),
            };
            Controls.Add(_label);
        }

        public void SetMessage(string text)
        {
            _label.Text = text;
            int innerW = Math.Max(60, Width - 24);
            var measured = TextRenderer.MeasureText(text, _label.Font, new Size(innerW, 400),
                TextFormatFlags.WordBreak | TextFormatFlags.TextBoxControl);
            _label.Size = new Size(innerW, Math.Max(20, measured.Height));
            Height = _label.Height + 16;
            Invalidate();
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            e.Graphics.Clear(Parent?.BackColor ?? BgCard);
            var rect = new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f);
            using var path = CreateRoundRectPath(rect, 6f);
            using var fill = new SolidBrush(ErrorBg);
            using var pen = new Pen(ErrorBorder, 1f);
            e.Graphics.FillPath(fill, path);
            e.Graphics.DrawPath(pen, path);
        }
    }
}
