import Foundation
import ScreenCaptureKit
import CoreGraphics
import CoreImage
import CoreMedia

final class ScreenCapturer: NSObject, @unchecked Sendable, SCStreamOutput, SCStreamDelegate {
    var onFrame: ((CGImage, Int, Int) -> Void)?

    private(set) var screenWidth:  Int = 1920
    private(set) var screenHeight: Int = 1080

    private var stream:  SCStream?
    private let ciCtx = CIContext(options: [.useSoftwareRenderer: false])

    func start(fps: Int = 30) async throws {
        // SCShareableContent 会触发系统「屏幕录制」会话授权弹窗
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                         ?? content.displays.first else {
            ConnectionLogger.shared.logStep(sessionId: "capturer", step: "no_display")
            throw RemoterError.captureUnavailable
        }

        screenWidth  = display.width
        screenHeight = display.height

        ConnectionLogger.shared.logStep(sessionId: "capturer", step: "display_found",
            detail: "id=\(display.displayID) \(screenWidth)x\(screenHeight)")

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let cfg = SCStreamConfiguration()
        cfg.width            = screenWidth
        cfg.height           = screenHeight
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        cfg.capturesAudio    = false
        cfg.pixelFormat      = kCVPixelFormatType_32BGRA
        cfg.showsCursor      = false
        cfg.scalesToFit      = false

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen,
                              sampleHandlerQueue: DispatchQueue(label: "remoter.capture", qos: .userInitiated))
        try await s.startCapture()
        stream = s

        ConnectionLogger.shared.logStep(sessionId: "capturer", step: "sck_stream_started",
            detail: "\(screenWidth)x\(screenHeight) @\(fps)fps")
    }

    func stop() async {
        guard let s = stream else { return }
        stream = nil
        try? await s.stopCapture()
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen,
              sampleBuffer.isValid,
              let imageBuffer = sampleBuffer.imageBuffer else { return }

        let ci = CIImage(cvImageBuffer: imageBuffer)
        guard let cg = ciCtx.createCGImage(ci, from: ci.extent) else { return }
        onFrame?(cg, screenWidth, screenHeight)
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        ConnectionLogger.shared.logStep(sessionId: "capturer", step: "sck_error",
            detail: error.localizedDescription)
    }
}

enum RemoterError: Error {
    case encoderSetupFailed
    case captureUnavailable
}
