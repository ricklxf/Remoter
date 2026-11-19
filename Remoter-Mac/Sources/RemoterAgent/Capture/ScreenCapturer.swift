import Foundation
import AppKit
import CoreGraphics
import CoreVideo
import ScreenCaptureKit

// SCStream — ScreenCaptureKit compositor readback (replaces CGDisplayStream).
// CGDisplayStream's frame delivery is paced by the display's internal vsync;
// on a headless Mac (no physical monitor attached) that clock is unreliable,
// so frames arrive in irregular bursts instead of a steady cadence — this
// showed up as encode/sent fps swinging between ~5fps and ~50fps every few
// seconds. SCStream doesn't depend on a real vsync source the same way and
// is what modern remote-desktop tools use for headless capture.
//
// Frames are handled synchronously on captureQueue as SCStream delivers them
// (see handle() below for why), which also means encode submission is
// naturally paced by capture — no separate queue or backpressure needed here.

enum ChromaMode: String, Sendable {
    case yuv420 = "420"
    case yuv444 = "444"
}

final class ScreenCapturer: NSObject, @unchecked Sendable {
    // CVPixelBuffer straight from SCStream — H264Encoder feeds it to
    // VideoToolbox directly. Used to render this to a CGImage first (via
    // CIContext) and hand that up, but VT accepts CVPixelBuffer natively and
    // we requested BGRA32 in SCStreamConfiguration below, so that render was
    // pure overhead: a GPU/CPU round-trip that produced a CGImage just so
    // H264Encoder could immediately draw it into a *different* CVPixelBuffer.
    // Same waste existed with CGDisplayStream before it. Skipping it roughly
    // halved per-frame CPU cost, which matters most exactly when it's
    // scarce — background load on the Mac competing for the same cores was
    // showing up as capture-side fps collapsing (encode CPU time doubling)
    // well before any network/decode limit was ever hit.
    var onFrame:   ((CVPixelBuffer, Int, Int) -> Void)?
    var onStaticFrameReady: ((CVPixelBuffer) -> Void)?
    var onStopped: (() -> Void)?   // called when SCStream reports a stop/error
    // System audio PCM from SCStream (48kHz float). Capture always runs (the
    // cost of unconsumed PCM callbacks is negligible); Session only encodes/
    // sends when the client actually asked for audio, so toggling it on
    // doesn't need a stream rebuild.
    var onAudioSample: ((CMSampleBuffer) -> Void)?

    private(set) var physWidth:    Int = 1920  // physical display pixels
    private(set) var physHeight:   Int = 1080
    private(set) var pointWidth:   Double = 1920 // display bounds in points (CGEvent coordinate space)
    private(set) var pointHeight:  Double = 1080
    private(set) var screenWidth:  Int = 960   // encode/stream resolution
    private(set) var screenHeight: Int = 540
    private(set) var currentFps:    Int = 60
    private(set) var currentChroma: ChromaMode = .yuv420
    private(set) var currentHdr:    Bool = false
    // Global-desktop origin of the captured display (needed to map the
    // client's display-relative coords to CGEvent's global space) and the
    // full display list (sent to the client so it can offer a picker).
    /// Hardware refresh rate of the captured display (60 when the mode
    /// doesn't report one). SCStream can't deliver faster than this.
    private(set) var maxRefreshRate: Int = 60
    private(set) var originX: Double = 0
    private(set) var originY: Double = 0
    private(set) var displays: [(id: UInt32, name: String, width: Int, height: Int)] = []

    private var stream: SCStream?
    private var streamOutput: StreamOutput?
    // Static-frame refinement state (accessed exclusively on captureQueue)
    private var latestPixelBuffer: CVPixelBuffer?
    private var staticFrameWorkItem: DispatchWorkItem?
    private let staticFrameDelaySeconds: TimeInterval = 0.15
    // .userInteractive, not .userInitiated — the comment on handle() below
    // (and on onFrame above) already documents that background CPU
    // contention on this Mac shows up directly as capture-side fps
    // collapse. .userInitiated can still get deprioritized under real
    // system load; .userInteractive is the one QoS tier the scheduler
    // treats as near-realtime, which is what a synchronous per-frame
    // capture callback actually is.
    private let captureQueue    = DispatchQueue(label: "remoter.capture.cb", qos: .userInteractive)
    private let audioQueue      = DispatchQueue(label: "remoter.capture.audio", qos: .userInitiated)

