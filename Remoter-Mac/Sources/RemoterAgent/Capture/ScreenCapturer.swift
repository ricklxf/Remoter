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
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false
        )
        guard let display = content.displays.first else {
            throw RemoterError.noDisplay
        }

        let scale = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2.0 }
        screenWidth  = display.width  * Int(scale)
        screenHeight = display.height * Int(scale)

        let config = SCStreamConfiguration()
        config.width    = screenWidth
        config.height   = screenHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat   = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        config.showsCursor   = true
        config.scalesToFit   = false
        config.capturesAudio = false

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        // delegate: self 确保 macOS 26 上 startCapture() 能正常完成
        let s = SCStream(filter: filter, configuration: config, delegate: self)
        self.stream = s

        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)

        // 加 10s 超时，避免 startCapture() 无限挂起
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await s.startCapture() }
            group.addTask {
                try await Task.sleep(nanoseconds: 10_000_000_000)
                throw RemoterError.captureTimeout
            }
            try await group.next()
            group.cancelAll()
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
        config.pixelFormat   = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
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
