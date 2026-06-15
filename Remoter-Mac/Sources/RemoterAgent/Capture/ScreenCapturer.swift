import Foundation
import CoreGraphics

// CGWindowListCreateImage reads from the display compositor — captures everything
// visible on screen including status-bar menus, popups, and overlay windows.
// SCK (ScreenCaptureKit) misses certain window levels (e.g. NSPopUpMenuWindowLevel)
// on some macOS versions, which is why we use this lower-level API instead.
//
// We capture at nominal (1x) resolution to keep JPEG encoding fast:
// a 2x Retina display at full resolution would produce 4× more pixels with
// no perceptible quality gain for remote desktop purposes.

final class ScreenCapturer: NSObject, @unchecked Sendable {
    var onFrame: ((CGImage, Int, Int) -> Void)?

    private(set) var screenWidth:  Int = 1920
    private(set) var screenHeight: Int = 1080

    private var captureTimer: DispatchSourceTimer?
    private let captureQueue = DispatchQueue(label: "remoter.capture", qos: .userInitiated)
    private var displayID: CGDirectDisplayID = 0
    private var displayBounds: CGRect = .zero

    func start(fps: Int = 60) async throws {
        displayID     = CGMainDisplayID()
        displayBounds = CGDisplayBounds(displayID)
        screenWidth   = Int(displayBounds.width)
        screenHeight  = Int(displayBounds.height)

        ConnectionLogger.shared.logStep(sessionId: "capturer", step: "display_found",
            detail: "id=\(displayID) logical=\(screenWidth)x\(screenHeight)")

        // Verify capture permission (triggers prompt if needed).
        guard CGWindowListCreateImage(displayBounds, .optionOnScreenOnly,
                                      kCGNullWindowID, .nominalResolution) != nil else {
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
        t.schedule(deadline: .now(), repeating: .nanoseconds(ns), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.captureFrame() }
        t.resume()
        captureTimer = t
    }

    private func captureFrame() {
        guard let image = CGWindowListCreateImage(
            displayBounds, .optionOnScreenOnly, kCGNullWindowID, .nominalResolution
        ) else { return }
        onFrame?(image, screenWidth, screenHeight)
    }
}

enum RemoterError: Error {
    case encoderSetupFailed
    case captureUnavailable
}
