import Foundation

// Binary frame type prefix (first byte of binary WebSocket messages from server)
enum FrameType: UInt8 {
    case videoFrame = 0x01
    case fileChunk  = 0x02
}

// Incoming JSON message types from client
enum ClientMessage {
    case auth(pin: String)
    case mouseMove(x: Double, y: Double)
    case mouseButton(button: String, down: Bool, x: Double, y: Double)
    case mouseScroll(dx: Int, dy: Int)
    case key(code: String, down: Bool, modifiers: [String])
    case clipboardSet(text: String)
    case fileStart(id: String, name: String, size: Int64)
    case fileEnd(id: String)
    case qualitySet(fps: Int, bitrate: Int)
    case ping
    case unknown

    static func parse(_ json: [String: Any]) -> ClientMessage {
        guard let type = json["type"] as? String else { return .unknown }
        switch type {
        case "auth":
            return .auth(pin: json["pin"] as? String ?? "")
        case "mouse_move":
            return .mouseMove(
                x: json["x"] as? Double ?? 0,
                y: json["y"] as? Double ?? 0
            )
        case "mouse_button":
            return .mouseButton(
                button: json["button"] as? String ?? "left",
                down: json["down"] as? Bool ?? false,
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
        case "quality":
            return .qualitySet(
                fps: json["fps"] as? Int ?? 60,
                bitrate: json["bitrate"] as? Int ?? 10_000_000
            )
        case "ping":
            return .ping
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
