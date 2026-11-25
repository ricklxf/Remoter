using System.Runtime.InteropServices;
using Vortice.Direct3D11;
using Vortice.MediaFoundation;

namespace RemoterWin;

public enum WinVideoCodec
{
    H264,
    H265,
}

// Hardware H.264 / H.265 (HEVC) encoder via Media Foundation, driven directly through
// IMFTransform (not IMFSinkWriter — the sink writer targets file/container
// muxing and buffers for that; for live low-latency streaming we want the
// encoder MFT's raw input→output cadence with no extra buffering).
//
// MFTEnumEx picks whatever hardware MFT the driver exposes (NVENC/QuickSync/
// AMD VCE) automatically; if HEVC is requested and unavailable, falls back
// automatically to hardware/software H.264 so encoding never hard-fails.
// When a multithread-protected D3D11 device is provided, attempts to bind
// IMFDXGIDeviceManager + ARGB32 input for DXGI GPU zero-copy encoding, falling
// back seamlessly to the CPU BGRA→NV12 path if the driver rejects it.
sealed class H264Encoder : IDisposable
{
    private IMFTransform?   _transform;
    private ICodecAPI?      _codecApi;
    private nint            _dxgiDeviceManagerPtr;
    private int             _width, _height;
    private int             _fps = 60;
    private int             _bitrateBps = 8_000_000;
    private long            _frameDuration100ns; // 1 / fps in 100ns units
    private bool            _streaming;
    private byte[]          _nv12Buf = [];
    private readonly object _lock = new();

    public bool IsHardware { get; private set; }
    public bool IsGpuZeroCopy { get; private set; }
    public WinVideoCodec ActiveCodec { get; private set; } = WinVideoCodec.H264;
    public int CurrentBitrateBps => _bitrateBps;
    public int CurrentFps => _fps;

    private static readonly Guid MftCategoryVideoEncoder = new("f79eac7d-e545-4387-bdee-d647d7bde42a");
    private static readonly Guid MfMediaTypeVideo         = new("73646976-0000-0010-8000-00aa00389b71");
    private static readonly Guid MFVideoFormat_HEVC       = new(0x43564548, 0x0000, 0x0010, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71);
    private static readonly Guid IID_ID3D11Texture2D      = new("6f15aaf2-d208-4e89-9ab4-489535d34f9c");
    private const int MFT_MESSAGE_SET_D3D_MANAGER         = 0x00000002;

    [DllImport("mfplat.dll", ExactSpelling = true)]
    private static extern int MFCreateDXGIDeviceManager(out uint resetToken, out nint ppDeviceManager);

    [DllImport("mfplat.dll", ExactSpelling = true)]
    private static extern int MFCreateDXGISurfaceBuffer(
        ref Guid riid,
        nint punkSurface,
        uint uSubresourceIndex,
        [MarshalAs(UnmanagedType.Bool)] bool fBottomUpWhenLinear,
        out nint ppBuffer);

    // MF_MT_* attribute GUIDs (mfapi.h)
    private static readonly Guid MF_MT_MAJOR_TYPE           = new("48eba18e-f8c9-4687-bf11-0a74c9f96a8f");
    private static readonly Guid MF_MT_SUBTYPE              = new("f7e34c9a-42e8-4714-b74b-cb29d72c35e5");
    private static readonly Guid MF_MT_AVG_BITRATE          = new("20332624-fb0d-4d9e-bd0d-cbf6786c102e");
    private static readonly Guid MF_MT_FRAME_SIZE           = new("1652c33d-d6b2-4012-b834-72030849a37d");
    private static readonly Guid MF_MT_FRAME_RATE           = new("c459a2e8-3d2c-4e44-b132-fee5156c7bb0");
    private static readonly Guid MF_MT_INTERLACE_MODE       = new("e2724bb8-e676-4806-b4b2-a8d6efb44ccd");
    private static readonly Guid MF_MT_MAX_KEYFRAME_SPACING = new("c16eb52b-73a1-476f-8d62-839d6a020652");
    private static readonly Guid MF_MT_VIDEO_PRIMARIES      = new("dbfbe4d7-0740-4ee0-8192-850ab0e21935");
    private static readonly Guid MF_MT_YUV_MATRIX           = new("3e23d450-2c75-4d25-a00e-b91670d12327");
    private static readonly Guid MF_MT_TRANSFER_FUNCTION    = new("5fb0fce9-be5c-4935-a811-ec838f8eed93");
    private static readonly Guid MF_MT_VIDEO_NOMINAL_RANGE  = new("c21b8ee5-b956-4071-8daf-325edf5cab11");

