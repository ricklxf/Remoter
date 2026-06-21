using System.Runtime.InteropServices;
using Vortice.MediaFoundation;

namespace RemoterWin;

// Hardware H.264 encoder via Media Foundation, driven directly through
// IMFTransform (not IMFSinkWriter — the sink writer targets file/container
// muxing and buffers for that; for live low-latency streaming we want the
// encoder MFT's raw input→output cadence with no extra buffering).
//
// MFTEnumEx picks whatever hardware MFT the driver exposes (NVENC/QuickSync/
// AMD VCE) automatically; if none is found we fall back to the software H.264
// MFT that ships with Windows itself, so this never hard-fails to "no encoder".
//
// Input: BGRA32 frames (same format ScreenCapturer already produces from the
// DXGI staging texture). The encoder wants NV12, so each frame is converted
// CPU-side — still far cheaper than the JPEG encode it replaces.
sealed class H264Encoder : IDisposable
{
    private IMFTransform?   _transform;
    private int             _width, _height;
    private long            _frameDuration100ns; // 1 / fps in 100ns units
    private bool            _streaming;
    private byte[]          _nv12Buf = [];
    private readonly object _lock = new();

    public bool IsHardware { get; private set; }

    // 调用方需在进程启动时调一次 MediaFactory.MFStartup（main 入口已调用）。
    public void Initialize(int width, int height, int fps, int bitrateBps)
    {
        _width  = width;
        _height = height;
        _frameDuration100ns = 10_000_000L / Math.Max(fps, 1);
        _nv12Buf = new byte[width * height * 3 / 2];

        if (!TryCreateTransform(hardware: true))
        {
            AppLog.Write("[H264Encoder] no hardware MFT found, falling back to software H.264 encoder");
            if (!TryCreateTransform(hardware: false))
                throw new InvalidOperationException("No H.264 encoder MFT available (hardware or software)");
        }

        ConfigureTypes(width, height, fps, bitrateBps);

        _transform!.ProcessMessage(MFTMessageType.NotifyBeginStreaming, 0);
        _transform!.ProcessMessage(MFTMessageType.NotifyStartOfStream, 0);
        _streaming = true;

        AppLog.Write($"[H264Encoder] ready {width}x{height}@{fps}fps bitrate={bitrateBps}bps hw={IsHardware}");
    }

    private bool TryCreateTransform(bool hardware)
    {
        try
        {
            var flags = hardware
                ? MFTEnumFlag.Hardware | MFTEnumFlag.SortAndFilter
                : MFTEnumFlag.SyncMFT  | MFTEnumFlag.SortAndFilter;

            var activates = MediaFactory.MFTEnumEx(
                TransformCategoryGuid.VideoEncoder,
                flags,
                null,
                new MFTRegisterTypeInfo { GuidMajorType = MediaTypeGuids.Video, GuidSubtype = VideoFormatGuids.H264 });

            if (activates == null || activates.Length == 0)
            {
                AppLog.Write($"[H264Encoder] MFTEnumEx found 0 candidates (hardware={hardware})");
                return false;
            }

            // activates[0] is MFTEnumEx's own quality-sorted pick (SortAndFilter).
            _transform = activates[0].ActivateObject<IMFTransform>();
            IsHardware = hardware;
            AppLog.Write($"[H264Encoder] picked MFT #{0}/{activates.Length} candidates, hardware={hardware}");
            return true;
        }
        catch (Exception ex)
        {
            AppLog.Write($"[H264Encoder] TryCreateTransform(hardware={hardware}) failed: {ex.Message}");
            return false;
        }
    }

