using System.Runtime.InteropServices;

namespace RemoterWin;

/// <summary>
/// Zero-dependency WinMM (winmm.dll) 48kHz mono 16-bit signed LE PCM playback engine
/// for remote microphone passthrough.
/// SAFETY: Enumerates waveOut devices and ONLY opens a virtual audio cable device
/// (VB-Cable, Voicemeeter, Virtual, BlackHole). Never opens physical speakers.
/// </summary>
sealed class MicPlayer : IDisposable
{
    private const uint WAVE_FORMAT_PCM = 1;
    private const uint CALLBACK_NULL   = 0;
    private const uint WHDR_DONE       = 0x00000001;
    private const int  MaxQueuedBuffers = 32;

    private static readonly string[] VirtualDeviceKeywords =
    [
        "cable",
        "vb-audio",
        "virtual",
        "voicemeeter",
        "blackhole",
    ];

    private sealed class PendingBuffer
    {
        public required byte[] Data { get; init; }
        public required GCHandle DataHandle { get; init; }
        public required nint HeaderPtr { get; init; }
    }

    private readonly object _lock = new();
    private readonly Queue<PendingBuffer> _queue = new();
    private nint _hWaveOut = nint.Zero;
    private bool _disposed;

    public string ActiveDeviceName { get; private set; } = "";
    public bool IsRunning { get; private set; }

    /// <summary>
    /// Opens the first detected virtual audio output device at 48kHz mono 16-bit PCM.
    /// Returns false if no virtual audio device is installed on this Windows machine.
    /// </summary>
    public bool Start()
    {
        lock (_lock)
        {
            if (_disposed) return false;
            if (IsRunning && _hWaveOut != nint.Zero) return true;

            if (!TryFindVirtualDevice(out uint deviceId, out string deviceName))
            {
                ActiveDeviceName = "";
                IsRunning = false;
                AppLog.Write("[MicPlayer] No virtual audio output device found (VB-Cable / Voicemeeter / Virtual)");
                return false;
            }

            var fmt = new WAVEFORMATEX
            {
                wFormatTag      = (ushort)WAVE_FORMAT_PCM,
                nChannels       = 1,
                nSamplesPerSec  = 48_000,
                wBitsPerSample  = 16,
                nBlockAlign     = 2,
                nAvgBytesPerSec = 96_000,
                cbSize          = 0,
            };

            uint res = waveOutOpen(out nint hwo, deviceId, ref fmt, nint.Zero, nint.Zero, CALLBACK_NULL);
            if (res != 0 || hwo == nint.Zero)
            {
                ActiveDeviceName = "";
                IsRunning = false;
                AppLog.Write($"[MicPlayer] waveOutOpen failed for '{deviceName}' (id={deviceId}): mmresult={res}");
                return false;
            }

            _hWaveOut = hwo;
            ActiveDeviceName = deviceName;
            IsRunning = true;
            AppLog.Write($"[MicPlayer] Started 48kHz mono PCM output on virtual device '{deviceName}' (id={deviceId})");
            return true;
        }
    }

    /// <summary>
    /// Enqueues a 48kHz mono 16-bit signed little-endian PCM buffer for playback.
    /// Reclaims completed WAVEHDR buffers automatically so no pinned memory leaks.
    /// </summary>
    public void EnqueuePcm(ReadOnlySpan<byte> pcmInt16Le)
    {
        if (pcmInt16Le.Length < 2) return;

        lock (_lock)
        {
            if (_disposed || !IsRunning || _hWaveOut == nint.Zero) return;

            ReclaimCompletedLocked();

            if (_queue.Count >= MaxQueuedBuffers)
            {
                // Drop oldest/incoming excess to keep live voice latency bounded
                return;
            }

            byte[] data = pcmInt16Le.ToArray();
            var dataHandle = GCHandle.Alloc(data, GCHandleType.Pinned);
            int hdrSize = Marshal.SizeOf<WAVEHDR>();
            nint hdrPtr = Marshal.AllocHGlobal(hdrSize);

            try
            {
                var hdr = new WAVEHDR
                {
                    lpData          = dataHandle.AddrOfPinnedObject(),
                    dwBufferLength  = (uint)data.Length,
                    dwBytesRecorded = 0,
                    dwUser          = nint.Zero,
                    dwFlags         = 0,
                    dwLoops         = 0,
                    lpNext          = nint.Zero,
                    reserved        = nint.Zero,
                };
                Marshal.StructureToPtr(hdr, hdrPtr, fDeleteOld: false);

                uint prep = waveOutPrepareHeader(_hWaveOut, hdrPtr, (uint)hdrSize);
                if (prep != 0)
                {
                    Marshal.FreeHGlobal(hdrPtr);
                    dataHandle.Free();
                    return;
                }

                uint wr = waveOutWrite(_hWaveOut, hdrPtr, (uint)hdrSize);
                if (wr != 0)
                {
                    waveOutUnprepareHeader(_hWaveOut, hdrPtr, (uint)hdrSize);
                    Marshal.FreeHGlobal(hdrPtr);
                    dataHandle.Free();
                    return;
                }

                _queue.Enqueue(new PendingBuffer
                {
                    Data = data,
                    DataHandle = dataHandle,
                    HeaderPtr = hdrPtr,
                });
            }
            catch
            {
                try { Marshal.FreeHGlobal(hdrPtr); } catch { }
                if (dataHandle.IsAllocated) dataHandle.Free();
            }
        }
    }

