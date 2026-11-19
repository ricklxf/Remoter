using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace RemoterWinClient.UI;

/// <summary>
/// Shared native Windows 10/11 clean light-mode (white) palette and DWM titlebar helper.
/// </summary>
public static class DarkTheme
{
    public static readonly Color WindowBg     = Color.FromArgb(245, 247, 250); // #F5F7FA soft off-white canvas
    public static readonly Color SurfaceBg    = Color.White;                   // #FFFFFF crisp white cards
    public static readonly Color InputBg      = Color.White;                   // #FFFFFF clean inputs
    public static readonly Color HoverBg      = Color.FromArgb(236, 241, 247); // #ECF1F7 subtle hover
    public static readonly Color BorderColor  = Color.FromArgb(216, 223, 232); // #D8DFE8 crisp border
    public static readonly Color Accent       = Color.FromArgb(13, 148, 136);  // #0D9488 Remoter teal
    public static readonly Color AccentHover  = Color.FromArgb(15, 118, 110);  // #0F766E
    public static readonly Color Danger       = Color.FromArgb(220, 38, 38);   // #DC2626
    public static readonly Color DangerHover  = Color.FromArgb(185, 28, 28);   // #B91C1C
    public static readonly Color TextPrimary  = Color.FromArgb(24, 30, 41);    // #181E29 deep slate
    public static readonly Color TextMuted    = Color.FromArgb(100, 116, 139); // #64748B muted slate
    public static readonly Color VideoBg      = Color.FromArgb(15, 18, 24);    // Dark letterbox behind remote video

    private const int DWMWA_USE_IMMERSIVE_DARK_MODE_BEFORE_20H1 = 19;
    private const int DWMWA_USE_IMMERSIVE_DARK_MODE = 20;

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(nint hwnd, int attr, ref int attrValue, int attrSize);

    /// <summary>
    /// Ensures Windows 10/11 uses the native light (white) title bar on the given window handle.
    /// </summary>
    public static void EnableDarkTitleBar(nint hwnd)
    {
        if (hwnd == nint.Zero) return;
        int dark = 0;
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
            btn.ForeColor = Color.White;
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
