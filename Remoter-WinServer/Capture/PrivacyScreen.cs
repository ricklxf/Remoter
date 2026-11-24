using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace RemoterWin;

// Fullscreen top-most curtain overlay excluded from DXGI / DWM capture via WDA_EXCLUDEFROMCAPTURE,
// paired with automatic Core Audio speaker mute/restore while privacy screen is active.
static class PrivacyScreen
{
    private static Form? _overlay;
    private static bool _enabled;
    private static bool _mutedByPrivacy;
    private static bool _previousMuteState;
    private static readonly object _lock = new();

    private const uint WDA_EXCLUDEFROMCAPTURE = 0x00000011;
    private const uint CLSCTX_ALL = 23;
    private const int eRender = 0;
    private const int eConsole = 0;

    private static readonly Guid CLSID_MMDeviceEnumerator = new("BCDE0395-E52F-467C-8E3D-C4579291692E");
    private static readonly Guid IID_IAudioEndpointVolume = new("5CDF2C82-841E-4546-9722-0CF74078229A");

    [DllImport("user32.dll")]
    private static extern bool SetWindowDisplayAffinity(nint hWnd, uint dwAffinity);

    public static void SetEnabled(bool enabled)
    {
        lock (_lock)
        {
            if (enabled)
            {
                if (_enabled) return;
                _enabled = true;

                MuteSpeakerForPrivacyLocked();

                var t = new Thread(() =>
                {
                    var form = new Form
                    {
                        FormBorderStyle = FormBorderStyle.None,
                        WindowState = FormWindowState.Maximized,
                        TopMost = true,
                        BackColor = Color.FromArgb(12, 14, 18),
                        ShowInTaskbar = false,
                        StartPosition = FormStartPosition.Manual,
                        Bounds = SystemInformation.VirtualScreen
                    };

                    form.HandleCreated += (s, e) =>
                    {
                        SetWindowDisplayAffinity(form.Handle, WDA_EXCLUDEFROMCAPTURE);
                    };

                    var label = new Label
                    {
                        Text = "🔒 Remoter 防窥隐私模式已开启\n\n远程主控正在操作此设备，本地屏幕已安全遮盖。",
                        ForeColor = Color.White,
                        Font = new Font("Segoe UI", 16, FontStyle.Bold),
                        TextAlign = ContentAlignment.MiddleCenter,
                        Dock = DockStyle.Fill
                    };
                    form.Controls.Add(label);

                    bool shouldRun;
                    lock (_lock)
                    {
                        shouldRun = _enabled;
                        if (shouldRun) _overlay = form;
                    }

                    if (!shouldRun)
                    {
                        form.Dispose();
                        return;
                    }

                    Application.Run(form);
                });
                t.SetApartmentState(ApartmentState.STA);
                t.IsBackground = true;
                t.Start();
                AppLog.Write("[PrivacyScreen] Enabled curtain overlay");
            }
            else
            {
                if (!_enabled && _overlay == null && !_mutedByPrivacy) return;
                _enabled = false;

                if (_overlay != null && !_overlay.IsDisposed)
                {
                    try { _overlay.Invoke(new Action(() => _overlay.Close())); } catch { }
                    _overlay = null;
                    AppLog.Write("[PrivacyScreen] Disabled curtain overlay");
                }

                RestoreSpeakerAfterPrivacyLocked();
            }
        }
    }

    private static void MuteSpeakerForPrivacyLocked()
    {
        try
        {
            if (TryGetMasterMute(out bool wasMuted) && !wasMuted)
            {
                if (TrySetMasterMute(true))
                {
                    _previousMuteState = false;
                    _mutedByPrivacy = true;
                    AppLog.Write("[PrivacyScreen] Auto-muted local speaker for privacy");
                }
            }
        }
        catch (Exception ex)
        {
            AppLog.Write($"[PrivacyScreen] Auto-mute failed: {ex.Message}");
        }
    }

    private static void RestoreSpeakerAfterPrivacyLocked()
    {
        if (!_mutedByPrivacy) return;
        bool restoreState = _previousMuteState;
        _mutedByPrivacy = false;
        try
        {
            if (TrySetMasterMute(restoreState))
            {
                AppLog.Write($"[PrivacyScreen] Restored local speaker mute={restoreState}");
            }
        }
        catch (Exception ex)
        {
            AppLog.Write($"[PrivacyScreen] Restore mute failed: {ex.Message}");
        }
    }

