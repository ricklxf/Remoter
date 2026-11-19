import Foundation

/// Persists saved remote devices and client preferences in
/// `~/Library/Application Support/RemoterMacClient/devices.json`
/// using atomic temp-file + rename writes.
public final class DeviceStore: @unchecked Sendable {
    private struct StorePayload: Codable {
        var devices: [SavedDevice] = []
        var settings: ClientSettings = ClientSettings()
    }

    public static let shared = DeviceStore()

    private let lock = NSLock()
    private let fileURL: URL
    private var payload = StorePayload()

    private static let encoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return enc
    }()

    private static let decoder: JSONDecoder = {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }()

    public init(customFileURL: URL? = nil) {
        if let customFileURL {
            self.fileURL = customFileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
            self.fileURL = appSupport
                .appendingPathComponent("RemoterMacClient", isDirectory: true)
                .appendingPathComponent("devices.json", isDirectory: false)
        }
        load()
    }

    public func load() {
        lock.lock()
        defer { lock.unlock() }
        do {
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                payload = StorePayload()
                return
            }
            let data = try Data(contentsOf: fileURL)
            payload = try Self.decoder.decode(StorePayload.self, from: data)
        } catch {
            payload = StorePayload()
        }
    }

    public func save() {
        lock.lock()
        defer { lock.unlock() }
        saveLocked()
    }

    public func getDevices() -> [SavedDevice] {
        lock.lock()
        defer { lock.unlock() }
        return payload.devices.sorted { $0.lastConnectedAt > $1.lastConnectedAt }
    }

    public func findByHost(_ host: String, port: Int) -> SavedDevice? {
        lock.lock()
        defer { lock.unlock() }
        return payload.devices.first {
            $0.host.caseInsensitiveCompare(host) == .orderedSame && $0.port == port
        }
    }

    public func upsertDevice(_ device: SavedDevice) {
        lock.lock()
        defer { lock.unlock() }
        if let idx = payload.devices.firstIndex(where: {
            $0.id == device.id ||
            ($0.host.caseInsensitiveCompare(device.host) == .orderedSame && $0.port == device.port)
        }) {
            var existing = payload.devices[idx]
            if !device.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                existing.name = device.name
            }
            existing.host = device.host
            existing.port = device.port
            existing.useTls = device.useTls
            existing.authMode = device.authMode
            if let pin = device.pin { existing.pin = pin }
            if let username = device.username { existing.username = username }
            if let token = device.token { existing.token = token }
            if let comp = device.computerName, !comp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                existing.computerName = comp
            }
            if let model = device.modelId, !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                existing.modelId = model
            }
            if let os = device.serverOs, !os.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                existing.serverOs = os
            }
            existing.lastConnectedAt = device.lastConnectedAt
            payload.devices[idx] = existing
        } else {
            var newDevice = device
            if newDevice.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                newDevice.id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            }
            payload.devices.append(newDevice)
        }
        saveLocked()
    }

    @discardableResult
    public func removeDevice(id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let before = payload.devices.count
        payload.devices.removeAll { $0.id == id }
        let removed = payload.devices.count != before
        if removed { saveLocked() }
        return removed
    }

    public func updateMachineInfo(
        host: String,
        port: Int,
        computerName: String?,
        modelId: String?,
        serverOs: String?
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard let idx = payload.devices.firstIndex(where: {
            $0.host.caseInsensitiveCompare(host) == .orderedSame && $0.port == port
        }) else {
            return
        }
        if let comp = computerName, !comp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payload.devices[idx].computerName = comp
        }
        if let model = modelId, !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payload.devices[idx].modelId = model
        }
        if let os = serverOs, !os.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payload.devices[idx].serverOs = os
        }
        saveLocked()
    }

    public func updateToken(host: String, port: Int, username: String, token: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let idx = payload.devices.firstIndex(where: {
            $0.host.caseInsensitiveCompare(host) == .orderedSame && $0.port == port
        }) else {
            return
        }
        payload.devices[idx].username = username
        payload.devices[idx].token = token
        payload.devices[idx].lastConnectedAt = Date()
        saveLocked()
    }

    public func getSettings() -> ClientSettings {
        lock.lock()
        defer { lock.unlock() }
        return payload.settings
    }

    public func saveSettings(_ settings: ClientSettings) {
        lock.lock()
        defer { lock.unlock() }
        payload.settings = settings
        saveLocked()
    }

    private func saveLocked() {
        do {
            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try Self.encoder.encode(payload)
            let tmpURL = fileURL.appendingPathExtension("tmp")
            try data.write(to: tmpURL, options: [])
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmpURL)
            } else {
                try FileManager.default.moveItem(at: tmpURL, to: fileURL)
            }
        } catch {
            // Best-effort persistence; never crash UI on disk errors.
        }
    }
}
