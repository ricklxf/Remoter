using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using Vortice.Direct3D;
using Vortice.Direct3D11;
using Vortice.DXGI;
using Vortice.Mathematics;

using D3D11MapFlags = Vortice.Direct3D11.MapFlags;

namespace RemoterWinClient;

/// <summary>
/// Pure native Direct3D 11 + DXGI 1.2 Flip-Model renderer.
/// Supports zero-copy GPU NV12 (via BT.709 HLSL pixel shader), CPU NV12 fallback,
/// and direct BGRA32 rendering for JPEG fallback frames.
/// </summary>
public sealed class D3D11Renderer : IDisposable
{
    private readonly object _renderLock = new();

    private ID3D11Device? _device;
    private ID3D11DeviceContext? _context;
    private IDXGISwapChain1? _swapChain;
    private IDXGISwapChain2? _swapChain2;
    private ID3D11RenderTargetView? _rtv;
    private nint _frameLatencyWaitableObject;

    private ID3D11VertexShader? _vertexShader;
    private ID3D11PixelShader? _nv12PixelShader;
    private ID3D11PixelShader? _bgraPixelShader;
    private ID3D11SamplerState? _linearSampler;
    private ID3D11RasterizerState? _rasterizerState;
    private ID3D11Buffer? _paramsBuffer;

    [StructLayout(LayoutKind.Sequential, Size = 16)]
    private struct RenderParams
    {
        public float TexelWidth;
        public float TexelHeight;
        public float Sharpness;
        public int FullRange;
    }

    // Persistent GPU NV12 texture (ArraySize=1, BindFlags.ShaderResource) used as
    // the render target of GPU-to-GPU CopySubresourceRegion from DXVA decoder arrays,
    // or CopyResource from the CPU staging texture.
    private ID3D11Texture2D? _nv12GpuTex;
    private ID3D11Texture2D? _nv12StagingTex;
    private ID3D11ShaderResourceView? _nv12YSrv;
    private ID3D11ShaderResourceView? _nv12UvSrv;
    private int _nv12Width;
    private int _nv12Height;

    // Persistent GPU BGRA32 texture for JPEG / software RGB fallback.
    private ID3D11Texture2D? _bgraTex;
    private ID3D11ShaderResourceView? _bgraSrv;
    private int _bgraWidth;
    private int _bgraHeight;

    private enum ActiveSurface { None, Nv12, Bgra }
    private ActiveSurface _activeSurface = ActiveSurface.None;

    private SwapChainFlags _swapChainFlags;
    private ScaleMode _scaleMode = ScaleMode.Fit;
    private bool _vsyncEnabled;
    private bool _fullRangeColor;
    private float _sharpness = 0.25f; // Gentle AMD FidelityFX CAS anti-blur sharpening for crisp scrolling text
    private bool _disposed;

    // Present stats
    private long _fpsWindowStartTick;
    private int _fpsFrameCount;
    private double _renderedFps;
    private double _lastPresentMs;

    public ID3D11Device? Device => _device;
    public ID3D11DeviceContext? Context => _context;
    public bool AllowTearingSupported { get; private set; }

    public bool VSyncEnabled
    {
        get => _vsyncEnabled;
        set => _vsyncEnabled = value;
    }

    /// <summary>
    /// Selects BT.709 full-range (0..255, matching UU MetalRenderer) vs limited/studio-swing (16..235).
    /// </summary>
    public bool FullRangeColor
    {
        get => _fullRangeColor;
        set
        {
            if (_fullRangeColor == value) return;
            _fullRangeColor = value;
            RePresent();
        }
    }

    /// <summary>
    /// AMD FidelityFX CAS anti-blur sharpening intensity (0.0 = off, 0.25 = subtle default, 1.0 = max).
    /// </summary>
    public float Sharpness
    {
        get => _sharpness;
        set
        {
            float clamped = Math.Clamp(value, 0f, 1f);
            if (Math.Abs(_sharpness - clamped) < 0.001f) return;
            _sharpness = clamped;
            RePresent();
        }
    }

    public ScaleMode ScaleMode
    {
        get => _scaleMode;
        set
        {
            if (_scaleMode == value) return;
            _scaleMode = value;
            RePresent();
        }
    }

    public int ViewportWidth { get; private set; }
    public int ViewportHeight { get; private set; }
    public int VideoWidth { get; private set; }
    public int VideoHeight { get; private set; }
    public double RenderedFps => _renderedFps;
    public double LastPresentMs => _lastPresentMs;
    public (float X, float Y, float Width, float Height) ContentRect { get; private set; }

