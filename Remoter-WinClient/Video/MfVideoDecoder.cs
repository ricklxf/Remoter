using System.Diagnostics;
using System.Runtime.InteropServices;
using Vortice.Direct3D11;
using Vortice.MediaFoundation;

namespace RemoterWinClient;

/// <summary>
/// Native Windows Media Foundation H.264 &amp; HEVC/H.265 hardware video decoder.
/// Uses IMFDXGIDeviceManager bound to D3D11Renderer's ID3D11Device for true GPU
/// zero-copy NV12 ID3D11Texture2D output, with automatic fallback to CPU-copy NV12
/// when DXVA hardware decoding is unavailable.
/// </summary>
public sealed class MfVideoDecoder : IDisposable
{
    private static int _mfStarted;

    private readonly object _lock = new();
    private IMFTransform? _transform;
    private nint _dxgiDeviceManagerPtr;
    private uint _dxgiResetToken;

    private bool _streaming;
    private bool _waitingForKeyframe = true;
    private bool _disposed;
    private int _outputStride;

    // Cached Annex-B parameter sets (UU VideoHardwareDecoder pattern) for instant
    // recovery when a keyframe arrives without repeated inline VPS/SPS/PPS.
    private byte[]? _cachedVps;
    private byte[]? _cachedSps;
    private byte[]? _cachedPps;
    private byte[]? _prependedBuf;

    public Action<ID3D11Texture2D, int, int, int>? OnGpuNv12Frame;
    public Action<nint, int, int, int>? OnCpuNv12Frame;
    public Action<int, int>? OnResolutionChanged;
    public Action<bool>? OnColorRangeChanged;
    public Action? OnKeyframeNeeded;

    public VideoCodecType Codec { get; private set; } = VideoCodecType.H264;
    public bool IsHardware { get; private set; }
    public bool IsGpuZeroCopy { get; private set; }
    public bool IsFullRange { get; private set; }
    public int Width { get; private set; }
    public int Height { get; private set; }
    public double LastDecodeMs { get; private set; }
    public long DecodedFrames { get; private set; }
    public long DroppedFrames { get; private set; }

    // ── Media Foundation Constants & GUIDs (mfapi.h / mftransform.h) ───────

    private static readonly Guid MftCategoryVideoDecoder = new("d6c02d4b-6833-45b4-971a-05a4b04bab91");
    private static readonly Guid MfMediaTypeVideo        = new("73646976-0000-0010-8000-00aa00389b71");
    private static readonly Guid VideoFormatHevc         = new("43564548-0000-0010-8000-00aa00389b71"); // 'HEVC'

    private static readonly Guid MF_MT_MAJOR_TYPE     = new("48eba18e-f8c9-4687-bf11-0a74c9f96a8f");
    private static readonly Guid MF_MT_SUBTYPE        = new("f7e34c9a-42e8-4714-b74b-cb29d72c35e5");
    private static readonly Guid MF_MT_FRAME_SIZE          = new("1652c33d-d6b2-4012-b834-72030849a37d");
    private static readonly Guid MF_MT_INTERLACE_MODE      = new("e2724bb8-e676-4806-b4b2-a8d6efb44ccd");
    private static readonly Guid MF_MT_DEFAULT_STRIDE      = new("644b4e48-1e02-4516-b0eb-c01ca9d49ac6");
    private static readonly Guid MF_MT_VIDEO_NOMINAL_RANGE = new("c21b8ee5-b956-4071-8daf-325edf5cab11");
    private const uint MFNominalRange_0_255 = 1;

    // Low-latency & D3D11 decoder attributes
    private static readonly Guid MF_LOW_LATENCY                                = new("9c27891a-ed7a-40e1-88e8-b22727a024ee");
    private static readonly Guid MFT_DECODER_EXPOSE_OUTPUT_TYPES_IN_NATIVE_ORDER = new("ef80833f-f8fa-44d9-80d8-41ed6232670c");

