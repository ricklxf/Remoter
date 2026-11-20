using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace RemoterWin;

// Fullscreen top-most curtain overlay excluded from DXGI / DWM capture via WDA_EXCLUDEFROMCAPTURE.
static class PrivacyScreen
{
    private static Form? _overlay;
    private static readonly object _lock = new();

    private const uint WDA_EXCLUDEFROMCAPTURE = 0x00000011;
    [DllImport("user32.dll")] private static extern bool SetWindowDisplayAffinity(nint hWnd, uint dwAffinity);

    public static void SetEnabled(bool enabled)
    {
        lock (_lock)
        {
            if (enabled)
            {
                if (_overlay != null) return;
                var t = new Thread(() =>
                {
                    _overlay = new Form
                    {
                        FormBorderStyle = FormBorderStyle.None,
                        WindowState = FormWindowState.Maximized,
                        TopMost = true,
                        BackColor = Color.FromArgb(12, 14, 18),
                        ShowInTaskbar = false,
                        StartPosition = FormStartPosition.Manual,
                        Bounds = SystemInformation.VirtualScreen
                    };

                    _overlay.HandleCreated += (s, e) =>
                    {
                        SetWindowDisplayAffinity(_overlay.Handle, WDA_EXCLUDEFROMCAPTURE);
                    };

                    var label = new Label
                    {
                        Text = "🔒 Remoter 防窥隐私模式已开启\n\n远程主控正在操作此设备，本地屏幕已安全遮盖。",
                        ForeColor = Color.White,
                        Font = new Font("Segoe UI", 16, FontStyle.Bold),
                        TextAlign = ContentAlignment.MiddleCenter,
                        Dock = DockStyle.Fill
                    };
                    _overlay.Controls.Add(label);

                    Application.Run(_overlay);
                });
                t.SetApartmentState(ApartmentState.STA);
                t.IsBackground = true;
                t.Start();
                AppLog.Write("[PrivacyScreen] Enabled curtain overlay");
            }
            else
            {
                if (_overlay != null && !_overlay.IsDisposed)
                {
                    try { _overlay.Invoke(new Action(() => _overlay.Close())); } catch { }
                    _overlay = null;
                    AppLog.Write("[PrivacyScreen] Disabled curtain overlay");
                }
            }
        }
    }
}
