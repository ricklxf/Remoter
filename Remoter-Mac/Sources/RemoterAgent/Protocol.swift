import Foundation

// Binary frame type prefix (first byte of binary WebSocket messages from server)
enum FrameType: UInt8 {
    case videoFrame = 0x01
    case fileChunk  = 0x02
    case audioFrame = 0x03   // [0x03][ADTS-framed AAC packet]
}

// Incoming JSON message types from client
enum ClientMessage {
    case auth(pin: String)
    case mouseMove(x: Double, y: Double, dragging: String?)
    case mouseButton(button: String, down: Bool, x: Double, y: Double)
    case mouseDoubleClick(button: String, x: Double, y: Double)
    case mouseScroll(dx: Int, dy: Int)
    case key(code: String, down: Bool, modifiers: [String])
    case textInput(String)   // IME-composed text, injected as a unicode string
    case clipboardSet(text: String)
    case fileStart(id: String, name: String, size: Int64)
    case fileEnd(id: String)
    case fpsSet(fps: Int, auto: Bool)
    case bitrateSet(bitrate: Int, auto: Bool)
    case resolutionSet(tier: String)
    case setAudioEnabled(Bool)
    case displaySet(id: UInt32)
    case ping
    case requestKeyframe
    case webrtcOffer(sdp: String)
    case webrtcICE(json: String)
    case clientStats(fps: Double, rttMs: Int)
    case setCodec(codec: String)
    case cryptoHello(pubkey: String)
    case listDir(path: String)
    case requestFile(path: String)
    case setMuted(muted: Bool)
    case ctrlAltDel
    case setClipboardSync(enabled: Bool)
    case setInputEnabled(enabled: Bool)
    case clipboardSetImage(data: String)
    case lockScreen
    case logout
    case restart
    case authCredentials(username: String, password: String)
    case authToken(token: String)
    case unknown

    static func parse(_ json: [String: Any]) -> ClientMessage {
        guard let type = json["type"] as? String else { return .unknown }
        switch type {
        case "auth":
            return .auth(pin: json["pin"] as? String ?? "")
        case "mouse_move":
            return .mouseMove(
                x: json["x"] as? Double ?? 0,
                y: json["y"] as? Double ?? 0,
                dragging: json["dragging"] as? String
            )
        case "mouse_button":
            return .mouseButton(
                button: json["button"] as? String ?? "left",
                down: json["down"] as? Bool ?? false,
                x: json["x"] as? Double ?? 0,
                y: json["y"] as? Double ?? 0
            )
        case "mouse_double_click":
            return .mouseDoubleClick(
                button: json["button"] as? String ?? "left",
                x: json["x"] as? Double ?? 0,
                y: json["y"] as? Double ?? 0
            )
        case "mouse_scroll":
            return .mouseScroll(
                dx: json["dx"] as? Int ?? 0,
                dy: json["dy"] as? Int ?? 0
            )
        case "key":
            return .key(
                code: json["code"] as? String ?? "",
                down: json["down"] as? Bool ?? false,
                modifiers: json["modifiers"] as? [String] ?? []
            )
        case "text_input":
            return .textInput(json["text"] as? String ?? "")
        case "clipboard_set":
            return .clipboardSet(text: json["text"] as? String ?? "")
        case "file_start":
            return .fileStart(
                id: json["id"] as? String ?? "",
                name: json["name"] as? String ?? "",
                size: Int64(json["size"] as? Int ?? 0)
            )
        case "file_end":
            return .fileEnd(id: json["id"] as? String ?? "")
        case "fps":
            return .fpsSet(
                fps: json["fps"] as? Int ?? 30,
                auto: json["auto"] as? Bool ?? false
            )
        case "bitrate":
            return .bitrateSet(
                bitrate: json["bitrate"] as? Int ?? 2_000_000,
                auto: json["auto"] as? Bool ?? false
            )
        case "resolution":
            return .resolutionSet(tier: json["tier"] as? String ?? "1080")
        case "set_audio":
            return .setAudioEnabled(json["enabled"] as? Bool ?? false)
        case "display":
            return .displaySet(id: UInt32(json["id"] as? Int ?? 0))
        case "ping":
            return .ping
        case "request_keyframe":
            return .requestKeyframe
        case "webrtc_offer":
            return .webrtcOffer(sdp: json["sdp"] as? String ?? "")
        case "webrtc_ice":
            return .webrtcICE(json: json["candidate"] as? String ?? "")
        case "client_stats":
            return .clientStats(
                fps:   json["fps"]    as? Double ?? 0,
                rttMs: json["rtt_ms"] as? Int    ?? 0
            )
        case "set_codec":
            return .setCodec(codec: json["codec"] as? String ?? "h264")
        case "crypto_hello":
            return .cryptoHello(pubkey: json["pubkey"] as? String ?? "")
        case "list_dir":
            return .listDir(path: json["path"] as? String ?? "~")
        case "request_file":
            return .requestFile(path: json["path"] as? String ?? "")
        case "set_muted":
            return .setMuted(muted: json["muted"] as? Bool ?? false)
        case "ctrl_alt_del":
            return .ctrlAltDel
        case "set_clipboard_sync":
            return .setClipboardSync(enabled: json["enabled"] as? Bool ?? true)
        case "set_input_enabled":
            return .setInputEnabled(enabled: json["enabled"] as? Bool ?? true)
        case "clipboard_set_image":
            return .clipboardSetImage(data: json["data"] as? String ?? "")
        case "lock_screen":
            return .lockScreen
        case "logout":
            return .logout
        case "restart":
            return .restart
        case "auth_credentials":
            return .authCredentials(
                username: json["username"] as? String ?? "",
                password: json["password"] as? String ?? "")
        case "auth_token":
            return .authToken(token: json["token"] as? String ?? "")
        default:
            return .unknown
        }
    }
}

func buildVideoFramePacket(data: Data, frameId: UInt32, ptsMs: UInt32, isKeyframe: Bool) -> Data {
    var packet = Data(capacity: 10 + data.count)
    packet.append(FrameType.videoFrame.rawValue)
    var fid = frameId.bigEndian
    packet.append(Data(bytes: &fid, count: 4))
    var pts = ptsMs.bigEndian
    packet.append(Data(bytes: &pts, count: 4))
    packet.append(isKeyframe ? 0x01 : 0x00)
    packet.append(data)
    return packet
}
