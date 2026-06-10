import Foundation
import CoreGraphics

final class ScreenCapturer: @unchecked Sendable {
    var onFrame: ((CGImage, Int, Int) -> Void)?

    private(set) var screenWidth:  Int = 1920
    private(set) var screenHeight: Int = 1080

    private var displayID: CGDirectDisplayID = CGMainDisplayID()
    private var captureTimer: DispatchSourceTimer?
    private let captureQueue = DispatchQueue(label: "remoter.capture", qos: .userInitiated)

    func start(fps: Int = 30) async throws {
        displayID    = CGMainDisplayID()
        screenWidth  = CGDisplayPixelsWide(displayID)
        screenHeight = CGDisplayPixelsHigh(displayID)

        ConnectionLogger.shared.logStep(sessionId: "capturer", step: "display_found",
            detail: "id=\(displayID) \(screenWidth)x\(screenHeight)")

        // 测试帧：在当前 async 上下文调用（已知可行）
        ConnectionLogger.shared.logStep(sessionId: "capturer", step: "test_frame")
        guard CGDisplayCreateImage(displayID) != nil else {
            throw RemoterError.captureUnavailable
        }
        ConnectionLogger.shared.logStep(sessionId: "capturer", step: "test_frame_ok")

        // 采集循环：使用 DispatchSourceTimer（专为定时采集设计）
        // 在 captureQueue 上触发，不占用 GCD global 线程池
        let did = displayID, w = screenWidth, h = screenHeight
        let intervalNs = UInt64(1_000_000_000 / fps)

        let timer = DispatchSource.makeTimerSource(queue: captureQueue)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(Int(intervalNs)), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if let img = CGDisplayCreateImage(did) {
                self.onFrame?(img, w, h)
            }
        }
        captureTimer = timer

        ConnectionLogger.shared.logStep(sessionId: "capturer", step: "timer_armed")
        timer.resume()
        ConnectionLogger.shared.logStep(sessionId: "capturer", step: "loop_started")
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