    private static bool TryGetMasterMute(out bool muted)
    {
        muted = false;
        object? enumObj = null;
        object? devObj = null;
        object? volObj = null;
        try
        {
            var enumType = Type.GetTypeFromCLSID(CLSID_MMDeviceEnumerator);
            if (enumType == null) return false;
            enumObj = Activator.CreateInstance(enumType);
            if (enumObj is not IMMDeviceEnumerator enumerator) return false;

            if (enumerator.GetDefaultAudioEndpoint(eRender, eConsole, out devObj) != 0 || devObj is not IMMDevice device)
                return false;

            var iid = IID_IAudioEndpointVolume;
            if (device.Activate(ref iid, CLSCTX_ALL, IntPtr.Zero, out volObj) != 0 || volObj is not IAudioEndpointVolume volume)
                return false;

            return volume.GetMute(out muted) == 0;
        }
        catch
        {
            return false;
        }
        finally
        {
            if (volObj != null && Marshal.IsComObject(volObj)) Marshal.ReleaseComObject(volObj);
            if (devObj != null && Marshal.IsComObject(devObj)) Marshal.ReleaseComObject(devObj);
            if (enumObj != null && Marshal.IsComObject(enumObj)) Marshal.ReleaseComObject(enumObj);
        }
    }

    private static bool TrySetMasterMute(bool muted)
    {
        object? enumObj = null;
        object? devObj = null;
        object? volObj = null;
        try
        {
            var enumType = Type.GetTypeFromCLSID(CLSID_MMDeviceEnumerator);
            if (enumType == null) return false;
            enumObj = Activator.CreateInstance(enumType);
            if (enumObj is not IMMDeviceEnumerator enumerator) return false;

            if (enumerator.GetDefaultAudioEndpoint(eRender, eConsole, out devObj) != 0 || devObj is not IMMDevice device)
                return false;

            var iid = IID_IAudioEndpointVolume;
            if (device.Activate(ref iid, CLSCTX_ALL, IntPtr.Zero, out volObj) != 0 || volObj is not IAudioEndpointVolume volume)
                return false;

            var ctx = Guid.Empty;
            return volume.SetMute(muted, ref ctx) == 0;
        }
        catch
        {
            return false;
        }
        finally
        {
            if (volObj != null && Marshal.IsComObject(volObj)) Marshal.ReleaseComObject(volObj);
            if (devObj != null && Marshal.IsComObject(devObj)) Marshal.ReleaseComObject(devObj);
            if (enumObj != null && Marshal.IsComObject(enumObj)) Marshal.ReleaseComObject(enumObj);
        }
    }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDeviceEnumerator
    {
        [PreserveSig] int EnumAudioEndpoints(int dataFlow, uint stateMask,
            [MarshalAs(UnmanagedType.IUnknown)] out object devices);
        [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role,
            [MarshalAs(UnmanagedType.IUnknown)] out object endpoint);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDevice
    {
        [PreserveSig] int Activate(ref Guid iid, uint dwClsCtx, IntPtr activationParams,
            [MarshalAs(UnmanagedType.IUnknown)] out object ppInterface);
    }

    // IAudioEndpointVolume — all methods up to GetMute declared in exact vtable order.
    [ComImport, Guid("5CDF2C82-841E-4546-9722-0CF74078229A"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioEndpointVolume
    {
        [PreserveSig] int RegisterControlChangeNotify(IntPtr pNotify);
        [PreserveSig] int UnregisterControlChangeNotify(IntPtr pNotify);
        [PreserveSig] int GetChannelCount(out uint channelCount);
        [PreserveSig] int SetMasterVolumeLevel(float fLevelDB, ref Guid pguidEventContext);
        [PreserveSig] int SetMasterVolumeLevelScalar(float fLevel, ref Guid pguidEventContext);
        [PreserveSig] int GetMasterVolumeLevel(out float fLevelDB);
        [PreserveSig] int GetMasterVolumeLevelScalar(out float fLevel);
        [PreserveSig] int SetChannelVolumeLevel(uint nChannel, float fLevelDB, ref Guid pguidEventContext);
        [PreserveSig] int SetChannelVolumeLevelScalar(uint nChannel, float fLevel, ref Guid pguidEventContext);
        [PreserveSig] int GetChannelVolumeLevel(uint nChannel, out float fLevelDB);
        [PreserveSig] int GetChannelVolumeLevelScalar(uint nChannel, out float fLevel);
        [PreserveSig] int SetMute([MarshalAs(UnmanagedType.Bool)] bool bMute, [In] ref Guid pguidEventContext);
        [PreserveSig] int GetMute([MarshalAs(UnmanagedType.Bool)] out bool bMute);
    }
}