    private static readonly Guid IID_IMFDXGIBuffer   = new("e7174cfa-1c9e-48b1-8866-626226bfc258");
    private static readonly Guid IID_ID3D11Texture2D = new("6f15aaf2-d208-4e89-9ab4-489535d34f9c");

    private const uint MFVideoInterlace_Progressive = 2;

    private const uint MFT_ENUM_FLAG_SYNCMFT       = 0x00000001;
    private const uint MFT_ENUM_FLAG_ASYNCMFT      = 0x00000002;
    private const uint MFT_ENUM_FLAG_HARDWARE      = 0x00000004;
    private const uint MFT_ENUM_FLAG_SORTANDFILTER = 0x00000040;

    private const int MFT_MESSAGE_COMMAND_FLUSH   = 0x00000000;
    private const int MFT_MESSAGE_SET_D3D_MANAGER = 0x00000002;

    private const int MF_E_TRANSFORM_NEED_MORE_INPUT = unchecked((int)0xC00D6D72);
    private const int MF_E_TRANSFORM_STREAM_CHANGE   = unchecked((int)0xC00D6D61);
    private const int MF_E_NO_MORE_TYPES             = unchecked((int)0xC00D36B9);
    private const int MFT_OUTPUT_STREAM_PROVIDES_SAMPLES = 0x00000100;

    // ── Startup Helper ──────────────────────────────────────────────────────

    public static void EnsureMediaFoundationStarted()
    {
        if (Interlocked.CompareExchange(ref _mfStarted, 1, 0) == 0)
        {
            MediaFactory.MFStartup();
        }
    }

    // ── Initialization ──────────────────────────────────────────────────────