    private const uint MFVideoInterlace_Progressive = 2;
    private const uint MFVideoPrimaries_BT709       = 2;
    private const uint MFVideoTransferMatrix_BT709  = 1;
    private const uint MFVideoTransFunc_709         = 5;
    private const uint MFNominalRange_16_235        = 2;

    // CODECAPI_* GUIDs (codecapi.h) for low-latency, 0 B-frames, 2.0x burst headroom, live ABR & keyframe
    private static readonly Guid CODECAPI_AVEncCommonLowLatency        = new("9d3ecd55-89e8-490a-970a-0c9548d5a56e");
    private static readonly Guid CODECAPI_AVEncCommonRateControlMode   = new("1c0608e9-370c-4710-8a58-cb6181c42423");
    private static readonly Guid CODECAPI_AVEncCommonMeanBitRate       = new("f7222374-2144-4815-b550-a37f8e12ee52");
    private static readonly Guid CODECAPI_AVEncCommonMaxBitRate        = new("9651eae4-39b9-4ebf-85ef-d7f444ec7465");
    private static readonly Guid CODECAPI_AVEncMPVDefaultBPictureCount = new("8d390aac-dc5c-4200-b57f-814d04babab2");
    private static readonly Guid CODECAPI_AVEncMPVGOPSize              = new("95f31b26-95a4-41aa-9303-246a7fc6eef1");
    private static readonly Guid CODECAPI_AVEncVideoForceKeyFrame      = new("398c1b98-8353-475a-9ef2-8f265d260345");
    private const uint eAVEncCommonRateControlMode_PeakConstrainedVBR  = 3;

    // MFT_ENUM_FLAG_* (mfapi.h)
    private const uint MFT_ENUM_FLAG_SYNCMFT       = 0x00000001;
    private const uint MFT_ENUM_FLAG_HARDWARE      = 0x00000004;
    private const uint MFT_ENUM_FLAG_SORTANDFILTER = 0x00000040;

    // 调用方需在进程启动时调一次 MediaFactory.MFStartup（main 入口已调用）。
    public void Initialize(int width, int height, int fps, int bitrateBps, WinVideoCodec codec = WinVideoCodec.H264, ID3D11Device? d3d11Device = null)
    {
        lock (_lock)
        {
            _width      = width;
            _height     = height;
            _fps        = Math.Clamp(fps, 1, 120);
            _bitrateBps = Math.Clamp(bitrateBps, 500_000, 50_000_000);
            _frameDuration100ns = 10_000_000L / _fps;
            _nv12Buf = new byte[width * height * 3 / 2];
            IsGpuZeroCopy = false;

            bool ok = false;
            if (codec == WinVideoCodec.H265)
            {
                ok = TryCreateTransform(width, height, _fps, _bitrateBps, WinVideoCodec.H265, hardware: true, d3d11Device)
                  || TryCreateTransform(width, height, _fps, _bitrateBps, WinVideoCodec.H265, hardware: false, null);
                if (!ok)
                {
                    AppLog.Write("[H264Encoder] no HEVC encoder MFT available, falling back to H.264");
                }
            }

            if (!ok)
            {
                ok = TryCreateTransform(width, height, _fps, _bitrateBps, WinVideoCodec.H264, hardware: true, d3d11Device);
                if (!ok)
                {
                    AppLog.Write("[H264Encoder] no hardware H.264 MFT found, falling back to software H.264 encoder");
                    ok = TryCreateTransform(width, height, _fps, _bitrateBps, WinVideoCodec.H264, hardware: false, null);
                }
            }

            if (!ok || _transform == null)
                throw new InvalidOperationException("No H.264/H.265 encoder MFT available (hardware or software)");

            _transform.ProcessMessage(TMessageType.MessageNotifyBeginStreaming, UIntPtr.Zero);
            _transform.ProcessMessage(TMessageType.MessageNotifyStartOfStream, UIntPtr.Zero);
            _streaming = true;

            AppLog.Write($"[H264Encoder] ready codec={ActiveCodec} {width}x{height}@{_fps}fps bitrate={_bitrateBps}bps hw={IsHardware} gpuZeroCopy={IsGpuZeroCopy}");
        }
    }

