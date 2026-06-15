import Foundation
import CoreGraphics

// CGDisplayCreateImage reads directly from the composited display framebuffer.
// It captures everything visible on screen (including popup menus) because
// it reads AFTER the GPU compositor has composited all window layers.
//
// SCK missed certain popup menus due to its own filtering pipeline.
// CGDisplayCreateImage does not have that limitation.
//
// Capture (captureQueue) and JPEG encoding (encodeQueue) run on separate queues.
// When the encoder is still busy, incoming frames are dropped to keep latency
// constant rather than letting a backlog build up.

final class ScreenCapturer: NSObject, @unchecked Sendable {
    var onFrame: ((CGImage, Int, Int) -> Void)?

    // Logical screen dimensions sent to the client (points, not physical pixels).
    private(set) var screenWidth:  Int = 1920
    private(set) var screenHeight: Int = 1080

    private var captureTimer: DispatchSourceTimer?
    private let captureQueue    = DispatchQueue(label: "remoter.capture", qos: .userInitiated)
    private let encodeQueue     = DispatchQueue(label: "remoter.encode",  qos: .userInitiated)
    private let encodeSemaphore = DispatchSemaphore(value: 1)   // 1 = encoder free

    private var displayID:    CGDirectDisplayID = 0
    private var physW: Int = 0
    private var physH: Int = 0

    // Per-5-s diagnostics
    private var statCapMs:  Double = 0
    private var statEncMs:  Double = 0
    private var statDrop:   Int    = 0
    private var statFrames: Int    = 0
    private var statTick:   CFAbsoluteTime = 0

    func start(fps: Int = 60) async throws {
        displayID    = CGMainDisplayID()
        physW        = Int(CGDisplayPixelsWide(displayID))
        physH        = Int(CGDisplayPixelsHigh(displayID))
        let bounds   = CGDisplayBounds(displayID)
        screenWidth  = Int(bounds.width)
        screenHeight = Int(bounds.height)
        statTick     = CFAbsoluteTimeGetCurrent()

        ConnectionLogger.shared.logStep(sessionId: "capturer", step: "display_found",
            detail: "id=\(displayID) phys=\(physW)x\(physH) logical=\(screenWidth)x\(screenHeight)")

        guard CGDisplayCreateImage(displayID) != nil else {
            ConnectionLogger.shared.logStep(sessionId: "capturer", step: "no_capture_permission")
            throw RemoterError.captureUnavailable
        }

        scheduleTimer(fps: fps)
        ConnectionLogger.shared.logStep(sessionId: "capturer", step: "capture_started",
            detail: "\(screenWidth)x\(screenHeight) @\(fps)fps")
    }

    func updateFps(_ fps: Int) {
        guard captureTimer != nil else { return }
        scheduleTimer(fps: fps)
    }

    func stop() async {
        captureTimer?.cancel()
        captureTimer = nil
    }

    // MARK: - Private

    private func scheduleTimer(fps: Int) {
        captureTimer?.cancel()
        let ns = Int(1_000_000_000 / max(fps, 1))
        let t  = DispatchSource.makeTimerSource(flags: [], queue: captureQueue)
        t.schedule(deadline: .now(), repeating: .nanoseconds(ns), leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.captureFrame() }
        t.resume()
        captureTimer = t
    }

    private func captureFrame() {
        guard encodeSemaphore.wait(timeout: .now()) == .success else {
            statDrop += 1
            return
        }

        let t0  = CFAbsoluteTimeGetCurrent()
        guard let raw = CGDisplayCreateImage(displayID) else {
            encodeSemaphore.signal()
            return
        }
        let capMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000

        let w = screenWidth, h = screenHeight
        let pw = physW, ph = physH
        encodeQueue.async { [weak self] in
            guard let self else { self?.encodeSemaphore.signal(); return }
            let te = CFAbsoluteTimeGetCurrent()

            // Scale physical pixels down to logical resolution when the display
            // is HiDPI (2×). This reduces JPEG encoding work by 4× with no
            // visible quality loss for remote desktop use.
            let image: CGImage
            if raw.width != w || raw.height != h, let scaled = self.scaleImage(raw, w: w, h: h) {
                image = scaled
            } else {
                image = raw
            }

            self.onFrame?(image, w, h)
            let encMs = (CFAbsoluteTimeGetCurrent() - te) * 1000
            self.encodeSemaphore.signal()

            self.statCapMs  = capMs
            self.statEncMs  = encMs
            self.statFrames += 1
            let now = CFAbsoluteTimeGetCurrent()
            if now - self.statTick >= 5 {
                ConnectionLogger.shared.logStep(
                    sessionId: "capturer", step: "perf_5s",
                    detail: "phys=\(pw)x\(ph) cap=\(String(format: "%.1f", capMs))ms enc=\(String(format: "%.1f", encMs))ms drop=\(self.statDrop) frames=\(self.statFrames)"
                )
                self.statDrop   = 0
                self.statFrames = 0
                self.statTick   = now
            }
        }
    }

    private func scaleImage(_ image: CGImage, w: Int, h: Int) -> CGImage? {
        let space = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .low   // bilinear, fast enough for downscale
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}

enum RemoterError: Error {
    case encoderSetupFailed
    case captureUnavailable
}
