import Foundation
import CoreGraphics
import CoreMedia
import CoreVideo

final class ScreenCapturer: NSObject, @unchecked Sendable {
    var onFrame: ((CMSampleBuffer) -> Void)?

    private var captureTask: Task<Void, Never>?
    private var displayID: CGDirectDisplayID = CGMainDisplayID()

    private(set) var screenWidth:  Int = 1920
    private(set) var screenHeight: Int = 1080

    func start(fps: Int = 60) async throws {
        // 使用 CGMainDisplayID() 获取主显示器
        displayID    = CGMainDisplayID()
        screenWidth  = CGDisplayPixelsWide(displayID)
        screenHeight = CGDisplayPixelsHigh(displayID)

        ConnectionLogger.shared.logStep(sessionId: "capturer", step: "display_found",
            detail: "id=\(displayID) \(screenWidth)x\(screenHeight)")

        // 测试一帧，确认 CGDisplayCreateImage 可用
        ConnectionLogger.shared.logStep(sessionId: "capturer", step: "test_frame")
        guard CGDisplayCreateImage(displayID) != nil else {
            throw RemoterError.captureUnavailable
        }
        ConnectionLogger.shared.logStep(sessionId: "capturer", step: "test_frame_ok")

        // 启动采集循环
        let interval = 1.0 / Double(fps)
        let did = displayID
        captureTask = Task.detached(priority: .high) { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let t = ContinuousClock.now
                if let buf = Self.captureFrame(displayID: did,
                                               width: self.screenWidth,
                                               height: self.screenHeight) {
                    self.onFrame?(buf)
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

    func updateConfig(fps: Int, width: Int, height: Int) async throws {
        // 帧率由循环控制，无需额外更新
    }

    // MARK: - CGImage → CMSampleBuffer

    private static func captureFrame(displayID: CGDirectDisplayID,
                                     width: Int, height: Int) -> CMSampleBuffer? {
        guard let cgImage = CGDisplayCreateImage(displayID) else { return nil }

        // 创建 CVPixelBuffer（BGRA）
        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey:    true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        CVPixelBufferCreate(kCFAllocatorDefault,
                            width, height,
                            kCVPixelFormatType_32BGRA,
                            attrs as CFDictionary,
                            &pixelBuffer)
        guard let pb = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        let ctx = CGContext(
            data:             CVPixelBufferGetBaseAddress(pb),
            width:            width,
            height:           height,
            bitsPerComponent: 8,
            bytesPerRow:      CVPixelBufferGetBytesPerRow(pb),
            space:            CGColorSpaceCreateDeviceRGB(),
            bitmapInfo:       CGImageAlphaInfo.noneSkipFirst.rawValue |
                              CGBitmapInfo.byteOrder32Little.rawValue
        )
        ctx?.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // CVPixelBuffer → CMSampleBuffer
        var timing = CMSampleTimingInfo(
            duration:               CMTime(value: 1, timescale: 60),
            presentationTimeStamp:  CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp:        .invalid
        )
        var formatDesc: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pb,
            formatDescriptionOut: &formatDesc
        )
        guard let fd = formatDesc else { return nil }

        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(
            allocator:                 kCFAllocatorDefault,
            imageBuffer:               pb,
            dataReady:                 true,
            makeDataReadyCallback:     nil,
            refcon:                    nil,
            formatDescription:         fd,
            sampleTiming:              &timing,
            sampleBufferOut:           &sampleBuffer
        )
        return sampleBuffer
    }
}

enum RemoterError: Error {
    case noDisplay
    case encoderSetupFailed
    case captureTimeout
    case captureUnavailable
}
