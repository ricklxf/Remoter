import Foundation

// MARK: - Binary Frame Type Prefixes

/// First byte of binary WebSocket frames.
/// Exact match with Remoter-Mac (Protocol.swift), Remoter-Win (Protocol.cs), and Remoter-WinClient (Protocol.cs).
public enum FrameType: UInt8, Sendable {
    case videoFrame = 0x01
    case fileChunk  = 0x02
    case audioFrame = 0x03
    case encrypted  = 0xE0
}

// MARK: - Protocol Helpers

public enum ProtocolHelpers {
    /// 64-bit FNV-1a hash for fast clipboard anti-loop deduplication.
    public static func fnv1a64(_ data: Data) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        let prime: UInt64 = 0x100000001b3
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return hash
    }

    public static func fnv1a64(_ string: String) -> UInt64 {
        fnv1a64(Data(string.utf8))
    }
}

// MARK: - Binary Frame Parser & Builder

public enum BinaryFrames {
    /// Parses `[0x01][4B frameId BE][4B ptsMs BE][1B flags (bit0=keyframe)][payload]`.
    public static func parseVideoFrame(_ data: Data, activeCodec: VideoCodec) -> VideoFramePacket? {
        guard data.count >= 10 else { return nil }
        return data.withUnsafeBytes { raw -> VideoFramePacket? in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                  base[0] == FrameType.videoFrame.rawValue else {
                return nil
            }
            let frameId = (UInt32(base[1]) << 24)
                | (UInt32(base[2]) << 16)
                | (UInt32(base[3]) << 8)
                | UInt32(base[4])
            let ptsMs = (UInt32(base[5]) << 24)
                | (UInt32(base[6]) << 16)
                | (UInt32(base[7]) << 8)
                | UInt32(base[8])
            let isKeyframe = (base[9] & 0x01) != 0
            let payload = Data(bytes: base.advanced(by: 10), count: data.count - 10)
            return VideoFramePacket(
                data: payload,
                frameId: frameId,
                ptsMs: ptsMs,
                isKeyframe: isKeyframe,
                codec: activeCodec
            )
        }
    }

    /// Parses `[0x03][ADTS-framed AAC packet]`.
    public static func parseAudioFrame(_ data: Data) -> AudioFramePacket? {
        guard data.count > 1, data.first == FrameType.audioFrame.rawValue else { return nil }
        let payload = data.subdata(in: 1..<data.count)
        return AudioFramePacket(data: payload)
    }

    /// Parses `[0x02][16B UTF-8 fileId padded with '\0'][4B offset BE][chunk bytes]`.
    public static func parseFileChunk(_ data: Data) -> (fileId: String, offset: UInt32, chunk: Data)? {
        guard data.count >= 21 else { return nil }
        return data.withUnsafeBytes { raw -> (String, UInt32, Data)? in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                  base[0] == FrameType.fileChunk.rawValue else {
                return nil
            }
            var idLen = 16
            while idLen > 0 && base[1 + idLen - 1] == 0 {
                idLen -= 1
            }
            let idData = Data(bytes: base.advanced(by: 1), count: idLen)
            let fileId = String(data: idData, encoding: .utf8) ?? ""
            let offset = (UInt32(base[17]) << 24)
                | (UInt32(base[18]) << 16)
                | (UInt32(base[19]) << 8)
                | UInt32(base[20])
            let chunk = Data(bytes: base.advanced(by: 21), count: data.count - 21)
            return (fileId, offset, chunk)
        }
    }

    /// Builds `[0x02][16B UTF-8 fileId padded with '\0'][4B offset BE][chunk bytes]`.
    public static func buildFileChunkPacket(fileId: String, offset: UInt32, chunk: Data) -> Data {
        var packet = Data(count: 1 + 16 + 4 + chunk.count)
        let idBytes = Array(fileId.utf8)
        let idCopyLen = min(idBytes.count, 16)

        packet.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            base[0] = FrameType.fileChunk.rawValue
            if idCopyLen > 0 {
                for i in 0..<idCopyLen {
                    base[1 + i] = idBytes[i]
                }
            }
            // Remaining bytes in 1..<17 are already zero-initialized.
            base[17] = UInt8((offset >> 24) & 0xFF)
            base[18] = UInt8((offset >> 16) & 0xFF)
            base[19] = UInt8((offset >> 8) & 0xFF)
            base[20] = UInt8(offset & 0xFF)
            if !chunk.isEmpty {
                chunk.copyBytes(to: base.advanced(by: 21), count: chunk.count)
            }
        }
        return packet
    }
}

// MARK: - Outbound Client -> Agent JSON Messages

