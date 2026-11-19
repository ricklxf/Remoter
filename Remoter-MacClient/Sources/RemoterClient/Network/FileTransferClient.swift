import Foundation

/// Chunked bidirectional file transfer client matching Remoter's wire protocol:
/// - JSON:   `file_start { id, name, size }` -> Binary `0x02` chunks (64 KiB) -> JSON `file_end { id }`
/// - Binary: `[0x02][16B UTF-8 id padded with '\0'][4B offset BE][chunk data]`
public final class FileTransferClient: @unchecked Sendable {
    public static let chunkSize = 64 * 1024

    public enum TransferError: LocalizedError {
        case fileNotFound(String)
        case ioError(String)

        public var errorDescription: String? {
            switch self {
            case .fileNotFound(let path): return "File not found: \(path)"
            case .ioError(let msg): return msg
            }
        }
    }

    private final class DownloadState {
        let id: String
        let name: String
        let size: Int64
        let tempURL: URL
        let handle: FileHandle
        var received: Int64 = 0
        var lastSpeedTimeMs: UInt64
        var lastSpeedBytes: Int64 = 0
        var speedBps: Double = 0

        init(id: String, name: String, size: Int64, tempURL: URL, handle: FileHandle, nowMs: UInt64) {
            self.id = id
            self.name = name
            self.size = size
            self.tempURL = tempURL
            self.handle = handle
            self.lastSpeedTimeMs = nowMs
        }

        func close() {
            try? handle.close()
        }
    }

    private let lock = NSLock()
    private let sendJsonBytes: (Data) -> Void
    private let sendBinaryAsync: (Data) async throws -> Void
    private var downloads: [String: DownloadState] = [:]
    private var _downloadDirectory: URL

    public var onProgress: ((FileTransferProgress) -> Void)?
    public var onDownloadCompleted: ((_ fileName: String, _ savedPath: String) -> Void)?

