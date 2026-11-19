import AppKit
import Metal
import MetalKit
import CoreVideo
import QuartzCore
import simd

/// Zero-copy Metal video renderer (`MTKView` subclass) supporting NV12 (`IOSurface` / `CVMetalTextureCache`)
/// and BGRA (`kCVPixelFormatType_32BGRA`) `CVPixelBuffer`s via inline-compiled MSL shaders.
public final class MetalRendererView: MTKView, MTKViewDelegate {

    // MARK: - Public Properties

    public var scaleMode: ScaleMode = .fit {
        didSet {
            if scaleMode != oldValue {
                needsDisplay = true
            }
        }
    }

    public var sharpness: SharpnessLevel = .low {
        didSet {
            if sharpness != oldValue {
                needsDisplay = true
            }
        }
    }

    public var toneMap: Bool = false {
        didSet {
            if toneMap != oldValue {
                needsDisplay = true
            }
        }
    }

    public var videoSize: CGSize {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        return _videoSize
    }

    /// Exact active video rect in view-local coordinates (matching the rendered NDC quad).
    public var videoRect: NSRect {
        let size = videoSize
        let scale = computeNDCScale(viewSize: bounds.size, videoSize: size)
        let w = bounds.width * CGFloat(scale.x)
        let h = bounds.height * CGFloat(scale.y)
        let x = (bounds.width - w) * 0.5
        let y = (bounds.height - h) * 0.5
        return NSRect(x: x, y: y, width: w, height: h)
    }

    public var onVideoSizeChanged: ((CGSize) -> Void)?

    public var targetFPS: Int {
        get { preferredFramesPerSecond }
        set { preferredFramesPerSecond = max(1, min(240, newValue)) }
    }

    public var vsyncEnabled: Bool {
        get { (layer as? CAMetalLayer)?.displaySyncEnabled ?? true }
        set { (layer as? CAMetalLayer)?.displaySyncEnabled = newValue }
    }

    /// Optional input manager attached directly to this view for mouse/keyboard/scroll event forwarding.
    public weak var inputManager: InputManager?

    // MARK: - Private Metal State

    private struct VertexUniforms {
        var scale: SIMD2<Float>
    }

    private struct YUVFragmentUniforms {
        var colorMatrix: simd_float3x3
        var texelSize: SIMD2<Float>
        var yOffset: Float
        var sharpness: Float
        var isFullRange: UInt32
        var toneMap: UInt32
    }

    private struct BGRAFragmentUniforms {
        var texelSize: SIMD2<Float>
        var sharpness: Float
        var toneMap: UInt32
    }

    private var commandQueue: MTLCommandQueue?
    private var nv12PipelineState: MTLRenderPipelineState?
    private var bgraPipelineState: MTLRenderPipelineState?
    private var textureCache: CVMetalTextureCache?

    private let bufferLock = NSLock()
    private var currentPixelBuffer: CVPixelBuffer?
    private var _videoSize: CGSize = .zero

    private static let mslSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexUniforms {
        float2 scale;
    };

    struct YUVUniforms {
        float3x3 colorMatrix;
        float2 texelSize;
        float yOffset;
        float sharpness;
        uint isFullRange;
        uint toneMap;
    };

    struct BGRAUniforms {
        float2 texelSize;
        float sharpness;
        uint toneMap;
    };

    struct VertexOut {
        float4 position [[position]];
        float2 texCoords;
    };

