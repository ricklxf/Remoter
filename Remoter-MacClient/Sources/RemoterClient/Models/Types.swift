import Foundation

// MARK: - Connection & Session Enums

public enum ConnectionMode: String, Codable, CaseIterable, Sendable {
    case direct
    case relay
}

public enum AuthMode: String, Codable, CaseIterable, Sendable {
    case pin
    case credentials
    case token
}

public enum ConnectionState: String, Equatable, Sendable {
    case idle
    case connecting
    case authenticating
    case streaming
    case reconnecting
    case disconnected
    case error
}

public enum ScaleMode: String, Codable, CaseIterable, Sendable {
    case fit
    case stretch
    case original
}

public enum ResolutionTier: String, Codable, CaseIterable, Sendable {
    case match
    case native
    case res1080
    case res2k

    public var wireString: String {
        switch self {
        case .match:   return "match"
        case .native:  return "native"
        case .res1080: return "1080"
        case .res2k:   return "2k"
        }
    }

    public var displayName: String {
        switch self {
        case .match:   return "Match Window"
        case .native:  return "Native"
        case .res1080: return "1080p"
        case .res2k:   return "2K"
        }
    }
}

public enum VideoCodec: String, Codable, CaseIterable, Sendable {
    case h264
    case h265
    case jpeg

    public init(wireString: String?) {
        switch wireString?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "h265", "hevc":
            self = .h265
        case "jpeg", "mjpeg":
            self = .jpeg
        default:
            self = .h264
        }
    }

    public var wireString: String {
        switch self {
        case .h264: return "h264"
        case .h265: return "h265"
        case .jpeg: return "jpeg"
        }
    }

    public var badgeText: String {
        switch self {
        case .h264: return "H.264"
        case .h265: return "H.265"
        case .jpeg: return "JPEG"
        }
    }
}

public enum ChromaMode: String, Codable, CaseIterable, Sendable {
    case yuv420
    case yuv444

    public init(wireString: String?) {
        if wireString?.trimmingCharacters(in: .whitespacesAndNewlines) == "444" {
            self = .yuv444
        } else {
            self = .yuv420
        }
    }

    public var wireString: String {
        switch self {
        case .yuv420: return "420"
        case .yuv444: return "444"
        }
    }
}

public enum FileTransferDirection: String, Codable, Sendable {
    case upload
    case download
}

// MARK: - Display & Stream Models

public struct DisplayInfo: Identifiable, Equatable, Codable, Sendable {
    public let id: UInt32
    public let name: String
    public let width: Int
    public let height: Int

    public init(id: UInt32, name: String, width: Int, height: Int) {
        self.id = id
        self.name = name
        self.width = width
        self.height = height
    }
}

public struct ServerHello: Equatable, Sendable {
    public let version: String
    public let os: String
    public let pubkey: String?
    public let computerName: String
    public let modelId: String
    public let inputLocked: Bool?

    public init(
        version: String,
        os: String,
        pubkey: String?,
        computerName: String,
        modelId: String,
        inputLocked: Bool?
    ) {
        self.version = version
        self.os = os
        self.pubkey = pubkey
        self.computerName = computerName
        self.modelId = modelId
        self.inputLocked = inputLocked
    }
}

public struct StreamStartedInfo: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let codec: VideoCodec
    public let fps: Int
    public let displays: [DisplayInfo]
    public let activeDisplayId: UInt32

    public init(
        width: Int,
        height: Int,
        codec: VideoCodec,
        fps: Int,
        displays: [DisplayInfo],
        activeDisplayId: UInt32
    ) {
        self.width = width
        self.height = height
        self.codec = codec
        self.fps = fps
        self.displays = displays
        self.activeDisplayId = activeDisplayId
    }
}

// MARK: - Connection Parameters

public enum ConnectParamsError: LocalizedError {
    case invalidURL(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let raw):
            return "Invalid WebSocket URL: \(raw)"
        }
    }
}

public struct ConnectParams: Equatable, Sendable {
    public var mode: ConnectionMode
    public var host: String
    public var port: Int
    public var useTls: Bool
    public var directUrl: String?
    public var relayUrl: String?
    public var sessionId: String?
    public var pin: String
    public var label: String?
    public var authMode: AuthMode
    public var username: String?
    public var password: String?
    public var token: String?
    public var rememberDevice: Bool

