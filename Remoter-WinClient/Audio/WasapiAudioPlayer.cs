using System.Diagnostics;
using System.Runtime.InteropServices;
using Vortice.MediaFoundation;

namespace RemoterWinClient;

/// <summary>
/// Pure native Windows WASAPI low-latency audio player (&lt;15ms) with Media Foundation
/// ADTS AAC-LC decoder (matching Remoter-Mac &amp; Remoter-Win FrameType 0x03) and PCM16 fallback.
/// Includes a float32 ring buffer with underrun silence protection and drift clamping.
/// </summary>
public sealed class WasapiAudioPlayer : IDisposable
{
    private readonly object _decLock = new();
    private readonly object _ringLock = new();

    private IMFTransform? _aacDecoder;
    private bool _decoderReady;
    private bool _decoderOutputsFloat;

    private Thread? _renderThread;
    private volatile bool _running;
    private volatile bool _muted;
    private volatile float _volume = 1.0f;
    private bool _disposed;

    private AutoResetEvent? _stopEvent;
    private AutoResetEvent? _audioReadyEvent;

    private int _sampleRate = 48000;
    private int _channels = 2;

    // Interleaved float32 ring buffer (250ms capacity @ 48kHz stereo = 24000 floats)
    private float[] _ringBuffer = new float[24000];
    private int _ringReadPos;
    private int _ringWritePos;
    private int _ringCount; // number of float samples currently buffered
    private int _maxBufferSamples = 4320;   // ~45ms drift cap (UU sub-8ms target pipeline)
    private int _targetTrimSamples = 960;   // ~10ms trim target on burst
    private bool _needsFadeIn = true;       // 2ms anti-click ramp after underrun or drift trim

    public bool IsRunning => _running;

    public bool IsMuted
    {
        get => _muted;
        set => _muted = value;
    }

    public float Volume
    {
        get => _volume;
        set => _volume = Math.Clamp(value, 0f, 1f);
    }

    public int BufferedMs
    {
        get
        {
            lock (_ringLock)
            {
                int denom = Math.Max(_sampleRate * _channels, 1);
                return (int)(_ringCount * 1000L / denom);
            }
        }
    }

    // ── Media Foundation AAC Decoder GUIDs ─────────────────────────────────

    private static readonly Guid CLSID_CMSAACDecMFT             = new("32D186A7-218F-4C75-8876-DD77273A8999");
    private static readonly Guid MfMediaTypeAudio               = new("73647561-0000-0010-8000-00aa00389b71");
    private static readonly Guid MFAudioFormat_AAC              = new("00001610-0000-0010-8000-00aa00389b71");
    private static readonly Guid MFAudioFormat_Float            = new("00000003-0000-0010-8000-00aa00389b71");
    private static readonly Guid MFAudioFormat_PCM              = new("00000001-0000-0010-8000-00aa00389b71");

    private static readonly Guid MF_MT_MAJOR_TYPE               = new("48eba18e-f8c9-4687-bf11-0a74c9f96a8f");
    private static readonly Guid MF_MT_SUBTYPE                  = new("f7e34c9a-42e8-4714-b74b-cb29d72c35e5");
    private static readonly Guid MF_MT_AUDIO_SAMPLES_PER_SECOND = new("5faeeae7-0290-4c31-9e8a-c534f68d9dba");
    private static readonly Guid MF_MT_AUDIO_NUM_CHANNELS       = new("37eab8d7-9f43-41bb-9e29-79718b1accfb");
    private static readonly Guid MF_MT_AUDIO_BITS_PER_SAMPLE    = new("f2deb57f-4009-4497-b647-7359de047294");
    private static readonly Guid MF_MT_AAC_PAYLOAD_TYPE         = new("bfbabe79-7434-4d1c-94f0-72a3b9e17188");

    private const int MF_E_TRANSFORM_NEED_MORE_INPUT = unchecked((int)0xC00D6D72);
    private const int MF_E_TRANSFORM_STREAM_CHANGE   = unchecked((int)0xC00D6D61);
    private const int MFT_OUTPUT_STREAM_PROVIDES_SAMPLES = 0x00000100;

