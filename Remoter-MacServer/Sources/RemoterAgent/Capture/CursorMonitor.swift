import Foundation
import AppKit

// Watches the system-wide cursor shape and reports changes as a small PNG +
// hotspot. The client hides the captured cursor (SCStream showsCursor=false)
// and renders its *local* pointer with this shape via CSS `cursor: url(...)`
// — the standard remote-desktop trick (Parsec/RDP do the same): position
// tracking stays local (zero latency), only the shape follows the remote.
//
// Polling (10Hz) rather than events: AppKit has no public notification for
// "any app changed the cursor"; NSCursor.currentSystem is the only public
// window into the global cursor, and a 100ms poll of an object pointer +
// occasional small PNG encode is negligible.
final class CursorMonitor {
    /// (pngBase64, hotspotX, hotspotY, width, height) — all in points.
    var onCursorChanged: ((String, Int, Int, Int, Int) -> Void)?

    private var timer: Timer?
    private var lastTIFFHash: Int = 0

    func start() {
        guard timer == nil else { return }
        // NSCursor is AppKit — keep all access on the main thread.
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        lastTIFFHash = 0
    }

    private func poll() {
        guard let cursor = NSCursor.currentSystem else { return }
        let image = cursor.image
        guard let tiff = image.tiffRepresentation else { return }
        let hash = tiff.hashValue
        guard hash != lastTIFFHash else { return }
        lastTIFFHash = hash

        // Re-render at point size: the image's bitmap rep is usually 2x on
        // Retina, but CSS `cursor: url()` sizes by intrinsic pixels — sending
        // the raw rep would show a double-sized cursor on the client.
        let w = max(Int(image.size.width.rounded()), 1)
        let h = max(Int(image.size.height.rounded()), 1)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return }

        let hot = cursor.hotSpot
        onCursorChanged?(png.base64EncodedString(), Int(hot.x.rounded()), Int(hot.y.rounded()), w, h)
    }
}