    public init(
        mode: ConnectionMode = .direct,
        host: String = "",
        port: Int = 7788,
        useTls: Bool = true,
        directUrl: String? = nil,
        relayUrl: String? = nil,
        sessionId: String? = nil,
        pin: String = "",
        label: String? = nil,
        authMode: AuthMode = .pin,
        username: String? = nil,
        password: String? = nil,
        token: String? = nil,
        rememberDevice: Bool = true
    ) {
        self.mode = mode
        self.host = host
        self.port = port
        self.useTls = useTls
        self.directUrl = directUrl
        self.relayUrl = relayUrl
        self.sessionId = sessionId
        self.pin = pin
        self.label = label
        self.authMode = authMode
        self.username = username
        self.password = password
        self.token = token
        self.rememberDevice = rememberDevice
    }

    public func buildWebSocketURL() throws -> URL {
        switch mode {
        case .direct:
            if let direct = directUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !direct.isEmpty {
                let raw: String
                let lower = direct.lowercased()
                if lower.hasPrefix("ws://") || lower.hasPrefix("wss://") {
                    raw = direct
                } else {
                    raw = "\(useTls ? "wss" : "ws")://\(direct)"
                }
                guard let url = URL(string: raw) else {
                    throw ConnectParamsError.invalidURL(raw)
                }
                return url
            }

            var trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = trimmedHost.lowercased()
            if lower.hasPrefix("ws://") || lower.hasPrefix("wss://") {
                guard let url = URL(string: trimmedHost) else {
                    throw ConnectParamsError.invalidURL(trimmedHost)
                }
                return url
            }

            // Bracket bare IPv6 addresses
            if trimmedHost.contains(":"), !trimmedHost.hasPrefix("[") {
                trimmedHost = "[\(trimmedHost)]"
            }

            let scheme = useTls ? "wss" : "ws"
            let raw = "\(scheme)://\(trimmedHost):\(port)"
            guard let url = URL(string: raw) else {
                throw ConnectParamsError.invalidURL(raw)
            }
            return url

        case .relay:
            var baseUrl = (relayUrl ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            while baseUrl.hasSuffix("/") {
                baseUrl.removeLast()
            }
            let sid = Self.percentEncodeQueryValue(sessionId ?? "")
            let encodedPin = Self.percentEncodeQueryValue(pin)
            let raw = "\(baseUrl)?role=client&session=\(sid)&pin=\(encodedPin)"
            guard let url = URL(string: raw) else {
                throw ConnectParamsError.invalidURL(raw)
            }
            return url
        }
    }

    private static func percentEncodeQueryValue(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=?+#/")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

// MARK: - Persistence Models

public struct SavedDevice: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var host: String
    public var port: Int
    public var useTls: Bool
    public var authMode: AuthMode
    public var pin: String?
    public var username: String?
    public var token: String?
    public var computerName: String?
    public var modelId: String?
    public var serverOs: String?
    public var lastConnectedAt: Date

    public init(
        id: String = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
        name: String = "",
        host: String = "",
        port: Int = 7788,
        useTls: Bool = true,
        authMode: AuthMode = .pin,
        pin: String? = nil,
        username: String? = nil,
        token: String? = nil,
        computerName: String? = nil,
        modelId: String? = nil,
        serverOs: String? = nil,
        lastConnectedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.useTls = useTls
        self.authMode = authMode
        self.pin = pin
        self.username = username
        self.token = token
        self.computerName = computerName
        self.modelId = modelId
        self.serverOs = serverOs
        self.lastConnectedAt = lastConnectedAt
    }

    public var displayName: String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty { return trimmedName }
        if let comp = computerName?.trimmingCharacters(in: .whitespacesAndNewlines), !comp.isEmpty {
            return comp
        }
        return "\(host):\(port)"
    }
}

public struct ClientSettings: Codable, Equatable, Sendable {
    public var scaleMode: ScaleMode
    public var resolutionTier: ResolutionTier
    public var preferredCodec: VideoCodec
    public var fps: Int
    public var autoFps: Bool
    public var bitrateBps: Int
    public var autoBitrate: Bool
    public var audioEnabled: Bool
    public var audioVolume: Float
    public var clipboardSyncEnabled: Bool
    public var macWinKeySwap: Bool
    public var vsyncEnabled: Bool
    public var downloadDirectory: String?

