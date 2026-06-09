import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo

final class ScreenCapturer: NSObject, @unchecked Sendable {
    var onFrame: ((CMSampleBuffer) -> Void)?

    private var captureTask: Task<Void, Never>?
    private let captureQueue = DispatchQueue(label: "remoter.capture", qos: .userInteractive)

    private(set) var screenWidth:  Int = 1920
    private(set) var screenHeight: Int = 1080

    private var filter: SCContentFilter?
    private var config: SCStreamConfiguration?

    func start(fps: Int = 60) async throws {
        // 1. 获取显示器
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false
        )
        guard let display = content.displays.first else {
            throw RemoterError.noDisplay
        }

        let scale = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 1.0 }
        screenWidth  = display.width  * Int(scale)
        screenHeight = display.height * Int(scale)

        ConnectionLogger.shared.logStep(sessionId: "capturer", step: "display_found",
            detail: "id=\(display.displayID) \(screenWidth)x\(screenHeight)")

        // 2. 配置
        let cfg = SCStreamConfiguration()
        cfg.width    = screenWidth
        cfg.height   = screenHeight
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        cfg.pixelFormat   = kCVPixelFormatType_32BGRA
        cfg.showsCursor   = true
        cfg.capturesAudio = false

        let flt = SCContentFilter(display: display,
                                  excludingApplications: [],
                                  exceptingWindows: [])
        self.filter = flt
        self.config = cfg

        // 3. 先截一帧验证权限和配置正常
        ConnectionLogger.shared.logStep(sessionId: "capturer", step: "test_screenshot")
        _ = try await SCScreenshotManager.captureSampleBuffer(
            contentFilter: flt, configuration: cfg
        )
        ConnectionLogger.shared.logStep(sessionId: "capturer", step: "test_screenshot_ok")

        // 4. 启动采集循环
        let interval = 1.0 / Double(fps)
        captureTask = Task.detached(priority: .userInteractive) { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let t = Date()
                if let buf = try? await SCScreenshotManager.captureSampleBuffer(
                    contentFilter: flt, configuration: cfg
                ) {
                    self.onFrame?(buf)
                }
                // 维持目标帧率
                let elapsed = Date().timeIntervalSince(t)
                let wait    = interval - elapsed
                if wait > 0.001 {
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                }
            }
        }
    }

    func stop() async {
        captureTask?.cancel()
        captureTask = nil
    }

    func updateConfig(fps: Int, width: Int, height: Int) async throws {
        // SCScreenshotManager 无需更新配置，帧率由循环控制
    }
}

enum RemoterError: Error {
    case noDisplay
    case encoderSetupFailed
    case captureTimeout
}