    // ── HLSL Shaders ────────────────────────────────────────────────────────

    private const string FullscreenVsHlsl = """
        struct VSOut {
            float4 pos : SV_Position;
            float2 uv  : TEXCOORD0;
        };

        VSOut main(uint id : SV_VertexID) {
            VSOut o;
            // Fullscreen triangle covering [-1, 1] NDC with top-left UV (0, 0)
            float2 uv = float2((id << 1) & 2, id & 2);
            o.uv = uv;
            o.pos = float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.0, 1.0);
            return o;
        }
        """;

    // BT.709 NV12 -> RGB conversion (supports both limited-range & UU full-range)
    // + AMD FidelityFX CAS 5-tap anti-blur sharpening for crisp text during fast scroll.
    private const string Nv12PsHlsl = """
        cbuffer RenderParams : register(b0) {
            float2 texelSize;
            float  sharpness;
            int    fullRange;
        };

        Texture2D<float>  texY  : register(t0);
        Texture2D<float2> texUV : register(t1);
        SamplerState      samp  : register(s0);

        struct PSIn {
            float4 pos : SV_Position;
            float2 uv  : TEXCOORD0;
        };

        float3 sampleNv12Rgb(float2 coord) {
            float yRaw = texY.Sample(samp, coord).r;
            float2 uv = texUV.Sample(samp, coord).rg - float2(0.5, 0.5);

            if (fullRange != 0) {
                // BT.709 Full-Range (0..255, matching UU Remote MetalRenderer)
                float r = saturate(yRaw + 1.5748 * uv.y);
                float g = saturate(yRaw - 0.1873 * uv.x - 0.4681 * uv.y);
                float b = saturate(yRaw + 1.8556 * uv.x);
                return float3(r, g, b);
            } else {
                // BT.709 Studio/Limited-Range (16..235)
                float y = (yRaw - 0.0627451) * 1.16438356;
                float r = saturate(y + 1.79274107 * uv.y);
                float g = saturate(y - 0.21324861 * uv.x - 0.53290933 * uv.y);
                float b = saturate(y + 2.11240179 * uv.x);
                return float3(r, g, b);
            }
        }

        float4 main(PSIn input) : SV_Target {
            float3 e = sampleNv12Rgb(input.uv);
            float3 color = e;

            if (sharpness > 0.001) {
                float3 b = sampleNv12Rgb(input.uv + float2(0.0, -texelSize.y));
                float3 d = sampleNv12Rgb(input.uv + float2(-texelSize.x, 0.0));
                float3 f = sampleNv12Rgb(input.uv + float2(texelSize.x, 0.0));
                float3 h = sampleNv12Rgb(input.uv + float2(0.0, texelSize.y));

                float3 mnRGB = min(min(min(d, e), min(f, b)), h);
                float3 mxRGB = max(max(max(d, e), max(f, b)), h);
                float3 rcpMxRGB = 1.0 / max(mxRGB, float3(1e-5, 1e-5, 1e-5));
                float3 ampRGB = sqrt(saturate(min(mnRGB, 1.0 - mxRGB) * rcpMxRGB));

                float peak = -1.0 / lerp(8.0, 5.0, saturate(sharpness));
                float3 wRGB = ampRGB * peak;
                float3 rcpWeight = 1.0 / (1.0 + 4.0 * wRGB);
                color = saturate(((b + d + f + h) * wRGB + e) * rcpWeight);
            }

            return float4(color, 1.0);
        }
        """;

    private const string BgraPsHlsl = """
        cbuffer RenderParams : register(b0) {
            float2 texelSize;
            float  sharpness;
            int    fullRange;
        };

        Texture2D<float4> texBgra : register(t0);
        SamplerState      samp    : register(s0);

        struct PSIn {
            float4 pos : SV_Position;
            float2 uv  : TEXCOORD0;
        };

        float4 main(PSIn input) : SV_Target {
            float3 e = texBgra.Sample(samp, input.uv).rgb;
            float3 color = e;

            if (sharpness > 0.001) {
                float3 b = texBgra.Sample(samp, input.uv + float2(0.0, -texelSize.y)).rgb;
                float3 d = texBgra.Sample(samp, input.uv + float2(-texelSize.x, 0.0)).rgb;
                float3 f = texBgra.Sample(samp, input.uv + float2(texelSize.x, 0.0)).rgb;
                float3 h = texBgra.Sample(samp, input.uv + float2(0.0, texelSize.y)).rgb;

                float3 mnRGB = min(min(min(d, e), min(f, b)), h);
                float3 mxRGB = max(max(max(d, e), max(f, b)), h);
                float3 rcpMxRGB = 1.0 / max(mxRGB, float3(1e-5, 1e-5, 1e-5));
                float3 ampRGB = sqrt(saturate(min(mnRGB, 1.0 - mxRGB) * rcpMxRGB));

                float peak = -1.0 / lerp(8.0, 5.0, saturate(sharpness));
                float3 wRGB = ampRGB * peak;
                float3 rcpWeight = 1.0 / (1.0 + 4.0 * wRGB);
                color = saturate(((b + d + f + h) * wRGB + e) * rcpWeight);
            }

            return float4(color, 1.0);
        }
        """;