    public void Stop()
    {
        lock (_lock)
        {
            StopLocked();
        }
    }

    public void Dispose()
    {
        lock (_lock)
        {
            if (_disposed) return;
            _disposed = true;
            StopLocked();
        }
    }

    private void StopLocked()
    {
        IsRunning = false;
        if (_hWaveOut != nint.Zero)
        {
            try { waveOutReset(_hWaveOut); } catch { }
            DrainAllBuffersLocked();
            try { waveOutClose(_hWaveOut); } catch { }
            _hWaveOut = nint.Zero;
            AppLog.Write($"[MicPlayer] Stopped (device='{ActiveDeviceName}')");
        }
        else
        {
            DrainAllBuffersLocked();
        }
        ActiveDeviceName = "";
    }

    private void ReclaimCompletedLocked()
    {
        int hdrSize = Marshal.SizeOf<WAVEHDR>();
        while (_queue.Count > 0)
        {
            var front = _queue.Peek();
            var hdr = Marshal.PtrToStructure<WAVEHDR>(front.HeaderPtr);
            if ((hdr.dwFlags & WHDR_DONE) == 0)
                break;

            _queue.Dequeue();
            if (_hWaveOut != nint.Zero)
            {
                try { waveOutUnprepareHeader(_hWaveOut, front.HeaderPtr, (uint)hdrSize); } catch { }
            }
            Marshal.FreeHGlobal(front.HeaderPtr);
            if (front.DataHandle.IsAllocated) front.DataHandle.Free();
        }
    }

    private void DrainAllBuffersLocked()
    {
        int hdrSize = Marshal.SizeOf<WAVEHDR>();
        while (_queue.Count > 0)
        {
            var item = _queue.Dequeue();
            if (_hWaveOut != nint.Zero)
            {
                try { waveOutUnprepareHeader(_hWaveOut, item.HeaderPtr, (uint)hdrSize); } catch { }
            }
            try { Marshal.FreeHGlobal(item.HeaderPtr); } catch { }
            if (item.DataHandle.IsAllocated) item.DataHandle.Free();
        }
    }

    private static bool TryFindVirtualDevice(out uint deviceId, out string deviceName)
    {
        deviceId = 0;
        deviceName = "";

        uint count = waveOutGetNumDevs();
        uint capsSize = (uint)Marshal.SizeOf<WAVEOUTCAPSW>();

        for (uint i = 0; i < count; i++)
        {
            if (waveOutGetDevCapsW(i, out var caps, capsSize) != 0)
                continue;

            string name = caps.szPname ?? "";
            if (IsVirtualAudioDevice(name))
            {
                deviceId = i;
                deviceName = name;
                return true;
            }
        }
        return false;
    }

    private static bool IsVirtualAudioDevice(string name)
    {
        if (string.IsNullOrWhiteSpace(name)) return false;
        foreach (var kw in VirtualDeviceKeywords)
        {
            if (name.Contains(kw, StringComparison.OrdinalIgnoreCase))
                return true;
        }
        return false;
    }

    // ── WinMM P/Invoke ───────────────────────────────────────────────────

    [DllImport("winmm.dll")]
    private static extern uint waveOutGetNumDevs();

    [DllImport("winmm.dll", CharSet = CharSet.Unicode)]
    private static extern uint waveOutGetDevCapsW(nuint uDeviceID, out WAVEOUTCAPSW pwoc, uint cbwoc);

    [DllImport("winmm.dll")]
    private static extern uint waveOutOpen(
        out nint phwo,
        uint uDeviceID,
        ref WAVEFORMATEX pwfx,
        nint dwCallback,
        nint dwInstance,
        uint fdwOpen);

    [DllImport("winmm.dll")]
    private static extern uint waveOutPrepareHeader(nint hwo, nint pwh, uint cbwh);

    [DllImport("winmm.dll")]
    private static extern uint waveOutWrite(nint hwo, nint pwh, uint cbwh);

    [DllImport("winmm.dll")]
    private static extern uint waveOutUnprepareHeader(nint hwo, nint pwh, uint cbwh);

    [DllImport("winmm.dll")]
    private static extern uint waveOutReset(nint hwo);

    [DllImport("winmm.dll")]
    private static extern uint waveOutClose(nint hwo);

    [StructLayout(LayoutKind.Sequential, Pack = 1, CharSet = CharSet.Unicode)]
    private struct WAVEOUTCAPSW
    {
        public ushort wMid;
        public ushort wPid;
        public uint   vDriverVersion;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string szPname;
        public uint   dwFormats;
        public ushort wChannels;
        public ushort wReserved1;
        public uint   dwSupport;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    private struct WAVEFORMATEX
    {
        public ushort wFormatTag;
        public ushort nChannels;
        public uint   nSamplesPerSec;
        public uint   nAvgBytesPerSec;
        public ushort nBlockAlign;
        public ushort wBitsPerSample;
        public ushort cbSize;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct WAVEHDR
    {
        public nint lpData;
        public uint dwBufferLength;
        public uint dwBytesRecorded;
        public nint dwUser;
        public uint dwFlags;
        public uint dwLoops;
        public nint lpNext;
        public nint reserved;
    }
}
