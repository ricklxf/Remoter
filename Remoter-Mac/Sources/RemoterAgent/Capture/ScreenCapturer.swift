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
        screenWidth = Int(display.width * Int(scale))
        screenHeight = Int(display.height * Int(scale))

        let config = SCStreamConfiguration()
        config.width = screenWidth
        config.height = screenHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        config.showsCursor = true
        config.scalesToFit = false
        config.capturesAudio = false

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let s = SCStream(filter: filter, configuration: config, delegate: nil)
        self.stream = s

        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        try await s.startCapture()
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    func updateConfig(fps: Int, width: Int, height: Int) async throws {
        guard let s = stream else { return }
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        config.showsCursor = true
        try await s.updateConfiguration(config)
    }
}

extension ScreenCapturer: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer buf: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, buf.isValid else { return }
        onFrame?(buf)
    }
}

enum RemoterError: Error {
    case noDisplay
    case encoderSetupFailed
}