    private bool TryCreateTransform(int width, int height, int fps, int bitrateBps, WinVideoCodec codec, bool hardware, ID3D11Device? d3d11Device)
    {
        IMFTransform? candidate = null;
        try
        {
            uint flags = (hardware ? MFT_ENUM_FLAG_HARDWARE : MFT_ENUM_FLAG_SYNCMFT) | MFT_ENUM_FLAG_SORTANDFILTER;
            Guid outputSubtype = codec == WinVideoCodec.H265 ? MFVideoFormat_HEVC : VideoFormatGuids.H264;

            MediaFactory.MFTEnumEx(
                MftCategoryVideoEncoder, flags,
                inputType:  null,
                outputType: new RegisterTypeInfo { GuidMajorType = MfMediaTypeVideo, GuidSubtype = outputSubtype },
                out nint pppActivate, out uint count);

            if (count == 0 || pppActivate == nint.Zero)
            {
                AppLog.Write($"[H264Encoder] MFTEnumEx found 0 candidates (codec={codec}, hardware={hardware})");
                return false;
            }

            try
            {
                using var activate = new IMFActivate(Marshal.ReadIntPtr(pppActivate, 0));
                for (uint i = 1; i < count; i++)
                {
                    nint pOther = Marshal.ReadIntPtr(pppActivate, (int)i * IntPtr.Size);
                    if (pOther != nint.Zero) Marshal.Release(pOther);
                }

                candidate = activate.ActivateObject<IMFTransform>();
                AppLog.Write($"[H264Encoder] picked MFT #0/{count} candidates, codec={codec}, hardware={hardware}");
            }
            finally
            {
                Marshal.FreeCoTaskMem(pppActivate);
            }

            _transform = candidate;
            IsHardware = hardware;
            ActiveCodec = codec;
            IsGpuZeroCopy = false;
            _codecApi = Marshal.GetObjectForIUnknown(candidate.NativePointer) as ICodecAPI;

            // Bind IMFDXGIDeviceManager before negotiating media types when using a hardware MFT + D3D11 device
            bool d3dBound = hardware && d3d11Device != null && TryBindDxgiDeviceManagerLocked(candidate, d3d11Device);

            // Configure low-latency rate control before setting media types (some MFTs require this pre-init)
            ApplyLowLatencyCodecApiLocked(bitrateBps);
            ConfigureTypes(width, height, fps, bitrateBps, outputSubtype, preferGpuArgb32: d3dBound);
            // Re-apply bitrate & max burst headroom after media types are negotiated
            ApplyBitrateLocked(bitrateBps);
            return true;
        }
        catch (Exception ex)
        {
            AppLog.Write($"[H264Encoder] TryCreateTransform(codec={codec}, hardware={hardware}) failed: {ex.Message}");
            ReleaseDxgiDeviceManagerLocked();
            IsGpuZeroCopy = false;
            _codecApi = null;
            _transform = null;
            try { candidate?.Dispose(); } catch { }
            return false;
        }
    }