    private void ConfigureTypes(int width, int height, int fps, int bitrateBps)
    {
        // Encoder MFTs need the output (target) type set before the input type —
        // the transform uses it to decide which input formats it'll accept.
        using var outputType = MediaFactory.MFCreateMediaType();
        outputType.Set(MediaTypeAttributeKeys.MajorType, MediaTypeGuids.Video);
        outputType.Set(MediaTypeAttributeKeys.Subtype, VideoFormatGuids.H264);
        outputType.Set(MediaTypeAttributeKeys.AvgBitrate, bitrateBps);
        outputType.Set(MediaTypeAttributeKeys.FrameSize, PackLong(width, height));
        outputType.Set(MediaTypeAttributeKeys.FrameRate, PackLong(fps, 1));
        outputType.Set(MediaTypeAttributeKeys.InterlaceMode, (int)MFVideoInterlaceMode.Progressive);
        outputType.Set(MediaTypeAttributeKeys.MpegLevel, 0); // let the MFT pick a level for the size/fps
        // Result-returning Vortice calls don't auto-throw (same as the DXGI
        // calls in ScreenCapturer.cs) — check explicitly so a rejected media
        // type fails loudly here instead of surfacing as a confusing
        // ProcessInput/ProcessOutput error later.
        var hrOut = _transform!.SetOutputType(0, outputType, 0);
        if (hrOut.Failure) AppLog.Write($"[H264Encoder] SetOutputType failed: 0x{hrOut.Code:X8}");

        using var inputType = MediaFactory.MFCreateMediaType();
        inputType.Set(MediaTypeAttributeKeys.MajorType, MediaTypeGuids.Video);
        inputType.Set(MediaTypeAttributeKeys.Subtype, VideoFormatGuids.NV12);
        inputType.Set(MediaTypeAttributeKeys.FrameSize, PackLong(width, height));
        inputType.Set(MediaTypeAttributeKeys.FrameRate, PackLong(fps, 1));
        inputType.Set(MediaTypeAttributeKeys.InterlaceMode, (int)MFVideoInterlaceMode.Progressive);
        var hrIn = _transform!.SetInputType(0, inputType, 0);
        if (hrIn.Failure) AppLog.Write($"[H264Encoder] SetInputType failed: 0x{hrIn.Code:X8}");
    }

    private static long PackLong(int high, int low) => ((long)high << 32) | (uint)low;

    // 动态调码率（ABR 用）。多数硬件 MFT 支持运行时改 AVEncCommonMeanBitRate，
    // 不需要重建编码器；少数不支持的会静默失败，不影响后续编码（只是码率不变）。
    public void SetBitrate(int bps)
    {
        try
        {
            using var codecApi = _transform?.QueryInterface<ICodecAPI>();
            codecApi?.SetValue(CodecApiEventIdentifiers.AVEncCommonMeanBitRate, (uint)bps);
        }
        catch (Exception ex)
        {
            AppLog.Write($"[H264Encoder] SetBitrate({bps}) failed (non-fatal): {ex.Message}");
        }
    }

    // bgra: tightly-packed BGRA32, width*height*4 bytes (matches the staging
    // texture ScreenCapturer maps). Returns Annex-B H.264 bytes, or null if the
    // MFT swallowed the frame without producing output yet (it buffers a little
    // for B-frame-free low-latency profiles — caller should just send the next
    // frame and not treat null as an error).
    public byte[]? Encode(ReadOnlySpan<byte> bgra, long ptsMs, out bool keyframe)
    {
        keyframe = false;
        if (_transform == null || !_streaming) return null;

        lock (_lock)
        {
            BgraToNv12(bgra, _width, _height, _nv12Buf);

            using var buffer = MediaFactory.MFCreateMemoryBuffer(_nv12Buf.Length);
            unsafe
            {
                var dst = buffer.Lock(out _, out _);
                Marshal.Copy(_nv12Buf, 0, (nint)dst, _nv12Buf.Length);
            }
            buffer.CurrentLength = _nv12Buf.Length;
            buffer.Unlock();

            using var sample = MediaFactory.MFCreateSample();
            sample.AddBuffer(buffer);
            sample.SampleTime     = ptsMs * 10_000; // ms → 100ns units
            sample.SampleDuration = _frameDuration100ns;

            var hrIn = _transform.ProcessInput(0, sample, 0);
            if (hrIn.Code == MF_E_NOTACCEPTING)
            {
                // Input queue full — drain whatever's ready, then retry once.
                DrainOutput(out _);
                hrIn = _transform.ProcessInput(0, sample, 0);
            }
            if (hrIn.Failure)
            {
                AppLog.Write($"[H264Encoder] ProcessInput failed: 0x{hrIn.Code:X8}");
                return null;
            }

            return DrainOutput(out keyframe);
        }
    }

    // Same Result/.Code/.CheckError() convention already proven to work for
    // Vortice.DXGI calls in ScreenCapturer.cs — kept consistent here rather
    // than guessing at a Try* overload that may not exist on this transform.
    private const int MF_E_TRANSFORM_NEED_MORE_INPUT = unchecked((int)0xC00D6D72);
    private const int MF_E_TRANSFORM_STREAM_CHANGE   = unchecked((int)0xC00D6D61);
    private const int MF_E_NOTACCEPTING              = unchecked((int)0xC00D36B5);