    public void Initialize(VideoCodecType codec, int width, int height, ID3D11Device? d3d11Device = null)
    {
        if (codec == VideoCodecType.Jpeg)
            throw new ArgumentException("Use JpegDecoder for JPEG streams.", nameof(codec));

        EnsureMediaFoundationStarted();

        lock (_lock)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            ReleaseInternal();

            Codec = codec;
            Width = Math.Max(width, 2);
            Height = Math.Max(height, 2);
            _outputStride = Width;
            _waitingForKeyframe = true;

            Guid inputSubtype = codec == VideoCodecType.H265 ? VideoFormatHevc : VideoFormatGuids.H264;

            // 1. Try DXVA hardware / D3D11-aware decoder first
            bool ok = false;
            if (d3d11Device != null)
            {
                ok = TryCreateDecoder(inputSubtype, Width, Height, d3d11Device, preferHardware: true);
            }

            // 2. Fallback: synchronous MFT (Windows built-in H.264/HEVC decoder) with D3D11 manager
            // Note: Windows' inbox CMSH264DecoderMFT / HEVC decoder is registered as SYNCMFT
            // even though it supports DXVA2/D3D11 hardware acceleration via SET_D3D_MANAGER!
            if (!ok && d3d11Device != null)
            {
                ok = TryCreateDecoder(inputSubtype, Width, Height, d3d11Device, preferHardware: false);
            }

            // 3. Final fallback: CPU-only software decode (no D3D11 device manager)
            if (!ok)
            {
                ok = TryCreateDecoder(inputSubtype, Width, Height, d3d11Device: null, preferHardware: false);
            }

            if (!ok || _transform == null)
            {
                throw new InvalidOperationException($"Failed to initialize Media Foundation {codec} decoder.");
            }

            _transform.ProcessMessage(TMessageType.MessageNotifyBeginStreaming, UIntPtr.Zero);
            _transform.ProcessMessage(TMessageType.MessageNotifyStartOfStream, UIntPtr.Zero);
            _streaming = true;

            Debug.WriteLine($"[MfVideoDecoder] Ready: {codec} {Width}x{Height} hw={IsHardware} gpuZeroCopy={IsGpuZeroCopy}");
        }
    }

    private bool TryCreateDecoder(Guid inputSubtype, int width, int height, ID3D11Device? d3d11Device, bool preferHardware)
    {
        try
        {
            // Always use synchronous MFTs for synchronous ProcessInput/ProcessOutput:
            // Microsoft's built-in H.264/HEVC Video Decoder MFT is a sync MFT that
            // automatically enables DXVA2/D3D11 hardware acceleration when bound to IMFDXGIDeviceManager.
            // Async MFTs require IMFMediaEventGenerator and would fail or stall in synchronous mode.
            uint flags = MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_SORTANDFILTER;

            MediaFactory.MFTEnumEx(
                MftCategoryVideoDecoder,
                flags,
                inputType: new RegisterTypeInfo { GuidMajorType = MfMediaTypeVideo, GuidSubtype = inputSubtype },
                outputType: null,
                out nint pppActivate,
                out uint count);

            if (count == 0 || pppActivate == nint.Zero)
            {
                return false;
            }

            try
            {
                for (uint i = 0; i < count; i++)
                {
                    nint pAct = Marshal.ReadIntPtr(pppActivate, (int)i * IntPtr.Size);
                    if (pAct == nint.Zero) continue;

                    using var activate = new IMFActivate(pAct);
                    if (_transform != null) continue; // Release remaining activates cleanly

                    try
                    {
                        var mft = activate.ActivateObject<IMFTransform>();
                        if (ConfigureTransform(mft, inputSubtype, width, height, d3d11Device))
                        {
                            _transform = mft;
                        }
                        else
                        {
                            mft.Dispose();
                        }
                    }
                    catch
                    {
                        // Try next candidate
                    }
                }
            }
            finally
            {
                Marshal.FreeCoTaskMem(pppActivate);
            }

            return _transform != null;
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[MfVideoDecoder] TryCreateDecoder(preferHw={preferHardware}, d3d={d3d11Device != null}) failed: {ex.Message}");
            return false;
        }
    }

    private bool ConfigureTransform(IMFTransform mft, Guid inputSubtype, int width, int height, ID3D11Device? d3d11Device)
    {
        nint pDxgiMgr = nint.Zero;
        bool d3dBound = false;

        try
        {
            // 1. Enable low-latency & native output order on MFT attributes
            TryConfigureLowLatency(mft);

            // 2. Bind IMFDXGIDeviceManager if a D3D11 device was provided
            if (d3d11Device != null)
            {
                int hrMgr = MFCreateDXGIDeviceManager(out uint resetToken, out pDxgiMgr);
                if (hrMgr >= 0 && pDxgiMgr != nint.Zero)
                {
                    var mgr = (IMFDXGIDeviceManagerCom)Marshal.GetObjectForIUnknown(pDxgiMgr);
                    int hrReset = mgr.ResetDevice(d3d11Device.NativePointer, resetToken);
                    if (hrReset >= 0)
                    {
                        try
                        {
                            mft.ProcessMessage((TMessageType)MFT_MESSAGE_SET_D3D_MANAGER, (nuint)pDxgiMgr);
                            d3dBound = true;
                            _dxgiResetToken = resetToken;
                        }
                        catch
                        {
                            // MFT rejected D3D manager — continue in CPU mode if needed
                            Marshal.Release(pDxgiMgr);
                            pDxgiMgr = nint.Zero;
                        }
                    }
                    else
                    {
                        Marshal.Release(pDxgiMgr);
                        pDxgiMgr = nint.Zero;
                    }
                }
            }

            // 3. Set Input Media Type (H.264 or HEVC Annex-B)
            using var inType = MediaFactory.MFCreateMediaType();
            inType.Set(MF_MT_MAJOR_TYPE, MfMediaTypeVideo);
            inType.Set(MF_MT_SUBTYPE, inputSubtype);
            inType.Set(MF_MT_FRAME_SIZE, PackLong(width, height));
            inType.Set(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
            mft.SetInputType(0, inType, 0);

            // 4. Select NV12 Output Media Type
            if (!SelectNv12OutputType(mft, width, height))
            {
                if (pDxgiMgr != nint.Zero) Marshal.Release(pDxgiMgr);
                return false;
            }

            _dxgiDeviceManagerPtr = pDxgiMgr;
            IsGpuZeroCopy = d3dBound;
            IsHardware = d3dBound;
            return true;
        }
        catch
        {
            if (pDxgiMgr != nint.Zero) Marshal.Release(pDxgiMgr);
            return false;
        }
    }

    private static void TryConfigureLowLatency(IMFTransform mft)
    {
        try
        {
            var comMft = (IMFTransformCom)Marshal.GetObjectForIUnknown(mft.NativePointer);
            if (comMft.GetAttributes(out nint pAttrs) >= 0 && pAttrs != nint.Zero)
            {
                using var attrs = new IMFAttributes(pAttrs);
                try { attrs.Set(MF_LOW_LATENCY, 1u); } catch { }
                try { attrs.Set(MFT_DECODER_EXPOSE_OUTPUT_TYPES_IN_NATIVE_ORDER, 1u); } catch { }
            }
        }
        catch
        {
            // Optional attributes — non-fatal
        }
    }

    private bool SelectNv12OutputType(IMFTransform mft, int fallbackWidth, int fallbackHeight)
    {
        try
        {
            var comMft = (IMFTransformCom)Marshal.GetObjectForIUnknown(mft.NativePointer);
            for (uint i = 0; i < 64; i++)
            {
                int hr = comMft.GetOutputAvailableType(0, i, out nint pType);
                if (hr == MF_E_NO_MORE_TYPES || hr < 0 || pType == nint.Zero)
                    break;

                using var outType = new IMFMediaType(pType);
                Guid subtype = TryGetGuid(outType, MF_MT_SUBTYPE);
                if (subtype == VideoFormatGuids.NV12)
                {
                    mft.SetOutputType(0, outType, 0);
                    ReadOutputGeometry(outType, fallbackWidth, fallbackHeight);
                    return true;
                }
            }
        }
        catch
        {
            // Fall through to explicit NV12 type creation
        }

        try
        {
            using var nv12Type = MediaFactory.MFCreateMediaType();
            nv12Type.Set(MF_MT_MAJOR_TYPE, MfMediaTypeVideo);
            nv12Type.Set(MF_MT_SUBTYPE, VideoFormatGuids.NV12);
            nv12Type.Set(MF_MT_FRAME_SIZE, PackLong(fallbackWidth, fallbackHeight));
            nv12Type.Set(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
            mft.SetOutputType(0, nv12Type, 0);
            Width = fallbackWidth;
            Height = fallbackHeight;
            _outputStride = fallbackWidth;
            return true;
        }
        catch
        {
            return false;
        }
    }

    private void ReadOutputGeometry(IMFMediaType outType, int fallbackWidth, int fallbackHeight)
    {
        try
        {
            ulong frameSize = outType.GetUInt64(MF_MT_FRAME_SIZE);
            int w = (int)(frameSize >> 32);
            int h = (int)(frameSize & 0xFFFFFFFF);
            if (w > 0 && h > 0)
            {
                Width = w;
                Height = h;
            }
            else
            {
                Width = fallbackWidth;
                Height = fallbackHeight;
            }
        }
        catch
        {
            Width = fallbackWidth;
            Height = fallbackHeight;
        }

        try
        {
            int stride = unchecked((int)outType.GetUInt32(MF_MT_DEFAULT_STRIDE));
            _outputStride = stride > 0 ? stride : Width;
        }
        catch
        {
            _outputStride = Width;
        }

        try
        {
            uint nominalRange = outType.GetUInt32(MF_MT_VIDEO_NOMINAL_RANGE);
            bool fullRange = nominalRange == MFNominalRange_0_255;
            if (fullRange != IsFullRange)
            {
                IsFullRange = fullRange;
                OnColorRangeChanged?.Invoke(fullRange);
            }
        }
        catch
        {
            // Default limited/studio range when attribute not present
        }
    }

    private static unsafe Guid TryGetGuid(IMFAttributes attrs, Guid key)
    {
        nint pAttr = attrs.NativePointer;
        if (pAttr == nint.Zero) return Guid.Empty;
        // IMFAttributes vtable slot 10 = GetGUID(REFGUID guidKey, GUID* pguidValue)
        nint* vtbl = *(nint**)pAttr;
        var getGuid = (delegate* unmanaged[Stdcall]<nint, Guid*, Guid*, int>)vtbl[10];
        Guid result = Guid.Empty;
        int hr = getGuid(pAttr, &key, &result);
        return hr >= 0 ? result : Guid.Empty;
    }

    // ── Decode ──────────────────────────────────────────────────────────────

    public bool Decode(ReadOnlySpan<byte> annexBData, bool isKeyframe, long timestampUs)
    {
        if (annexBData.IsEmpty) return false;

        lock (_lock)
        {
            if (_disposed || !_streaming || _transform == null) return false;

            // Inspect & cache Annex-B parameter sets (VPS/SPS/PPS) matching UU VideoHardwareDecoder
            InspectAndCacheParameterSets(annexBData, Codec, out bool hasKeyNal, out bool hasParamSets);

            if (_waitingForKeyframe)
            {
                if (!isKeyframe && !hasKeyNal)
                {
                    DroppedFrames++;
                    return false;
                }
                _waitingForKeyframe = false;
            }

            // If a keyframe arrives without inline VPS/SPS/PPS, prepend cached parameter sets
            ReadOnlySpan<byte> payload = annexBData;
            if ((isKeyframe || hasKeyNal) && !hasParamSets && HasCachedParameterSets(Codec))
            {
                payload = PrependCachedParameterSets(annexBData, Codec);
            }

            long t0 = Stopwatch.GetTimestamp();
            try
            {
                using var inBuf = MediaFactory.MFCreateMemoryBuffer(payload.Length);
                inBuf.Lock(out nint dst, out _, out _);
                try
                {
                    unsafe
                    {
                        fixed (byte* src = payload)
                        {
                            Buffer.MemoryCopy(src, (void*)dst, payload.Length, payload.Length);
                        }
                    }
                }
                finally
                {
                    inBuf.Unlock();
                }
                inBuf.CurrentLength = payload.Length;

                using var inSample = MediaFactory.MFCreateSample();
                inSample.AddBuffer(inBuf);
                inSample.SampleTime = timestampUs * 10L; // us -> 100ns

                _transform.ProcessInput(0, inSample, 0);

                bool emitted = DrainOutputs();
                if (emitted)
                {
                    long t1 = Stopwatch.GetTimestamp();
                    LastDecodeMs = (t1 - t0) * 1000.0 / Stopwatch.Frequency;
                    DecodedFrames++;
                }
                return emitted;
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"[MfVideoDecoder] Decode error: {ex.Message}");
                DroppedFrames++;
                _waitingForKeyframe = true;
                try { _transform.ProcessMessage((TMessageType)MFT_MESSAGE_COMMAND_FLUSH, UIntPtr.Zero); } catch { }
                OnKeyframeNeeded?.Invoke();
                return false;
            }
        }
    }

    private bool DrainOutputs()
    {
        if (_transform == null) return false;
        bool emittedAny = false;

        for (int iter = 0; iter < 8; iter++)
        {
            var streamInfo = _transform.GetOutputStreamInfo(0);
            bool mftAllocates = (streamInfo.Flags & MFT_OUTPUT_STREAM_PROVIDES_SAMPLES) != 0;

            IMFSample? outSample = null;
            if (!mftAllocates)
            {
                int bufSize = streamInfo.Size > 0 ? streamInfo.Size : Width * Height * 3 / 2;
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

            var hr = _transform.ProcessOutput(ProcessOutputFlags.None, 1, ref dataBuffer, out _);

            if (hr.Code == MF_E_TRANSFORM_NEED_MORE_INPUT)
            {
                outSample?.Dispose();
                break;
            }

            if (hr.Code == MF_E_TRANSFORM_STREAM_CHANGE)
            {
                outSample?.Dispose();
                int prevW = Width;
                int prevH = Height;
                if (SelectNv12OutputType(_transform, Width, Height))
                {
                    if (Width != prevW || Height != prevH)
                    {
                        Debug.WriteLine($"[MfVideoDecoder] Dynamic resolution change: {prevW}x{prevH} -> {Width}x{Height}");
                        OnResolutionChanged?.Invoke(Width, Height);
                    }
                    continue; // Retry ProcessOutput immediately with renegotiated output type
                }
                break;
            }

            if (hr.Failure)
            {
                outSample?.Dispose();
                Debug.WriteLine($"[MfVideoDecoder] ProcessOutput failed: 0x{hr.Code:X8}");
                break;
            }

            var produced = dataBuffer.Sample;
            if (produced == null) break;

            try
            {
                EmitDecodedSample(produced);
                emittedAny = true;
            }
            finally
            {
                produced.Dispose();
            }
        }

        return emittedAny;
    }

    private void EmitDecodedSample(IMFSample sample)
    {
        using var mediaBuf = sample.ConvertToContiguousBuffer();

        // 1. Try true GPU zero-copy path via IMFDXGIBuffer
        if (IsGpuZeroCopy && OnGpuNv12Frame != null)
        {
            Guid iidDxgiBuf = IID_IMFDXGIBuffer;
            int hrQi = Marshal.QueryInterface(mediaBuf.NativePointer, in iidDxgiBuf, out nint pDxgiBuf);
            if (hrQi >= 0 && pDxgiBuf != nint.Zero)
            {
                try
                {
                    var dxgiBuf = (IMFDXGIBufferCom)Marshal.GetObjectForIUnknown(pDxgiBuf);
                    Guid iidTex2d = IID_ID3D11Texture2D;
                    if (dxgiBuf.GetResource(ref iidTex2d, out nint pTex) >= 0 && pTex != nint.Zero)
                    {
                        dxgiBuf.GetSubresourceIndex(out uint subIdx);
                        using var texture = new ID3D11Texture2D(pTex);
                        OnGpuNv12Frame.Invoke(texture, (int)subIdx, Width, Height);
                        return;
                    }
                }
                finally
                {
                    Marshal.Release(pDxgiBuf);
                }
            }
        }

        // 2. Fallback: CPU-accessible NV12 buffer
        if (OnCpuNv12Frame != null)
        {
            mediaBuf.Lock(out nint pData, out _, out int curLen);
            try
            {
                if (pData != nint.Zero && curLen > 0)
                {
                    int stride = _outputStride > 0 ? _outputStride : Width;
                    OnCpuNv12Frame.Invoke(pData, stride, Width, Height);
                }
            }
            finally
            {
                mediaBuf.Unlock();
            }
        }
    }

    // ── Annex-B NAL Inspection & Parameter Set Cache (UU Pattern) ───────────

    private void InspectAndCacheParameterSets(
        ReadOnlySpan<byte> data,
        VideoCodecType codec,
        out bool hasKeyframeNal,
        out bool hasParamSets)
    {
        hasKeyframeNal = false;
        hasParamSets = false;
        int len = data.Length;
        if (len < 5) return;

        int pos = 0;
        while (pos < len - 3)
        {
            int scLen = MatchStartCode(data, pos);
            if (scLen == 0)
            {
                pos++;
                continue;
            }

            int nalStart = pos + scLen;
            if (nalStart >= len) break;

            // Find end of this NAL unit (start of next start code or end of buffer)
            int nextPos = nalStart + 1;
            while (nextPos < len - 2 && MatchStartCode(data, nextPos) == 0)
            {
                nextPos++;
            }
            int nalEnd = nextPos < len - 2 ? nextPos : len;

            if (codec == VideoCodecType.H264)
            {
                int nalType = data[nalStart] & 0x1F;
                if (nalType == 5) hasKeyframeNal = true;
                else if (nalType == 7)
                {
                    hasKeyframeNal = true;
                    hasParamSets = true;
                    _cachedSps = data.Slice(pos, nalEnd - pos).ToArray();
                }
                else if (nalType == 8)
                {
                    hasParamSets = true;
                    _cachedPps = data.Slice(pos, nalEnd - pos).ToArray();
                }
            }
            else if (codec == VideoCodecType.H265)
            {
                int nalType = (data[nalStart] >> 1) & 0x3F;
                if (nalType >= 16 && nalType <= 21) hasKeyframeNal = true;
                else if (nalType == 32)
                {
                    hasKeyframeNal = true;
                    hasParamSets = true;
                    _cachedVps = data.Slice(pos, nalEnd - pos).ToArray();
                }
                else if (nalType == 33)
                {
                    hasKeyframeNal = true;
                    hasParamSets = true;
                    _cachedSps = data.Slice(pos, nalEnd - pos).ToArray();
                }
                else if (nalType == 34)
                {
                    hasParamSets = true;
                    _cachedPps = data.Slice(pos, nalEnd - pos).ToArray();
                }
            }

            pos = nalEnd;
        }
    }

    private static int MatchStartCode(ReadOnlySpan<byte> data, int index)
    {
        if (index + 3 < data.Length && data[index] == 0 && data[index + 1] == 0)
        {
            if (data[index + 2] == 1) return 3;
            if (data[index + 2] == 0 && data[index + 3] == 1) return 4;
        }
        else if (index + 2 < data.Length && data[index] == 0 && data[index + 1] == 0 && data[index + 2] == 1)
        {
            return 3;
        }
        return 0;
    }

    private bool HasCachedParameterSets(VideoCodecType codec) =>
        codec == VideoCodecType.H265
            ? (_cachedVps != null && _cachedSps != null && _cachedPps != null)
            : (_cachedSps != null && _cachedPps != null);

    private ReadOnlySpan<byte> PrependCachedParameterSets(ReadOnlySpan<byte> annexBData, VideoCodecType codec)
    {
        int prefixLen = (_cachedSps?.Length ?? 0) + (_cachedPps?.Length ?? 0)
            + (codec == VideoCodecType.H265 ? (_cachedVps?.Length ?? 0) : 0);
        int totalLen = prefixLen + annexBData.Length;

        if (_prependedBuf == null || _prependedBuf.Length < totalLen)
        {
            _prependedBuf = new byte[totalLen];
        }

        int offset = 0;
        if (codec == VideoCodecType.H265 && _cachedVps != null)
        {
            Buffer.BlockCopy(_cachedVps, 0, _prependedBuf, offset, _cachedVps.Length);
            offset += _cachedVps.Length;
        }
        if (_cachedSps != null)
        {
            Buffer.BlockCopy(_cachedSps, 0, _prependedBuf, offset, _cachedSps.Length);
            offset += _cachedSps.Length;
        }
        if (_cachedPps != null)
        {
            Buffer.BlockCopy(_cachedPps, 0, _prependedBuf, offset, _cachedPps.Length);
            offset += _cachedPps.Length;
        }
        annexBData.CopyTo(_prependedBuf.AsSpan(offset));
        return _prependedBuf.AsSpan(0, totalLen);
    }

    // ── Flush / Reset / Dispose ─────────────────────────────────────────────

    public void Flush()
    {
        lock (_lock)
        {
            if (_disposed || _transform == null) return;
            try
            {
                _transform.ProcessMessage((TMessageType)MFT_MESSAGE_COMMAND_FLUSH, UIntPtr.Zero);
            }
            catch { }
        }
    }

    public void Reset()
    {
        lock (_lock)
        {
            _waitingForKeyframe = true;
            if (_disposed || _transform == null) return;
            try
            {
                _transform.ProcessMessage((TMessageType)MFT_MESSAGE_COMMAND_FLUSH, UIntPtr.Zero);
            }
            catch { }
        }
    }

    private void ReleaseInternal()
    {
        if (_streaming && _transform != null)
        {
            try
            {
                _transform.ProcessMessage(TMessageType.MessageNotifyEndOfStream, UIntPtr.Zero);
                _transform.ProcessMessage(TMessageType.MessageNotifyEndStreaming, UIntPtr.Zero);
            }
            catch { }
        }
        _streaming = false;

        _transform?.Dispose();
        _transform = null;

        if (_dxgiDeviceManagerPtr != nint.Zero)
        {
            Marshal.Release(_dxgiDeviceManagerPtr);
            _dxgiDeviceManagerPtr = nint.Zero;
        }

        IsHardware = false;
        IsGpuZeroCopy = false;
        IsFullRange = false;
        _cachedVps = null;
        _cachedSps = null;
        _cachedPps = null;
        _prependedBuf = null;
    }

    public void Dispose()
    {
        lock (_lock)
        {
            if (_disposed) return;
            _disposed = true;
            ReleaseInternal();
        }
    }

    private static ulong PackLong(int high, int low) => ((ulong)(uint)high << 32) | (uint)low;

    // ── Native COM / P/Invoke Declarations ─────────────────────────────────

    [DllImport("mfplat.dll", ExactSpelling = true)]
    private static extern int MFCreateDXGIDeviceManager(out uint resetToken, out nint ppDeviceManager);

    [ComImport, Guid("eb533d5d-2db6-40f8-97a9-494692014f07"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMFDXGIDeviceManagerCom
    {
        [PreserveSig] int CloseDeviceHandle(nint hDevice);
        [PreserveSig] int GetVideoService(nint hDevice, ref Guid riid, out nint ppService);
        [PreserveSig] int LockDevice(nint hDevice, ref Guid riid, out nint ppUnkDevice, bool fBlock);
        [PreserveSig] int OpenDeviceHandle(out nint phDevice);
        [PreserveSig] int ResetDevice(nint pUnkDevice, uint resetToken);
    }

    [ComImport, Guid("e7174cfa-1c9e-48b1-8866-626226bfc258"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMFDXGIBufferCom
    {
        [PreserveSig] int GetResource(ref Guid riid, out nint ppvObject);
        [PreserveSig] int GetSubresourceIndex(out uint puSubresource);
        [PreserveSig] int GetUnknown(ref Guid guid, ref Guid riid, out nint ppvObject);
        [PreserveSig] int SetUnknown(ref Guid guid, nint pUnkData);
    }

    // Minimal vtable-exact IMFTransform subset for GetAttributes & GetOutputAvailableType
    [ComImport, Guid("bf94c121-5b05-4e6f-8000-ba598961414d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMFTransformCom
    {
        [PreserveSig] int GetStreamLimits(out uint pdwInputMinimum, out uint pdwInputMaximum, out uint pdwOutputMinimum, out uint pdwOutputMaximum);
        [PreserveSig] int GetStreamCount(out uint pcInputStreams, out uint pcOutputStreams);
        [PreserveSig] int GetStreamIDs(uint dwInputIDArraySize, nint pdwInputIDs, uint dwOutputIDArraySize, nint pdwOutputIDs);
        [PreserveSig] int GetInputStreamInfo(uint dwInputStreamID, nint pStreamInfo);
        [PreserveSig] int GetOutputStreamInfo(uint dwOutputStreamID, nint pStreamInfo);
        [PreserveSig] int GetAttributes(out nint pAttributes);
        [PreserveSig] int GetInputStreamAttributes(uint dwInputStreamID, out nint pAttributes);
        [PreserveSig] int GetOutputStreamAttributes(uint dwOutputStreamID, out nint pAttributes);
        [PreserveSig] int DeleteInputStream(uint dwStreamID);
        [PreserveSig] int AddInputStreams(uint cStreams, nint adwStreamIDs);
        [PreserveSig] int GetInputAvailableType(uint dwInputStreamID, uint dwTypeIndex, out nint ppType);
        [PreserveSig] int GetOutputAvailableType(uint dwOutputStreamID, uint dwTypeIndex, out nint ppType);
    }
}