    public init(
        scaleMode: ScaleMode = .fit,
        resolutionTier: ResolutionTier = .native,
        preferredCodec: VideoCodec = .h264,
        fps: Int = 60,
        autoFps: Bool = true,
        bitrateBps: Int = 8_000_000,
        autoBitrate: Bool = true,
        audioEnabled: Bool = true,
        audioVolume: Float = 1.0,
        clipboardSyncEnabled: Bool = true,
        macWinKeySwap: Bool = true,
        vsyncEnabled: Bool = false,
        downloadDirectory: String? = nil
    ) {
        self.scaleMode = scaleMode
        self.resolutionTier = resolutionTier
        self.preferredCodec = preferredCodec
        self.fps = fps
        self.autoFps = autoFps
        self.bitrateBps = bitrateBps
        self.autoBitrate = autoBitrate
        self.audioEnabled = audioEnabled
        self.audioVolume = audioVolume
        self.clipboardSyncEnabled = clipboardSyncEnabled
        self.macWinKeySwap = macWinKeySwap
        self.vsyncEnabled = vsyncEnabled
        self.downloadDirectory = downloadDirectory
    }
}

// MARK: - Telemetry, Media, Cursor, Clipboard & File Transfer Models

public struct ClientStats: Equatable, Sendable {
    public let fps: Double
    public let rttMs: Int
    public let bitrateKbps: Int
    public let encodeMs: Int
    public let decodeMs: Int
    public let transport: String
    public let codec: VideoCodec
    public let isHardwareDecoded: Bool

    public init(
        fps: Double,
        rttMs: Int,
        bitrateKbps: Int,
        encodeMs: Int,
        decodeMs: Int,
        transport: String = "TCP",
        codec: VideoCodec = .h264,
        isHardwareDecoded: Bool = true
    ) {
        self.fps = fps
        self.rttMs = rttMs
        self.bitrateKbps = bitrateKbps
        self.encodeMs = encodeMs
        self.decodeMs = decodeMs
        self.transport = transport
        self.codec = codec
        self.isHardwareDecoded = isHardwareDecoded
    }
}

public struct ServerStats: Equatable, Sendable {
    public let fps: Int
    public let uploadSpeed: String
    public let quality: Int

    public init(fps: Int, uploadSpeed: String, quality: Int) {
        self.fps = fps
        self.uploadSpeed = uploadSpeed
        self.quality = quality
    }
}

public struct VideoFramePacket: Sendable {
    public let data: Data
    public let frameId: UInt32
    public let ptsMs: UInt32
    public let isKeyframe: Bool
    public let codec: VideoCodec

    public init(
        data: Data,
        frameId: UInt32,
        ptsMs: UInt32,
        isKeyframe: Bool,
        codec: VideoCodec
    ) {
        self.data = data
        self.frameId = frameId
        self.ptsMs = ptsMs
        self.isKeyframe = isKeyframe
        self.codec = codec
    }
}

public struct AudioFramePacket: Sendable {
    public let data: Data

    public init(data: Data) {
        self.data = data
    }
}

public struct CursorShapeInfo: Equatable, Sendable {
    public let pngData: Data
    public let pngBase64: String
    public let hotX: Int
    public let hotY: Int
    public let width: Int
    public let height: Int
    public let isVisible: Bool

    public init(
        pngData: Data,
        pngBase64: String,
        hotX: Int,
        hotY: Int,
        width: Int,
        height: Int,
        isVisible: Bool = true
    ) {
        self.pngData = pngData
        self.pngBase64 = pngBase64
        self.hotX = hotX
        self.hotY = hotY
        self.width = width
        self.height = height
        self.isVisible = isVisible
    }
}

public struct ClipboardData: Equatable, Sendable {
    public let text: String?
    public let imagePngData: Data?
    public let imageBase64: String?

    public init(text: String?, imagePngData: Data?, imageBase64: String?) {
        self.text = text
        self.imagePngData = imagePngData
        self.imageBase64 = imageBase64
    }
}

public struct RemoteFileEntry: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public let name: String
    public let size: Int64
    public let isDir: Bool
    public let modifiedMs: Int64

    public init(name: String, size: Int64, isDir: Bool, modifiedMs: Int64) {
        self.name = name
        self.size = size
        self.isDir = isDir
        self.modifiedMs = modifiedMs
    }
}

public struct FileTransferProgress: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let size: Int64
    public let transferred: Int64
    public let direction: FileTransferDirection
    public let speedBps: Double
    public let done: Bool
    public let savedPath: String?
    public let error: String?

    public init(
        id: String,
        name: String,
        size: Int64,
        transferred: Int64,
        direction: FileTransferDirection,
        speedBps: Double,
        done: Bool,
        savedPath: String? = nil,
        error: String? = nil
    ) {
        self.id = id
        self.name = name
        self.size = size
        self.transferred = transferred
        self.direction = direction
        self.speedBps = speedBps
        self.done = done
        self.savedPath = savedPath
        self.error = error
    }

    public var fractionCompleted: Double {
        guard size > 0 else { return done ? 1.0 : 0.0 }
        return min(1.0, max(0.0, Double(transferred) / Double(size)))
    }
}
