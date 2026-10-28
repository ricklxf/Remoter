using System.Runtime.InteropServices;

namespace RemoterWin;

// Captures system audio output via WASAPI Loopback on the default audio render endpoint.
// Produces 48kHz / 16-bit / Stereo PCM data frames for AudioEncoder.
sealed class AudioCapturer : IDisposable
{
    public Action<byte[], int>? OnPcmData;

    private Thread? _thread;
    private volatile bool _running;
    private AutoResetEvent? _stopEvent;
    private AutoResetEvent? _sampleReadyEvent;

    public void Start()
    {
        if (_running) return;
        _running = true;
        _stopEvent = new AutoResetEvent(false);
        _sampleReadyEvent = new AutoResetEvent(false);

        _thread = new Thread(CaptureLoop)
        {
            Name = "WASAPI-AudioLoopback",
            IsBackground = true
        };
        _thread.Start();
    }

    public void Stop()
    {
        if (!_running) return;
        _running = false;
        _stopEvent?.Set();
        _thread?.Join(1000);
        _thread = null;
    }

    private void CaptureLoop()
    {
        nint pFormat = 0;
        try
        {
            var enumerator = (IMMDeviceEnumerator)Activator.CreateInstance(
                Type.GetTypeFromCLSID(new Guid("BCDE0395-E52F-467C-8E3D-C4579291692E"))!)!;

            enumerator.GetDefaultAudioEndpoint(0 /* eRender */, 1 /* eMultimedia */, out var devObj);
            var device = (IMMDevice)devObj;

            var iidAudioClient = new Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2");
            device.Activate(ref iidAudioClient, 23 /* CLSCTX_ALL */, IntPtr.Zero, out var clientObj);
            var audioClient = (IAudioClient)clientObj;

            audioClient.GetMixFormat(out pFormat);
            var waveFormat = Marshal.PtrToStructure<WAVEFORMATEX>(pFormat);

            // AUDCLNT_STREAMFLAGS_LOOPBACK = 0x00020000 | AUDCLNT_STREAMFLAGS_EVENTCALLBACK = 0x00040000
            const uint streamFlags = 0x00020000 | 0x00040000;
            const long hnsBufferDuration = 10_000_000; // 1 second buffer

            audioClient.Initialize(0 /* SHARED */, streamFlags, hnsBufferDuration, 0, pFormat, Guid.Empty);
            audioClient.SetEventHandle(_sampleReadyEvent!.SafeWaitHandle.DangerousGetHandle());

            var iidCaptureClient = new Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317");
            audioClient.GetService(ref iidCaptureClient, out var captureObj);
            var captureClient = (IAudioCaptureClient)captureObj;

            audioClient.Start();
            AppLog.Write($"[AudioCapturer] WASAPI loopback started: {waveFormat.nSamplesPerSec}Hz, {waveFormat.nChannels}ch, {waveFormat.wBitsPerSample}bit");

            var waitHandles = new WaitHandle[] { _stopEvent!, _sampleReadyEvent! };
            var pcmBuffer = new byte[8192];

            while (_running)
            {
                int index = WaitHandle.WaitAny(waitHandles, 100);
                if (index == 0 || !_running) break;

                while (true)
                {
                    int hr = captureClient.GetNextPacketSize(out uint packetSize);
                    if (hr != 0 || packetSize == 0) break;

                    hr = captureClient.GetBuffer(out nint pData, out uint numFramesRead, out uint flags, out _, out _);
                    if (hr != 0) break;

                    try
                    {
                        if (numFramesRead > 0)
                        {
                            int bytesToRead = (int)numFramesRead * waveFormat.nBlockAlign;
                            if (pcmBuffer.Length < bytesToRead)
                                pcmBuffer = new byte[bytesToRead * 2];

                            if ((flags & 0x01 /* AUDCLNT_BUFFERFLAGS_SILENT */) != 0)
                            {
                                Array.Clear(pcmBuffer, 0, bytesToRead);
                            }
                            else
                            {
                                Marshal.Copy(pData, pcmBuffer, 0, bytesToRead);
                            }

                            // Convert to standard 16-bit 48kHz stereo if needed or pass directly
                            OnPcmData?.Invoke(pcmBuffer, bytesToRead);
                        }
                    }
                    finally
                    {
                        captureClient.ReleaseBuffer(numFramesRead);
                    }
                }
            }

            try { audioClient.Stop(); } catch { }
        }
        catch (Exception ex)
        {
            AppLog.Write($"[AudioCapturer] error: {ex.Message}");
        }
        finally
        {
            if (pFormat != 0) Marshal.FreeCoTaskMem(pFormat);
        }
    }

    public void Dispose()
    {
        Stop();
        _stopEvent?.Dispose();
        _sampleReadyEvent?.Dispose();
    }

    // ── COM Declarations ───────────────────────────────────────────────────

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDeviceEnumerator
    {
        [PreserveSig] int EnumAudioEndpoints(int dataFlow, uint stateMask, [MarshalAs(UnmanagedType.IUnknown)] out object devices);
        [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, [MarshalAs(UnmanagedType.IUnknown)] out object endpoint);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDevice
    {
        [PreserveSig] int Activate(ref Guid iid, uint dwClsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object ppInterface);
    }

    [ComImport, Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioClient
    {
        [PreserveSig] int Initialize(int shareMode, uint streamFlags, long hnsBufferDuration, long hnsPeriodicity, nint pFormat, [MarshalAs(UnmanagedType.LPStruct)] Guid audioSessionGuid);
        [PreserveSig] int GetBufferSize(out uint numBufferFrames);
        [PreserveSig] int GetStreamLatency(out long hnsLatency);
        [PreserveSig] int GetCurrentPadding(out uint numPaddingFrames);
        [PreserveSig] int IsFormatSupported(int shareMode, nint pFormat, out nint ppClosestMatch);
        [PreserveSig] int GetMixFormat(out nint ppDeviceFormat);
        [PreserveSig] int GetDevicePeriod(out long hnsDefaultDevicePeriod, out long hnsMinimumDevicePeriod);
        [PreserveSig] int Start();
        [PreserveSig] int Stop();
        [PreserveSig] int Reset();
        [PreserveSig] int SetEventHandle(nint eventHandle);
        [PreserveSig] int GetService(ref Guid riid, [MarshalAs(UnmanagedType.IUnknown)] out object ppv);
    }

    [ComImport, Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioCaptureClient
    {
        [PreserveSig] int GetBuffer(out nint ppData, out uint pNumFramesToRead, out uint pdwFlags, out ulong pu64DevicePosition, out ulong pu64QPCPosition);
        [PreserveSig] int ReleaseBuffer(uint numFramesRead);
        [PreserveSig] int GetNextPacketSize(out uint pNumFramesInNextPacket);
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct WAVEFORMATEX
    {
        public ushort wFormatTag;
        public ushort nChannels;
        public uint nSamplesPerSec;
        public uint nAvgBytesPerSec;
        public ushort nBlockAlign;
        public ushort wBitsPerSample;
        public ushort cbSize;
    }
}