    public var downloadDirectory: URL {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _downloadDirectory
        }
        set {
            lock.lock()
            _downloadDirectory = newValue
            lock.unlock()
        }
    }

    public init(
        sendJsonBytes: @escaping (Data) -> Void,
        sendBinaryAsync: @escaping (Data) async throws -> Void,
        downloadDirectory: URL? = nil
    ) {
        self.sendJsonBytes = sendJsonBytes
        self.sendBinaryAsync = sendBinaryAsync
        if let downloadDirectory {
            self._downloadDirectory = downloadDirectory
        } else {
            self._downloadDirectory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
        }
    }

    deinit {
        cancelAllDownloads()
    }

    // MARK: - Upload (Client -> Agent)

    public func uploadFile(at url: URL) async throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            throw TransferError.fileNotFound(url.path)
        }

        let attrs = try fm.attributesOfItem(atPath: url.path)
        let totalSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let name = url.lastPathComponent
        let id = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(16))

        var lastSpeedTimeMs = Self.monotonicMs()
        var lastSpeedBytes: Int64 = 0
        var speedBps: Double = 0

        emitProgress(FileTransferProgress(
            id: id,
            name: name,
            size: totalSize,
            transferred: 0,
            direction: .upload,
            speedBps: 0,
            done: false
        ))

        sendJsonBytes(ClientMessages.fileStart(id: id, name: name, size: totalSize))

        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }

            var offset: Int64 = 0
            var chunksSent = 0

            while offset < totalSize {
                try Task.checkCancellation()
                guard let chunk = try handle.read(upToCount: Self.chunkSize), !chunk.isEmpty else {
                    break
                }

                // Protocol offset is 32-bit unsigned big-endian (supports up to 4 GiB)
                let packet = BinaryFrames.buildFileChunkPacket(
                    fileId: id,
                    offset: UInt32(truncatingIfNeeded: offset),
                    chunk: chunk
                )
                try await sendBinaryAsync(packet)

                offset += Int64(chunk.count)
                chunksSent += 1

                // Yield 1ms every 1 MiB (16 x 64 KiB chunks) so uploads never starve interactive input/video.
                if (chunksSent & 0x0F) == 0 && offset < totalSize {
                    try await Task.sleep(nanoseconds: 1_000_000)
                }

                let nowMs = Self.monotonicMs()
                let dt = nowMs &- lastSpeedTimeMs
                if dt >= 300 {
                    speedBps = Double(offset - lastSpeedBytes) * 1000.0 / Double(dt)
                    lastSpeedTimeMs = nowMs
                    lastSpeedBytes = offset
                }

                emitProgress(FileTransferProgress(
                    id: id,
                    name: name,
                    size: totalSize,
                    transferred: min(offset, totalSize),
                    direction: .upload,
                    speedBps: speedBps,
                    done: false
                ))
            }

            sendJsonBytes(ClientMessages.fileEnd(id: id))
            emitProgress(FileTransferProgress(
                id: id,
                name: name,
                size: totalSize,
                transferred: totalSize,
                direction: .upload,
                speedBps: speedBps,
                done: true
            ))
        } catch {
            emitProgress(FileTransferProgress(
                id: id,
                name: name,
                size: totalSize,
                transferred: 0,
                direction: .upload,
                speedBps: 0,
                done: true,
                error: error.localizedDescription
            ))
            throw error
        }
    }

    // MARK: - Download (Agent -> Client)

    internal func handleFileStart(id: String, name: String, size: Int64) {
        guard !id.isEmpty else { return }
        let safeName = Self.sanitizeFileName(name)
        let dir = downloadDirectory

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            let tempURL = dir.appendingPathComponent(".remoter_dl_\(id)_\(suffix).part")
            FileManager.default.createFile(atPath: tempURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: tempURL)
            if size > 0 {
                try handle.truncate(atOffset: UInt64(size))
                try handle.seek(toOffset: 0)
            }

            let state = DownloadState(
                id: id,
                name: safeName,
                size: size,
                tempURL: tempURL,
                handle: handle,
                nowMs: Self.monotonicMs()
            )

            lock.lock()
            let old = downloads.removeValue(forKey: id)
            downloads[id] = state
            lock.unlock()

            if let old {
                old.close()
                Self.tryDelete(old.tempURL)
            }

            emitProgress(FileTransferProgress(
                id: id,
                name: safeName,
                size: size,
                transferred: 0,
                direction: .download,
                speedBps: 0,
                done: false
            ))
        } catch {
            emitProgress(FileTransferProgress(
                id: id,
                name: safeName,
                size: size,
                transferred: 0,
                direction: .download,
                speedBps: 0,
                done: true,
                error: error.localizedDescription
            ))
        }
    }

    internal func handleFileChunk(id: String, offset: UInt32, chunk: Data) {
        lock.lock()
        guard let state = downloads[id] else {
            lock.unlock()
            return
        }

        do {
            try state.handle.seek(toOffset: UInt64(offset))
            try state.handle.write(contentsOf: chunk)
            state.received += Int64(chunk.count)

            let nowMs = Self.monotonicMs()
            let dt = nowMs &- state.lastSpeedTimeMs
            if dt >= 300 {
                state.speedBps = Double(state.received - state.lastSpeedBytes) * 1000.0 / Double(dt)
                state.lastSpeedTimeMs = nowMs
                state.lastSpeedBytes = state.received
            }

            let progress = FileTransferProgress(
                id: id,
                name: state.name,
                size: state.size,
                transferred: min(state.received, state.size),
                direction: .download,
                speedBps: state.speedBps,
                done: false
            )
            lock.unlock()
            emitProgress(progress)
        } catch {
            downloads.removeValue(forKey: id)
            let name = state.name
            let size = state.size
            let received = state.received
            lock.unlock()

            state.close()
            Self.tryDelete(state.tempURL)
            emitProgress(FileTransferProgress(
                id: id,
                name: name,
                size: size,
                transferred: received,
                direction: .download,
                speedBps: 0,
                done: true,
                error: error.localizedDescription
            ))
        }
    }

    internal func handleFileEnd(id: String) {
        lock.lock()
        guard let state = downloads.removeValue(forKey: id) else {
            lock.unlock()
            return
        }
        let dir = _downloadDirectory
        lock.unlock()

        do {
            try state.handle.synchronize()
            state.close()

            let finalURL = Self.uniqueDestinationURL(in: dir, fileName: state.name)
            try FileManager.default.moveItem(at: state.tempURL, to: finalURL)

            emitProgress(FileTransferProgress(
                id: id,
                name: state.name,
                size: state.size,
                transferred: state.size,
                direction: .download,
                speedBps: 0,
                done: true,
                savedPath: finalURL.path
            ))
            onDownloadCompleted?(state.name, finalURL.path)
        } catch {
            state.close()
            Self.tryDelete(state.tempURL)
            emitProgress(FileTransferProgress(
                id: id,
                name: state.name,
                size: state.size,
                transferred: state.received,
                direction: .download,
                speedBps: 0,
                done: true,
                error: error.localizedDescription
            ))
        }
    }

    public func cancelAllDownloads() {
        lock.lock()
        let active = Array(downloads.values)
        downloads.removeAll()
        lock.unlock()

        for state in active {
            state.close()
            Self.tryDelete(state.tempURL)
        }
    }

    // MARK: - Helpers

    private func emitProgress(_ progress: FileTransferProgress) {
        onProgress?(progress)
    }

    private static func monotonicMs() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds / 1_000_000
    }

    private static func sanitizeFileName(_ name: String) -> String {
        let base = URL(fileURLWithPath: name).lastPathComponent
        if base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || base == "." || base == ".." {
            return "download.bin"
        }
        let invalid = CharacterSet(charactersIn: "/:\\\0")
        let cleaned = base.unicodeScalars.map { invalid.contains($0) ? "_" : String($0) }.joined()
        return cleaned.isEmpty ? "download.bin" : cleaned
    }

    private static func uniqueDestinationURL(in directory: URL, fileName: String) -> URL {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let candidate = directory.appendingPathComponent(fileName)
        if !FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        let ext = candidate.pathExtension
        let stem = candidate.deletingPathExtension().lastPathComponent
        for i in 1..<10_000 {
            let name = ext.isEmpty ? "\(stem) (\(i))" : "\(stem) (\(i)).\(ext)"
            let next = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: next.path) {
                return next
            }
        }
        let uid = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let fallback = ext.isEmpty ? "\(stem)_\(uid)" : "\(stem)_\(uid).\(ext)"
        return directory.appendingPathComponent(fallback)
    }

    private static func tryDelete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
