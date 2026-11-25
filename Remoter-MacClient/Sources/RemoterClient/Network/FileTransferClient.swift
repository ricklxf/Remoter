import Foundation

/// Chunked bidirectional file transfer client matching Remoter's wire protocol:
/// - JSON:   `file_start { id, name, size, relPath?, destDir?, resume?, purpose? }`
///           -> optional `file_ack { id, offset, resumed }`
///           -> Binary `0x02` chunks (64 KiB)
///           -> JSON `file_end { id }`
///           -> optional `file_done { id, path }`
/// - Binary: `[0x02][16B UTF-8 id padded with '\0'][4B offset BE][chunk data]`
public final class FileTransferClient: @unchecked Sendable {
    public static let chunkSize = 64 * 1024
    public static let maxRecursiveFiles = 2000

    public enum TransferError: LocalizedError {
        case fileNotFound(String)
        case ioError(String)
        case timeout(String)

        public var errorDescription: String? {
            switch self {
            case .fileNotFound(let path): return "File not found: \(path)"
            case .ioError(let msg): return msg
            case .timeout(let msg): return msg
            }
        }
    }

    private struct PendingDownloadTarget {
        let expectedName: String
        let destURL: URL
        let overwriteExisting: Bool
        let completion: CheckedContinuation<String, Error>?
    }

    private final class DownloadState {
        let id: String
        let name: String
        let size: Int64
        let destURL: URL
        let partURL: URL
        let overwriteExisting: Bool
        let resumed: Bool
        let handle: FileHandle
        let completion: CheckedContinuation<String, Error>?
        var received: Int64
        var lastSpeedTimeMs: UInt64
        var lastSpeedBytes: Int64
        var speedBps: Double = 0

        init(
            id: String,
            name: String,
            size: Int64,
            destURL: URL,
            partURL: URL,
            overwriteExisting: Bool,
            resumed: Bool,
            initialReceived: Int64,
            handle: FileHandle,
            completion: CheckedContinuation<String, Error>?,
            nowMs: UInt64
        ) {
            self.id = id
            self.name = name
            self.size = size
            self.destURL = destURL
            self.partURL = partURL
            self.overwriteExisting = overwriteExisting
            self.resumed = resumed
            self.received = initialReceived
            self.lastSpeedBytes = initialReceived
            self.handle = handle
            self.completion = completion
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
    private var pendingTargets: [PendingDownloadTarget] = []
    private var fileAckWaiters: [String: CheckedContinuation<(offset: Int64, resumed: Bool), Never>] = [:]
    private var fileDoneWaiters: [String: CheckedContinuation<String?, Never>] = [:]
    private var _downloadDirectory: URL

    /// Timeout waiting for `file_ack` before falling back to `offset = 0` (default 1.5s).
    public var ackTimeoutNanoseconds: UInt64 = 1_500_000_000
    /// Timeout waiting for `file_done` when `waitForDone == true` (default 5s).
    public var doneTimeoutNanoseconds: UInt64 = 5_000_000_000

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

    @discardableResult
    public func uploadFile(
        at url: URL,
        relPath: String? = nil,
        destDir: String? = nil,
        resume: Bool = true,
        purpose: String? = nil,
        waitForDone: Bool = false
    ) async throws -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            throw TransferError.fileNotFound(url.path)
        }

        let attrs = try fm.attributesOfItem(atPath: url.path)
        let totalSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let name = url.lastPathComponent
        let displayName = (relPath?.isEmpty == false) ? relPath! : name
        let id = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(16))

        var lastSpeedTimeMs = Self.monotonicMs()
        var lastSpeedBytes: Int64 = 0
        var speedBps: Double = 0

        emitProgress(FileTransferProgress(
            id: id,
            name: displayName,
            size: totalSize,
            transferred: 0,
            direction: .upload,
            speedBps: 0,
            done: false,
            resumed: false
        ))