public enum ClientMessages {
    private static func serialize(_ dict: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: dict, options: [])) ?? Data("{}".utf8)
    }

    public static func cryptoHello(pubkeyBase64: String) -> Data {
        serialize(["type": "crypto_hello", "pubkey": pubkeyBase64])
    }

    public static func authPin(_ pin: String) -> Data {
        serialize(["type": "auth", "pin": pin])
    }

    public static func authCredentials(username: String, password: String) -> Data {
        serialize(["type": "auth_credentials", "username": username, "password": password])
    }

    public static func authToken(_ token: String) -> Data {
        serialize(["type": "auth_token", "token": token])
    }

    public static func mouseMove(x: Double, y: Double, dragging: String? = nil) -> Data {
        var dict: [String: Any] = ["type": "mouse_move", "x": x, "y": y]
        if let dragging { dict["dragging"] = dragging }
        return serialize(dict)
    }

    public static func mouseButton(button: String, down: Bool, x: Double, y: Double) -> Data {
        serialize(["type": "mouse_button", "button": button, "down": down, "x": x, "y": y])
    }

    public static func mouseDoubleClick(button: String, x: Double, y: Double) -> Data {
        serialize(["type": "mouse_double_click", "button": button, "x": x, "y": y])
    }

    public static func mouseScroll(
        dx: Int,
        dy: Int,
        px: Int? = nil,
        py: Int? = nil,
        isPrecise: Bool? = nil,
        phase: Int? = nil,
        momentumPhase: Int? = nil
    ) -> Data {
        var dict: [String: Any] = ["type": "mouse_scroll", "dx": dx, "dy": dy]
        if let px { dict["px"] = px }
        if let py { dict["py"] = py }
        if let isPrecise { dict["isPrecise"] = isPrecise }
        if let phase { dict["phase"] = phase }
        if let momentumPhase { dict["momentumPhase"] = momentumPhase }
        return serialize(dict)
    }

    public static func key(code: String, down: Bool, modifiers: [String]) -> Data {
        serialize(["type": "key", "code": code, "down": down, "modifiers": modifiers])
    }

    public static func textInput(_ text: String) -> Data {
        serialize(["type": "text_input", "text": text])
    }

    public static func clipboardSet(text: String) -> Data {
        serialize(["type": "clipboard_set", "text": text])
    }

    public static func clipboardSetImage(base64Png: String) -> Data {
        serialize(["type": "clipboard_set_image", "data": base64Png])
    }

    public static func setReverseClipboardSync(enabled: Bool) -> Data {
        serialize(["type": "set_reverse_clipboard_sync", "enabled": enabled])
    }

    public static func fileStart(id: String, name: String, size: Int64) -> Data {
        serialize(["type": "file_start", "id": id, "name": name, "size": size])
    }

    public static func fileEnd(id: String) -> Data {
        serialize(["type": "file_end", "id": id])
    }

    public static func listDir(path: String) -> Data {
        serialize(["type": "list_dir", "path": path])
    }

    public static func requestFile(path: String) -> Data {
        serialize(["type": "request_file", "path": path])
    }

    public static func fps(_ fps: Int, auto: Bool) -> Data {
        serialize(["type": "fps", "fps": fps, "auto": auto])
    }

    public static func bitrate(_ bitrate: Int, auto: Bool) -> Data {
        serialize(["type": "bitrate", "bitrate": bitrate, "auto": auto])
    }

    public static func resolution(
        tier: ResolutionTier,
        width: Int? = nil,
        height: Int? = nil,
        scale: Double? = nil
    ) -> Data {
        var dict: [String: Any] = ["type": "resolution", "tier": tier.wireString]
        if let width { dict["width"] = width }
        if let height { dict["height"] = height }
        if let scale { dict["scale"] = scale }
        return serialize(dict)
    }

    public static func chroma(_ mode: ChromaMode) -> Data {
        serialize(["type": "chroma", "mode": mode.wireString])
    }

    public static func hdr(enabled: Bool) -> Data {
        serialize(["type": "hdr", "enabled": enabled])
    }

    public static func lowLatency(enabled: Bool) -> Data {
        serialize(["type": "low_latency", "enabled": enabled])
    }

    public static func setCodec(_ codec: VideoCodec) -> Data {
        serialize(["type": "set_codec", "codec": codec.wireString])
    }

    public static func codecCaps(_ codecs: [String]) -> Data {
        serialize(["type": "codec_caps", "codecs": codecs])
    }

    public static func setAudio(enabled: Bool) -> Data {
        serialize(["type": "set_audio", "enabled": enabled])
    }

    public static func setMuted(_ muted: Bool) -> Data {
        serialize(["type": "set_muted", "muted": muted])
    }

    public static func setPrivacyScreen(enabled: Bool) -> Data {
        serialize(["type": "set_privacy_screen", "enabled": enabled])
    }

    public static func setInputLock(locked: Bool) -> Data {
        serialize(["type": "set_input_lock", "locked": locked])
    }

    public static func setInputEnabled(enabled: Bool) -> Data {
        serialize(["type": "set_input_enabled", "enabled": enabled])
    }

    public static func setDisplay(id: UInt32) -> Data {
        serialize(["type": "display", "id": id])
    }

    public static func ping() -> Data {
        serialize(["type": "ping"])
    }

    public static func requestKeyframe() -> Data {
        serialize(["type": "request_keyframe"])
    }

    public static func clientStats(fps: Double, rttMs: Int, rx: String = "") -> Data {
        serialize(["type": "client_stats", "fps": fps, "rtt_ms": rttMs, "rx": rx])
    }

    public static func netHint(lan: Bool) -> Data {
        serialize(["type": "net_hint", "lan": lan])
    }

    public static func ctrlAltDel() -> Data {
        serialize(["type": "ctrl_alt_del"])
    }

    public static func lockScreen() -> Data {
        serialize(["type": "lock_screen"])
    }

    public static func logout() -> Data {
        serialize(["type": "logout"])
    }

    public static func restart() -> Data {
        serialize(["type": "restart"])
    }
}

