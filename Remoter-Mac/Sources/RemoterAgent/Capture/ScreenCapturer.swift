import Foundation
import CoreGraphics

final class ScreenCapturer: @unchecked Sendable {
    var onFrame: ((CGImage, Int, Int) -> Void)?

    private(set) var screenWidth:  Int = 1920
    private(set) var screenHeight: Int = 1080

    private var displayID: CGDirectDisplayID = CGMainDisplayID()
    private var running   = false
    private var fps       = 30

    func start(fps: Int = 30) async throws {
        self.fps     = fps
        displayID    = CGMainDisplayID()
        screenWidth  = CGDisplayPixelsWide(displayID)
        screenHeight = CGDisplayPixelsHigh(displayID)

        ConnectionLogger.shared.logStep(sessionId: "capturer", step: "display_found",
            detail: "id=\(displayID) \(screenWidth)x\(screenHeight)")

        // 测试帧：在当前 async 上下文直接调用（已知可行）
        ConnectionLogger.shared.logStep(sessionId: "capturer", step: "test_frame")
        guard CGDisplayCreateImage(displayID) != nil else {
            throw RemoterError.captureUnavailable
        }
        ConnectionLogger.shared.logStep(sessionId: "capturer", step: "test_frame_ok")

        // 采集循环用 DispatchQueue（GCD 管理的线程）
        // macOS 26 上 CGDisplayCreateImage 在裸 OS 线程(Thread.detachNewThread)上会崩溃，
        // 但在 GCD 线程 / 启动时的 DispatchQueue.global 上调用正常
        running = true
        let did = displayID, w = screenWidth, h = screenHeight
        let interval = 1.0 / Double(fps)

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            ConnectionLogger.shared.logStep(sessionId: "capturer", step: "loop_started")
            while let self, self.running {
                let t = Date()
                if let img = CGDisplayCreateImage(did) {
                    self.onFrame?(img, w, h)
                }
                let elapsed = -t.timeIntervalSinceNow
                let wait    = interval - elapsed
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
            }
            ConnectionLogger.shared.logStep(sessionId: "capturer", step: "loop_stopped")
        }
    }

    func stop() async {
        running = false
    }
}

enum RemoterError: Error {
    case encoderSetupFailed
    case captureUnavailable
}