    // ── Lifecycle ───────────────────────────────────────────────────────────

    public void Start(int sampleRate = 48000, int channels = 2)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (_running) return;

        MfVideoDecoder.EnsureMediaFoundationStarted();

        _sampleRate = sampleRate > 0 ? sampleRate : 48000;
        _channels = channels > 0 ? channels : 2;

        lock (_ringLock)
        {
            int capSamples = _sampleRate * _channels / 4; // 250ms ring
            _ringBuffer = new float[Math.Max(capSamples, 4096)];
            _ringReadPos = 0;
            _ringWritePos = 0;
            _ringCount = 0;
            _maxBufferSamples = (_sampleRate * _channels * 45) / 1000;   // 45ms drift cap
            _targetTrimSamples = (_sampleRate * _channels * 10) / 1000;  // 10ms trim target
            _needsFadeIn = true;
        }

        InitAacDecoder(_sampleRate, _channels);

        _stopEvent?.Dispose();
        _audioReadyEvent?.Dispose();
        _stopEvent = new AutoResetEvent(false);
        _audioReadyEvent = new AutoResetEvent(false);

        _running = true;
        _renderThread = new Thread(RenderLoop)
        {
            Name = "WASAPI-AudioRender",
            IsBackground = true,
            Priority = ThreadPriority.AboveNormal,
        };
        _renderThread.Start();
    }

    public void Stop()
    {
        if (!_running) return;
        _running = false;
        _stopEvent?.Set();
        _renderThread?.Join(1000);
        _renderThread = null;

        ReleaseAacDecoder();

        lock (_ringLock)
        {
            _ringReadPos = 0;
            _ringWritePos = 0;
            _ringCount = 0;
        }
    }

    // ── Media Foundation ADTS AAC Decoder ───────────────────────────────────

    private void InitAacDecoder(int sampleRate, int channels)
    {
        lock (_decLock)
        {
            ReleaseAacDecoderUnsafe();

            try
            {
                int hr = CoCreateInstance(
                    CLSID_CMSAACDecMFT,
                    nint.Zero,
                    CLSCTX_INPROC_SERVER,
                    IID_IMFTransform,
                    out nint pMft);

                if (hr < 0 || pMft == nint.Zero)
                {
                    Debug.WriteLine($"[WasapiAudioPlayer] CoCreateInstance(CLSID_CMSAACDecMFT) failed: 0x{hr:X8}");
                    return;
                }

                _aacDecoder = new IMFTransform(pMft);

                // Input: ADTS-framed AAC-LC (MF_MT_AAC_PAYLOAD_TYPE = 1)
                using var inType = MediaFactory.MFCreateMediaType();
                inType.Set(MF_MT_MAJOR_TYPE, MfMediaTypeAudio);
                inType.Set(MF_MT_SUBTYPE, MFAudioFormat_AAC);
                inType.Set(MF_MT_AUDIO_SAMPLES_PER_SECOND, (uint)sampleRate);
                inType.Set(MF_MT_AUDIO_NUM_CHANNELS, (uint)channels);
                inType.Set(MF_MT_AAC_PAYLOAD_TYPE, 1u); // 1 = ADTS
                _aacDecoder.SetInputType(0, inType, 0);

                // Output: prefer 32-bit IEEE Float (matches WASAPI mix natively)
                ConfigureAacOutputType(_aacDecoder, sampleRate, channels);

                _aacDecoder.ProcessMessage(TMessageType.MessageNotifyBeginStreaming, UIntPtr.Zero);
                _aacDecoder.ProcessMessage(TMessageType.MessageNotifyStartOfStream, UIntPtr.Zero);
                _decoderReady = true;

                Debug.WriteLine($"[WasapiAudioPlayer] MF AAC decoder ready: {sampleRate}Hz {channels}ch float={_decoderOutputsFloat}");
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"[WasapiAudioPlayer] AAC decoder init failed: {ex.Message}");
                ReleaseAacDecoderUnsafe();
            }
        }
    }

    private void ConfigureAacOutputType(IMFTransform decoder, int sampleRate, int channels)
    {
        try
        {
            using var floatType = MediaFactory.MFCreateMediaType();
            floatType.Set(MF_MT_MAJOR_TYPE, MfMediaTypeAudio);
            floatType.Set(MF_MT_SUBTYPE, MFAudioFormat_Float);
            floatType.Set(MF_MT_AUDIO_SAMPLES_PER_SECOND, (uint)sampleRate);
            floatType.Set(MF_MT_AUDIO_NUM_CHANNELS, (uint)channels);
            floatType.Set(MF_MT_AUDIO_BITS_PER_SAMPLE, 32u);
            decoder.SetOutputType(0, floatType, 0);
            _decoderOutputsFloat = true;
        }
        catch
        {
            using var pcmType = MediaFactory.MFCreateMediaType();
            pcmType.Set(MF_MT_MAJOR_TYPE, MfMediaTypeAudio);
            pcmType.Set(MF_MT_SUBTYPE, MFAudioFormat_PCM);
            pcmType.Set(MF_MT_AUDIO_SAMPLES_PER_SECOND, (uint)sampleRate);
            pcmType.Set(MF_MT_AUDIO_NUM_CHANNELS, (uint)channels);
            pcmType.Set(MF_MT_AUDIO_BITS_PER_SAMPLE, 16u);
            decoder.SetOutputType(0, pcmType, 0);
            _decoderOutputsFloat = false;
        }
    }

    private void ReleaseAacDecoder()
    {
        lock (_decLock)
        {
            ReleaseAacDecoderUnsafe();
        }
    }

    private void ReleaseAacDecoderUnsafe()
    {
        if (_decoderReady && _aacDecoder != null)
        {
            try
            {
                _aacDecoder.ProcessMessage(TMessageType.MessageNotifyEndOfStream, UIntPtr.Zero);
                _aacDecoder.ProcessMessage(TMessageType.MessageNotifyEndStreaming, UIntPtr.Zero);
            }
            catch { }
        }
        _decoderReady = false;
        _aacDecoder?.Dispose();
        _aacDecoder = null;
    }

    // ── Input Push APIs ─────────────────────────────────────────────────────

    /// <summary>
    /// Feeds an ADTS-framed AAC-LC packet (binary FrameType 0x03 payload) into the
    /// Media Foundation AAC decoder and queues decoded float32 PCM into the WASAPI ring buffer.
    /// </summary>
    public void PushAdtsAac(ReadOnlySpan<byte> adtsPacket)
    {
        if (!_running || adtsPacket.Length < 7) return;

        lock (_decLock)
        {
            if (!_decoderReady || _aacDecoder == null) return;

            try
            {
                using var inBuf = MediaFactory.MFCreateMemoryBuffer(adtsPacket.Length);
                inBuf.Lock(out nint dst, out _, out _);
                try
                {
                    unsafe
                    {
                        fixed (byte* src = adtsPacket)
                        {
                            Buffer.MemoryCopy(src, (void*)dst, adtsPacket.Length, adtsPacket.Length);
                        }
                    }
                }
                finally
                {
                    inBuf.Unlock();
                }
                inBuf.CurrentLength = adtsPacket.Length;

                using var inSample = MediaFactory.MFCreateSample();
                inSample.AddBuffer(inBuf);

                _aacDecoder.ProcessInput(0, inSample, 0);
                DrainAacOutputs();
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"[WasapiAudioPlayer] PushAdtsAac error: {ex.Message}");
            }
        }
    }

    private void DrainAacOutputs()
    {
        if (_aacDecoder == null) return;

        for (int iter = 0; iter < 8; iter++)
        {
            var streamInfo = _aacDecoder.GetOutputStreamInfo(0);
            bool mftAllocates = (streamInfo.Flags & MFT_OUTPUT_STREAM_PROVIDES_SAMPLES) != 0;

            IMFSample? outSample = null;
            if (!mftAllocates)
            {
                int bufSize = Math.Max(streamInfo.Size, 16384);
                using var outBuf = MediaFactory.MFCreateMemoryBuffer(bufSize);
                outSample = MediaFactory.MFCreateSample();
                outSample.AddBuffer(outBuf);
            }

            var dataBuffer = new OutputDataBuffer
            {
                StreamID = 0,
                Sample = outSample,
                Status = 0,
                Events = null,
            };

            var hr = _aacDecoder.ProcessOutput(ProcessOutputFlags.None, 1, ref dataBuffer, out _);

            if (hr.Code == MF_E_TRANSFORM_NEED_MORE_INPUT)
            {
                outSample?.Dispose();
                break;
            }

            if (hr.Code == MF_E_TRANSFORM_STREAM_CHANGE)
            {
                outSample?.Dispose();
                try
                {
                    ConfigureAacOutputType(_aacDecoder, _sampleRate, _channels);
                    continue;
                }
                catch
                {
                    break;
                }
            }

            if (hr.Failure)
            {
                outSample?.Dispose();
                break;
            }

            var produced = dataBuffer.Sample;
            if (produced == null) break;

            try
            {
                using var resBuf = produced.ConvertToContiguousBuffer();
                resBuf.Lock(out nint pData, out _, out int byteLen);
                try
                {
                    if (pData != nint.Zero && byteLen > 0)
                    {
                        unsafe
                        {
                            if (_decoderOutputsFloat)
                            {
                                var span = new ReadOnlySpan<float>((void*)pData, byteLen / sizeof(float));
                                WriteToRingBuffer(span);
                            }
                            else
                            {
                                var pcm16 = new ReadOnlySpan<short>((void*)pData, byteLen / sizeof(short));
                                WritePcm16ToRingBuffer(pcm16);
                            }
                        }
                    }
                }
                finally
                {
                    resBuf.Unlock();
                }
            }
            finally
            {
                produced.Dispose();
            }
        }
    }

    /// <summary>
    /// Optional raw 16-bit interleaved PCM input path.
    /// </summary>
    public void PushPcm16(ReadOnlySpan<byte> pcm16Interleaved)
    {
        if (!_running || pcm16Interleaved.Length < 2) return;
        var shorts = MemoryMarshal.Cast<byte, short>(pcm16Interleaved);
        WritePcm16ToRingBuffer(shorts);
    }

    private void WritePcm16ToRingBuffer(ReadOnlySpan<short> pcm16)
    {
        const float scale = 1.0f / 32768.0f;
        lock (_ringLock)
        {
            int cap = _ringBuffer.Length;
            for (int i = 0; i < pcm16.Length; i++)
            {
                if (_ringCount >= cap)
                {
                    _ringReadPos = (_ringReadPos + 1) % cap;
                    _ringCount--;
                }
                _ringBuffer[_ringWritePos] = pcm16[i] * scale;
                _ringWritePos = (_ringWritePos + 1) % cap;
                _ringCount++;
            }
            TrimDriftLocked();
        }
    }

    private void WriteToRingBuffer(ReadOnlySpan<float> samples)
    {
        lock (_ringLock)
        {
            int cap = _ringBuffer.Length;
            for (int i = 0; i < samples.Length; i++)
            {
                if (_ringCount >= cap)
                {
                    _ringReadPos = (_ringReadPos + 1) % cap;
                    _ringCount--;
                }
                _ringBuffer[_ringWritePos] = samples[i];
                _ringWritePos = (_ringWritePos + 1) % cap;
                _ringCount++;
            }
            TrimDriftLocked();
        }
    }

    private void TrimDriftLocked()
    {
        if (_ringCount > _maxBufferSamples)
        {
            int drop = _ringCount - _targetTrimSamples;
            // Keep channel alignment
            drop -= drop % Math.Max(_channels, 1);
            if (drop > 0)
            {
                _ringReadPos = (_ringReadPos + drop) % _ringBuffer.Length;
                _ringCount -= drop;
                _needsFadeIn = true;
            }
        }
    }

    // ── WASAPI Shared-Mode Event-Driven Render Thread ───────────────────────

    private void RenderLoop()
    {
        IMMDeviceEnumerator? enumerator = null;
        IMMDevice? device = null;
        IAudioClient? audioClient = null;
        IAudioClient3? audioClient3 = null;
        IAudioRenderClient? renderClient = null;
        nint pFormat = nint.Zero;
        nint pMixFormat = nint.Zero;
        nint mmcssHandle = nint.Zero;

        try
        {
            // Elevate to Windows MMCSS "Pro Audio" for deterministic <8ms scheduling
            uint mmcssTaskIndex = 0;
            try { mmcssHandle = AvSetMmThreadCharacteristicsW("Pro Audio", ref mmcssTaskIndex); } catch { }

            var enumType = Type.GetTypeFromCLSID(new Guid("BCDE0395-E52F-467C-8E3D-C4579291692E"));
            if (enumType == null) return;

            enumerator = (IMMDeviceEnumerator)Activator.CreateInstance(enumType)!;
            int hr = enumerator.GetDefaultAudioEndpoint(0 /* eRender */, 1 /* eMultimedia */, out var devObj);
            if (hr < 0 || devObj == null) return;
            device = (IMMDevice)devObj;

            const uint AUDCLNT_STREAMFLAGS_EVENTCALLBACK       = 0x00040000;
            const uint AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM      = 0x80000000;
            const uint AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY = 0x08000000;

            bool initializedLowLatency = false;

            // 1. Prefer IAudioClient3 (Windows 10+) minimum shared-mode engine period (~2.67ms-5ms)
            //    when the endpoint mix format already matches our 48kHz stereo float32 stream.
            var iidAudioClient3 = new Guid("7ED4EE07-8E67-4CD4-8C1A-2B7A5987AD42");
            if (device.Activate(ref iidAudioClient3, 23 /* CLSCTX_ALL */, nint.Zero, out var client3Obj) >= 0 && client3Obj != null)
            {
                audioClient3 = (IAudioClient3)client3Obj;
                audioClient = (IAudioClient)client3Obj;
                if (audioClient3.GetMixFormat(out pMixFormat) >= 0 && pMixFormat != nint.Zero)
                {
                    var mix = Marshal.PtrToStructure<WAVEFORMATEX>(pMixFormat);
                    bool isFloat32 = mix.wBitsPerSample == 32 && (mix.wFormatTag == 3 || mix.wFormatTag == 0xFFFE);
                    if (isFloat32 && mix.nSamplesPerSec == (uint)_sampleRate && mix.nChannels == (ushort)_channels)
                    {
                        if (audioClient3.GetSharedModeEnginePeriod(pMixFormat, out _, out _, out uint minPeriod, out _) >= 0 && minPeriod > 0)
                        {
                            hr = audioClient3.InitializeSharedAudioStream(AUDCLNT_STREAMFLAGS_EVENTCALLBACK, minPeriod, pMixFormat, Guid.Empty);
                            if (hr >= 0)
                            {
                                initializedLowLatency = true;
                                Debug.WriteLine($"[WasapiAudioPlayer] IAudioClient3 low-latency period={minPeriod} frames ({minPeriod * 1000.0 / _sampleRate:F2}ms)");
                            }
                        }
                    }
                }

                if (!initializedLowLatency)
                {
                    Marshal.ReleaseComObject(audioClient3);
                    audioClient3 = null;
                    audioClient = null;
                }
            }

            // 2. Fallback: standard IAudioClient with automatic WASAPI resampling (AUTOCONVERTPCM)
            if (!initializedLowLatency)
            {
                var iidAudioClient = new Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2");
                hr = device.Activate(ref iidAudioClient, 23 /* CLSCTX_ALL */, nint.Zero, out var clientObj);
                if (hr < 0 || clientObj == null) return;
                audioClient = (IAudioClient)clientObj;

                var fmt = new WAVEFORMATEX
                {
                    wFormatTag = 3, // WAVE_FORMAT_IEEE_FLOAT
                    nChannels = (ushort)_channels,
                    nSamplesPerSec = (uint)_sampleRate,
                    wBitsPerSample = 32,
                    nBlockAlign = (ushort)(_channels * 4),
                    nAvgBytesPerSec = (uint)(_sampleRate * _channels * 4),
                    cbSize = 0,
                };

                pFormat = Marshal.AllocCoTaskMem(Marshal.SizeOf<WAVEFORMATEX>());
                Marshal.StructureToPtr(fmt, pFormat, false);

                audioClient.GetDevicePeriod(out long defaultPeriod, out long minPeriod);
                long bufferDuration = minPeriod > 0 ? minPeriod * 2 : (defaultPeriod > 0 ? defaultPeriod : 100_000);

                uint streamFlags = AUDCLNT_STREAMFLAGS_EVENTCALLBACK
                                 | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM
                                 | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY;

                hr = audioClient.Initialize(0 /* AUDCLNT_SHAREMODE_SHARED */, streamFlags, bufferDuration, 0, pFormat, Guid.Empty);
                if (hr < 0)
                {
                    Debug.WriteLine($"[WasapiAudioPlayer] IAudioClient.Initialize failed: 0x{hr:X8}");
                    return;
                }
            }

            hr = audioClient!.GetBufferSize(out uint bufferFrameCount);
            if (hr < 0 || bufferFrameCount == 0) return;

            hr = audioClient.SetEventHandle(_audioReadyEvent!.SafeWaitHandle.DangerousGetHandle());
            if (hr < 0) return;

            var iidRenderClient = new Guid("F294ACFC-3146-4483-A7BF-ADDCA7C260E2");
            hr = audioClient.GetService(ref iidRenderClient, out var renderObj);
            if (hr < 0 || renderObj == null) return;
            renderClient = (IAudioRenderClient)renderObj;

            // Prime with silence before starting
            if (renderClient.GetBuffer(bufferFrameCount, out _) >= 0)
            {
                renderClient.ReleaseBuffer(bufferFrameCount, 0x02 /* AUDCLNT_BUFFERFLAGS_SILENT */);
            }

            audioClient.Start();
            Debug.WriteLine($"[WasapiAudioPlayer] WASAPI render started: {_sampleRate}Hz {_channels}ch bufFrames={bufferFrameCount}");

            var waitHandles = new WaitHandle[] { _stopEvent!, _audioReadyEvent! };

            while (_running)
            {
                int idx = WaitHandle.WaitAny(waitHandles, 100);
                if (idx == 0 || !_running) break;

                if (audioClient.GetCurrentPadding(out uint padding) < 0) break;
                uint framesAvailable = bufferFrameCount > padding ? bufferFrameCount - padding : 0;
                if (framesAvailable == 0) continue;

                if (renderClient.GetBuffer(framesAvailable, out nint pData) < 0) continue;

                uint releaseFlags = 0;
                int samplesNeeded = (int)framesAvailable * _channels;

                if (_muted || _volume <= 0.0001f)
                {
                    // Drain ring buffer while muted so audio stays in sync when unmuted
                    lock (_ringLock)
                    {
                        int discard = Math.Min(_ringCount, samplesNeeded);
                        _ringReadPos = (_ringReadPos + discard) % _ringBuffer.Length;
                        _ringCount -= discard;
                    }
                    releaseFlags = 0x02; // AUDCLNT_BUFFERFLAGS_SILENT
                }
                else
                {
                    int readCount = ReadFromRingBufferToNative(pData, samplesNeeded, _volume);
                    if (readCount == 0)
                    {
                        releaseFlags = 0x02; // Underrun -> clean silence
                    }
                }

                renderClient.ReleaseBuffer(framesAvailable, releaseFlags);
            }

            try { audioClient.Stop(); } catch { }
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[WasapiAudioPlayer] RenderLoop error: {ex.Message}");
        }
        finally
        {
            if (pFormat != nint.Zero) Marshal.FreeCoTaskMem(pFormat);
            if (pMixFormat != nint.Zero) Marshal.FreeCoTaskMem(pMixFormat);
            if (renderClient != null) Marshal.ReleaseComObject(renderClient);
            if (audioClient3 != null) Marshal.ReleaseComObject(audioClient3);
            else if (audioClient != null) Marshal.ReleaseComObject(audioClient);
            if (device != null) Marshal.ReleaseComObject(device);
            if (enumerator != null) Marshal.ReleaseComObject(enumerator);
            if (mmcssHandle != nint.Zero)
            {
                try { AvRevertMmThreadCharacteristics(mmcssHandle); } catch { }
            }
        }
    }

    private unsafe int ReadFromRingBufferToNative(nint dstPtr, int samplesNeeded, float volume)
    {
        float* dst = (float*)dstPtr;
        lock (_ringLock)
        {
            if (_ringCount == 0)
            {
                _needsFadeIn = true;
                return 0;
            }

            int toRead = Math.Min(_ringCount, samplesNeeded);
            int cap = _ringBuffer.Length;
            int fadeSamples = _needsFadeIn ? Math.Min(toRead, Math.Max(_channels * 96, 1)) : 0; // ~2ms @ 48kHz

            for (int i = 0; i < toRead; i++)
            {
                float s = _ringBuffer[_ringReadPos] * volume;
                if (i < fadeSamples)
                {
                    s *= (float)i / fadeSamples;
                }
                dst[i] = s;
                _ringReadPos = (_ringReadPos + 1) % cap;
            }

            _needsFadeIn = false;
            _ringCount -= toRead;

            // Zero-fill any tail on partial underrun and arm fade-in for next packet
            if (toRead < samplesNeeded)
            {
                for (int i = toRead; i < samplesNeeded; i++)
                {
                    dst[i] = 0f;
                }
                _needsFadeIn = true;
            }

            return toRead;
        }
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        Stop();
        _stopEvent?.Dispose();
        _audioReadyEvent?.Dispose();
        _stopEvent = null;
        _audioReadyEvent = null;
    }

    // ── COM / P/Invoke Declarations ────────────────────────────────────────

    private static readonly Guid IID_IMFTransform = new("bf94c121-5b05-4e6f-8000-ba598961414d");
    private const uint CLSCTX_INPROC_SERVER = 1;

    [DllImport("ole32.dll", ExactSpelling = true)]
    private static extern int CoCreateInstance(
        in Guid rclsid,
        nint pUnkOuter,
        uint dwClsContext,
        in Guid riid,
        out nint ppv);

    [DllImport("avrt.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern nint AvSetMmThreadCharacteristicsW(string taskName, ref uint taskIndex);

    [DllImport("avrt.dll", SetLastError = true)]
    private static extern bool AvRevertMmThreadCharacteristics(nint avrtHandle);

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDeviceEnumerator
    {
        [PreserveSig] int EnumAudioEndpoints(int dataFlow, uint stateMask, [MarshalAs(UnmanagedType.IUnknown)] out object devices);
        [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, [MarshalAs(UnmanagedType.IUnknown)] out object endpoint);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDevice
    {
        [PreserveSig] int Activate(ref Guid iid, uint dwClsCtx, nint activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object ppInterface);
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

    [ComImport, Guid("7ED4EE07-8E67-4CD4-8C1A-2B7A5987AD42"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioClient3
    {
        // IAudioClient (12)
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
        // IAudioClient2 (3)
        [PreserveSig] int IsOffloadCapable(int category, out bool isOffloadCapable);
        [PreserveSig] int SetClientProperties(nint pProperties);
        [PreserveSig] int GetBufferSizeLimits(nint pFormat, bool eventDriven, out long hnsMinBufferDuration, out long hnsMaxBufferDuration);
        // IAudioClient3 (3)
        [PreserveSig] int GetSharedModeEnginePeriod(nint pFormat, out uint defaultPeriodInFrames, out uint fundamentalPeriodInFrames, out uint minPeriodInFrames, out uint maxPeriodInFrames);
        [PreserveSig] int GetCurrentSharedModeEnginePeriod(out nint ppFormat, out uint currentPeriodInFrames);
        [PreserveSig] int InitializeSharedAudioStream(uint streamFlags, uint periodInFrames, nint pFormat, [MarshalAs(UnmanagedType.LPStruct)] Guid audioSessionGuid);
    }

    [ComImport, Guid("F294ACFC-3146-4483-A7BF-ADDCA7C260E2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioRenderClient
    {
        [PreserveSig] int GetBuffer(uint numFramesRequested, out nint ppData);
        [PreserveSig] int ReleaseBuffer(uint numFramesWritten, uint dwFlags);
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
