using System;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Channels;
using System.Threading.Tasks;

namespace RemoterWinClient;

/// <summary>
/// Captures local microphone audio on Windows via WinMM (winmm.dll) P/Invoke with
/// zero external dependencies. Outputs 48,000 Hz, 1-channel (mono), 16-bit signed LE PCM
/// in 20 ms chunks (960 samples = 1,920 bytes) using 4 rotating pinned buffers.
/// </summary>
public sealed class MicCapturer : IDisposable
{
    public const int SampleRate = 48_000;
    public const int Channels = 1;
    public const int BitsPerSample = 16;
    public const int ChunkSamples = SampleRate / 50; // 20 ms = 960 samples
    public const int ChunkBytes = ChunkSamples * Channels * (BitsPerSample / 8); // 1,920 bytes
    private const int BufferCount = 4;

    private const uint WAVE_MAPPER = unchecked((uint)-1);
    private const uint CALLBACK_FUNCTION = 0x0003_0000;
    private const ushort WAVE_FORMAT_PCM = 1;
    private const uint WIM_DATA = 0x03C0;
    private const uint MMSYSERR_NOERROR = 0;

    [StructLayout(LayoutKind.Sequential, Pack = 1)]
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

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate void WaveInProc(nint hwi, uint uMsg, nint dwInstance, nint dwParam1, nint dwParam2);

    [DllImport("winmm.dll", ExactSpelling = true)]
    private static extern uint waveInOpen(
        out nint phwi,
        uint uDeviceID,
        ref WAVEFORMATEX pwfx,
        WaveInProc dwCallback,
        nint dwInstance,
        uint fdwOpen);

    [DllImport("winmm.dll", ExactSpelling = true)]
    private static extern uint waveInPrepareHeader(nint hwi, nint pwh, uint cbwh);

    [DllImport("winmm.dll", ExactSpelling = true)]
    private static extern uint waveInUnprepareHeader(nint hwi, nint pwh, uint cbwh);

    [DllImport("winmm.dll", ExactSpelling = true)]
    private static extern uint waveInAddBuffer(nint hwi, nint pwh, uint cbwh);

    [DllImport("winmm.dll", ExactSpelling = true)]
    private static extern uint waveInStart(nint hwi);

    [DllImport("winmm.dll", ExactSpelling = true)]
    private static extern uint waveInStop(nint hwi);

    [DllImport("winmm.dll", ExactSpelling = true)]
    private static extern uint waveInReset(nint hwi);

    [DllImport("winmm.dll", ExactSpelling = true)]
    private static extern uint waveInClose(nint hwi);

    private readonly object _lock = new();
    private readonly WaveInProc _callback; // GC-rooted for the lifetime of this instance

    private nint _hWaveIn;
    private byte[][]? _buffers;
    private GCHandle[]? _bufferHandles;
    private nint[]? _headerPtrs;
    private int _waveHdrSize;

    private Channel<int>? _completedChannel;
    private Task? _workerTask;
    private volatile bool _running;
    private volatile bool _disposed;

    /// <summary>
    /// Fired on a background thread with 48 kHz mono 16-bit LE PCM chunks (~20 ms / 1,920 bytes).
    /// </summary>
    public event Action<byte[]>? PcmCaptured;

    public bool IsRunning => _running;

    public MicCapturer()
    {
        _callback = OnWaveInCallback;
        _waveHdrSize = Marshal.SizeOf<WAVEHDR>();
    }

    public bool Start()
    {
        lock (_lock)
        {
            if (_disposed) return false;
            if (_running) return true;

            var format = new WAVEFORMATEX
            {
                wFormatTag = WAVE_FORMAT_PCM,
                nChannels = Channels,
                nSamplesPerSec = SampleRate,
                wBitsPerSample = BitsPerSample,
                nBlockAlign = (ushort)(Channels * (BitsPerSample / 8)),
                nAvgBytesPerSec = (uint)(SampleRate * Channels * (BitsPerSample / 8)),
                cbSize = 0,
            };

            uint mm = waveInOpen(out nint hWaveIn, WAVE_MAPPER, ref format, _callback, nint.Zero, CALLBACK_FUNCTION);
            if (mm != MMSYSERR_NOERROR || hWaveIn == nint.Zero)
            {
                return false;
            }

            _hWaveIn = hWaveIn;
            _buffers = new byte[BufferCount][];
            _bufferHandles = new GCHandle[BufferCount];
            _headerPtrs = new nint[BufferCount];

            try
            {
                for (int i = 0; i < BufferCount; i++)
                {
                    _buffers[i] = new byte[ChunkBytes];
                    _bufferHandles[i] = GCHandle.Alloc(_buffers[i], GCHandleType.Pinned);
                    nint hdrPtr = Marshal.AllocHGlobal(_waveHdrSize);
                    _headerPtrs[i] = hdrPtr;

                    var hdr = new WAVEHDR
                    {
                        lpData = _bufferHandles[i].AddrOfPinnedObject(),
                        dwBufferLength = (uint)ChunkBytes,
                        dwBytesRecorded = 0,
                        dwUser = (nint)i,
                        dwFlags = 0,
                        dwLoops = 0,
                        lpNext = nint.Zero,
                        reserved = nint.Zero,
                    };
                    Marshal.StructureToPtr(hdr, hdrPtr, false);

                    if (waveInPrepareHeader(_hWaveIn, hdrPtr, (uint)_waveHdrSize) != MMSYSERR_NOERROR ||
                        waveInAddBuffer(_hWaveIn, hdrPtr, (uint)_waveHdrSize) != MMSYSERR_NOERROR)
                    {
                        CleanupNativeLocked();
                        return false;
                    }
                }

                _completedChannel = Channel.CreateUnbounded<int>(new UnboundedChannelOptions
                {
                    SingleReader = true,
                    SingleWriter = false,
                });

                _running = true;
                var ch = _completedChannel;
                _workerTask = Task.Run(() => ProcessCompletedBuffersAsync(ch));

                if (waveInStart(_hWaveIn) != MMSYSERR_NOERROR)
                {
                    _running = false;
                    _completedChannel.Writer.TryComplete();
                    CleanupNativeLocked();
                    return false;
                }

                return true;
            }
            catch
            {
                _running = false;
                _completedChannel?.Writer.TryComplete();
                CleanupNativeLocked();
                return false;
            }
        }
    }

