import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo

final class ScreenCapturer: NSObject, @unchecked Sendable {
    var onFrame: ((CMSampleBuffer) -> Void)?

    private var stream: SCStream?
    private let captureQueue = DispatchQueue(label: "remoter.capture", qos: .userInteractive)

    private(set) var screenWidth: Int = 2560
    private(set) var screenHeight: Int = 1440

    func start(fps: Int = 60) async throws {
        // 1. 获取可共享内容（同时触发/验证权限）
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false
        )

        guard let display = content.displays.first else {
            throw RemoterError.noDisplay
        }

        ConnectionLogger.shared.logStep(sessionId: "capturer",
            step: "display_found",
            detail: "id=\(display.displayID) \(display.width)x\(display.height)")

        // 2. 计算实际分辨率（无显示器时 backingScaleFactor 可能为 nil）
        let scale = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 1.0 }
        screenWidth  = display.width  * Int(scale)
        screenHeight = display.height * Int(scale)

        ConnectionLogger.shared.logStep(sessionId: "capturer",
            step: "resolution",
            detail: "\(screenWidth)x\(screenHeight) scale=\(scale)")

        // 3. 配置流
        let config = SCStreamConfiguration()
        config.width    = screenWidth
        config.height   = screenHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat   = kCVPixelFormatType_32BGRA   // 更兼容的像素格式
        config.showsCursor   = true
        config.capturesAudio = false

        let filter = SCContentFilter(display: display,
                                     excludingApplications: [],
                                     exceptingWindows: [])

        // 4. 用 continuation 包装 startCapture，外层用 DispatchQueue timer 超时
        let s = SCStream(filter: filter, configuration: config, delegate: self)
        self.stream = s
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)

        ConnectionLogger.shared.logStep(sessionId: "capturer", step: "calling_startCapture")

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            // 10 秒超时定时器
            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + 10)
            var resolved = false
            let lock = NSLock()

            func resolve(_ result: Result<Void, Error>) {
                lock.lock()
                defer { lock.unlock() }
                guard !resolved else { return }
                resolved = true
                timer.cancel()
                switch result {
                case .success: cont.resume()
                case .failure(let e): cont.resume(throwing: e)
                }
            }

            timer.setEventHandler {
                ConnectionLogger.shared.logStep(sessionId: "capturer", step: "startCapture_timeout")
                resolve(.failure(RemoterError.captureTimeout))
            }
            timer.resume()

            // 实际启动
            Task {
                do {
                    try await s.startCapture()
                    resolve(.success(()))
                } catch {
                    resolve(.failure(error))
                }
            }
        }
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    func updateConfig(fps: Int, width: Int, height: Int) async throws {
        guard let s = stream else { return }
        let config = SCStreamConfiguration()
        config.width    = width
        config.height   = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat   = kCVPixelFormatType_32BGRA
        config.showsCursor   = true
        try await s.updateConfiguration(config)
    }
}

// MARK: - SCStreamOutput

extension ScreenCapturer: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer buf: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, buf.isValid else { return }
        onFrame?(buf)
    }
}

// MARK: - SCStreamDelegate

extension ScreenCapturer: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        ConnectionLogger.shared.logPermission(event: "stream_stopped", detail: "\(error)")
    }
}

enum RemoterError: Error {
    case noDisplay
    case encoderSetupFailed
    case captureTimeout
}
