import Foundation
import CoreGraphics
import CoreMedia

final class ScreenCapturer: @unchecked Sendable {
    /// 每帧回调：(CGImage, displayWidth, displayHeight)
    var onFrame: ((CGImage, Int, Int) -> Void)?

    private var captureTask: Task<Void, Never>?
    private var displayID: CGDirectDisplayID = CGMainDisplayID()

    private(set) var screenWidth:  Int = 1920
    private(set) var screenHeight: Int = 1080

    func start(fps: Int = 30) async throws {
        displayID    = CGMainDisplayID()
        screenWidth  = CGDisplayPixelsWide(displayID)
        screenHeight = CGDisplayPixelsHigh(displayID)

        ConnectionLogger.shared.logStep(sessionId: "capturer", step: "display_found",
            detail: "id=\(displayID) \(screenWidth)x\(screenHeight)")

        // 先抓一帧确认权限和 API 可用
        ConnectionLogger.shared.logStep(sessionId: "capturer", step: "test_frame")
        guard CGDisplayCreateImage(displayID) != nil else {
            throw RemoterError.captureUnavailable
        }
        ConnectionLogger.shared.logStep(sessionId: "capturer", step: "test_frame_ok")

        let interval = 1.0 / Double(fps)
        let did = displayID, w = screenWidth, h = screenHeight
        captureTask = Task.detached(priority: .high) { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let t = ContinuousClock.now
                if let img = CGDisplayCreateImage(did) {
                    self.onFrame?(img, w, h)
                }
                let elapsed = ContinuousClock.now - t
                let wait = Duration.seconds(interval) - elapsed
                if wait > .zero {
                    try? await Task.sleep(for: wait)
                }
            }
        }
    }

    func stop() async {
        captureTask?.cancel()
        captureTask = nil
    }
}

enum RemoterError: Error {
    case encoderSetupFailed
    case captureUnavailable
}