    public void Stop()
    {
        Task? worker;
        lock (_lock)
        {
            if (!_running && _hWaveIn == nint.Zero) return;
            _running = false;
            _completedChannel?.Writer.TryComplete();
            worker = _workerTask;
            _workerTask = null;

            if (_hWaveIn != nint.Zero)
            {
                try { waveInStop(_hWaveIn); } catch { }
                try { waveInReset(_hWaveIn); } catch { }
            }
        }

        // Wait briefly for worker loop to exit before unpreparing/freeing buffers
        if (worker != null)
        {
            try { worker.Wait(250); } catch { }
        }

        lock (_lock)
        {
            CleanupNativeLocked();
            _completedChannel = null;
        }
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        Stop();
    }

    // Invoked on WinMM internal callback thread: NEVER call waveIn* APIs here (deadlock risk).
    private void OnWaveInCallback(nint hwi, uint uMsg, nint dwInstance, nint dwParam1, nint dwParam2)
    {
        if (uMsg != WIM_DATA || !_running || dwParam1 == nint.Zero) return;

        try
        {
            var hdr = Marshal.PtrToStructure<WAVEHDR>(dwParam1);
            int idx = (int)hdr.dwUser;
            if (idx >= 0 && idx < BufferCount)
            {
                _completedChannel?.Writer.TryWrite(idx);
            }
        }
        catch { }
    }

    private async Task ProcessCompletedBuffersAsync(Channel<int> channel)
    {
        try
        {
            await foreach (int idx in channel.Reader.ReadAllAsync().ConfigureAwait(false))
            {
                if (!_running) break;

                byte[]? pcmCopy = null;
                lock (_lock)
                {
                    if (!_running || _hWaveIn == nint.Zero || _buffers == null || _headerPtrs == null)
                        break;

                    nint hdrPtr = _headerPtrs[idx];
                    if (hdrPtr == nint.Zero) continue;

                    var hdr = Marshal.PtrToStructure<WAVEHDR>(hdrPtr);
                    int recorded = (int)Math.Min(hdr.dwBytesRecorded, (uint)_buffers[idx].Length);
                    if (recorded > 0)
                    {
                        pcmCopy = new byte[recorded];
                        Buffer.BlockCopy(_buffers[idx], 0, pcmCopy, 0, recorded);
                    }

                    // Re-submit buffer back to WinMM
                    hdr.dwBytesRecorded = 0;
                    Marshal.StructureToPtr(hdr, hdrPtr, false);
                    _ = waveInAddBuffer(_hWaveIn, hdrPtr, (uint)_waveHdrSize);
                }

                if (pcmCopy != null)
                {
                    try { PcmCaptured?.Invoke(pcmCopy); } catch { }
                }
            }
        }
        catch { }
    }

    private void CleanupNativeLocked()
    {
        if (_hWaveIn != nint.Zero && _headerPtrs != null)
        {
            for (int i = 0; i < _headerPtrs.Length; i++)
            {
                if (_headerPtrs[i] != nint.Zero)
                {
                    try { waveInUnprepareHeader(_hWaveIn, _headerPtrs[i], (uint)_waveHdrSize); } catch { }
                }
            }
        }

        if (_hWaveIn != nint.Zero)
        {
            try { waveInClose(_hWaveIn); } catch { }
            _hWaveIn = nint.Zero;
        }

        if (_headerPtrs != null)
        {
            for (int i = 0; i < _headerPtrs.Length; i++)
            {
                if (_headerPtrs[i] != nint.Zero)
                {
                    Marshal.FreeHGlobal(_headerPtrs[i]);
                    _headerPtrs[i] = nint.Zero;
                }
            }
            _headerPtrs = null;
        }

        if (_bufferHandles != null)
        {
            for (int i = 0; i < _bufferHandles.Length; i++)
            {
                if (_bufferHandles[i].IsAllocated)
                {
                    _bufferHandles[i].Free();
                }
            }
            _bufferHandles = null;
        }

        _buffers = null;
    }
}