// MARK: - Inbound Agent -> Client JSON Messages

public enum ServerMessage: Equatable, Sendable {
    case hello(ServerHello)
    case cryptoOk
    case authOk(token: String?, username: String?)
    case streamStarted(StreamStartedInfo)
    case codecChanged(VideoCodec)
    case qualityActive(fps: Int, bitrate: Int)
    case chromaActive(ChromaMode)
    case hdrActive(enabled: Bool)
    case forceCanvas(enabled: Bool)
    case udpOffer(port: Int, sessionTokenHex: String)
    case udpActive(enabled: Bool)
    case inputLockChanged(locked: Bool)
    case cursorShape(CursorShapeInfo)
    case pong(encodeMs: Int)
    case serverStats(ServerStats)
    case fileStart(id: String, name: String, size: Int64)
    case fileEnd(id: String)
    case dirListing(path: String, entries: [RemoteFileEntry])
    case clipboardFromTarget(ClipboardData)
    case keepalive
    case hostDisconnected
    case error(code: String, message: String)
    case unknown(type: String)

    public static func parse(jsonData: Data) -> ServerMessage {
        guard let obj = try? JSONSerialization.jsonObject(with: jsonData, options: []),
              let dict = obj as? [String: Any] else {
            return .unknown(type: "")
        }
        return parse(jsonObject: dict)
    }

    public static func parse(jsonObject root: [String: Any]) -> ServerMessage {
        let type = readString(root, "type")
        switch type {
        case "hello":
            return .hello(ServerHello(
                version: readString(root, "version"),
                os: readString(root, "os"),
                pubkey: readOptionalString(root, "pubkey"),
                computerName: readString(root, "computerName"),
                modelId: readString(root, "modelId"),
                inputLocked: readOptionalBool(root, "inputLocked")
            ))

        case "crypto_ok":
            return .cryptoOk

        case "auth_ok", "connected":
            return .authOk(
                token: readOptionalString(root, "token"),
                username: readOptionalString(root, "username")
            )

        case "stream_started":
            return parseStreamStarted(root)

        case "codec_changed":
            return .codecChanged(VideoCodec(wireString: readOptionalString(root, "codec")))

        case "quality_active":
            return .qualityActive(
                fps: readInt(root, "fps"),
                bitrate: readInt(root, "bitrate")
            )

        case "chroma_active":
            return .chromaActive(ChromaMode(wireString: readOptionalString(root, "mode")))

        case "hdr_active":
            return .hdrActive(enabled: readBool(root, "enabled"))

        case "force_canvas":
            return .forceCanvas(enabled: readBool(root, "enabled"))

        case "udp_offer":
            return .udpOffer(
                port: readInt(root, "port"),
                sessionTokenHex: readString(root, "session_token")
            )

        case "udp_active":
            return .udpActive(enabled: readBool(root, "enabled"))

        case "input_lock_changed":
            return .inputLockChanged(locked: readBool(root, "locked"))

        case "cursor_shape":
            return parseCursorShape(root)

        case "pong":
            return .pong(encodeMs: readInt(root, "encode_ms"))

        case "stats":
            return .serverStats(ServerStats(
                fps: readInt(root, "fps"),
                uploadSpeed: readString(root, "uploadSpeed"),
                quality: readInt(root, "quality")
            ))

        case "file_start":
            return .fileStart(
                id: readString(root, "id"),
                name: readString(root, "name"),
                size: readInt64(root, "size")
            )

        case "file_end":
            return .fileEnd(id: readString(root, "id"))

        case "dir_listing":
            return parseDirListing(root)

        case "clipboard_from_target":
            return parseClipboardFromTarget(root)

        case "keepalive":
            return .keepalive

        case "host_disconnected":
            return .hostDisconnected

        case "error":
            let code = readString(root, "code")
            let message = readOptionalString(root, "message") ?? code
            return .error(code: code, message: message)

        default:
            return .unknown(type: type)
        }
    }

