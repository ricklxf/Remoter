import Foundation

// Receives chunked file transfers from the client with folder hierarchy,
// custom destination, clipboard target, and resumable `.remoter.part` support.
final class FileReceiver {
    private struct Transfer {
        let name: String
        let size: Int64
        let finalURL: URL
        let partURL: URL
        var fileHandle: FileHandle
        var received: Int64
    }

    private var transfers: [String: Transfer] = [:]
    private let queue = DispatchQueue(label: "remoter.filerecv")

    func start(
        id: String,
        name: String,
        size: Int64,
        relPath: String? = nil,
        destDir: String? = nil,
        resume: Bool = false,
        purpose: String? = nil,
        completion: ((Int64, Bool) -> Void)? = nil
    ) {
        queue.async {
            let fm = FileManager.default
            let downloadsDir = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")

            // 1. Resolve base directory
            let baseDir: URL
            if purpose == "clipboard" {
                let clipDir = downloadsDir.appendingPathComponent("Remoter-Clipboard", isDirectory: true)
                try? fm.createDirectory(at: clipDir, withIntermediateDirectories: true)
                baseDir = clipDir
            } else if let dest = destDir, !dest.isEmpty {
                let expanded = (dest as NSString).expandingTildeInPath
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
                    baseDir = URL(fileURLWithPath: expanded, isDirectory: true)
                } else {
                    baseDir = downloadsDir
                }
            } else {
                baseDir = downloadsDir
            }

            // 2. Compute sanitized final URL (supporting relative subfolder paths)
            let finalURL: URL
            if let rawRel = relPath, !rawRel.isEmpty {
                let segments = Self.sanitizeRelativePath(rawRel)
                if !segments.isEmpty {
                    var target = baseDir
                    for seg in segments {
                        target.appendPathComponent(seg)
                    }
                    finalURL = target
                } else {
                    finalURL = baseDir.appendingPathComponent(Self.sanitizeFilename(name))
                }
            } else {
                finalURL = baseDir.appendingPathComponent(Self.sanitizeFilename(name))
            }

            try? fm.createDirectory(at: finalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let partURL = URL(fileURLWithPath: finalURL.path + ".remoter.part")

            // 3. Resumable `.remoter.part` check
            var startOffset: Int64 = 0
            var resumed = false
            var fileHandle: FileHandle?

            if resume,
               fm.fileExists(atPath: partURL.path),
               let attrs = try? fm.attributesOfItem(atPath: partURL.path),
               let existingSize = (attrs[.size] as? NSNumber)?.int64Value,
               existingSize > 0, existingSize < size,
               let fh = try? FileHandle(forUpdating: partURL) {
                startOffset = existingSize
                resumed = true
                fileHandle = fh
            } else {
                fm.createFile(atPath: partURL.path, contents: nil)
                fileHandle = try? FileHandle(forWritingTo: partURL)
            }

            guard let fh = fileHandle else {
                print("[FileReceiver] Cannot open \(partURL.path)")
                completion?(0, false)
                return
            }

            self.transfers[id] = Transfer(
                name: name,
                size: size,
                finalURL: finalURL,
                partURL: partURL,
                fileHandle: fh,
                received: startOffset
            )
            print("[FileReceiver] Starting \(finalURL.lastPathComponent) (\(size)B, offset=\(startOffset), resumed=\(resumed))")
            completion?(startOffset, resumed)
        }
    }

    func receive(id: String, offset: Int64, chunk: Data) {
        queue.async {
            guard var t = self.transfers[id] else { return }
            t.fileHandle.seek(toFileOffset: UInt64(max(0, offset)))
            t.fileHandle.write(chunk)
            t.received += Int64(chunk.count)
            self.transfers[id] = t
        }
    }

    func finish(id: String, completion: ((String?) -> Void)? = nil) {
        queue.async {
            guard let t = self.transfers.removeValue(forKey: id) else {
                completion?(nil)
                return
            }
            try? t.fileHandle.synchronize()
            try? t.fileHandle.close()

            let fm = FileManager.default
            var finalPath: String? = t.finalURL.path
            do {
                if fm.fileExists(atPath: t.finalURL.path) {
                    _ = try fm.replaceItemAt(t.finalURL, withItemAt: t.partURL)
                } else {
                    try fm.moveItem(at: t.partURL, to: t.finalURL)
                }
                print("[FileReceiver] Completed \(t.finalURL.path)")
            } catch {
                // Fallback: remove existing target and move
                try? fm.removeItem(at: t.finalURL)
                do {
                    try fm.moveItem(at: t.partURL, to: t.finalURL)
                    print("[FileReceiver] Completed \(t.finalURL.path)")
                } catch {
                    print("[FileReceiver] Failed to finalize \(t.partURL.path): \(error)")
                    finalPath = nil
                }
            }
            completion?(finalPath)
        }
    }

    // MARK: - Path sanitization

    private static func sanitizeRelativePath(_ raw: String) -> [String] {
        let normalized = raw.replacingOccurrences(of: "\\", with: "/")
        return normalized
            .split(separator: "/")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }
    }

    private static func sanitizeFilename(_ raw: String) -> String {
        let cleaned = raw
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." {
            return "file"
        }
        return cleaned
    }
}
