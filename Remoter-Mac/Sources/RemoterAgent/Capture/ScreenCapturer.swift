import Foundation
import CoreGraphics

// CGDisplayCreateImage reads from the display compositor — captures everything
// visible on screen including status-bar menus, popups, and overlay windows.
// SCK (ScreenCaptureKit) misses certain window levels (e.g. NSPopUpMenuWindowLevel)
// on some macOS versions, which is why we use this lower-level API instead.

final class ScreenCapturer: NSObject, @unchecked Sendable {
    var onFrame: ((CGImage, Int, Int) -> Void)?

    private(set) var screenWidth:  Int = 1920
    private(set) var screenHeight: Int = 1080

    private var captureTimer: DispatchSourceTimer?
    private let captureQueue = DispatchQueue(label: "remoter.capture", qos: .userInitiated)

    func start(fps: Int = 30) async throws {
        let displayID = CGMainDisplayID()
        screenWidth  = Int(CGDisplayPixelsWide(displayID))
        screenHeight = Int(CGDisplayPixelsHigh(displayID))

        ConnectionLogger.shared.logStep(sessionId: "capturer", step: "display_found",
            detail: "id=\(displayID) \(screenWidth)x\(screenHeight)")

        // First capture also triggers the screen-recording permission prompt if needed.
        guard CGDisplayCreateImage(displayID) != nil else {
            ConnectionLogger.shared.logStep(sessionId: "capturer", step: "no_capture_permission")
            throw RemoterError.captureUnavailable
        }

        let ns = Int(1_000_000_000 / max(fps, 1))
        let t = DispatchSource.makeTimerSource(flags: [], queue: captureQueue)
        t.schedule(deadline: .now(), repeating: .nanoseconds(ns), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in
            guard let self, let image = CGDisplayCreateImage(displayID) else { return }
            self.onFrame?(image, self.screenWidth, self.screenHeight)
        }
        t.resume()
        captureTimer = t

        ConnectionLogger.shared.logStep(sessionId: "capturer", step: "capture_started",
            detail: "\(screenWidth)x\(screenHeight) @\(fps)fps")
    }

    func stop() async {
        captureTimer?.cancel()
        captureTimer = nil
    }
}

enum RemoterError: Error {
    case encoderSetupFailed
    case captureUnavailable
}