        let startOffset: Int64
        let resumed: Bool
        if resume {
            let ack = await waitForFileAck(id: id) {
                self.sendJsonBytes(ClientMessages.fileStart(
                    id: id,
                    name: name,
                    size: totalSize,
                    relPath: relPath,
                    destDir: destDir,
                    resume: true,
                    purpose: purpose
                ))
            }
            if ack.offset > 0 && ack.offset <= totalSize {
                startOffset = ack.offset
                resumed = ack.resumed || ack.offset > 0
            } else {
                startOffset = 0
                resumed = false
            }
        } else {
            sendJsonBytes(ClientMessages.fileStart(
                id: id,
                name: name,
                size: totalSize,
                relPath: relPath,
                destDir: destDir,
                resume: false,
                purpose: purpose
            ))
            startOffset = 0
            resumed = false
        }

        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }

            var offset: Int64 = startOffset
            lastSpeedBytes = startOffset
            var chunksSent = 0

            if offset > 0 && offset < totalSize {
                try handle.seek(toOffset: UInt64(offset))
                emitProgress(FileTransferProgress(
                    id: id,
                    name: displayName,
                    size: totalSize,
                    transferred: offset,
                    direction: .upload,
                    speedBps: 0,
                    done: false,
                    resumed: true
                ))
            }

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
                    name: displayName,
                    size: totalSize,
                    transferred: min(offset, totalSize),
                    direction: .upload,
                    speedBps: speedBps,
                    done: false,
                    resumed: resumed
                ))
            }

            let remotePath: String?
            if waitForDone {
                remotePath = await waitForFileDone(id: id) {
                    self.sendJsonBytes(ClientMessages.fileEnd(id: id))
                }
            } else {
                sendJsonBytes(ClientMessages.fileEnd(id: id))
                remotePath = nil
            }

            emitProgress(FileTransferProgress(
                id: id,
                name: displayName,
                size: totalSize,
                transferred: totalSize,
                direction: .upload,
                speedBps: speedBps,
                done: true,
                resumed: resumed,
                savedPath: remotePath
            ))
            return remotePath
        } catch {
            emitProgress(FileTransferProgress(
                id: id,
                name: displayName,
                size: totalSize,
                transferred: startOffset,
                direction: .upload,
                speedBps: 0,
                done: true,
                resumed: resumed,
                error: error.localizedDescription
            ))
            throw error
        }
    }

    /// Recursively uploads files and directories. Directories are walked via `FileManager.enumerator`
    /// and each regular file is uploaded with `relPath` relative to its top-level dropped/selected folder.
    /// Returns the list of remote host paths reported by `file_done` when `waitForDone == true`.
    @discardableResult
    public func uploadItems(
        at urls: [URL],
        destDir: String? = nil,
        resume: Bool = true,
        purpose: String? = nil,
        waitForDone: Bool = false
    ) async throws -> [String] {
        let items = Self.enumerateUploadItems(from: urls)
        var remotePaths: [String] = []
        for item in items {
            try Task.checkCancellation()
            let saved = try await uploadFile(
                at: item.url,
                relPath: item.relPath,
                destDir: destDir,
                resume: resume,
                purpose: purpose,
                waitForDone: waitForDone
            )
            if let saved, !saved.isEmpty {
                remotePaths.append(saved)
            }
        }
        return remotePaths
    }

    public static func enumerateUploadItems(from urls: [URL]) -> [(url: URL, relPath: String?)] {
        let fm = FileManager.default
        var results: [(url: URL, relPath: String?)] = []

        for rawURL in urls {
            if results.count >= maxRecursiveFiles { break }
            let url = rawURL.standardizedFileURL
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }

            if !isDir.boolValue {
                results.append((url: url, relPath: nil))
                continue
            }

            let rootName = url.lastPathComponent
            let basePath = url.path.hasSuffix("/") ? url.path : (url.path + "/")
            guard let enumerator = fm.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsPackageDescendants]
            ) else { continue }

            for case let fileURL as URL in enumerator {
                if results.count >= maxRecursiveFiles { break }
                if fileURL.lastPathComponent == ".DS_Store" { continue }
                guard let rv = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
                    continue
                }
                if rv.isSymbolicLink == true || rv.isRegularFile != true {
                    continue
                }
                let fullPath = fileURL.standardizedFileURL.path
                let subPath: String
                if fullPath.hasPrefix(basePath) {
                    subPath = String(fullPath.dropFirst(basePath.count))
                } else {
                    subPath = fileURL.lastPathComponent
                }
                let rel = rootName + "/" + subPath.replacingOccurrences(of: "\\", with: "/")
                results.append((url: fileURL, relPath: rel))
            }
        }
        return results
    }

    // MARK: - Upload Ack / Done Handlers

    internal func handleFileAck(id: String, offset: Int64, resumed: Bool) {
        lock.lock()
        let cont = fileAckWaiters.removeValue(forKey: id)
        lock.unlock()
        cont?.resume(returning: (offset, resumed))
    }

    internal func handleFileDone(id: String, path: String) {
        lock.lock()
        let cont = fileDoneWaiters.removeValue(forKey: id)
        lock.unlock()
        cont?.resume(returning: path.isEmpty ? nil : path)
    }

    private func waitForFileAck(id: String, sendStart: @escaping () -> Void) async -> (offset: Int64, resumed: Bool) {
        let timeoutNs = ackTimeoutNanoseconds
        return await withCheckedContinuation { cont in
            lock.lock()
            fileAckWaiters[id] = cont
            lock.unlock()

            sendStart()

            Task.detached { [weak self] in
                try? await Task.sleep(nanoseconds: timeoutNs)
                guard let self else { return }
                let timedOutCont = self.lock.withLock {
                    self.fileAckWaiters.removeValue(forKey: id)
                }
                timedOutCont?.resume(returning: (offset: 0, resumed: false))
            }
        }
    }

    private func waitForFileDone(id: String, sendEnd: @escaping () -> Void) async -> String? {
        let timeoutNs = doneTimeoutNanoseconds
        return await withCheckedContinuation { cont in
            lock.lock()
            fileDoneWaiters[id] = cont
            lock.unlock()

            sendEnd()

            Task.detached { [weak self] in
                try? await Task.sleep(nanoseconds: timeoutNs)
                guard let self else { return }
                let timedOutCont = self.lock.withLock {
                    self.fileDoneWaiters.removeValue(forKey: id)
                }
                timedOutCont?.resume(returning: nil)
            }
        }
    }

    // MARK: - Download Preparation & Resumable Download (Agent -> Client)

    /// Computes existing `.remoter.part` length for a remote file download and registers the target destination.
    public func prepareDownloadTarget(
        remotePath: String,
        destURL: URL? = nil,
        overwriteExisting: Bool = false
    ) -> Int64 {
        let remoteName = Self.extractRemoteFileName(remotePath)
        let targetURL = destURL ?? downloadDirectory.appendingPathComponent(Self.sanitizeFileName(remoteName))
        let existingOffset = Self.existingPartSize(for: targetURL)

        lock.lock()
        pendingTargets.append(PendingDownloadTarget(
            expectedName: Self.sanitizeFileName(remoteName),
            destURL: targetURL,
            overwriteExisting: overwriteExisting,
            completion: nil
        ))
        lock.unlock()

        return existingOffset
    }

    /// Requests a remote file into `destURL` (with automatic `.remoter.part` resume) and awaits completion.
    public func downloadFile(
        remotePath: String,
        to destURL: URL,
        overwriteExisting: Bool = true,
        sendRequest: (_ path: String, _ offset: Int64) -> Void
    ) async throws -> String {
        let remoteName = Self.extractRemoteFileName(remotePath)
        let expectedName = Self.sanitizeFileName(remoteName)
        let existingOffset = Self.existingPartSize(for: destURL)

        return try await withCheckedThrowingContinuation { cont in
            lock.lock()
            pendingTargets.append(PendingDownloadTarget(
                expectedName: expectedName,
                destURL: destURL,
                overwriteExisting: overwriteExisting,
                completion: cont
            ))
            lock.unlock()

            sendRequest(remotePath, existingOffset)
        }
    }

    internal func handleFileStart(id: String, name: String, size: Int64, offset: Int64 = 0) {
        guard !id.isEmpty else { return }
        let safeName = Self.sanitizeFileName(name)

        lock.lock()
        let pendingTarget: PendingDownloadTarget?
        if let idx = pendingTargets.firstIndex(where: { $0.expectedName == safeName }) {
            pendingTarget = pendingTargets.remove(at: idx)
        } else if !pendingTargets.isEmpty {
            pendingTarget = pendingTargets.removeFirst()
        } else {
            pendingTarget = nil
        }
        let defaultDir = _downloadDirectory
        lock.unlock()

        let destURL = pendingTarget?.destURL ?? defaultDir.appendingPathComponent(safeName)
        let overwriteExisting = pendingTarget?.overwriteExisting ?? false
        let partURL = URL(fileURLWithPath: destURL.path + ".remoter.part")

        do {
            let parentDir = destURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

            let existingPartLen = Self.existingPartSize(for: destURL)
            let handle: FileHandle
            let initialReceived: Int64
            let resumed: Bool

            if offset > 0 && existingPartLen >= offset {
                handle = try FileHandle(forUpdating: partURL)
                try handle.seek(toOffset: UInt64(offset))
                initialReceived = offset
                resumed = true
            } else {
                FileManager.default.createFile(atPath: partURL.path, contents: nil)
                handle = try FileHandle(forWritingTo: partURL)
                try handle.truncate(atOffset: 0)
                initialReceived = 0
                resumed = false
            }

            let state = DownloadState(
                id: id,
                name: safeName,
                size: size,
                destURL: destURL,
                partURL: partURL,
                overwriteExisting: overwriteExisting,
                resumed: resumed,
                initialReceived: initialReceived,
                handle: handle,
                completion: pendingTarget?.completion,
                nowMs: Self.monotonicMs()
            )

            lock.lock()
            let old = downloads.removeValue(forKey: id)
            downloads[id] = state
            lock.unlock()

            if let old {
                old.close()
                old.completion?.resume(throwing: CancellationError())
            }

            emitProgress(FileTransferProgress(
                id: id,
                name: safeName,
                size: size,
                transferred: initialReceived,
                direction: .download,
                speedBps: 0,
                done: false,
                resumed: resumed
            ))
        } catch {
            pendingTarget?.completion?.resume(throwing: error)
            emitProgress(FileTransferProgress(
                id: id,
                name: safeName,
                size: size,
                transferred: 0,
                direction: .download,
                speedBps: 0,
                done: true,
                resumed: false,
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
            let endPos = Int64(offset) + Int64(chunk.count)
            state.received = max(state.received, endPos)

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
                done: false,
                resumed: state.resumed
            )
            lock.unlock()
            emitProgress(progress)
        } catch {
            downloads.removeValue(forKey: id)
            let name = state.name
            let size = state.size
            let received = state.received
            let resumed = state.resumed
            let completion = state.completion
            lock.unlock()

            state.close()
            completion?.resume(throwing: error)
            emitProgress(FileTransferProgress(
                id: id,
                name: name,
                size: size,
                transferred: received,
                direction: .download,
                speedBps: 0,
                done: true,
                resumed: resumed,
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
        lock.unlock()

        do {
            try state.handle.synchronize()
            state.close()

            let fm = FileManager.default
            let finalURL: URL
            if state.overwriteExisting {
                finalURL = state.destURL
                try fm.createDirectory(at: finalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: finalURL.path) {
                    try fm.removeItem(at: finalURL)
                }
                try fm.moveItem(at: state.partURL, to: finalURL)
            } else {
                let dir = state.destURL.deletingLastPathComponent()
                finalURL = Self.uniqueDestinationURL(in: dir, fileName: state.destURL.lastPathComponent)
                try fm.moveItem(at: state.partURL, to: finalURL)
            }

            emitProgress(FileTransferProgress(
                id: id,
                name: state.name,
                size: state.size,
                transferred: state.size,
                direction: .download,
                speedBps: 0,
                done: true,
                resumed: state.resumed,
                savedPath: finalURL.path
            ))
            onDownloadCompleted?(state.name, finalURL.path)
            state.completion?.resume(returning: finalURL.path)
        } catch {
            state.close()
            state.completion?.resume(throwing: error)
            emitProgress(FileTransferProgress(
                id: id,
                name: state.name,
                size: state.size,
                transferred: state.received,
                direction: .download,
                speedBps: 0,
                done: true,
                resumed: state.resumed,
                error: error.localizedDescription
            ))
        }
    }

    public func cancelAllDownloads() {
        lock.lock()
        let active = Array(downloads.values)
        downloads.removeAll()
        let pending = pendingTargets
        pendingTargets.removeAll()
        let acks = fileAckWaiters
        fileAckWaiters.removeAll()
        let dones = fileDoneWaiters
        fileDoneWaiters.removeAll()
        lock.unlock()

        // Close handles without deleting `.remoter.part` so interrupted downloads can resume later.
        for state in active {
            state.close()
            state.completion?.resume(throwing: CancellationError())
        }
        for p in pending {
            p.completion?.resume(throwing: CancellationError())
        }
        for (_, cont) in acks {
            cont.resume(returning: (0, false))
        }
        for (_, cont) in dones {
            cont.resume(returning: nil)
        }
    }

    // MARK: - Helpers

    private func emitProgress(_ progress: FileTransferProgress) {
        onProgress?(progress)
    }

    private static func monotonicMs() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds / 1_000_000
    }

    public static func existingPartSize(for destURL: URL) -> Int64 {
        let partPath = destURL.path + ".remoter.part"
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: partPath),
              let sz = (attrs[.size] as? NSNumber)?.int64Value,
              sz > 0 else {
            return 0
        }
        return sz
    }

    public static func extractRemoteFileName(_ remotePath: String) -> String {
        let normalized = remotePath.replacingOccurrences(of: "\\", with: "/")
        let last = normalized.split(separator: "/").last.map(String.init) ?? remotePath
        return last.isEmpty ? "download.bin" : last
    }

    public static func sanitizeFileName(_ name: String) -> String {
        let base = URL(fileURLWithPath: name).lastPathComponent
        if base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || base == "." || base == ".." {
            return "download.bin"
        }
        let invalid = CharacterSet(charactersIn: "/:\\\0")
        let cleaned = base.unicodeScalars.map { invalid.contains($0) ? "_" : String($0) }.joined()
        return cleaned.isEmpty ? "download.bin" : cleaned
    }

    /// Sanitizes a relative path (rejecting `..` and leading `/`) into safe path components.
    public static func sanitizeRelativePathComponents(_ relPath: String) -> [String] {
        let normalized = relPath.replacingOccurrences(of: "\\", with: "/")
        return normalized
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
            .map { sanitizeFileName($0) }
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
}