    // Diagnostics (benign data-race on counters — log only)
    private var statFrames:   Int = 0
    private var statTick:     CFAbsoluteTime = 0

    /// maxDimension caps the longer side (preserving aspect ratio) — e.g.
    /// 1920 for "1080p", 2560 for "2K". nil/omitted uses the physical
    /// display resolution as-is. Never upscales past physical regardless of
    /// the cap given.
    func start(
        fps: Int = 60,
        maxDimension: Int? = nil,
        displayID requestedID: UInt32? = nil,
        chroma: ChromaMode = .yuv420,
        hdr: Bool = false
    ) async throws {
        statTick = CFAbsoluteTimeGetCurrent()
        currentFps = fps
        currentChroma = chroma
        currentHdr = hdr

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            ConnectionLogger.shared.logStep(sessionId: "capturer", step: "no_capture_permission",
                detail: "\(error)")
            throw RemoterError.captureUnavailable
        }

        // Human-readable display names come from NSScreen (SCDisplay has
        // none); match by the NSScreenNumber device-description key.
        var names: [UInt32: String] = [:]
        for screen in NSScreen.screens {
            if let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                names[num.uint32Value] = screen.localizedName
            }
        }
        displays = content.displays.enumerated().map { i, d in
            (id: d.displayID, name: names[d.displayID] ?? "显示器 \(i + 1)", width: d.width, height: d.height)
        }

        let displayID = requestedID.flatMap { req in
            content.displays.first(where: { $0.displayID == req })?.displayID
        } ?? CGMainDisplayID()
        var display = content.displays.first(where: { $0.displayID == displayID })
            ?? content.displays.first

        // Headless / Clamshell fallback: If no display is detected, dynamically create a virtual display
        if display == nil {
            ConnectionLogger.shared.logStep(sessionId: "capturer", step: "headless_detected", detail: "Creating virtual display")
            if let vId = VirtualDisplayManager.shared.createOrUpdateVirtualDisplay(width: 1920, height: 1080, refreshRate: Double(fps), hiDPI: true) {
                try? await Task.sleep(nanoseconds: 350_000_000)
                if let freshContent = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) {
                    display = freshContent.displays.first(where: { $0.displayID == vId }) ?? freshContent.displays.first
                }
            }
        }

        guard let display else {
            ConnectionLogger.shared.logStep(sessionId: "capturer", step: "no_capture_permission",
                detail: "no SCDisplay matched displayID=\(displayID)")
            throw RemoterError.captureUnavailable
        }

        physWidth  = Int(CGDisplayPixelsWide(display.displayID))
        physHeight = Int(CGDisplayPixelsHigh(display.displayID))
        let bounds = CGDisplayBounds(display.displayID)
        pointWidth  = bounds.width > 0 ? bounds.width : Double(physWidth)
        pointHeight = bounds.height > 0 ? bounds.height : Double(physHeight)
        if let rate = CGDisplayCopyDisplayMode(display.displayID)?.refreshRate, rate >= 1 {
            maxRefreshRate = Int(rate.rounded())
        } else {
            maxRefreshRate = 60
        }
        originX = bounds.origin.x
        originY = bounds.origin.y
        if let maxDimension, maxDimension < max(physWidth, physHeight) {
            let scale = Double(maxDimension) / Double(max(physWidth, physHeight))
            // SCStreamConfiguration wants even dimensions.
            screenWidth  = Int(Double(physWidth)  * scale) & ~1
            screenHeight = Int(Double(physHeight) * scale) & ~1
        } else {
            screenWidth  = physWidth
            screenHeight = physHeight
        }

        ConnectionLogger.shared.logStep(sessionId: "capturer", step: "display_found",
            detail: "id=\(display.displayID) of \(displays.count) phys=\(physWidth)x\(physHeight) stream=\(screenWidth)x\(screenHeight) origin=\(Int(originX)),\(Int(originY))")

        let overlayIDs = Set(PrivacyScreenManager.shared.getOverlayWindowIDs())
        let excluded = content.windows.filter { overlayIDs.contains(CGWindowID($0.windowID)) }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)

        let preferredFormat = preferredPixelFormat(chroma: chroma, hdr: hdr)
        let config = makeConfiguration(fps: fps, chroma: chroma, hdr: hdr, pixelFormatOverride: preferredFormat)

        let output = StreamOutput(capturer: self)
        var s = SCStream(filter: filter, configuration: config, delegate: output)
        do {
            try await startStreamWithTimeout(s, output: output)
        } catch {
            if preferredFormat != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange {
                // Safe fallback when macOS SCStream rejects 444 or 10-bit video-range pixel format.
                let fallbackHdr = false
                let fallbackChroma: ChromaMode = .yuv420
                let fallbackConfig = makeConfiguration(
                    fps: fps,
                    chroma: fallbackChroma,
                    hdr: fallbackHdr,
                    pixelFormatOverride: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                )
                ConnectionLogger.shared.logStep(
                    sessionId: "capturer",
                    step: "pixel_format_fallback",
                    detail: "chroma=\(chroma.rawValue) hdr=\(hdr) failed (\(error)); falling back to 420v"
                )
                let fallbackStream = SCStream(filter: filter, configuration: fallbackConfig, delegate: output)
                do {
                    try await startStreamWithTimeout(fallbackStream, output: output)
                    s = fallbackStream
                    currentChroma = fallbackChroma
                    currentHdr = fallbackHdr
                } catch {
                    ConnectionLogger.shared.logStep(sessionId: "capturer", step: "stream_start_failed",
                        detail: "\(error)")
                    throw RemoterError.captureUnavailable
                }
            } else {
                ConnectionLogger.shared.logStep(sessionId: "capturer", step: "stream_start_failed",
                    detail: "\(error)")
                throw RemoterError.captureUnavailable
            }
        }

        stream = s
        streamOutput = output
        ConnectionLogger.shared.logStep(sessionId: "capturer", step: "capture_started",
            detail: "\(screenWidth)x\(screenHeight) @\(fps)fps chroma=\(currentChroma.rawValue) hdr=\(currentHdr)")
    }

    private func startStreamWithTimeout(_ s: SCStream, output: StreamOutput) async throws {
        try s.addStreamOutput(output, type: .screen, sampleHandlerQueue: captureQueue)
        try s.addStreamOutput(output, type: .audio,  sampleHandlerQueue: audioQueue)
        // startCapture() 在某些 macOS 版本上会无限挂起（见 9c24e14），
        // 用 10s 超时兜底，避免 beginCapture() 卡死不报错。
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await s.startCapture() }
            group.addTask {
                try await Task.sleep(nanoseconds: 10_000_000_000)
                throw RemoterError.captureTimeout
            }
            try await group.next()
            group.cancelAll()
        }
    }

    private func preferredPixelFormat(chroma: ChromaMode, hdr: Bool) -> OSType {
        // Match UU Remote & standard VideoToolbox/WebRTC/DXVA pipeline: use Video/Limited Range (16..235)
        // so Chromium WebRTC, Media Foundation DXVA, and VideoToolbox decoders all agree on luminance range
        // without blowing out highlights / washing out light UI tones.
        if hdr {
            return kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        }
        switch chroma {
        case .yuv420:
            return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        case .yuv444:
            return kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange
        }
    }

    private func makeConfiguration(
        fps: Int,
        chroma: ChromaMode,
        hdr: Bool,
        pixelFormatOverride: OSType? = nil
    ) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width  = screenWidth
        config.height = screenHeight
        config.pixelFormat = pixelFormatOverride ?? preferredPixelFormat(chroma: chroma, hdr: hdr)
        config.colorSpaceName = hdr ? CGColorSpace.itur_2100_PQ : CGColorSpace.sRGB
        config.colorMatrix = hdr ? kCVImageBufferYCbCrMatrix_ITU_R_2020 : kCVImageBufferYCbCrMatrix_ITU_R_709_2
        config.showsCursor = false
        config.minimumFrameInterval = CMTime(value: 1, timescale: Int32(max(fps, 1)))
        config.queueDepth = max(3, min(5, fps / 30 + 1))
        config.capturesAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = true
        return config
    }

    func updateFps(_ fps: Int) {
        // Was a no-op ("requires stop/restart") — SCStream actually supports
        // live reconfiguration via updateConfiguration(), no restart/black-
        // screen gap needed. This mattered in practice: the client's quality
        // picker has a lower-fps "流畅优先" preset specifically to cut decode
        // load on underpowered machines, but with this as a no-op, picking
        // it only lowered bitrate while capture kept running at the full
        // rate — same number of frames/sec to decode, so it didn't relieve
        // decode-side struggle (client kept signaling overload/requesting
        // keyframes) at all.
        currentFps = fps
        guard let stream else { return }
        let config = makeConfiguration(fps: fps, chroma: currentChroma, hdr: currentHdr)
        Task {
            do {
                try await stream.updateConfiguration(config)
                ConnectionLogger.shared.logStep(sessionId: "capturer", step: "fps_updated", detail: "\(fps)fps")
            } catch {
                ConnectionLogger.shared.logStep(sessionId: "capturer", step: "fps_update_failed", detail: "\(error)")
            }
        }
    }

    func updateColorConfig(chroma: ChromaMode, hdr: Bool) {
        currentChroma = chroma
        currentHdr = hdr
        guard let stream else { return }
        let preferredFormat = preferredPixelFormat(chroma: chroma, hdr: hdr)
        let config = makeConfiguration(fps: currentFps, chroma: chroma, hdr: hdr, pixelFormatOverride: preferredFormat)
        Task {
            do {
                try await stream.updateConfiguration(config)
                ConnectionLogger.shared.logStep(
                    sessionId: "capturer",
                    step: "color_config_updated",
                    detail: "chroma=\(chroma.rawValue) hdr=\(hdr)"
                )
            } catch {
                if preferredFormat != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange {
                    let fallbackConfig = makeConfiguration(
                        fps: currentFps,
                        chroma: .yuv420,
                        hdr: false,
                        pixelFormatOverride: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                    )
                    do {
                        try await stream.updateConfiguration(fallbackConfig)
                        currentChroma = .yuv420
                        currentHdr = false
                        ConnectionLogger.shared.logStep(
                            sessionId: "capturer",
                            step: "color_config_fallback",
                            detail: "chroma=\(chroma.rawValue) hdr=\(hdr) failed (\(error)); fell back to 420v"
                        )
                    } catch {
                        ConnectionLogger.shared.logStep(
                            sessionId: "capturer",
                            step: "color_config_update_failed",
                            detail: "\(error)"
                        )
                    }
                } else {
                    ConnectionLogger.shared.logStep(
                        sessionId: "capturer",
                        step: "color_config_update_failed",
                        detail: "\(error)"
                    )
                }
            }
        }
    }

    func stop() async {
        captureQueue.async { [weak self] in
            self?.staticFrameWorkItem?.cancel()
            self?.staticFrameWorkItem = nil
            self?.latestPixelBuffer = nil
        }
        if let s = stream {
            try? await s.stopCapture()
        }
        stream = nil
        streamOutput = nil
    }

    // MARK: - Frame handling (called from StreamOutput)

    fileprivate func handle(sampleBuffer: CMSampleBuffer) {
        // Inspect ScreenCaptureKit frame status and dirtyRects attachments to
        // skip idle/blank/suspended frames or frames with no dirty regions.
        // Never drop valid frames if attachments are missing.
        if let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let attachments = attachmentsArray.first {
            var isInitialFrame = false
            if let statusRaw = attachments[.status] as? Int,
               let status = SCFrameStatus(rawValue: statusRaw) {
                switch status {
                case .idle, .blank, .suspended, .stopped:
                    return
                case .started:
                    isInitialFrame = true
                case .complete:
                    break
                @unknown default:
                    break
                }
            }
            if !isInitialFrame,
               let dirtyRects = attachments[.dirtyRects] as? [Any],
               dirtyRects.isEmpty {
                return
            }
        }

        guard let pixelBuffer = sampleBuffer.imageBuffer else { return }

        // Cancel any pending static-frame refinement because new motion arrived.
        staticFrameWorkItem?.cancel()
        staticFrameWorkItem = nil

        // Must run synchronously, still on captureQueue (called from
        // SCStreamOutput, off the main thread — see StreamOutput below), not
        // hopped to another queue. ScreenCaptureKit's imageBuffer is backed
        // by a small pool of IOSurfaces (sized by config.queueDepth); once
        // this callback returns, the pool can recycle that surface's memory
        // for the *next* capture regardless of whether Swift's ARC still
        // holds a reference to the CVPixelBuffer wrapper object — retaining
        // it across an async dispatch let VideoToolbox read a buffer whose
        // content was concurrently being overwritten by the next frame,
        // which is exactly what corrupted-looking video during any fast
        // screen change (typing, scrolling) would look like. Submitting to
        // VTCompressionSessionEncodeFrame before returning avoids the gap;
        // encode() itself is just a submission call (the actual encode work
        // happens on VT's own thread via the completion callback).
        let te = CFAbsoluteTimeGetCurrent()
        onFrame?(pixelBuffer, screenWidth, screenHeight)
        let encMs = (CFAbsoluteTimeGetCurrent() - te) * 1000

        // Schedule a one-shot static-frame refinement callback after 150ms of
        // stillness following active motion.
        if onStaticFrameReady != nil {
            latestPixelBuffer = pixelBuffer
            var workItem: DispatchWorkItem?
            let item = DispatchWorkItem { [weak self] in
                guard let self,
                      let currentItem = workItem,
                      !currentItem.isCancelled,
                      self.staticFrameWorkItem === currentItem,
                      let buf = self.latestPixelBuffer else { return }
                self.latestPixelBuffer = nil
                self.staticFrameWorkItem = nil
                self.onStaticFrameReady?(buf)
            }
            workItem = item
            staticFrameWorkItem = item
            captureQueue.asyncAfter(deadline: .now() + staticFrameDelaySeconds, execute: item)
        } else {
            latestPixelBuffer = nil
        }

        statFrames += 1
        let now = CFAbsoluteTimeGetCurrent()
        if now - statTick >= 5 {
            ConnectionLogger.shared.logStep(
                sessionId: "capturer", step: "perf_5s",
                detail: "enc=\(String(format: "%.1f", encMs))ms frames=\(statFrames)"
            )
            statFrames = 0
            statTick   = now
        }
    }

    fileprivate func handleStop(_ error: Error?) {
        ConnectionLogger.shared.logStep(sessionId: "capturer", step: "stream_stopped",
            detail: error.map { "\($0)" } ?? "")
        onStopped?()
    }
}

// SCStreamOutput/SCStreamDelegate need a separate NSObject — SCStream holds
// an unowned reference to its delegate/output, so this must outlive the stream.
private final class StreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    private weak var capturer: ScreenCapturer?

    init(capturer: ScreenCapturer) {
        self.capturer = capturer
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .screen: capturer?.handle(sampleBuffer: sampleBuffer)
        case .audio:  capturer?.onAudioSample?(sampleBuffer)
        default:      break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        capturer?.handleStop(error)
    }
}

enum RemoterError: Error {
    case encoderSetupFailed
    case captureUnavailable
    case captureTimeout
}
