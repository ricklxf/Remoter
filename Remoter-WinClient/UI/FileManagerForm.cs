using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace RemoterWinClient.UI;

/// <summary>
/// Dual-pane file manager (Left = Local Windows filesystem, Right = Remote host filesystem)
/// supporting recursive folder upload/download and resumable `.remoter.part` transfers.
/// </summary>
public sealed class FileManagerForm : Form
{
    private readonly RemoterConnection _conn;

    // Left (Local) controls
    private readonly TextBox _localPathBox;
    private readonly Button _localUpBtn;
    private readonly Button _localRefreshBtn;
    private readonly Button _uploadBtn;
    private readonly ListView _localList;

    // Right (Remote) controls
    private readonly TextBox _remotePathBox;
    private readonly Button _remoteUpBtn;
    private readonly Button _remoteRefreshBtn;
    private readonly Button _downloadBtn;
    private readonly ListView _remoteList;

    // Bottom transfer progress bar
    private readonly ProgressBar _progressBar;
    private readonly Label _statusLabel;
    private readonly Button _cancelBtn;

    private string _localPath;
    private string _remotePath = "~";
    private bool _remoteUsesBackslash;
    private CancellationTokenSource? _transferCts;
    private bool _busy;

    public FileManagerForm(RemoterConnection conn, string? initialLocalDir = null)
    {
        _conn = conn ?? throw new ArgumentNullException(nameof(conn));
        _localPath = !string.IsNullOrWhiteSpace(initialLocalDir) && Directory.Exists(initialLocalDir)
            ? initialLocalDir
            : Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        _remoteUsesBackslash = _conn.ServerOs.Contains("win", StringComparison.OrdinalIgnoreCase);

        Text = "Remoter 文件传输管理器 (双栏)";
        Size = new Size(1060, 680);
        MinimumSize = new Size(800, 480);
        StartPosition = FormStartPosition.CenterParent;
        BackColor = DarkTheme.WindowBg;
        ForeColor = DarkTheme.TextPrimary;
        Font = new Font("Segoe UI", 9.0f, FontStyle.Regular);

        // ── Bottom status / progress bar ──
        var bottomPanel = new Panel
        {
            Dock = DockStyle.Bottom,
            Height = 56,
            Padding = new Padding(12, 8, 12, 8),
            BackColor = DarkTheme.SurfaceBg,
        };
        bottomPanel.Paint += (_, e) =>
        {
            using var pen = new Pen(DarkTheme.BorderColor, 1);
            e.Graphics.DrawLine(pen, 0, 0, bottomPanel.Width, 0);
        };

        _cancelBtn = new Button
        {
            Text = "取消",
            Width = 64,
            Height = 28,
            Dock = DockStyle.Right,
            Enabled = false,
            Margin = new Padding(8, 0, 0, 0),
        };
        DarkTheme.StyleButton(_cancelBtn, danger: true);
        _cancelBtn.Click += (_, _) => _transferCts?.Cancel();

        var progressStack = new Panel
        {
            Dock = DockStyle.Fill,
            Padding = new Padding(0, 0, 10, 0),
            BackColor = DarkTheme.SurfaceBg,
        };

        _statusLabel = new Label
        {
            Text = "就绪 — 支持单文件、多选及整个文件夹递归传输与断点续传",
            Dock = DockStyle.Top,
            Height = 20,
            ForeColor = DarkTheme.TextMuted,
            AutoEllipsis = true,
        };

        _progressBar = new ProgressBar
        {
            Dock = DockStyle.Bottom,
            Height = 14,
            Minimum = 0,
            Maximum = 100,
            Value = 0,
            Style = ProgressBarStyle.Continuous,
        };

        progressStack.Controls.Add(_statusLabel);
        progressStack.Controls.Add(_progressBar);
        bottomPanel.Controls.Add(progressStack);
        bottomPanel.Controls.Add(_cancelBtn);

        // ── Dual-pane SplitContainer ──
        var split = new SplitContainer
        {
            Dock = DockStyle.Fill,
            Orientation = Orientation.Vertical,
            SplitterWidth = 6,
            BackColor = DarkTheme.BorderColor,
            Panel1MinSize = 320,
            Panel2MinSize = 320,
        };

        // Left pane (Local)
        (_localPathBox, _localUpBtn, _localRefreshBtn, _uploadBtn, _localList) = BuildPane(
            split.Panel1,
            title: "本地文件 (Local)",
            actionText: "上传 →",
            onUp: NavigateLocalUp,
            onRefresh: () => LoadLocalDirectory(_localPath),
            onAction: () => _ = UploadSelectedAsync(),
            onPathEnter: p => LoadLocalDirectory(p),
            onItemDoubleClick: OnLocalItemDoubleClick);

        // Right pane (Remote)
        (_remotePathBox, _remoteUpBtn, _remoteRefreshBtn, _downloadBtn, _remoteList) = BuildPane(
            split.Panel2,
            title: "远端文件 (Remote)",
            actionText: "← 下载",
            onUp: NavigateRemoteUp,
            onRefresh: () => RequestRemoteDirectory(_remotePath),
            onAction: () => _ = DownloadSelectedAsync(),
            onPathEnter: p => RequestRemoteDirectory(p),
            onItemDoubleClick: OnRemoteItemDoubleClick);

        Controls.Add(split);
        Controls.Add(bottomPanel);

        Shown += (_, _) =>
        {
            try { split.SplitterDistance = split.Width / 2; } catch { }
            LoadLocalDirectory(_localPath);
            RequestRemoteDirectory(_remotePath);
        };

        _conn.DirListingReceived += OnRemoteDirListingReceived;
        _conn.FileTransferProgress += OnFileTransferProgress;
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        DarkTheme.EnableDarkTitleBar(Handle);
    }