    private static func parseStreamStarted(_ root: [String: Any]) -> ServerMessage {
        let width = readInt(root, "width")
        let height = readInt(root, "height")
        let codec = VideoCodec(wireString: readOptionalString(root, "codec"))
        let fps = readInt(root, "fps", defaultValue: 60)
        let activeDisplay = readUInt32(root, "display")

        var displays: [DisplayInfo] = []
        if let arr = root["displays"] as? [[String: Any]] {
            displays.reserveCapacity(arr.count)
            for item in arr {
                displays.append(DisplayInfo(
                    id: readUInt32(item, "id"),
                    name: readString(item, "name"),
                    width: readInt(item, "width"),
                    height: readInt(item, "height")
                ))
            }
        }

        return .streamStarted(StreamStartedInfo(
            width: width,
            height: height,
            codec: codec,
            fps: fps,
            displays: displays,
            activeDisplayId: activeDisplay
        ))
    }

    private static func parseCursorShape(_ root: [String: Any]) -> ServerMessage {
        let pngBase64 = readString(root, "png")
        let pngData = pngBase64.isEmpty ? Data() : (Data(base64Encoded: pngBase64) ?? Data())
        return .cursorShape(CursorShapeInfo(
            pngData: pngData,
            pngBase64: pngBase64,
            hotX: readInt(root, "hot_x"),
            hotY: readInt(root, "hot_y"),
            width: readInt(root, "width"),
            height: readInt(root, "height"),
            isVisible: readBool(root, "visible", defaultValue: true)
        ))
    }

    private static func parseDirListing(_ root: [String: Any]) -> ServerMessage {
        let path = readString(root, "path")
        var entries: [RemoteFileEntry] = []
        if let arr = root["entries"] as? [[String: Any]] {
            entries.reserveCapacity(arr.count)
            for item in arr {
                entries.append(RemoteFileEntry(
                    name: readString(item, "name"),
                    size: readInt64(item, "size"),
                    isDir: readBool(item, "isDir"),
                    modifiedMs: readInt64(item, "modified")
                ))
            }
        }
        return .dirListing(path: path, entries: entries)
    }

    private static func parseClipboardFromTarget(_ root: [String: Any]) -> ServerMessage {
        let text = readOptionalString(root, "text")
        let imageBase64 = readOptionalString(root, "image")
        let imageData: Data?
        if let b64 = imageBase64, !b64.isEmpty {
            imageData = Data(base64Encoded: b64)
        } else {
            imageData = nil
        }
        return .clipboardFromTarget(ClipboardData(
            text: text,
            imagePngData: imageData,
            imageBase64: imageBase64
        ))
    }

    // MARK: - Safe JSON Readers

    private static func readString(_ dict: [String: Any], _ key: String) -> String {
        dict[key] as? String ?? ""
    }

    private static func readOptionalString(_ dict: [String: Any], _ key: String) -> String? {
        dict[key] as? String
    }

    private static func readBool(_ dict: [String: Any], _ key: String, defaultValue: Bool = false) -> Bool {
        if let b = dict[key] as? Bool { return b }
        return defaultValue
    }

    private static func readOptionalBool(_ dict: [String: Any], _ key: String) -> Bool? {
        if let b = dict[key] as? Bool { return b }
        return nil
    }

    private static func readInt(_ dict: [String: Any], _ key: String, defaultValue: Int = 0) -> Int {
        if let n = dict[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
            return Int(n.doubleValue.rounded())
        }
        return defaultValue
    }

    private static func readUInt32(_ dict: [String: Any], _ key: String, defaultValue: UInt32 = 0) -> UInt32 {
        if let n = dict[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
            let v = n.doubleValue.rounded()
            if v >= 0 && v <= Double(UInt32.max) {
                return UInt32(v)
            }
        }
        return defaultValue
    }

    private static func readInt64(_ dict: [String: Any], _ key: String, defaultValue: Int64 = 0) -> Int64 {
        if let n = dict[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
            return n.int64Value
        }
        return defaultValue
    }
}