    private bool TryBindDxgiDeviceManagerLocked(IMFTransform transform, ID3D11Device d3d11Device)
    {
        ReleaseDxgiDeviceManagerLocked();
        nint pDxgiMgr = nint.Zero;
        try
        {
            int hr = MFCreateDXGIDeviceManager(out uint resetToken, out pDxgiMgr);
            if (hr < 0 || pDxgiMgr == nint.Zero)
            {
                AppLog.Write($"[H264Encoder] MFCreateDXGIDeviceManager failed: 0x{hr:X8}");
                return false;
            }

            var mgr = (IMFDXGIDeviceManagerCom)Marshal.GetObjectForIUnknown(pDxgiMgr);
            hr = mgr.ResetDevice(d3d11Device.NativePointer, resetToken);
            if (hr < 0)
            {
                AppLog.Write($"[H264Encoder] IMFDXGIDeviceManager.ResetDevice failed: 0x{hr:X8}");
                Marshal.Release(pDxgiMgr);
                return false;
            }

            transform.ProcessMessage((TMessageType)MFT_MESSAGE_SET_D3D_MANAGER, (nuint)pDxgiMgr);
            _dxgiDeviceManagerPtr = pDxgiMgr;
            AppLog.Write("[H264Encoder] Bound IMFDXGIDeviceManager to hardware MFT for DXGI zero-copy");
            return true;
        }
        catch (Exception ex)
        {
            AppLog.Write($"[H264Encoder] MFT_MESSAGE_SET_D3D_MANAGER rejected (falling back to CPU NV12): {ex.Message}");
            if (pDxgiMgr != nint.Zero)
            {
                try { Marshal.Release(pDxgiMgr); } catch { }
            }
            return false;
        }
    }

    private void ReleaseDxgiDeviceManagerLocked()
    {
        if (_dxgiDeviceManagerPtr != nint.Zero)
        {
            try { Marshal.Release(_dxgiDeviceManagerPtr); } catch { }
            _dxgiDeviceManagerPtr = nint.Zero;
        }
    }

    private void ApplyLowLatencyCodecApiLocked(int bitrateBps)
    {
        if (_codecApi == null) return;
        TrySetCodecApiValue(CODECAPI_AVEncCommonLowLatency, true);
        TrySetCodecApiValue(CODECAPI_AVEncMPVDefaultBPictureCount, 0u);
        // Long GOP (7200 frames = ~2 min @ 60fps) prevents unsolicited ~200KB periodic keyframes
        // from bursting into WAN/WireGuard tunnels; on-demand ForceKeyframe() handles all recovery.
        TrySetCodecApiValue(CODECAPI_AVEncMPVGOPSize, 7200u);
        TrySetCodecApiValue(CODECAPI_AVEncCommonRateControlMode, eAVEncCommonRateControlMode_PeakConstrainedVBR);
        ApplyBitrateLocked(bitrateBps);
    }

    private void ApplyBitrateLocked(int bitrateBps)
    {
        if (_codecApi == null) return;
        uint meanBps = (uint)Math.Clamp(bitrateBps, 500_000, 50_000_000);
        uint maxBps  = (uint)Math.Min((long)meanBps * 2, 50_000_000L);
        TrySetCodecApiValue(CODECAPI_AVEncCommonMeanBitRate, meanBps);
        TrySetCodecApiValue(CODECAPI_AVEncCommonMaxBitRate, maxBps);
    }

    private bool TrySetCodecApiValue(Guid key, object value)
    {
        if (_codecApi == null) return false;
        try
        {
            object boxed = value;
            int hr = _codecApi.SetValue(ref key, ref boxed);
            return hr >= 0;
        }
        catch
        {
            return false;
        }
    }