    inline float3 acesFilmic(float3 x) {
        const float a = 2.51;
        const float b = 0.03;
        const float c = 2.43;
        const float d = 0.59;
        const float e = 0.14;
        return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0);
    }

    inline float3 applyCAS(float3 e, float3 b, float3 d, float3 f, float3 h, float sharpness) {
        float3 mnRGB = min(min(min(d, e), min(f, b)), h);
        float3 mxRGB = max(max(max(d, e), max(f, b)), h);
        float3 rcpMxRGB = 1.0 / max(mxRGB, float3(1e-5));
        float3 ampRGB = clamp(min(mnRGB, 1.0 - mxRGB) * rcpMxRGB, 0.0, 1.0);
        ampRGB = sqrt(ampRGB);
        float peak = -1.0 / mix(8.0, 5.0, clamp(sharpness, 0.0, 1.0));
        float3 wRGB = ampRGB * peak;
        float3 rcpWeightRGB = 1.0 / (1.0 + 4.0 * wRGB);
        return clamp(((b + d + f + h) * wRGB + e) * rcpWeightRGB, 0.0, 1.0);
    }

    inline float3 applyToneMap(float3 color) {
        float3 linear = pow(max(color, float3(0.0)), float3(2.2));
        float3 mapped = acesFilmic(linear * 1.15);
        return pow(mapped, float3(1.0 / 2.2));
    }

    inline float3 sampleNV12RGB(
        texture2d<float, access::sample> yTex,
        texture2d<float, access::sample> uvTex,
        sampler s,
        float2 uvCoord,
        constant YUVUniforms &uniforms
    ) {
        float y = yTex.sample(s, uvCoord).r - uniforms.yOffset;
        float2 uv = uvTex.sample(s, uvCoord).rg - float2(0.5, 0.5);
        return clamp(uniforms.colorMatrix * float3(y, uv.x, uv.y), 0.0, 1.0);
    }

    vertex VertexOut remoterVertexShader(
        uint vertexID [[vertex_id]],
        constant VertexUniforms &uniforms [[buffer(0)]]
    ) {
        constexpr float2 positions[4] = {
            float2(-1.0,  1.0),
            float2( 1.0,  1.0),
            float2(-1.0, -1.0),
            float2( 1.0, -1.0)
        };
        constexpr float2 uvs[4] = {
            float2(0.0, 0.0),
            float2(1.0, 0.0),
            float2(0.0, 1.0),
            float2(1.0, 1.0)
        };
        VertexOut out;
        out.position = float4(positions[vertexID] * uniforms.scale, 0.0, 1.0);
        out.texCoords = uvs[vertexID];
        return out;
    }

    fragment float4 remoterNV12FragmentShader(
        VertexOut in [[stage_in]],
        texture2d<float, access::sample> yTex [[texture(0)]],
        texture2d<float, access::sample> uvTex [[texture(1)]],
        constant YUVUniforms &uniforms [[buffer(0)]]
    ) {
        constexpr sampler s(address::clamp_to_edge, filter::linear);
        float3 e = sampleNV12RGB(yTex, uvTex, s, in.texCoords, uniforms);
        float3 color = e;

        if (uniforms.sharpness > 0.001) {
            float2 ts = uniforms.texelSize;
            float3 b = sampleNV12RGB(yTex, uvTex, s, in.texCoords + float2(0.0, -ts.y), uniforms);
            float3 d = sampleNV12RGB(yTex, uvTex, s, in.texCoords + float2(-ts.x, 0.0), uniforms);
            float3 f = sampleNV12RGB(yTex, uvTex, s, in.texCoords + float2(ts.x, 0.0), uniforms);
            float3 h = sampleNV12RGB(yTex, uvTex, s, in.texCoords + float2(0.0, ts.y), uniforms);
            color = applyCAS(e, b, d, f, h, uniforms.sharpness);
        }

        if (uniforms.toneMap != 0) {
            color = applyToneMap(color);
        }

        return float4(color, 1.0);
    }

    fragment float4 remoterBGRAFragmentShader(
        VertexOut in [[stage_in]],
        texture2d<float, access::sample> bgraTex [[texture(0)]],
        constant BGRAUniforms &uniforms [[buffer(0)]]
    ) {
        constexpr sampler s(address::clamp_to_edge, filter::linear);
        float3 e = bgraTex.sample(s, in.texCoords).rgb;
        float3 color = e;

        if (uniforms.sharpness > 0.001) {
            float2 ts = uniforms.texelSize;
            float3 b = bgraTex.sample(s, in.texCoords + float2(0.0, -ts.y)).rgb;
            float3 d = bgraTex.sample(s, in.texCoords + float2(-ts.x, 0.0)).rgb;
            float3 f = bgraTex.sample(s, in.texCoords + float2(ts.x, 0.0)).rgb;
            float3 h = bgraTex.sample(s, in.texCoords + float2(0.0, ts.y)).rgb;
            color = applyCAS(e, b, d, f, h, uniforms.sharpness);
        }

        if (uniforms.toneMap != 0) {
            color = applyToneMap(color);
        }

        return float4(color, 1.0);
    }
    """

    // BT.709 Video Range (16..235 / 16..240)
    private static let bt709VideoMatrix = simd_float3x3(columns: (
        SIMD3<Float>(1.164383, 1.164383, 1.164383),
        SIMD3<Float>(0.000000, -0.213249, 2.112402),
        SIMD3<Float>(1.792741, -0.532909, 0.000000)
    ))

    // BT.709 Full Range (0..255)
    private static let bt709FullMatrix = simd_float3x3(columns: (
        SIMD3<Float>(1.000000, 1.000000, 1.000000),
        SIMD3<Float>(0.000000, -0.187324, 1.855600),
        SIMD3<Float>(1.574800, -0.468124, 0.000000)
    ))

    // BT.601 Video Range
    private static let bt601VideoMatrix = simd_float3x3(columns: (
        SIMD3<Float>(1.164383, 1.164383, 1.164383),
        SIMD3<Float>(0.000000, -0.391762, 2.017232),
        SIMD3<Float>(1.596027, -0.812968, 0.000000)
    ))

    // BT.601 Full Range
    private static let bt601FullMatrix = simd_float3x3(columns: (
        SIMD3<Float>(1.000000, 1.000000, 1.000000),
        SIMD3<Float>(0.000000, -0.344136, 1.772000),
        SIMD3<Float>(1.402000, -0.714136, 0.000000)
    ))

    // MARK: - Init

    public init(frame: NSRect) {
        let metalDevice = MTLCreateSystemDefaultDevice()
        super.init(frame: frame, device: metalDevice)
        if let metalDevice {
            configureMetal(device: metalDevice)
        }
    }

    public required init(coder: NSCoder) {
        let metalDevice = MTLCreateSystemDefaultDevice()
        super.init(coder: coder)
        self.device = metalDevice
        if let metalDevice {
            configureMetal(device: metalDevice)
        }
    }

    private func configureMetal(device: MTLDevice) {
        self.delegate = self
        self.colorPixelFormat = .bgra8Unorm
        if let metalLayer = self.layer as? CAMetalLayer {
            metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        }
        self.clearColor = MTLClearColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1.0)
        self.isPaused = false
        self.enableSetNeedsDisplay = false
        self.preferredFramesPerSecond = 60
        self.framebufferOnly = true

        self.commandQueue = device.makeCommandQueue()
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)

        do {
            let library = try device.makeLibrary(source: Self.mslSource, options: nil)
            let vertexFn = library.makeFunction(name: "remoterVertexShader")

            if let nv12Frag = library.makeFunction(name: "remoterNV12FragmentShader") {
                let desc = MTLRenderPipelineDescriptor()
                desc.vertexFunction = vertexFn
                desc.fragmentFunction = nv12Frag
                desc.colorAttachments[0].pixelFormat = self.colorPixelFormat
                self.nv12PipelineState = try device.makeRenderPipelineState(descriptor: desc)
            }

            if let bgraFrag = library.makeFunction(name: "remoterBGRAFragmentShader") {
                let desc = MTLRenderPipelineDescriptor()
                desc.vertexFunction = vertexFn
                desc.fragmentFunction = bgraFrag
                desc.colorAttachments[0].pixelFormat = self.colorPixelFormat
                self.bgraPipelineState = try device.makeRenderPipelineState(descriptor: desc)
            }
        } catch {
            NSLog("MetalRendererView: Failed to compile MSL pipelines: %@", error.localizedDescription)
        }
    }

    // MARK: - Public Frame & Coordinate API

    /// Thread-safe frame update called from `VideoDecoder.onDecodedFrame`.
    public func updateFrame(_ pixelBuffer: CVPixelBuffer) {
        let w = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let h = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let newSize = CGSize(width: w, height: h)

        var sizeChanged = false
        bufferLock.lock()
        currentPixelBuffer = pixelBuffer
        if w > 0, h > 0, _videoSize != newSize {
            _videoSize = newSize
            sizeChanged = true
        }
        bufferLock.unlock()

        if sizeChanged {
            DispatchQueue.main.async { [weak self] in
                self?.onVideoSizeChanged?(newSize)
            }
        }
    }

    /// Clears the displayed frame (e.g., on disconnect).
    public func clearFrame() {
        bufferLock.lock()
        currentPixelBuffer = nil
        _videoSize = .zero
        bufferLock.unlock()
    }

    /// Maps a point in view-local coordinates (AppKit bottom-left origin) to normalized remote coordinates
    /// `(x, y)` in `[0.0, 1.0]` with top-left `(0, 0)` and bottom-right `(1, 1)`.
    /// Accounts accurately for `.fit` letterboxing, `.stretch`, and `.original` scaling.
    public func normalizePoint(_ viewPoint: NSPoint) -> (Double, Double)? {
        let rect = videoRect
        guard rect.width > 0, rect.height > 0 else { return nil }

        let nx = Double((viewPoint.x - rect.origin.x) / rect.width)
        let ny: Double
        if isFlipped {
            ny = Double((viewPoint.y - rect.origin.y) / rect.height)
        } else {
            ny = Double(1.0 - ((viewPoint.y - rect.origin.y) / rect.height))
        }

        return (min(1.0, max(0.0, nx)), min(1.0, max(0.0, ny)))
    }

    /// Convenience helper converting an `NSEvent.locationInWindow` directly to normalized remote coordinates.
    public func normalizeWindowPoint(_ windowPoint: NSPoint) -> (Double, Double)? {
        let local = convert(windowPoint, from: nil)
        return normalizePoint(local)
    }

    // MARK: - Layout Math

    private func computeNDCScale(viewSize: CGSize, videoSize: CGSize) -> SIMD2<Float> {
        guard viewSize.width > 0, viewSize.height > 0,
              videoSize.width > 0, videoSize.height > 0 else {
            return SIMD2<Float>(1.0, 1.0)
        }

        switch scaleMode {
        case .stretch:
            return SIMD2<Float>(1.0, 1.0)
        case .fit:
            let viewAspect = viewSize.width / viewSize.height
            let videoAspect = videoSize.width / videoSize.height
            if videoAspect > viewAspect {
                return SIMD2<Float>(1.0, Float(viewAspect / videoAspect))
            } else {
                return SIMD2<Float>(Float(videoAspect / viewAspect), 1.0)
            }
        case .original:
            let backingScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
            let pixelViewW = viewSize.width * backingScale
            let pixelViewH = viewSize.height * backingScale
            guard pixelViewW > 0, pixelViewH > 0 else { return SIMD2<Float>(1.0, 1.0) }
            return SIMD2<Float>(Float(videoSize.width / pixelViewW), Float(videoSize.height / pixelViewH))
        }
    }

    // MARK: - MTKViewDelegate

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        bufferLock.lock()
        let pixelBuffer = currentPixelBuffer
        let currentSize = _videoSize
        bufferLock.unlock()

        guard let device = self.device,
              let commandQueue = self.commandQueue,
              let renderPassDesc = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable else {
            return
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDesc) else {
            return
        }

        if let pixelBuffer {
            let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
            var vertexUniforms = VertexUniforms(scale: computeNDCScale(viewSize: bounds.size, videoSize: currentSize))

            if pixelFormat == kCVPixelFormatType_32BGRA {
                drawBGRA(
                    pixelBuffer: pixelBuffer,
                    device: device,
                    encoder: encoder,
                    vertexUniforms: &vertexUniforms
                )
            } else {
                drawNV12(
                    pixelBuffer: pixelBuffer,
                    pixelFormat: pixelFormat,
                    device: device,
                    encoder: encoder,
                    vertexUniforms: &vertexUniforms
                )
            }
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()

        if let cache = textureCache {
            CVMetalTextureCacheFlush(cache, 0)
        }
    }

    private func drawNV12(
        pixelBuffer: CVPixelBuffer,
        pixelFormat: OSType,
        device: MTLDevice,
        encoder: MTLRenderCommandEncoder,
        vertexUniforms: inout VertexUniforms
    ) {
        guard let pipeline = nv12PipelineState else { return }

        var yTexture: MTLTexture?
        var uvTexture: MTLTexture?
        // Retain CVMetalTexture handles until draw completes
        var cvYRef: CVMetalTexture?
        var cvUVRef: CVMetalTexture?

        let yW = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let yH = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let uvW = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
        let uvH = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
        guard yW > 0, yH > 0, uvW > 0, uvH > 0 else { return }

        let is10Bit = (
            pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange ||
            pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
            pixelFormat == kCVPixelFormatType_444YpCbCr10BiPlanarFullRange ||
            pixelFormat == kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange
        )
        let yPixelFormat: MTLPixelFormat = is10Bit ? .r16Unorm : .r8Unorm
        let uvPixelFormat: MTLPixelFormat = is10Bit ? .rg16Unorm : .rg8Unorm

        if let surfaceRef = CVPixelBufferGetIOSurface(pixelBuffer) {
            let surface = surfaceRef.takeUnretainedValue()
            let yDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: yPixelFormat, width: yW, height: yH, mipmapped: false)
            yDesc.usage = [.shaderRead]
            yTexture = device.makeTexture(descriptor: yDesc, iosurface: surface, plane: 0)

            let uvDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: uvPixelFormat, width: uvW, height: uvH, mipmapped: false)
            uvDesc.usage = [.shaderRead]
            uvTexture = device.makeTexture(descriptor: uvDesc, iosurface: surface, plane: 1)
        }

        if (yTexture == nil || uvTexture == nil), let cache = textureCache {
            CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, cache, pixelBuffer, nil, yPixelFormat, yW, yH, 0, &cvYRef
            )
            if let cvYRef { yTexture = CVMetalTextureGetTexture(cvYRef) }

            CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, cache, pixelBuffer, nil, uvPixelFormat, uvW, uvH, 1, &cvUVRef
            )
            if let cvUVRef { uvTexture = CVMetalTextureGetTexture(cvUVRef) }
        }

        guard let yTex = yTexture, let uvTex = uvTexture else { return }

        let isFullRange = (
            pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
            pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange ||
            pixelFormat == kCVPixelFormatType_444YpCbCr8BiPlanarFullRange ||
            pixelFormat == kCVPixelFormatType_444YpCbCr10BiPlanarFullRange
        )
        let isBT601 = isBT601ColorMatrix(pixelBuffer)
        let matrix: simd_float3x3
        if isBT601 {
            matrix = isFullRange ? Self.bt601FullMatrix : Self.bt601VideoMatrix
        } else {
            matrix = isFullRange ? Self.bt709FullMatrix : Self.bt709VideoMatrix
        }

        var yuvUniforms = YUVFragmentUniforms(
            colorMatrix: matrix,
            texelSize: SIMD2<Float>(1.0 / Float(yW), 1.0 / Float(yH)),
            yOffset: isFullRange ? 0.0 : (16.0 / 255.0),
            sharpness: sharpness.strength,
            isFullRange: isFullRange ? 1 : 0,
            toneMap: toneMap ? 1 : 0
        )

        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&vertexUniforms, length: MemoryLayout<VertexUniforms>.size, index: 0)
        encoder.setFragmentTexture(yTex, index: 0)
        encoder.setFragmentTexture(uvTex, index: 1)
        encoder.setFragmentBytes(&yuvUniforms, length: MemoryLayout<YUVFragmentUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    private func drawBGRA(
        pixelBuffer: CVPixelBuffer,
        device: MTLDevice,
        encoder: MTLRenderCommandEncoder,
        vertexUniforms: inout VertexUniforms
    ) {
        guard let pipeline = bgraPipelineState else { return }

        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        guard w > 0, h > 0 else { return }

        var bgraTexture: MTLTexture?
        var cvRef: CVMetalTexture?

        if let surfaceRef = CVPixelBufferGetIOSurface(pixelBuffer) {
            let surface = surfaceRef.takeUnretainedValue()
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
            desc.usage = [.shaderRead]
            bgraTexture = device.makeTexture(descriptor: desc, iosurface: surface, plane: 0)
        }

        if bgraTexture == nil, let cache = textureCache {
            CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, cache, pixelBuffer, nil, .bgra8Unorm, w, h, 0, &cvRef
            )
            if let cvRef { bgraTexture = CVMetalTextureGetTexture(cvRef) }
        }

        guard let tex = bgraTexture else { return }

        var bgraUniforms = BGRAFragmentUniforms(
            texelSize: SIMD2<Float>(1.0 / Float(w), 1.0 / Float(h)),
            sharpness: sharpness.strength,
            toneMap: toneMap ? 1 : 0
        )

        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&vertexUniforms, length: MemoryLayout<VertexUniforms>.size, index: 0)
        encoder.setFragmentTexture(tex, index: 0)
        encoder.setFragmentBytes(&bgraUniforms, length: MemoryLayout<BGRAFragmentUniforms>.size, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    private func isBT601ColorMatrix(_ pixelBuffer: CVPixelBuffer) -> Bool {
        guard let attachment = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, nil) else {
            return false
        }
        let matrixName = attachment as! CFString
        return CFStringCompare(matrixName, kCVImageBufferYCbCrMatrix_ITU_R_601_4, []) == .compareEqualTo
    }

    // MARK: - AppKit Responder & Tracking Area Forwarding

    public override var acceptsFirstResponder: Bool { true }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        let options: NSTrackingArea.Options = [
            .mouseMoved,
            .mouseEnteredAndExited,
            .activeInKeyWindow,
            .inVisibleRect
        ]
        addTrackingArea(NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil))
    }

    public override func mouseMoved(with event: NSEvent) {
        inputManager?.handleMouseMoved(event)
    }

    public override func mouseDragged(with event: NSEvent) {
        inputManager?.handleMouseDragged(event, button: "left")
    }

    public override func rightMouseDragged(with event: NSEvent) {
        inputManager?.handleMouseDragged(event, button: "right")
    }

    public override func otherMouseDragged(with event: NSEvent) {
        inputManager?.handleMouseDragged(event, button: InputManager.otherButtonName(event.buttonNumber))
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        inputManager?.handleMouseDown(event, button: "left")
    }

    public override func mouseUp(with event: NSEvent) {
        inputManager?.handleMouseUp(event, button: "left")
    }

    public override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        inputManager?.handleMouseDown(event, button: "right")
    }

    public override func rightMouseUp(with event: NSEvent) {
        inputManager?.handleMouseUp(event, button: "right")
    }

    public override func otherMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        inputManager?.handleMouseDown(event, button: InputManager.otherButtonName(event.buttonNumber))
    }

    public override func otherMouseUp(with event: NSEvent) {
        inputManager?.handleMouseUp(event, button: InputManager.otherButtonName(event.buttonNumber))
    }

    public override func scrollWheel(with event: NSEvent) {
        inputManager?.handleScrollWheel(event)
    }

    public override func keyDown(with event: NSEvent) {
        inputManager?.handleKeyDown(event)
    }

    public override func keyUp(with event: NSEvent) {
        inputManager?.handleKeyUp(event)
    }

    public override func flagsChanged(with event: NSEvent) {
        inputManager?.handleFlagsChanged(event)
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let inputManager, inputManager.shouldCaptureKeyEquivalent(event) {
            inputManager.handleKeyDown(event)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
