import Foundation
import AppKit

/// Bidirectional macOS `NSPasteboard.general` text & PNG image synchronization
/// using 64-bit FNV-1a (`ProtocolHelpers.fnv1a64`) anti-loop hash deduplication.
public final class ClipboardSync {

    // MARK: - Public Properties

    public var isEnabled: Bool = true {
        didSet {
            connection?.setClipboardSyncEnabled(isEnabled)
            connection?.setReverseClipboardActive(isEnabled)
            if isEnabled {
                lastChangeCount = NSPasteboard.general.changeCount
            }
        }
    }

    // MARK: - Private State

    private weak var connection: RemoterConnection?
    private var pollTimer: Timer?
    private var lastChangeCount: Int = -1
    private var lastInjectedTextHash: UInt64 = 0
    private var lastSentTextHash: UInt64 = 0
    private var lastInjectedImageHash: UInt64 = 0
    private var lastSentImageHash: UInt64 = 0

    private static let pollIntervalSeconds: TimeInterval = 0.35
    private static let maxImageBytes: Int = 8 * 1024 * 1024 // 8 MB safety cap

    // MARK: - Lifecycle

    public init() {}

    deinit {
        stop()
    }

    // MARK: - Public API

    /// Starts polling `NSPasteboard.general` every 350ms and syncs changes over `connection`.
    public func start(connection: RemoterConnection) {
        stop()
        self.connection = connection
        self.lastChangeCount = NSPasteboard.general.changeCount

        connection.setClipboardSyncEnabled(isEnabled)
        connection.setReverseClipboardActive(isEnabled)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pollTimer?.invalidate()
            let timer = Timer(timeInterval: Self.pollIntervalSeconds, repeats: true) { [weak self] _ in
                self?.pollLocalPasteboard()
            }
            RunLoop.main.add(timer, forMode: .common)
            self.pollTimer = timer
        }
    }

    /// Stops clipboard polling and detaches from the connection.
    public func stop() {
        if Thread.isMainThread {
            pollTimer?.invalidate()
            pollTimer = nil
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.pollTimer?.invalidate()
                self?.pollTimer = nil
            }
        }
        connection = nil
    }

    /// Applies clipboard content received from the remote host into `NSPasteboard.general`
    /// while recording its FNV-1a hash so the next poll does not echo it back.
    public func applyRemoteClipboard(_ data: ClipboardData) {
        guard isEnabled else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self, self.isEnabled else { return }

            if let text = data.text, !text.isEmpty {
                let hash = ProtocolHelpers.fnv1a64(text)
                guard hash != self.lastSentTextHash else { return }
                self.lastInjectedTextHash = hash

                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
                self.lastChangeCount = pb.changeCount
                return
            }

            let pngData: Data?
            if let raw = data.imagePngData, !raw.isEmpty {
                pngData = raw
            } else if let b64 = data.imageBase64, !b64.isEmpty {
                pngData = Data(base64Encoded: b64)
            } else {
                pngData = nil
            }

            if let pngData, !pngData.isEmpty {
                let hash = ProtocolHelpers.fnv1a64(pngData)
                guard hash != self.lastSentImageHash else { return }
                self.lastInjectedImageHash = hash

                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setData(pngData, forType: .png)
                self.lastChangeCount = pb.changeCount
            }
        }
    }

    // MARK: - Local Pasteboard Polling

    private func pollLocalPasteboard() {
        guard isEnabled, let connection, connection.isConnected else { return }

        let pb = NSPasteboard.general
        let currentCount = pb.changeCount
        guard currentCount != lastChangeCount else { return }
        lastChangeCount = currentCount

        // 1. Check plain text first
        if let text = pb.string(forType: .string), !text.isEmpty {
            let hash = ProtocolHelpers.fnv1a64(text)
            if hash != lastInjectedTextHash && hash != lastSentTextHash {
                lastSentTextHash = hash
                connection.sendClipboardText(text)
            }
            return
        }

        // 2. Check PNG or TIFF image (converting TIFF -> PNG for cross-platform compatibility)
        if let pngData = extractPNGImage(from: pb), !pngData.isEmpty, pngData.count <= Self.maxImageBytes {
            let hash = ProtocolHelpers.fnv1a64(pngData)
            if hash != lastInjectedImageHash && hash != lastSentImageHash {
                lastSentImageHash = hash
                connection.sendClipboardImage(pngData)
            }
        }
    }

    private func extractPNGImage(from pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png), !png.isEmpty {
            return png
        }
        if let tiff = pasteboard.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return png
        }
        return nil
    }
}