    protected override void OnFormClosed(FormClosedEventArgs e)
    {
        _transferCts?.Cancel();
        _transferCts?.Dispose();
        _transferCts = null;
        _conn.DirListingReceived -= OnRemoteDirListingReceived;
        _conn.FileTransferProgress -= OnFileTransferProgress;
        base.OnFormClosed(e);
    }

    private static (TextBox pathBox, Button upBtn, Button refreshBtn, Button actionBtn, ListView list) BuildPane(
        SplitterPanel container,
        string title,
        string actionText,
        Action onUp,
        Action onRefresh,
        Action onAction,
        Action<string> onPathEnter,
        Action<ListViewItem> onItemDoubleClick)
    {
        container.BackColor = DarkTheme.WindowBg;
        container.Padding = new Padding(8);

        var headerPanel = new Panel
        {
            Dock = DockStyle.Top,
            Height = 66,
            BackColor = DarkTheme.WindowBg,
        };

        var titleLabel = new Label
        {
            Text = title,
            Dock = DockStyle.Top,
            Height = 24,
            Font = new Font("Segoe UI", 9.5f, FontStyle.Bold),
            ForeColor = DarkTheme.TextPrimary,
        };

        var navPanel = new Panel
        {
            Dock = DockStyle.Bottom,
            Height = 34,
            BackColor = DarkTheme.WindowBg,
        };

        var actionBtn = new Button
        {
            Text = actionText,
            Width = 78,
            Height = 28,
            Dock = DockStyle.Right,
        };
        DarkTheme.StyleButton(actionBtn, primary: true);
        actionBtn.Click += (_, _) => onAction();

        var refreshBtn = new Button
        {
            Text = "刷新",
            Width = 52,
            Height = 28,
            Dock = DockStyle.Right,
        };
        DarkTheme.StyleButton(refreshBtn);
        refreshBtn.Click += (_, _) => onRefresh();

        var upBtn = new Button
        {
            Text = "上级",
            Width = 52,
            Height = 28,
            Dock = DockStyle.Left,
        };
        DarkTheme.StyleButton(upBtn);
        upBtn.Click += (_, _) => onUp();

        var pathBox = new TextBox
        {
            Dock = DockStyle.Fill,
            BackColor = DarkTheme.InputBg,
            ForeColor = DarkTheme.TextPrimary,
            BorderStyle = BorderStyle.FixedSingle,
            Font = new Font("Segoe UI", 9.0f),
        };
        pathBox.KeyDown += (_, e) =>
        {
            if (e.KeyCode == Keys.Enter)
            {
                e.SuppressKeyPress = true;
                onPathEnter(pathBox.Text.Trim());
            }
        };

        var pathWrap = new Panel
        {
            Dock = DockStyle.Fill,
            Padding = new Padding(6, 2, 6, 2),
            BackColor = DarkTheme.WindowBg,
        };
        pathWrap.Controls.Add(pathBox);

        navPanel.Controls.Add(pathWrap);
        navPanel.Controls.Add(upBtn);
        navPanel.Controls.Add(refreshBtn);
        navPanel.Controls.Add(actionBtn);

        headerPanel.Controls.Add(titleLabel);
        headerPanel.Controls.Add(navPanel);

        var list = new ListView
        {
            Dock = DockStyle.Fill,
            View = View.Details,
            FullRowSelect = true,
            MultiSelect = true,
            GridLines = false,
            HideSelection = false,
            BackColor = DarkTheme.SurfaceBg,
            ForeColor = DarkTheme.TextPrimary,
            BorderStyle = BorderStyle.FixedSingle,
        };
        list.Columns.Add("名称", 250);
        list.Columns.Add("大小", 86, HorizontalAlignment.Right);
        list.Columns.Add("修改时间", 136);
        list.ItemActivate += (_, _) =>
        {
            if (list.SelectedItems.Count == 1)
                onItemDoubleClick(list.SelectedItems[0]);
        };

        container.Controls.Add(list);
        container.Controls.Add(headerPanel);

        return (pathBox, upBtn, refreshBtn, actionBtn, list);
    }

