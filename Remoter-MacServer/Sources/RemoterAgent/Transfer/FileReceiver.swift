import Foundation

// Receives chunked file transfers from the client and writes to ~/Downloads
final class FileReceiver {
    private struct Transfer {
        let name: String
        let size: Int64
        var fileHandle: FileHandle
        var received: Int64
    }

    private var transfers: [String: Transfer] = [:]
    private let queue = DispatchQueue(label: "remoter.filerecv")

    func start(id: String, name: String, size: Int64) {
        queue.async {
            let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
            let url = dir.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            guard let fh = try? FileHandle(forWritingTo: url) else {
                print("[FileReceiver] Cannot open \(url.path)")
                return
            }
            self.transfers[id] = Transfer(name: name, size: size, fileHandle: fh, received: 0)
            print("[FileReceiver] Starting \(name) (\(size) bytes)")
        }
    }

    func receive(id: String, offset: Int64, chunk: Data) {
        queue.async {
            guard var t = self.transfers[id] else { return }
            t.fileHandle.seek(toFileOffset: UInt64(offset))
            t.fileHandle.write(chunk)
            t.received += Int64(chunk.count)
            self.transfers[id] = t
        }
    }

    func finish(id: String) {
        queue.async {
            guard let t = self.transfers[id] else { return }
            try? t.fileHandle.close()
            self.transfers.removeValue(forKey: id)
            print("[FileReceiver] Completed \(t.name)")
        }
    }
}
