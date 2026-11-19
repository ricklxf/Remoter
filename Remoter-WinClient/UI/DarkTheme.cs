using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace RemoterWinClient.UI;

/// <summary>
/// Shared native Windows 10/11 dark-mode palette and DWM titlebar helper.
/// </summary>
public static class DarkTheme
{
    public static readonly Color WindowBg     = Color.FromArgb(18, 20, 25);
    public static readonly Color SurfaceBg    = Color.FromArgb(26, 30, 38);
    public static readonly Color InputBg      = Color.FromArgb(34, 40, 50);
    public static readonly Color HoverBg      = Color.FromArgb(44, 52, 65);
    public static readonly Color BorderColor  = Color.FromArgb(52, 60, 74);
    public static readonly Color Accent       = Color.FromArgb(15, 184, 171); // Remoter teal (#0fb8ab)
    public static readonly Color AccentHover  = Color.FromArgb(20, 204, 190);
    public static readonly Color Danger       = Color.FromArgb(224, 72, 82);
    public static readonly Color DangerHover  = Color.FromArgb(240, 88, 98);
    public static readonly Color TextPrimary  = Color.FromArgb(234, 239, 246);
    public static readonly Color TextMuted    = Color.FromArgb(142, 152, 168);
    public static readonly Color VideoBg      = Color.FromArgb(10, 12, 16);

    private const int DWMWA_USE_IMMERSIVE_DARK_MODE_BEFORE_20H1 = 19;
    private const int DWMWA_USE_IMMERSIVE_DARK_MODE = 20;

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(nint hwnd, int attr, ref int attrValue, int attrSize);

    /// <summary>
    /// Enables Windows 10/11 immersive dark title bar on the given window handle.
    /// </summary>
    public static void EnableDarkTitleBar(nint hwnd)
    {
        if (hwnd == nint.Zero) return;
        int dark = 1;
        if (DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, ref dark, sizeof(int)) != 0)
        {
            DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE_BEFORE_20H1, ref dark, sizeof(int));
        }
    }

    public static void StyleButton(Button btn, bool primary = false, bool danger = false)
    {
        btn.FlatStyle = FlatStyle.Flat;
        btn.Cursor = Cursors.Hand;
        if (primary)
        {
            btn.BackColor = Accent;
            btn.ForeColor = Color.FromArgb(12, 18, 22);
            btn.FlatAppearance.BorderSize = 0;
            btn.FlatAppearance.MouseOverBackColor = AccentHover;
        }
        else if (danger)
        {
            btn.BackColor = Danger;
            btn.ForeColor = Color.White;
            btn.FlatAppearance.BorderSize = 0;
            btn.FlatAppearance.MouseOverBackColor = DangerHover;
        }
        else
        {
            btn.BackColor = InputBg;
            btn.ForeColor = TextPrimary;
            btn.FlatAppearance.BorderColor = BorderColor;
            btn.FlatAppearance.BorderSize = 1;
            btn.FlatAppearance.MouseOverBackColor = HoverBg;
        }
    }
}
