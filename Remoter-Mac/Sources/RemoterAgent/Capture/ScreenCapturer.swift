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
    var onStopped: (() -> Void)?   // called when SCStream reports a stop/error
    // System audio PCM from SCStream (48kHz float). Capture always runs (the
    // cost of unconsumed PCM callbacks is negligible); Session only encodes/
    // sends when the client actually asked for audio, so toggling it on
    // doesn't need a stream rebuild.
    var onAudioSample: ((CMSampleBuffer) -> Void)?

    private(set) var physWidth:    Int = 1920  // physical display pixels (for input mapping)
    private(set) var physHeight:   Int = 1080
    private(set) var screenWidth:  Int = 960   // encode/stream resolution (50% of physical)
    private(set) var screenHeight: Int = 540
    // Global-desktop origin of the captured display (needed to map the
    // client's display-relative coords to CGEvent's global space) and the
    // full display list (sent to the client so it can offer a picker).
    private(set) var originX: Double = 0
    private(set) var originY: Double = 0
    private(set) var displays: [(id: UInt32, name: String, width: Int, height: Int)] = []

    private var stream: SCStream?
    private var streamOutput: StreamOutput?
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
    func start(fps: Int = 60, maxDimension: Int? = nil, displayID requestedID: UInt32? = nil) async throws {
        statTick = CFAbsoluteTimeGetCurrent()

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
        guard let display = content.displays.first(where: { $0.displayID == displayID })
            ?? content.displays.first else {
            ConnectionLogger.shared.logStep(sessionId: "capturer", step: "no_capture_permission",
                detail: "no SCDisplay matched displayID=\(displayID)")
            throw RemoterError.captureUnavailable
        }

        physWidth  = Int(CGDisplayPixelsWide(display.displayID))
        physHeight = Int(CGDisplayPixelsHigh(display.displayID))
        let bounds = CGDisplayBounds(display.displayID)
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

        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.width  = screenWidth
        config.height = screenHeight
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.minimumFrameInterval = CMTime(value: 1, timescale: Int32(max(fps, 1)))
        config.queueDepth = 2
        config.capturesAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = true

        let output = StreamOutput(capturer: self)
        let s = SCStream(filter: filter, configuration: config, delegate: output)
        do {
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
        } catch {
            ConnectionLogger.shared.logStep(sessionId: "capturer", step: "stream_start_failed",
                detail: "\(error)")
            throw RemoterError.captureUnavailable
        }

        stream = s
        streamOutput = output
        ConnectionLogger.shared.logStep(sessionId: "capturer", step: "capture_started",
            detail: "\(screenWidth)x\(screenHeight) @\(fps)fps")
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
        guard let stream else { return }
        let config = SCStreamConfiguration()
        config.width  = screenWidth
        config.height = screenHeight
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.minimumFrameInterval = CMTime(value: 1, timescale: Int32(max(fps, 1)))
        config.queueDepth = 2
        Task {
            do {
                try await stream.updateConfiguration(config)
                ConnectionLogger.shared.logStep(sessionId: "capturer", step: "fps_updated", detail: "\(fps)fps")
            } catch {
                ConnectionLogger.shared.logStep(sessionId: "capturer", step: "fps_update_failed", detail: "\(error)")
            }
        }
    }

    func stop() async {
        if let s = stream {
            try? await s.stopCapture()
        }
        stream = nil
        streamOutput = nil
    }

    // MARK: - Frame handling (called from StreamOutput)

    fileprivate func handle(sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = sampleBuffer.imageBuffer else { return }
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
