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

    /// Invoked on main thread when new local Finder file URLs appear in `NSPasteboard.general`.
    public var onLocalClipboardFilesChanged: ((_ urls: [URL], _ signature: String) -> Void)?

    // MARK: - Private State

    private weak var connection: RemoterConnection?
    private var pollTimer: Timer?
    private var lastChangeCount: Int = -1
    private var lastInjectedTextHash: UInt64 = 0
    private var lastSentTextHash: UInt64 = 0
    private var lastInjectedImageHash: UInt64 = 0
    private var lastSentImageHash: UInt64 = 0
    private var lastAppliedRemoteClipboardFilesSig: String = ""
    private var lastNotifiedLocalFilesSig: String = ""

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
                let pb = NSPasteboard.general
                let hash = ProtocolHelpers.fnv1a64(text)
                if pb.string(forType: .string) == text {
                    self.lastInjectedTextHash = hash
                    return
                }
                self.lastInjectedTextHash = hash
                self.lastSentTextHash = 0

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
                self.lastSentImageHash = 0

                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setData(pngData, forType: .png)
                self.lastChangeCount = pb.changeCount
            }
        }
    }

    /// Writes downloaded remote clipboard file URLs into `NSPasteboard.general`
    /// while recording their signature so the next poll does not echo them back.
    public func applyRemoteClipboardFiles(_ localURLs: [URL]) {
        guard isEnabled, !localURLs.isEmpty else { return }

        let applyBlock = { [weak self] in
            guard let self, self.isEnabled else { return }
            let existing = localURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !existing.isEmpty else { return }

            let sig = Self.computeFileURLsSignature(existing)
            self.lastAppliedRemoteClipboardFilesSig = sig
            self.lastNotifiedLocalFilesSig = sig

            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects(existing as [NSURL])
            self.lastChangeCount = pb.changeCount
        }

        if Thread.isMainThread {
            applyBlock()
        } else {
            DispatchQueue.main.async(execute: applyBlock)
        }
    }

    /// Immediately checks `NSPasteboard.general` for unsent file URLs (e.g. on Cmd+V / Ctrl+V).
    public func checkLocalClipboardFilesNow() {
        let checkBlock = { [weak self] in
            guard let self, self.isEnabled, let connection = self.connection, connection.isConnected else { return }
            self.checkPasteboardFileURLs(NSPasteboard.general)
        }
        if Thread.isMainThread {
            checkBlock()
        } else {
            DispatchQueue.main.async(execute: checkBlock)
        }
    }

    /// Immediately checks `NSPasteboard.general` and syncs any unsent text, image, or file URLs to the remote host.
    /// Safe to call on connect or window activation (deduplicated via FNV-1a hashes / file signatures).
    public func syncNow() {
        if Thread.isMainThread {
            pollLocalPasteboard(force: true)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.pollLocalPasteboard(force: true)
            }
        }
    }

    public static func computeFileURLsSignature(_ urls: [URL]) -> String {
        let fm = FileManager.default
        let parts: [String] = urls.map { url in
            let path = url.standardizedFileURL.path
            if let attrs = try? fm.attributesOfItem(atPath: path) {
                let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                let mtimeMs = Int64(((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) * 1000)
                return "\(path)|\(size)|\(mtimeMs)"
            }
            return "\(path)|0|0"
        }.sorted()
        return parts.joined(separator: "\n")
    }

    // MARK: - Local Pasteboard Polling

    @discardableResult
    private func checkPasteboardFileURLs(_ pb: NSPasteboard) -> Bool {
        guard let rawURLs = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !rawURLs.isEmpty else {
            return false
        }
        let existing = rawURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return false }

        let sig = Self.computeFileURLsSignature(existing)
        if sig != lastAppliedRemoteClipboardFilesSig && sig != lastNotifiedLocalFilesSig {
            lastNotifiedLocalFilesSig = sig
            onLocalClipboardFilesChanged?(existing, sig)
        }
        return true
    }

    private func pollLocalPasteboard(force: Bool = false) {
        guard isEnabled, let connection, connection.isConnected else { return }

        let pb = NSPasteboard.general
        let currentCount = pb.changeCount
        if !force {
            guard currentCount != lastChangeCount else { return }
        }
        lastChangeCount = currentCount

        // 0. Check Finder file URLs first (Finder also writes filename strings to .string)
        if checkPasteboardFileURLs(pb) {
            return
        }

        // 1. Check plain text
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