    // ── Local Filesystem Navigation ──────────────────────────────────────

    private void LoadLocalDirectory(string path)
    {
        _localList.BeginUpdate();
        try
        {
            _localList.Items.Clear();

            if (string.IsNullOrWhiteSpace(path))
            {
                _localPath = "";
                _localPathBox.Text = "";
                foreach (var drive in DriveInfo.GetDrives())
                {
                    if (!drive.IsReady) continue;
                    var item = new ListViewItem($"💾 {drive.Name}")
                    {
                        Tag = new LocalEntryTag(drive.RootDirectory.FullName, IsDir: true),
                    };
                    item.SubItems.Add("驱动器");
                    item.SubItems.Add("");
                    _localList.Items.Add(item);
                }
                return;
            }

            if (path == "~")
                path = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);

            var dir = new DirectoryInfo(path);
            if (!dir.Exists)
            {
                SetStatus($"本地目录不存在: {path}");
                return;
            }

            _localPath = dir.FullName;
            _localPathBox.Text = _localPath;

            var entries = dir.EnumerateFileSystemInfos()
                .OrderByDescending(x => x is DirectoryInfo)
                .ThenBy(x => x.Name, StringComparer.OrdinalIgnoreCase);

            foreach (var entry in entries)
            {
                bool isDir = entry is DirectoryInfo;
                string label = isDir ? $"📁 {entry.Name}" : $"📄 {entry.Name}";
                var item = new ListViewItem(label)
                {
                    Tag = new LocalEntryTag(entry.FullName, isDir),
                };
                long size = 0;
                if (entry is FileInfo fi)
                {
                    try { size = fi.Length; } catch { }
                }
                item.SubItems.Add(isDir ? "<文件夹>" : FormatSize(size));
                item.SubItems.Add(entry.LastWriteTime.ToString("yyyy-MM-dd HH:mm"));
                _localList.Items.Add(item);
            }
        }
        catch (Exception ex)
        {
            SetStatus($"读取本地目录失败: {ex.Message}");
        }
        finally
        {
            _localList.EndUpdate();
        }
    }

    private void NavigateLocalUp()
    {
        if (string.IsNullOrWhiteSpace(_localPath)) return;
        var parent = Directory.GetParent(_localPath);
        LoadLocalDirectory(parent != null ? parent.FullName : "");
    }

    private void OnLocalItemDoubleClick(ListViewItem item)
    {
        if (item.Tag is LocalEntryTag tag && tag.IsDir)
        {
            LoadLocalDirectory(tag.FullPath);
        }
    }

    // ── Remote Filesystem Navigation ─────────────────────────────────────

    private void RequestRemoteDirectory(string path)
    {
        if (string.IsNullOrWhiteSpace(path)) path = "~";
        _remotePath = path;
        _remotePathBox.Text = path;
        _conn.SendListDir(path);
    }

    private void NavigateRemoteUp()
    {
        if (string.IsNullOrWhiteSpace(_remotePath) || _remotePath == "~" || _remotePath == "/")
            return;

        string sep = _remoteUsesBackslash ? "\\" : "/";
        string trimmed = _remotePath.TrimEnd('/', '\\');
        int idx = trimmed.LastIndexOfAny(['/', '\\']);
        if (idx < 0)
        {
            RequestRemoteDirectory("~");
            return;
        }
        if (idx == 0)
        {
            RequestRemoteDirectory("/");
            return;
        }

        string parent = trimmed[..idx];
        // Windows drive root (e.g. "C:") needs trailing backslash
        if (parent.Length == 2 && parent[1] == ':')
            parent += sep;

        RequestRemoteDirectory(parent);
    }

    private void OnRemoteDirListingReceived(string path, DirEntry[] entries)
    {
        if (IsDisposed || !IsHandleCreated) return;
        try
        {
            BeginInvoke(() =>
            {
                if (IsDisposed) return;
                _remotePath = path;
                _remoteUsesBackslash = path.Contains('\\') || (path.Length >= 2 && path[1] == ':');
                _remotePathBox.Text = path;

                _remoteList.BeginUpdate();
                try
                {
                    _remoteList.Items.Clear();
                    foreach (var entry in entries)
                    {
                        string label = entry.IsDir ? $"📁 {entry.Name}" : $"📄 {entry.Name}";
                        var item = new ListViewItem(label)
                        {
                            Tag = entry,
                        };
                        item.SubItems.Add(entry.IsDir ? "<文件夹>" : FormatSize(entry.Size));
                        string modText = entry.ModifiedMs > 0
                            ? DateTimeOffset.FromUnixTimeMilliseconds(entry.ModifiedMs).ToLocalTime().ToString("yyyy-MM-dd HH:mm")
                            : "";
                        item.SubItems.Add(modText);
                        _remoteList.Items.Add(item);
                    }
                }
                finally
                {
                    _remoteList.EndUpdate();
                }
            });
        }
        catch { }
    }

    private void OnRemoteItemDoubleClick(ListViewItem item)
    {
        if (item.Tag is DirEntry entry && entry.IsDir)
        {
            RequestRemoteDirectory(JoinRemotePath(_remotePath, entry.Name));
        }
    }

    // ── Transfers (Upload & Download with Folder Recursion + Resume) ─────

    private async Task UploadSelectedAsync()
    {
        if (_busy || _localList.SelectedItems.Count == 0) return;

        var selected = _localList.SelectedItems
            .Cast<ListViewItem>()
            .Select(i => i.Tag as LocalEntryTag)
            .Where(t => t != null)
            .Cast<LocalEntryTag>()
            .ToList();
        if (selected.Count == 0) return;

        string? destDir = string.IsNullOrWhiteSpace(_remotePath) || _remotePath == "~" ? null : _remotePath;

        SetBusy(true);
        _transferCts = new CancellationTokenSource();
        var ct = _transferCts.Token;

        try
        {
            int totalFiles = 0;
            foreach (var item in selected)
            {
                ct.ThrowIfCancellationRequested();
                if (item.IsDir)
                {
                    var paths = await _conn.UploadFolderAsync(
                        item.FullPath,
                        destDir: destDir,
                        resume: true,
                        onFileStarted: (idx, total, rel) =>
                            SetStatus($"↑ 上传文件夹 ({idx}/{total}): {rel}"),
                        ct: ct).ConfigureAwait(true);
                    totalFiles += paths.Count;
                }
                else
                {
                    SetStatus($"↑ 正在上传: {Path.GetFileName(item.FullPath)}");
                    await _conn.UploadFileExAsync(
                        item.FullPath,
                        destDir: destDir,
                        resume: true,
                        ct: ct).ConfigureAwait(true);
                    totalFiles++;
                }
            }

            SetProgress(100);
            SetStatus($"✓ 上传完成 ({totalFiles} 个文件)");
            RequestRemoteDirectory(_remotePath);
        }
        catch (OperationCanceledException)
        {
            SetStatus("上传已取消（已保留 .remoter.part 以便断点续传）");
        }
        catch (Exception ex)
        {
            SetStatus($"✕ 上传失败: {ex.Message}");
        }
        finally
        {
            SetBusy(false);
        }
    }

    private async Task DownloadSelectedAsync()
    {
        if (_busy || _remoteList.SelectedItems.Count == 0) return;
        if (string.IsNullOrWhiteSpace(_localPath) || !Directory.Exists(_localPath))
        {
            SetStatus("请先在左侧选择一个有效的本地目标目录");
            return;
        }

        var selected = _remoteList.SelectedItems
            .Cast<ListViewItem>()
            .Select(i => i.Tag as DirEntry)
            .Where(e => e != null)
            .Cast<DirEntry>()
            .ToList();
        if (selected.Count == 0) return;

        SetBusy(true);
        _transferCts = new CancellationTokenSource();
        var ct = _transferCts.Token;

        try
        {
            int totalFiles = 0;
            foreach (var entry in selected)
            {
                ct.ThrowIfCancellationRequested();
                string remoteFull = JoinRemotePath(_remotePath, entry.Name);
                if (entry.IsDir)
                {
                    int count = await _conn.DownloadFolderAsync(
                        remoteFull,
                        _localPath,
                        resume: true,
                        onFileStarted: (idx, total, rel) =>
                            SetStatus($"↓ 下载文件夹 ({idx}/{total}): {rel}"),
                        ct: ct).ConfigureAwait(true);
                    totalFiles += count;
                }
                else
                {
                    string localDest = Path.Combine(_localPath, entry.Name);
                    SetStatus($"↓ 正在下载: {entry.Name}");
                    await _conn.DownloadFileAsync(remoteFull, localDest, resume: true, ct: ct).ConfigureAwait(true);
                    totalFiles++;
                }
            }

            SetProgress(100);
            SetStatus($"✓ 下载完成 ({totalFiles} 个文件)");
            LoadLocalDirectory(_localPath);
        }
        catch (OperationCanceledException)
        {
            SetStatus("下载已取消（已保留 .remoter.part 以便断点续传）");
        }
        catch (Exception ex)
        {
            SetStatus($"✕ 下载失败: {ex.Message}");
        }
        finally
        {
            SetBusy(false);
        }
    }

    private void OnFileTransferProgress(FileTransferProgress p)
    {
        if (IsDisposed || !IsHandleCreated) return;
        try
        {
            BeginInvoke(() =>
            {
                if (IsDisposed) return;
                int pct = p.Size > 0
                    ? (int)Math.Clamp(p.Transferred * 100 / p.Size, 0, 100)
                    : (p.Done ? 100 : 0);
                _progressBar.Value = pct;

                string arrow = p.Direction == FileTransferDirection.Upload ? "↑" : "↓";
                string resumeTag = p.Resumed ? " [断点续传]" : "";
                if (!string.IsNullOrEmpty(p.Error))
                {
                    _statusLabel.Text = $"✕ {arrow} {p.Name} 失败: {p.Error}";
                }
                else if (p.Done)
                {
                    _statusLabel.Text = $"✓ {arrow} {p.Name}{resumeTag} 完成 ({FormatSize(p.Size)})";
                }
                else
                {
                    string speed = p.SpeedBps > 0 ? $" · {FormatSize((long)p.SpeedBps)}/s" : "";
                    _statusLabel.Text = $"{arrow} {p.Name}{resumeTag} — {pct}% ({FormatSize(p.Transferred)} / {FormatSize(p.Size)}){speed}";
                }
            });
        }
        catch { }
    }

    // ── Helpers ──────────────────────────────────────────────────────────

    private void SetBusy(bool busy)
    {
        _busy = busy;
        _uploadBtn.Enabled = !busy;
        _downloadBtn.Enabled = !busy;
        _cancelBtn.Enabled = busy;
        if (!busy)
        {
            _transferCts?.Dispose();
            _transferCts = null;
        }
    }

    private void SetStatus(string text)
    {
        if (IsDisposed || !IsHandleCreated) return;
        if (InvokeRequired)
            BeginInvoke(() => { if (!IsDisposed) _statusLabel.Text = text; });
        else
            _statusLabel.Text = text;
    }

    private void SetProgress(int value)
    {
        if (IsDisposed || !IsHandleCreated) return;
        int clamped = Math.Clamp(value, 0, 100);
        if (InvokeRequired)
            BeginInvoke(() => { if (!IsDisposed) _progressBar.Value = clamped; });
        else
            _progressBar.Value = clamped;
    }

    private string JoinRemotePath(string baseDir, string name)
    {
        string sep = _remoteUsesBackslash ? "\\" : "/";
        if (string.IsNullOrWhiteSpace(baseDir)) return name;
        if (baseDir.EndsWith('/') || baseDir.EndsWith('\\'))
            return baseDir + name;
        return baseDir + sep + name;
    }

    private static string FormatSize(long bytes)
    {
        if (bytes < 1024) return $"{bytes} B";
        if (bytes < 1024 * 1024) return $"{bytes / 1024.0:F1} KB";
        if (bytes < 1024L * 1024 * 1024) return $"{bytes / (1024.0 * 1024.0):F1} MB";
        return $"{bytes / (1024.0 * 1024.0 * 1024.0):F2} GB";
    }

    private sealed record LocalEntryTag(string FullPath, bool IsDir);
}