    private void ConfigureTypes(int width, int height, int fps, int bitrateBps, Guid outputSubtype, bool preferGpuArgb32)
    {
        using var outputType = MediaFactory.MFCreateMediaType();
        outputType.Set(MF_MT_MAJOR_TYPE, MfMediaTypeVideo);
        outputType.Set(MF_MT_SUBTYPE, outputSubtype);
        outputType.Set(MF_MT_AVG_BITRATE, (uint)bitrateBps);
        outputType.Set(MF_MT_FRAME_SIZE, PackLong(width, height));
        outputType.Set(MF_MT_FRAME_RATE, PackLong(fps, 1));
        outputType.Set(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
        outputType.Set(MF_MT_MAX_KEYFRAME_SPACING, (uint)(fps * 10));
        // Explicit BT.709 VideoRange (16..235) color metadata
        outputType.Set(MF_MT_VIDEO_PRIMARIES, MFVideoPrimaries_BT709);
        outputType.Set(MF_MT_YUV_MATRIX, MFVideoTransferMatrix_BT709);
        outputType.Set(MF_MT_TRANSFER_FUNCTION, MFVideoTransFunc_709);
        outputType.Set(MF_MT_VIDEO_NOMINAL_RANGE, MFNominalRange_16_235);
        _transform!.SetOutputType(0, outputType, 0);

        if (preferGpuArgb32)
        {
            try
            {
                // MFVideoFormat_ARGB32 (D3DFMT_A8R8G8B8 = 0x15)
                var mfVideoFormatArgb32 = new Guid(0x00000015, 0x0000, 0x0010, 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71);
                using var argbInputType = MediaFactory.MFCreateMediaType();
                argbInputType.Set(MF_MT_MAJOR_TYPE, MfMediaTypeVideo);
                argbInputType.Set(MF_MT_SUBTYPE, mfVideoFormatArgb32);
                argbInputType.Set(MF_MT_FRAME_SIZE, PackLong(width, height));
                argbInputType.Set(MF_MT_FRAME_RATE, PackLong(fps, 1));
                argbInputType.Set(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
                _transform!.SetInputType(0, argbInputType, 0);
                IsGpuZeroCopy = true;
                AppLog.Write("[H264Encoder] Negotiated GPU zero-copy ARGB32 input media type");
                return;
            }
            catch (Exception ex)
            {
                AppLog.Write($"[H264Encoder] GPU ARGB32 input rejected by MFT ({ex.Message}), falling back to CPU NV12");
                IsGpuZeroCopy = false;
                try { _transform!.ProcessMessage((TMessageType)MFT_MESSAGE_SET_D3D_MANAGER, UIntPtr.Zero); } catch { }
                ReleaseDxgiDeviceManagerLocked();
            }
        }

        using var inputType = MediaFactory.MFCreateMediaType();
        inputType.Set(MF_MT_MAJOR_TYPE, MfMediaTypeVideo);
        inputType.Set(MF_MT_SUBTYPE, VideoFormatGuids.NV12);
        inputType.Set(MF_MT_FRAME_SIZE, PackLong(width, height));
        inputType.Set(MF_MT_FRAME_RATE, PackLong(fps, 1));
        inputType.Set(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
        inputType.Set(MF_MT_VIDEO_PRIMARIES, MFVideoPrimaries_BT709);
        inputType.Set(MF_MT_YUV_MATRIX, MFVideoTransferMatrix_BT709);
        inputType.Set(MF_MT_TRANSFER_FUNCTION, MFVideoTransFunc_709);
        inputType.Set(MF_MT_VIDEO_NOMINAL_RANGE, MFNominalRange_16_235);
        _transform!.SetInputType(0, inputType, 0);
    }

    private static ulong PackLong(int high, int low) => ((ulong)(uint)high << 32) | (uint)low;

    public void SetBitrate(int bps)
    {
        lock (_lock)
        {
            _bitrateBps = Math.Clamp(bps, 500_000, 50_000_000);
            if (_transform == null) return;
            ApplyBitrateLocked(_bitrateBps);
        }
    }

    public void SetFps(int fps)
    {
        lock (_lock)
        {
            _fps = Math.Clamp(fps, 1, 120);
            _frameDuration100ns = 10_000_000L / _fps;
        }
    }

    public void ForceKeyframe()
    {
        if (_transform == null) return;
        lock (_lock)
        {
            if (TrySetCodecApiValue(CODECAPI_AVEncVideoForceKeyFrame, 1u))
            {
                return;
            }
            try
            {
                _transform.ProcessMessage(TMessageType.MessageNotifyEndOfStream, UIntPtr.Zero);
                _transform.ProcessMessage(TMessageType.MessageNotifyBeginStreaming, UIntPtr.Zero);
                _transform.ProcessMessage(TMessageType.MessageNotifyStartOfStream, UIntPtr.Zero);
            }
            catch (Exception ex)
            {
                AppLog.Write($"[H264Encoder] ForceKeyframe failed (non-fatal): {ex.Message}");
            }
        }
    }

    /// <summary>
    /// Encodes a single crisp low-QP refinement frame after motion stops by temporarily
    /// boosting target bitrate 1.5x (up to 50 Mbps) and immediately restoring baseline bitrate.
    /// </summary>
    public byte[]? EncodeRefinementFrame(byte[] bgra, long ptsMs, out bool keyframe) =>
        EncodeRefinementFrame(bgra.AsSpan(), ptsMs, out keyframe);

    public byte[]? EncodeRefinementFrame(ReadOnlySpan<byte> bgra, long ptsMs, out bool keyframe)
    {
        keyframe = false;
        if (_transform == null || !_streaming) return null;

        lock (_lock)
        {
            int boosted = (int)Math.Min((long)_bitrateBps * 3 / 2, 50_000_000L);
            ApplyBitrateLocked(boosted);
            try
            {
                return EncodeCoreLocked(bgra, ptsMs, out keyframe);
            }
            finally
            {
                ApplyBitrateLocked(_bitrateBps);
            }
        }
    }

    public byte[]? Encode(ReadOnlySpan<byte> bgra, long ptsMs, out bool keyframe)
    {
        keyframe = false;
        if (_transform == null || !_streaming) return null;

        lock (_lock)
        {
            return EncodeCoreLocked(bgra, ptsMs, out keyframe);
        }
    }

    private byte[]? EncodeCoreLocked(ReadOnlySpan<byte> bgra, long ptsMs, out bool keyframe)
    {
        keyframe = false;
        BgraToNv12(bgra, _width, _height, _nv12Buf);

        using var buffer = MediaFactory.MFCreateMemoryBuffer(_nv12Buf.Length);
        buffer.Lock(out nint dst, out _, out _);
        Marshal.Copy(_nv12Buf, 0, dst, _nv12Buf.Length);
        buffer.Unlock();
        buffer.CurrentLength = _nv12Buf.Length;

        using var sample = MediaFactory.MFCreateSample();
        sample.AddBuffer(buffer);
        sample.SampleTime     = ptsMs * 10_000; // ms → 100ns units
        sample.SampleDuration = _frameDuration100ns;

        _transform!.ProcessInput(0, sample, 0);
        return DrainOutput(out keyframe);
    }

    /// <summary>
    /// Zero-copy GPU encode path: wraps a D3D11 B8G8R8A8 texture directly in a DXGI
    /// Media Foundation surface buffer with zero CPU staging or NV12 conversion.
    /// </summary>
    public byte[]? EncodeGpuTexture(ID3D11Texture2D gpuTexture, long ptsMs, out bool keyframe)
    {
        keyframe = false;
        if (_transform == null || !_streaming || !IsGpuZeroCopy) return null;

        lock (_lock)
        {
            return EncodeGpuCoreLocked(gpuTexture, ptsMs, out keyframe);
        }
    }

    /// <summary>
    /// Encodes a single crisp low-QP refinement frame on the GPU zero-copy path after
    /// motion stops by temporarily boosting target bitrate 1.5x (up to 50 Mbps).
    /// </summary>
    public byte[]? EncodeGpuRefinementFrame(ID3D11Texture2D gpuTexture, long ptsMs, out bool keyframe)
    {
        keyframe = false;
        if (_transform == null || !_streaming || !IsGpuZeroCopy) return null;

        lock (_lock)
        {
            int boosted = (int)Math.Min((long)_bitrateBps * 3 / 2, 50_000_000L);
            ApplyBitrateLocked(boosted);
            try
            {
                return EncodeGpuCoreLocked(gpuTexture, ptsMs, out keyframe);
            }
            finally
            {
                ApplyBitrateLocked(_bitrateBps);
            }
        }
    }

    private byte[]? EncodeGpuCoreLocked(ID3D11Texture2D gpuTexture, long ptsMs, out bool keyframe)
    {
        keyframe = false;
        Guid iid = IID_ID3D11Texture2D;
        int hr = MFCreateDXGISurfaceBuffer(ref iid, gpuTexture.NativePointer, 0, false, out nint pBuffer);
        if (hr < 0 || pBuffer == nint.Zero)
        {
            AppLog.Write($"[H264Encoder] MFCreateDXGISurfaceBuffer failed: 0x{hr:X8}");
            return null;
        }

        using var buffer = new IMFMediaBuffer(pBuffer);
        using var sample = MediaFactory.MFCreateSample();
        sample.AddBuffer(buffer);
        sample.SampleTime     = ptsMs * 10_000; // ms → 100ns units
        sample.SampleDuration = _frameDuration100ns;

        _transform!.ProcessInput(0, sample, 0);
        return DrainOutput(out keyframe);
    }

    private const int MF_E_TRANSFORM_NEED_MORE_INPUT = unchecked((int)0xC00D6D72);
    private const int MF_E_TRANSFORM_STREAM_CHANGE   = unchecked((int)0xC00D6D61);
    private const int MFT_OUTPUT_STREAM_PROVIDES_SAMPLES = 0x00000100;
    private static readonly Guid MFSampleExtension_CleanPoint = new("9cdf01d8-a0f0-43ba-b077-eaa06cbd728a");

    private byte[]? DrainOutput(out bool keyframe)
    {
        keyframe = false;
        var streamInfo    = _transform!.GetOutputStreamInfo(0);
        bool mftAllocates = (streamInfo.Flags & MFT_OUTPUT_STREAM_PROVIDES_SAMPLES) != 0;

        IMFSample? outSample = null;
        if (!mftAllocates)
        {
            int bufSize = streamInfo.Size > 0 ? streamInfo.Size : _width * _height;
            using var outBuffer = MediaFactory.MFCreateMemoryBuffer(bufSize);
            outSample = MediaFactory.MFCreateSample();
            outSample.AddBuffer(outBuffer);
        }

        var dataBuffer = new OutputDataBuffer { StreamID = 0, Sample = outSample, Status = 0, Events = null };
        var hr = _transform.ProcessOutput(ProcessOutputFlags.None, 1, ref dataBuffer, out _);

        if (hr.Code == MF_E_TRANSFORM_NEED_MORE_INPUT) { outSample?.Dispose(); return null; } // normal — no frame ready yet
        if (hr.Code == MF_E_TRANSFORM_STREAM_CHANGE)
        {
            AppLog.Write("[H264Encoder] MF_E_TRANSFORM_STREAM_CHANGE — output type needs renegotiation (not yet handled, dropping frame)");
            outSample?.Dispose();
            return null;
        }
        if (hr.Failure)
        {
            AppLog.Write($"[H264Encoder] ProcessOutput failed: 0x{hr.Code:X8}");
            outSample?.Dispose();
            return null;
        }

        var producedSample = dataBuffer.Sample;
        if (producedSample == null) return null;

        try
        {
            keyframe = producedSample.GetUInt32(MFSampleExtension_CleanPoint) != 0;
        }
        catch (Exception ex)
        {
            // Keyframe detection failing isn't fatal — the H.264 bitstream itself
            // still carries SPS/PPS/IDR markers the decoder can use; we just lose
            // the protocol-level keyframe hint (client requests a resync less eagerly).
            AppLog.Write($"[H264Encoder] keyframe attribute read failed (non-fatal): {ex.Message}");
        }

        using var resultBuffer = producedSample.ConvertToContiguousBuffer();
        resultBuffer.Lock(out nint src, out _, out int len);
        var bytes = new byte[len];
        Marshal.Copy(src, bytes, 0, len);
        resultBuffer.Unlock();
        producedSample.Dispose();
        return bytes;
    }

    // High-performance BT.709 VideoRange (16..235) BGRA→NV12 with unsafe pointers,
    // shift division, and Parallel.For multi-core scaling (matches BT.709 MF_MT metadata).
    private static unsafe void BgraToNv12(ReadOnlySpan<byte> bgra, int width, int height, byte[] nv12)
    {
        int yPlaneSize = width * height;
        int uvOffset   = yPlaneSize;

        fixed (byte* pBgra = bgra)
        fixed (byte* pNv12 = nv12)
        {
            // A lambda can't use a fixed-statement pointer directly (CS1764);
            // carry the addresses as nint and cast back inside.
            nint bgraAddr = (nint)pBgra;
            nint nv12Addr = (nint)pNv12;
            // Multi-threaded Y plane conversion (BT.709 VideoRange 16..235)
            Parallel.For(0, height, y =>
            {
                byte* srcRow = (byte*)bgraAddr + (long)y * width * 4;
                byte* dstRow = (byte*)nv12Addr + (long)y * width;
                for (int x = 0; x < width; x++)
                {
                    int i = x * 4;
                    byte b = srcRow[i], g = srcRow[i + 1], r = srcRow[i + 2];
                    dstRow[x] = (byte)(((47 * r + 157 * g + 16 * b + 128) >> 8) + 16);
                }
            });

            // Multi-threaded UV plane conversion (BT.709 VideoRange, subsampled 2x2)
            int halfHeight = height / 2;
            int halfWidth  = width / 2;
            Parallel.For(0, halfHeight, yHalf =>
            {
                int y = yHalf * 2;
                byte* srcRow = (byte*)bgraAddr + (long)y * width * 4;
                byte* dstUv  = (byte*)nv12Addr + uvOffset + (long)yHalf * width;
                for (int xHalf = 0; xHalf < halfWidth; xHalf++)
                {
                    int x = xHalf * 2;
                    int i = x * 4;
                    byte b = srcRow[i], g = srcRow[i + 1], r = srcRow[i + 2];
                    int u = ((-26 * r - 87 * g + 112 * b + 128) >> 8) + 128;
                    int v = ((112 * r - 102 * g - 10 * b + 128) >> 8) + 128;
                    dstUv[x]     = (byte)Math.Clamp(u, 16, 240);
                    dstUv[x + 1] = (byte)Math.Clamp(v, 16, 240);
                }
            });
        }
    }

    public void Dispose()
    {
        lock (_lock)
        {
            try
            {
                if (_streaming)
                {
                    _transform?.ProcessMessage(TMessageType.MessageNotifyEndOfStream, UIntPtr.Zero);
                    _transform?.ProcessMessage(TMessageType.MessageNotifyEndStreaming, UIntPtr.Zero);
                }
            }
            catch (Exception ex) { AppLog.Write($"[H264Encoder] Dispose end-stream failed: {ex.Message}"); }
            _streaming = false;
            IsGpuZeroCopy = false;
            _codecApi = null;
            _transform?.Dispose();
            _transform = null;
            ReleaseDxgiDeviceManagerLocked();
        }
    }

    // Minimal vtable-exact Windows SDK ICodecAPI COM interface (strmif.h)
    [ComImport, Guid("901db4c7-31ce-41a2-85dc-8fa0bf41b8da"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface ICodecAPI
    {
        [PreserveSig] int IsSupported(ref Guid api);
        [PreserveSig] int IsModifiable(ref Guid api);
        [PreserveSig] int GetParameterRange(ref Guid api, [MarshalAs(UnmanagedType.Struct)] out object valueMin, [MarshalAs(UnmanagedType.Struct)] out object valueMax, [MarshalAs(UnmanagedType.Struct)] out object steppingDelta);
        [PreserveSig] int GetParameterValues(ref Guid api, out nint values, out uint valuesCount);
        [PreserveSig] int GetDefaultValue(ref Guid api, [MarshalAs(UnmanagedType.Struct)] out object value);
        [PreserveSig] int GetValue(ref Guid api, [MarshalAs(UnmanagedType.Struct)] out object value);
        [PreserveSig] int SetValue(ref Guid api, [MarshalAs(UnmanagedType.Struct)] ref object value);
    }

    // Minimal vtable-exact Windows SDK IMFDXGIDeviceManager COM interface (mfobjects.h)
    [ComImport, Guid("eb533d5d-2db6-40f8-97a9-494692014f07"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMFDXGIDeviceManagerCom
    {
        [PreserveSig] int CloseDeviceHandle(nint hDevice);
        [PreserveSig] int GetVideoService(nint hDevice, ref Guid riid, out nint ppService);
        [PreserveSig] int LockDevice(nint hDevice, ref Guid riid, out nint ppUnkDevice, [MarshalAs(UnmanagedType.Bool)] bool fBlock);
        [PreserveSig] int OpenDeviceHandle(out nint phDevice);
        [PreserveSig] int ResetDevice(nint pUnkDevice, uint resetToken);
        [PreserveSig] int TestDevice(nint hDevice);
        [PreserveSig] int UnlockDevice(nint hDevice, [MarshalAs(UnmanagedType.Bool)] bool fSaveState);
    }
}