    // ── Initialization ──────────────────────────────────────────────────────

    public void Initialize(nint hwnd, int width, int height)
    {
        if (hwnd == nint.Zero) throw new ArgumentException("Invalid HWND", nameof(hwnd));

        lock (_renderLock)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);

            width = Math.Max(width, 1);
            height = Math.Max(height, 1);
            ViewportWidth = width;
            ViewportHeight = height;

            // 1. Create D3D11 hardware device with VideoSupport for DXVA MFT sharing
            var createFlags = DeviceCreationFlags.BgraSupport | DeviceCreationFlags.VideoSupport;
            var hr = D3D11.D3D11CreateDevice(
                null,
                DriverType.Hardware,
                createFlags,
                [FeatureLevel.Level_11_1, FeatureLevel.Level_11_0],
                out _device!);

            if (hr.Failure)
            {
                D3D11.D3D11CreateDevice(
                    null,
                    DriverType.Hardware,
                    DeviceCreationFlags.BgraSupport,
                    [FeatureLevel.Level_11_0],
                    out _device!).CheckError();
            }

            _context = _device.ImmediateContext;

            // Enable D3D11 multithread protection so MF DXVA decoder & renderer can share _device
            using (var mt = _device.QueryInterfaceOrNull<ID3D11Multithread>())
            {
                mt?.SetMultithreadProtected(true);
            }

            // 2. Query DXGI factory & tearing support
            using var dxgiDevice = _device.QueryInterface<IDXGIDevice1>();
            using var adapter = dxgiDevice.GetParent<IDXGIAdapter1>();
            using var factory2 = adapter.GetParent<IDXGIFactory2>();

            using (var factory5 = factory2.QueryInterfaceOrNull<IDXGIFactory5>())
            {
                AllowTearingSupported = factory5?.PresentAllowTearing ?? false;
            }

            // Default to VSync off when tearing is supported for ultra-low latency
            _vsyncEnabled = !AllowTearingSupported;

            _swapChainFlags = SwapChainFlags.FrameLatencyWaitableObject;
            if (AllowTearingSupported)
            {
                _swapChainFlags |= SwapChainFlags.AllowTearing;
            }

            var scDesc = new SwapChainDescription1
            {
                Width = width,
                Height = height,
                Format = Format.B8G8R8A8_UNorm,
                Stereo = false,
                SampleDescription = new SampleDescription(1, 0),
                BufferUsage = Usage.RenderTargetOutput,
                BufferCount = 2,
                Scaling = Scaling.Stretch,
                SwapEffect = SwapEffect.FlipDiscard,
                AlphaMode = AlphaMode.Ignore,
                Flags = _swapChainFlags,
            };

            _swapChain = factory2.CreateSwapChainForHwnd(_device, hwnd, scDesc);

            // Prevent DXGI from hijacking Alt+Enter (we handle fullscreen ourselves)
            try
            {
                factory2.MakeWindowAssociation(hwnd, WindowAssociationFlags.IgnoreAltEnter);
            }
            catch
            {
                // Non-fatal
            }

            // Configure waitable frame latency object with max latency = 1
            _swapChain2 = _swapChain.QueryInterfaceOrNull<IDXGISwapChain2>();
            if (_swapChain2 != null)
            {
                _swapChain2.MaximumFrameLatency = 1;
                _frameLatencyWaitableObject = _swapChain2.FrameLatencyWaitableObject;
            }

            CreateBackBufferRtv();
            CreatePipelineResources();

            _fpsWindowStartTick = Stopwatch.GetTimestamp();
            _fpsFrameCount = 0;