    private byte[]? DrainOutput(out bool keyframe)
    {
        keyframe = false;
        var outputInfo = _transform!.GetOutputStreamInfo(0);
        using var outBuffer = MediaFactory.MFCreateMemoryBuffer(Math.Max(outputInfo.SizeInBytes, 1 << 16));
        using var outSample = MediaFactory.MFCreateSample();
        outSample.AddBuffer(outBuffer);

        var outputDataBuffer = new MFTOutputDataBuffer { Sample = outSample };
        var hr = _transform.ProcessOutput(MFTProcessOutputFlags.None, new[] { outputDataBuffer }, out _);

        if (hr.Code == MF_E_TRANSFORM_NEED_MORE_INPUT) return null; // normal — no frame ready yet
        if (hr.Code == MF_E_TRANSFORM_STREAM_CHANGE)
        {
            AppLog.Write("[H264Encoder] MF_E_TRANSFORM_STREAM_CHANGE — output type needs renegotiation (not yet handled, dropping frame)");
            return null;
        }
        try { hr.CheckError(); }
        catch (Exception ex)
        {
            AppLog.Write($"[H264Encoder] ProcessOutput failed: 0x{hr.Code:X8} {ex.Message}");
            return null;
        }

        try
        {
            keyframe = outSample.ContainsAttribute(SampleAttributeKeys.CleanPoint)
                && outSample.Get(SampleAttributeKeys.CleanPoint) != 0;
        }
        catch (Exception ex)
        {
            // Keyframe detection failing isn't fatal — the H.264 bitstream itself
            // still carries SPS/PPS/IDR markers the decoder can use; we just lose
            // the protocol-level keyframe hint (client requests a resync less eagerly).
            AppLog.Write($"[H264Encoder] keyframe attribute read failed (non-fatal): {ex.Message}");
        }

        using var resultBuffer = outSample.ConvertToContiguousBuffer();
        unsafe
        {
            var src = resultBuffer.Lock(out _, out var len);
            var bytes = new byte[len];
            Marshal.Copy((nint)src, bytes, 0, len);
            resultBuffer.Unlock();
            return bytes;
        }
    }

    // Straightforward BT.601 BGRA→NV12. Not SIMD-optimized — revisit if CPU
    // usage shows this as a hotspot; it's still far lighter than JPEG was.
    private static void BgraToNv12(ReadOnlySpan<byte> bgra, int width, int height, byte[] nv12)
    {
        int yPlaneSize = width * height;
        int uvOffset   = yPlaneSize;

        for (int y = 0; y < height; y++)
        {
            int rowBase = y * width * 4;
            for (int x = 0; x < width; x++)
            {
                int i = rowBase + x * 4;
                byte b = bgra[i], g = bgra[i + 1], r = bgra[i + 2];
                nv12[y * width + x] = (byte)Math.Clamp((16 + (66 * r + 129 * g + 25 * b + 128) / 256), 0, 255);
            }
        }

        for (int y = 0; y < height; y += 2)
        {
            int rowBase = y * width * 4;
            for (int x = 0; x < width; x += 2)
            {
                int i = rowBase + x * 4;
                byte b = bgra[i], g = bgra[i + 1], r = bgra[i + 2];
                int u = 128 + (-38 * r - 74 * g + 112 * b) / 256;
                int v = 128 + (112 * r - 94 * g - 18 * b) / 256;
                int uvIndex = uvOffset + (y / 2) * width + x;
                nv12[uvIndex]     = (byte)Math.Clamp(u, 0, 255);
                nv12[uvIndex + 1] = (byte)Math.Clamp(v, 0, 255);
            }
        }
    }

    public void Dispose()
    {
        try
        {
            if (_streaming)
            {
                _transform?.ProcessMessage(MFTMessageType.NotifyEndOfStream, 0);
                _transform?.ProcessMessage(MFTMessageType.EndStreaming, 0);
            }
        }
        catch (Exception ex) { AppLog.Write($"[H264Encoder] Dispose end-stream failed: {ex.Message}"); }
        _streaming = false;
        _transform?.Dispose();
        _transform = null;
    }
}
