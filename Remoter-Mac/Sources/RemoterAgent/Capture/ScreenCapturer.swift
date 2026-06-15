import Foundation
import CoreGraphics
import CoreImage

// CGDisplayStreamCreateWithDispatchQueue — push-based compositor readback.
// The OS pushes composited frames into an IOSurface without per-frame IPC,
// so frame delivery latency is ~0 ms (vs. ~24 ms for CGDisplayCreateImage).
// Reading the composited framebuffer captures all window levels including
// status-bar popup menus (same path macOS Screen Sharing uses).
//
// Encode runs on a separate queue; arriving frames are dropped (not queued)
// when the encoder is busy, keeping latency constant.

final class ScreenCapturer: NSObject, @unchecked Sendable {
    var onFrame:   ((CGImage, Int, Int) -> Void)?
    var onStopped: (() -> Void)?   // called when CGDisplayStream reports frameStopped

    private(set) var screenWidth:  Int = 1920
    private(set) var screenHeight: Int = 1080

    private var displayStream:  CGDisplayStream?
    private let captureQueue    = DispatchQueue(label: "remoter.capture.cb", qos: .userInitiated)
    private let encodeQueue     = DispatchQueue(label: "remoter.encode",     qos: .userInitiated)
    private let encodeSemaphore = DispatchSemaphore(value: 1)
    private let ciCtxGPU        = CIContext(options: [.useSoftwareRenderer: false])
    private let ciCtxCPU        = CIContext(options: [.useSoftwareRenderer: true])

    // Diagnostics (benign data-race on counters — log only)
    private var statFrames:   Int = 0
    private var statDrop:     Int = 0
    private var statNilImg:   Int = 0   // createCGImage returned nil
    private var statCpuFall:  Int = 0   // fell back to software renderer
    private var statTick:     CFAbsoluteTime = 0

    func start(fps: Int = 60) async throws {
        let displayID = CGMainDisplayID()
        screenWidth   = Int(CGDisplayPixelsWide(displayID))
        screenHeight  = Int(CGDisplayPixelsHigh(displayID))
        statTick      = CFAbsoluteTimeGetCurrent()

        ConnectionLogger.shared.logStep(sessionId: "capturer", step: "display_found",
            detail: "id=\(displayID) \(screenWidth)x\(screenHeight)")

        let props: [CFString: Any] = [
            CGDisplayStream.minimumFrameTime: 1.0 / Double(max(fps, 1)),
            CGDisplayStream.showCursor: false,
        ]

        guard let stream = CGDisplayStream(
            dispatchQueueDisplay: displayID,
            outputWidth: screenWidth,
            outputHeight: screenHeight,
            pixelFormat: Int32(kCVPixelFormatType_32BGRA),
            properties: props as CFDictionary,
            queue: captureQueue,
            handler: { [weak self] status, _, surface, _ in
                guard let self else { return }
                if status == .stopped {
                    // macOS stopped the stream (lock screen, sleep, permission revoked, etc.)
                    ConnectionLogger.shared.logStep(sessionId: "capturer", step: "stream_stopped")
                    self.onStopped?()
                    return
                }
                guard status == .frameComplete, let surface else { return }
                guard self.encodeSemaphore.wait(timeout: .now()) == .success else {
                    self.statDrop += 1
                    return
                }
                let w   = self.screenWidth
                let h   = self.screenHeight
                let sem = self.encodeSemaphore
                // CIImage retains the IOSurface; safe to use on encodeQueue.
                let ci  = CIImage(ioSurface: surface)
                self.encodeQueue.async { [weak self] in
                    defer { sem.signal() }
                    guard let self else { return }
                    let te = CFAbsoluteTimeGetCurrent()
                    // GPU renderer first; fall back to software if it returns nil
                    var cg = self.ciCtxGPU.createCGImage(ci, from: ci.extent)
                    if cg == nil {
                        self.statNilImg += 1
                        cg = self.ciCtxCPU.createCGImage(ci, from: ci.extent)
                        if cg != nil { self.statCpuFall += 1 }
                    }
                    if let cg {
                        self.onFrame?(cg, w, h)
                    }
                    let encMs = (CFAbsoluteTimeGetCurrent() - te) * 1000
                    self.statFrames += 1
                    let now = CFAbsoluteTimeGetCurrent()
                    if now - self.statTick >= 5 {
                        ConnectionLogger.shared.logStep(
                            sessionId: "capturer", step: "perf_5s",
                            detail: "enc=\(String(format: "%.1f", encMs))ms drop=\(self.statDrop) frames=\(self.statFrames) nil=\(self.statNilImg) cpuFall=\(self.statCpuFall)"
                        )
                        self.statDrop    = 0
                        self.statFrames  = 0
                        self.statNilImg  = 0
                        self.statCpuFall = 0
                        self.statTick    = now
                    }
                }
            }
        ) else {
            ConnectionLogger.shared.logStep(sessionId: "capturer", step: "no_capture_permission")
            throw RemoterError.captureUnavailable
        }

        guard stream.start() == .success else {
            ConnectionLogger.shared.logStep(sessionId: "capturer", step: "stream_start_failed")
            throw RemoterError.captureUnavailable
        }

        displayStream = stream
        ConnectionLogger.shared.logStep(sessionId: "capturer", step: "capture_started",
            detail: "\(screenWidth)x\(screenHeight) @\(fps)fps")
    }

    func updateFps(_ fps: Int) {
        // CGDisplayStream doesn't support updating minimumFrameTime after creation.
        // A stop/restart would be needed — skipping for now, 60 fps default covers most needs.
    }

    func stop() async {
        displayStream?.stop()
        displayStream = nil
    }
}

enum RemoterError: Error {
    case encoderSetupFailed
    case captureUnavailable
}