            // Present an initial black frame
            ClearAndPresentBlack();
        }
    }

    private void CreateBackBufferRtv()
    {
        _rtv?.Dispose();
        _rtv = null;

        using var backBuffer = _swapChain!.GetBuffer<ID3D11Texture2D>(0);
        _rtv = _device!.CreateRenderTargetView(backBuffer);
    }

    private void CreatePipelineResources()
    {
        byte[] vsBytecode = CompileHlsl(FullscreenVsHlsl, "main", "vs_5_0");
        byte[] nv12PsBytecode = CompileHlsl(Nv12PsHlsl, "main", "ps_5_0");
        byte[] bgraPsBytecode = CompileHlsl(BgraPsHlsl, "main", "ps_5_0");

        _vertexShader = _device!.CreateVertexShader(vsBytecode);
        _nv12PixelShader = _device.CreatePixelShader(nv12PsBytecode);
        _bgraPixelShader = _device.CreatePixelShader(bgraPsBytecode);

        var samplerDesc = new SamplerDescription
        {
            Filter = Filter.MinMagMipLinear,
            AddressU = TextureAddressMode.Clamp,
            AddressV = TextureAddressMode.Clamp,
            AddressW = TextureAddressMode.Clamp,
            MipLODBias = 0f,
            MaxAnisotropy = 1,
            ComparisonFunc = ComparisonFunction.Never,
            MinLOD = 0f,
            MaxLOD = float.MaxValue,
        };
        _linearSampler = _device.CreateSamplerState(samplerDesc);

        var rastDesc = new RasterizerDescription
        {
            FillMode = FillMode.Solid,
            CullMode = CullMode.None,
            FrontCounterClockwise = false,
            DepthClipEnable = false,
            ScissorEnable = false,
            MultisampleEnable = false,
            AntialiasedLineEnable = false,
        };
        _rasterizerState = _device.CreateRasterizerState(rastDesc);

        var cbDesc = new BufferDescription(
            16,
            BindFlags.ConstantBuffer,
            ResourceUsage.Dynamic,
            CpuAccessFlags.Write);
        _paramsBuffer = _device.CreateBuffer(cbDesc);
    }

    // ── Resize ──────────────────────────────────────────────────────────────

    public void Resize(int width, int height)
    {
        if (width <= 0 || height <= 0) return;

        lock (_renderLock)
        {
            if (_disposed || _swapChain == null || _context == null) return;
            if (ViewportWidth == width && ViewportHeight == height) return;

            ViewportWidth = width;
            ViewportHeight = height;

            _context.ClearState();
            _rtv?.Dispose();
            _rtv = null;
            _context.Flush();

            var hr = _swapChain.ResizeBuffers(
                2,
                width,
                height,
                Format.B8G8R8A8_UNorm,
                _swapChainFlags);

            if (hr.Failure)
            {
                Debug.WriteLine($"[D3D11Renderer] ResizeBuffers failed: 0x{hr.Code:X8}");
                return;
            }

            CreateBackBufferRtv();
            DrawCurrentAndPresent();
        }
    }

    // ── Render Paths ────────────────────────────────────────────────────────

    /// <summary>
    /// True GPU zero-copy NV12 path: copies the decoded DXVA subresource into our
    /// shader-readable NV12 GPU texture via CopySubresourceRegion and renders with
    /// the BT.709 NV12 pixel shader.
    /// </summary>
    public void RenderNv12Texture(ID3D11Texture2D srcTexture, int subresourceIndex, int videoWidth, int videoHeight)
    {
        if (srcTexture == null || videoWidth <= 0 || videoHeight <= 0) return;

        lock (_renderLock)
        {
            if (_disposed || _device == null || _context == null || _swapChain == null) return;

            EnsureNv12Resources(videoWidth, videoHeight, needStaging: false);

            var srcDesc = srcTexture.Description;
            int copyW = Math.Min(_nv12Width, (int)srcDesc.Width);
            int copyH = Math.Min(_nv12Height, (int)srcDesc.Height);
            if (copyW <= 0 || copyH <= 0) return;

            var srcBox = new Box(0, 0, 0, copyW, copyH, 1);
            _context.CopySubresourceRegion(
                _nv12GpuTex!,
                0,
                0, 0, 0,
                srcTexture,
                subresourceIndex,
                srcBox);

            VideoWidth = videoWidth;
            VideoHeight = videoHeight;
            _activeSurface = ActiveSurface.Nv12;

            DrawCurrentAndPresent();
        }
    }

    /// <summary>
    /// CPU-copy NV12 fallback path when DXVA MFT runs in software mode.
    /// </summary>
    public unsafe void RenderNv12Cpu(nint nv12Ptr, int stride, int videoWidth, int videoHeight)
    {
        if (nv12Ptr == nint.Zero || videoWidth <= 0 || videoHeight <= 0) return;
        if (stride <= 0) stride = videoWidth;

        lock (_renderLock)
        {
            if (_disposed || _device == null || _context == null || _swapChain == null) return;

            EnsureNv12Resources(videoWidth, videoHeight, needStaging: true);

            var mapped = _context.Map(_nv12StagingTex!, 0, MapMode.Write, D3D11MapFlags.None);
            try
            {
                int dstPitch = (int)mapped.RowPitch;
                byte* srcBase = (byte*)nv12Ptr;
                byte* dstBase = (byte*)mapped.DataPointer;

                // Copy Y plane (height rows of videoWidth bytes)
                int yCopyBytes = Math.Min(stride, dstPitch);
                if (stride == dstPitch && stride == videoWidth)
                {
                    Buffer.MemoryCopy(srcBase, dstBase, (long)dstPitch * videoHeight, (long)videoWidth * videoHeight);
                }
                else
                {
                    for (int y = 0; y < videoHeight; y++)
                    {
                        Buffer.MemoryCopy(
                            srcBase + (long)y * stride,
                            dstBase + (long)y * dstPitch,
                            dstPitch,
                            Math.Min(videoWidth, yCopyBytes));
                    }
                }

                // Copy UV plane (height/2 rows of videoWidth bytes)
                int uvHeight = videoHeight / 2;
                byte* srcUv = srcBase + (long)stride * videoHeight;
                byte* dstUv = dstBase + (long)dstPitch * _nv12Height;

                if (stride == dstPitch && stride == videoWidth)
                {
                    Buffer.MemoryCopy(srcUv, dstUv, (long)dstPitch * uvHeight, (long)videoWidth * uvHeight);
                }
                else
                {
                    for (int y = 0; y < uvHeight; y++)
                    {
                        Buffer.MemoryCopy(
                            srcUv + (long)y * stride,
                            dstUv + (long)y * dstPitch,
                            dstPitch,
                            Math.Min(videoWidth, yCopyBytes));
                    }
                }
            }
            finally
            {
                _context.Unmap(_nv12StagingTex!, 0);
            }

            _context.CopyResource(_nv12GpuTex!, _nv12StagingTex!);

            VideoWidth = videoWidth;
            VideoHeight = videoHeight;
            _activeSurface = ActiveSurface.Nv12;

            DrawCurrentAndPresent();
        }
    }

    /// <summary>
    /// Direct BGRA32 span upload path (used by JPEG / software fallback).
    /// </summary>
    public unsafe void RenderBgra(ReadOnlySpan<byte> bgraData, int width, int height, int stride = 0)
    {
        if (bgraData.IsEmpty || width <= 0 || height <= 0) return;
        if (stride <= 0) stride = width * 4;
        if (bgraData.Length < stride * height) return;

        fixed (byte* ptr = bgraData)
        {
            RenderBgra((nint)ptr, width, height, stride);
        }
    }

    /// <summary>
    /// Direct BGRA32 pointer upload path (zero extra copy from GDI+ BitmapData.Scan0).
    /// </summary>
    public unsafe void RenderBgra(nint bgraPtr, int width, int height, int stride)
    {
        if (bgraPtr == nint.Zero || width <= 0 || height <= 0) return;
        if (stride <= 0) stride = width * 4;

        lock (_renderLock)
        {
            if (_disposed || _device == null || _context == null || _swapChain == null) return;

            EnsureBgraResources(width, height);

            var mapped = _context.Map(_bgraTex!, 0, MapMode.WriteDiscard, D3D11MapFlags.None);
            try
            {
                int dstPitch = (int)mapped.RowPitch;
                int rowBytes = width * 4;
                byte* srcBase = (byte*)bgraPtr;
                byte* dstBase = (byte*)mapped.DataPointer;

                if (stride == dstPitch && stride == rowBytes)
                {
                    Buffer.MemoryCopy(srcBase, dstBase, (long)dstPitch * height, (long)rowBytes * height);
                }
                else
                {
                    for (int y = 0; y < height; y++)
                    {
                        Buffer.MemoryCopy(
                            srcBase + (long)y * stride,
                            dstBase + (long)y * dstPitch,
                            dstPitch,
                            rowBytes);
                    }
                }
            }
            finally
            {
                _context.Unmap(_bgraTex!, 0);
            }

            VideoWidth = width;
            VideoHeight = height;
            _activeSurface = ActiveSurface.Bgra;

            DrawCurrentAndPresent();
        }
    }

    /// <summary>
    /// Re-presents the most recent frame (e.g. after ScaleMode change or WM_PAINT).
    /// Non-blocking so UI-thread callers never deadlock against DXGI Present on the video thread.
    /// </summary>
    public void RePresent()
    {
        if (!Monitor.TryEnter(_renderLock, 0)) return;
        try
        {
            if (_disposed || _swapChain == null || _rtv == null) return;
            DrawCurrentAndPresent();
        }
        finally
        {
            Monitor.Exit(_renderLock);
        }
    }

    // ── Texture Resource Management ─────────────────────────────────────────

    private void EnsureNv12Resources(int width, int height, bool needStaging)
    {
        // NV12 requires even dimensions
        int alignedW = (width + 1) & ~1;
        int alignedH = (height + 1) & ~1;

        if (_nv12GpuTex == null || _nv12Width != alignedW || _nv12Height != alignedH)
        {
            _nv12YSrv?.Dispose();
            _nv12UvSrv?.Dispose();
            _nv12GpuTex?.Dispose();
            _nv12StagingTex?.Dispose();
            _nv12YSrv = null;
            _nv12UvSrv = null;
            _nv12GpuTex = null;
            _nv12StagingTex = null;

            _nv12Width = alignedW;
            _nv12Height = alignedH;

            _nv12GpuTex = _device!.CreateTexture2D(
                Format.NV12,
                alignedW,
                alignedH,
                mipLevels: 1,
                arraySize: 1,
                bindFlags: BindFlags.ShaderResource,
                usage: ResourceUsage.Default);

            var yDesc = new ShaderResourceViewDescription
            {
                Format = Format.R8_UNorm,
                ViewDimension = ShaderResourceViewDimension.Texture2D,
                Texture2D = new Texture2DShaderResourceView { MostDetailedMip = 0, MipLevels = 1 },
            };
            _nv12YSrv = _device.CreateShaderResourceView(_nv12GpuTex, yDesc);

            var uvDesc = new ShaderResourceViewDescription
            {
                Format = Format.R8G8_UNorm,
                ViewDimension = ShaderResourceViewDimension.Texture2D,
                Texture2D = new Texture2DShaderResourceView { MostDetailedMip = 0, MipLevels = 1 },
            };
            _nv12UvSrv = _device.CreateShaderResourceView(_nv12GpuTex, uvDesc);
        }

        if (needStaging && _nv12StagingTex == null)
        {
            _nv12StagingTex = _device!.CreateTexture2D(
                Format.NV12,
                _nv12Width,
                _nv12Height,
                mipLevels: 1,
                arraySize: 1,
                bindFlags: BindFlags.None,
                usage: ResourceUsage.Staging,
                cpuAccessFlags: CpuAccessFlags.Write);
        }
    }

    private void EnsureBgraResources(int width, int height)
    {
        if (_bgraTex != null && _bgraWidth == width && _bgraHeight == height) return;

        _bgraSrv?.Dispose();
        _bgraTex?.Dispose();
        _bgraSrv = null;
        _bgraTex = null;

        _bgraWidth = width;
        _bgraHeight = height;

        _bgraTex = _device!.CreateTexture2D(
            Format.B8G8R8A8_UNorm,
            width,
            height,
            mipLevels: 1,
            arraySize: 1,
            bindFlags: BindFlags.ShaderResource,
            usage: ResourceUsage.Dynamic,
            cpuAccessFlags: CpuAccessFlags.Write);

        var srvDesc = new ShaderResourceViewDescription
        {
            Format = Format.B8G8R8A8_UNorm,
            ViewDimension = ShaderResourceViewDimension.Texture2D,
            Texture2D = new Texture2DShaderResourceView { MostDetailedMip = 0, MipLevels = 1 },
        };
        _bgraSrv = _device.CreateShaderResourceView(_bgraTex, srvDesc);
    }

    // ── Core Draw + Present ─────────────────────────────────────────────────

    private void ClearAndPresentBlack()
    {
        if (_context == null || _rtv == null || _swapChain == null) return;

        _context.OMSetRenderTargets(_rtv);
        _context.ClearRenderTargetView(_rtv, new Color4(0f, 0f, 0f, 1f));
        PresentFrame();
    }

    private void DrawCurrentAndPresent()
    {
        if (_context == null || _rtv == null || _swapChain == null) return;

        // Wait on the flip-model frame latency object only when VSync is active (short 16ms cap)
        if (_vsyncEnabled && _frameLatencyWaitableObject != nint.Zero)
        {
            WaitForSingleObjectEx(_frameLatencyWaitableObject, 16, false);
        }

        _context.OMSetRenderTargets(_rtv);
        _context.ClearRenderTargetView(_rtv, new Color4(0f, 0f, 0f, 1f));

        if (_activeSurface == ActiveSurface.None || VideoWidth <= 0 || VideoHeight <= 0)
        {
            ContentRect = (0, 0, ViewportWidth, ViewportHeight);
            PresentFrame();
            return;
        }

        var (vpX, vpY, vpW, vpH) = ComputeDestinationRect(ViewportWidth, ViewportHeight, VideoWidth, VideoHeight, _scaleMode);
        ContentRect = (vpX, vpY, vpW, vpH);

        _context.RSSetState(_rasterizerState);
        _context.RSSetViewport(new Viewport(vpX, vpY, vpW, vpH, 0f, 1f));

        _context.IASetInputLayout(null);
        _context.IASetPrimitiveTopology(PrimitiveTopology.TriangleList);
        _context.VSSetShader(_vertexShader);
        _context.PSSetSampler(0, _linearSampler);
        UpdateAndBindRenderParams();

        if (_activeSurface == ActiveSurface.Nv12 && _nv12YSrv != null && _nv12UvSrv != null)
        {
            _context.PSSetShader(_nv12PixelShader);
            _context.PSSetShaderResource(0, _nv12YSrv);
            _context.PSSetShaderResource(1, _nv12UvSrv);
            _context.Draw(3, 0);
            _context.PSSetShaderResource(0, null!);
            _context.PSSetShaderResource(1, null!);
        }
        else if (_activeSurface == ActiveSurface.Bgra && _bgraSrv != null)
        {
            _context.PSSetShader(_bgraPixelShader);
            _context.PSSetShaderResource(0, _bgraSrv);
            _context.Draw(3, 0);
            _context.PSSetShaderResource(0, null!);
        }

        PresentFrame();
    }

    private unsafe void UpdateAndBindRenderParams()
    {
        if (_context == null || _paramsBuffer == null) return;

        var mapped = _context.Map(_paramsBuffer, 0, MapMode.WriteDiscard, D3D11MapFlags.None);
        try
        {
            *(RenderParams*)mapped.DataPointer = new RenderParams
            {
                TexelWidth = VideoWidth > 0 ? 1.0f / VideoWidth : 0f,
                TexelHeight = VideoHeight > 0 ? 1.0f / VideoHeight : 0f,
                Sharpness = _sharpness,
                FullRange = _fullRangeColor ? 1 : 0,
            };
        }
        finally
        {
            _context.Unmap(_paramsBuffer, 0);
        }

        _context.PSSetConstantBuffer(0, _paramsBuffer);
    }

    private void PresentFrame()
    {
        long t0 = Stopwatch.GetTimestamp();

        int syncInterval;
        PresentFlags presentFlags;
        if (_vsyncEnabled)
        {
            syncInterval = 1;
            presentFlags = PresentFlags.None;
        }
        else if (AllowTearingSupported)
        {
            syncInterval = 0;
            presentFlags = PresentFlags.AllowTearing;
        }
        else
        {
            syncInterval = 0;
            presentFlags = PresentFlags.None;
        }

        var hr = _swapChain!.Present(syncInterval, presentFlags);
        long t1 = Stopwatch.GetTimestamp();
        _lastPresentMs = (t1 - t0) * 1000.0 / Stopwatch.Frequency;

        if (hr.Failure)
        {
            Debug.WriteLine($"[D3D11Renderer] Present failed: 0x{hr.Code:X8}");
            return;
        }

        _fpsFrameCount++;
        double elapsedSec = (t1 - _fpsWindowStartTick) / (double)Stopwatch.Frequency;
        if (elapsedSec >= 1.0)
        {
            _renderedFps = _fpsFrameCount / elapsedSec;
            _fpsFrameCount = 0;
            _fpsWindowStartTick = t1;
        }
    }

    private static (float X, float Y, float W, float H) ComputeDestinationRect(
        int viewW, int viewH, int srcW, int srcH, ScaleMode mode)
    {
        if (viewW <= 0 || viewH <= 0 || srcW <= 0 || srcH <= 0)
            return (0, 0, Math.Max(viewW, 1), Math.Max(viewH, 1));

        switch (mode)
        {
            case ScaleMode.Stretch:
                return (0f, 0f, viewW, viewH);

            case ScaleMode.Original:
            {
                float x = (viewW - srcW) * 0.5f;
                float y = (viewH - srcH) * 0.5f;
                return (x, y, srcW, srcH);
            }

            case ScaleMode.Fit:
            default:
            {
                float srcAspect = (float)srcW / srcH;
                float dstAspect = (float)viewW / viewH;

                float drawW, drawH;
                if (dstAspect > srcAspect)
                {
                    drawH = viewH;
                    drawW = drawH * srcAspect;
                }
                else
                {
                    drawW = viewW;
                    drawH = drawW / srcAspect;
                }

                float x = (viewW - drawW) * 0.5f;
                float y = (viewH - drawH) * 0.5f;
                return (x, y, drawW, drawH);
            }
        }
    }

    // ── Native HLSL Compilation via built-in d3dcompiler_47.dll ────────────

    private static byte[] CompileHlsl(string source, string entryPoint, string target)
    {
        byte[] srcBytes = Encoding.ASCII.GetBytes(source);
        int hr = D3DCompile(
            srcBytes,
            (nuint)srcBytes.Length,
            null,
            nint.Zero,
            nint.Zero,
            entryPoint,
            target,
            D3DCOMPILE_OPTIMIZATION_LEVEL3,
            0,
            out nint pCodeBlob,
            out nint pErrorBlob);

        try
        {
            if (hr < 0 || pCodeBlob == nint.Zero)
            {
                string errMsg = $"D3DCompile({entryPoint}, {target}) failed: 0x{hr:X8}";
                if (pErrorBlob != nint.Zero)
                {
                    var errBlob = (ID3DBlobCom)Marshal.GetObjectForIUnknown(pErrorBlob);
                    nint errPtr = errBlob.GetBufferPointer();
                    int errLen = (int)errBlob.GetBufferSize();
                    if (errPtr != nint.Zero && errLen > 0)
                    {
                        errMsg += " - " + Marshal.PtrToStringAnsi(errPtr, errLen);
                    }
                }
                throw new InvalidOperationException(errMsg);
            }

            var codeBlob = (ID3DBlobCom)Marshal.GetObjectForIUnknown(pCodeBlob);
            nint ptr = codeBlob.GetBufferPointer();
            int len = (int)codeBlob.GetBufferSize();
            var bytecode = new byte[len];
            Marshal.Copy(ptr, bytecode, 0, len);
            return bytecode;
        }
        finally
        {
            if (pCodeBlob != nint.Zero) Marshal.Release(pCodeBlob);
            if (pErrorBlob != nint.Zero) Marshal.Release(pErrorBlob);
        }
    }

    private const uint D3DCOMPILE_OPTIMIZATION_LEVEL3 = 1u << 15;

    [DllImport("d3dcompiler_47.dll", CallingConvention = CallingConvention.Winapi, CharSet = CharSet.Ansi)]
    private static extern int D3DCompile(
        [In] byte[] pSrcData,
        nuint srcDataSize,
        string? pSourceName,
        nint pDefines,
        nint pInclude,
        string pEntrypoint,
        string pTarget,
        uint flags1,
        uint flags2,
        out nint ppCode,
        out nint ppErrorMsgs);

    [ComImport, Guid("8BA5FB08-5195-40E2-AC58-0D989C3A0102"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface ID3DBlobCom
    {
        [PreserveSig] nint GetBufferPointer();
        [PreserveSig] nuint GetBufferSize();
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObjectEx(nint hHandle, uint dwMilliseconds, bool bAlertable);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(nint hObject);

    // ── Dispose ─────────────────────────────────────────────────────────────

    public void Dispose()
    {
        lock (_renderLock)
        {
            if (_disposed) return;
            _disposed = true;

            _nv12YSrv?.Dispose();
            _nv12UvSrv?.Dispose();
            _nv12GpuTex?.Dispose();
            _nv12StagingTex?.Dispose();

            _bgraSrv?.Dispose();
            _bgraTex?.Dispose();

            _paramsBuffer?.Dispose();
            _rasterizerState?.Dispose();
            _linearSampler?.Dispose();
            _bgraPixelShader?.Dispose();
            _nv12PixelShader?.Dispose();
            _vertexShader?.Dispose();

            _rtv?.Dispose();
            _swapChain2?.Dispose();
            _swapChain?.Dispose();
            _context?.Dispose();
            _device?.Dispose();

            if (_frameLatencyWaitableObject != nint.Zero)
            {
                CloseHandle(_frameLatencyWaitableObject);
                _frameLatencyWaitableObject = nint.Zero;
            }

            _nv12YSrv = null;
            _nv12UvSrv = null;
            _nv12GpuTex = null;
            _nv12StagingTex = null;
            _bgraSrv = null;
            _bgraTex = null;
            _paramsBuffer = null;
            _rasterizerState = null;
            _linearSampler = null;
            _bgraPixelShader = null;
            _nv12PixelShader = null;
            _vertexShader = null;
            _rtv = null;
            _swapChain2 = null;
            _swapChain = null;
            _context = null;
            _device = null;
        }
    }
}
