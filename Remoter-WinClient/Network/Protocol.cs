using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace RemoterWinClient;

/// <summary>
/// Binary WebSocket frame type prefixes (first byte of binary WebSocket messages).
/// Exact match with Remoter-Mac (Protocol.swift), Remoter-Win (Protocol.cs), and Remoter-Client (Connection.ts).
/// </summary>
public static class FrameType
{
    public const byte VideoFrame = 0x01;
    public const byte FileChunk  = 0x02;
    public const byte AudioFrame = 0x03;
    public const byte Encrypted  = 0xE0;
}

public static class ProtocolHelpers
{
    public static readonly JsonSerializerOptions WireJsonOptions = new()
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    public static VideoCodecType ParseCodec(string? codec)
    {
        if (string.IsNullOrEmpty(codec)) return VideoCodecType.H264;
        return codec.Trim().ToLowerInvariant() switch
        {
            "h265" or "hevc" => VideoCodecType.H265,
            "jpeg" or "mjpeg" => VideoCodecType.Jpeg,
            _ => VideoCodecType.H264,
        };
    }

    public static string ToWireString(VideoCodecType codec) => codec switch
    {
        VideoCodecType.H265 => "h265",
        VideoCodecType.Jpeg => "jpeg",
        _ => "h264",
    };

    public static string ToWireString(ResolutionTier tier) => tier switch
    {
        ResolutionTier.Match => "match",
        ResolutionTier.Res1080 => "1080",
        ResolutionTier.Res2K => "2k",
        _ => "native",
    };

    public static string ToWireString(ChromaMode mode) => mode switch
    {
        ChromaMode.Yuv444 => "444",
        _ => "420",
    };

    public static ChromaMode ParseChroma(string? mode) =>
        string.Equals(mode, "444", StringComparison.OrdinalIgnoreCase)
            ? ChromaMode.Yuv444
            : ChromaMode.Yuv420;

    /// <summary>
    /// 64-bit FNV-1a hash (UU ClipboardManager anti-loop technique) for fast,
    /// allocation-free content deduplication.
    /// </summary>
    public static ulong ComputeFnv1a64(ReadOnlySpan<byte> data)
    {
        ulong hash = 0xcbf29ce484222325UL;
        const ulong prime = 0x100000001b3UL;
        for (int i = 0; i < data.Length; i++)
        {
            hash ^= data[i];
            hash *= prime;
        }
        return hash;
    }
}

/// <summary>
/// Binary frame parser and builder for video, audio, and file transfer packets.
/// </summary>
public static class BinaryFrames
{
    /// <summary>
    /// Parses [0x01][4B frameId BE][4B ptsMs BE][1B flags (bit0=keyframe)][payload].
    /// </summary>
    public static bool TryParseVideoFrame(
        ReadOnlySpan<byte> frame,
        VideoCodecType activeCodec,
        out VideoFramePacket packet)
    {
        if (frame.Length < 10 || frame[0] != FrameType.VideoFrame)
        {
            packet = default;
            return false;
        }

        uint frameId = BinaryPrimitives.ReadUInt32BigEndian(frame.Slice(1, 4));
        uint ptsMs = BinaryPrimitives.ReadUInt32BigEndian(frame.Slice(5, 4));
        bool isKeyframe = (frame[9] & 0x01) != 0;
        byte[] payload = frame[10..].ToArray();

        packet = new VideoFramePacket(payload, frameId, ptsMs, isKeyframe, activeCodec);
        return true;
    }

    /// <summary>
    /// Parses [0x03][ADTS-framed AAC packet].
    /// </summary>
    public static bool TryParseAudioFrame(ReadOnlySpan<byte> frame, out AudioFramePacket packet)
    {
        if (frame.Length <= 1 || frame[0] != FrameType.AudioFrame)
        {
            packet = default;
            return false;
        }

        packet = new AudioFramePacket(frame[1..].ToArray());
        return true;
    }

    /// <summary>
    /// Parses [0x02][16B UTF-8 fileId padded with '\0'][4B offset BE][chunk bytes].
    /// </summary>
    public static bool TryParseFileChunk(
        ReadOnlySpan<byte> frame,
        out string fileId,
        out uint offset,
        out byte[] chunk)
    {
        if (frame.Length < 21 || frame[0] != FrameType.FileChunk)
        {
            fileId = "";
            offset = 0;
            chunk = Array.Empty<byte>();
            return false;
        }

        fileId = Encoding.UTF8.GetString(frame.Slice(1, 16)).TrimEnd('\0');
        offset = BinaryPrimitives.ReadUInt32BigEndian(frame.Slice(17, 4));
        chunk = frame[21..].ToArray();
        return true;
    }

    /// <summary>
    /// Builds [0x02][16B UTF-8 fileId padded with '\0'][4B offset BE][chunk bytes].
    /// </summary>
    public static byte[] BuildFileChunkPacket(string fileId, uint offset, ReadOnlySpan<byte> chunk)
    {
        var pkt = new byte[1 + 16 + 4 + chunk.Length];
        pkt[0] = FrameType.FileChunk;

        var idBytes = Encoding.UTF8.GetBytes(fileId);
        int idLen = Math.Min(idBytes.Length, 16);
        Buffer.BlockCopy(idBytes, 0, pkt, 1, idLen);

        BinaryPrimitives.WriteUInt32BigEndian(pkt.AsSpan(17, 4), offset);
        chunk.CopyTo(pkt.AsSpan(21));
        return pkt;
    }
}

/// <summary>
/// Serializers for all client -> agent JSON control messages.
/// </summary>
public static class ClientMessages
{
    public static byte[] Serialize(object message) =>
        JsonSerializer.SerializeToUtf8Bytes(message, ProtocolHelpers.WireJsonOptions);

    public static byte[] CryptoHello(string pubkeyBase64) =>
        Serialize(new { type = "crypto_hello", pubkey = pubkeyBase64 });

    public static byte[] AuthPin(string pin) =>
        Serialize(new { type = "auth", pin });

    public static byte[] AuthCredentials(string username, string password) =>
        Serialize(new { type = "auth_credentials", username, password });

    public static byte[] AuthToken(string token) =>
        Serialize(new { type = "auth_token", token });

    public static byte[] MouseMove(double x, double y, string? dragging = null) =>
        Serialize(new { type = "mouse_move", x, y, dragging });

    public static byte[] MouseButton(string button, bool down, double x, double y) =>
        Serialize(new { type = "mouse_button", button, down, x, y });

    public static byte[] MouseDoubleClick(string button, double x, double y) =>
        Serialize(new { type = "mouse_double_click", button, x, y });

    public static byte[] MouseScroll(
        int dx,
        int dy,
        int? px = null,
        int? py = null,
        bool? isPrecise = null,
        int? phase = null,
        int? momentumPhase = null) =>
        Serialize(new { type = "mouse_scroll", dx, dy, px, py, isPrecise, phase, momentumPhase });

    public static byte[] Key(string code, bool down, string[] modifiers) =>
        Serialize(new { type = "key", code, down, modifiers });

    public static byte[] TextInput(string text) =>
        Serialize(new { type = "text_input", text });

    public static byte[] ClipboardSet(string text) =>
        Serialize(new { type = "clipboard_set", text });

    public static byte[] ClipboardSetImage(string base64Png) =>
        Serialize(new { type = "clipboard_set_image", data = base64Png });

    public static byte[] SetReverseClipboardSync(bool enabled) =>
        Serialize(new { type = "set_reverse_clipboard_sync", enabled });

    public static byte[] FileStart(string id, string name, long size) =>
        Serialize(new { type = "file_start", id, name, size });

    public static byte[] FileEnd(string id) =>
        Serialize(new { type = "file_end", id });

    public static byte[] ListDir(string path) =>
        Serialize(new { type = "list_dir", path });

    public static byte[] RequestFile(string path) =>
        Serialize(new { type = "request_file", path });

    public static byte[] Fps(int fps, bool auto) =>
        Serialize(new { type = "fps", fps, auto });

    public static byte[] Bitrate(int bitrate, bool auto) =>
        Serialize(new { type = "bitrate", bitrate, auto });

    public static byte[] Resolution(ResolutionTier tier, int? width = null, int? height = null, double? scale = null) =>
        Serialize(new { type = "resolution", tier = ProtocolHelpers.ToWireString(tier), width, height, scale });

    public static byte[] Chroma(ChromaMode mode) =>
        Serialize(new { type = "chroma", mode = ProtocolHelpers.ToWireString(mode) });

    public static byte[] Hdr(bool enabled) =>
        Serialize(new { type = "hdr", enabled });

    public static byte[] LowLatency(bool enabled) =>
        Serialize(new { type = "low_latency", enabled });

    public static byte[] SetCodec(VideoCodecType codec) =>
        Serialize(new { type = "set_codec", codec = ProtocolHelpers.ToWireString(codec) });

    public static byte[] CodecCaps(string[] codecs) =>
        Serialize(new { type = "codec_caps", codecs });

    public static byte[] SetAudio(bool enabled) =>
        Serialize(new { type = "set_audio", enabled });

    public static byte[] SetMuted(bool muted) =>
        Serialize(new { type = "set_muted", muted });

    public static byte[] SetPrivacyScreen(bool enabled) =>
        Serialize(new { type = "set_privacy_screen", enabled });

    public static byte[] SetInputLock(bool locked) =>
        Serialize(new { type = "set_input_lock", locked });

    public static byte[] SetInputEnabled(bool enabled) =>
        Serialize(new { type = "set_input_enabled", enabled });

    public static byte[] SetDisplay(uint id) =>
        Serialize(new { type = "display", id });

    public static byte[] Ping() =>
        Serialize(new { type = "ping" });

    public static byte[] RequestKeyframe() =>
        Serialize(new { type = "request_keyframe" });

    public static byte[] ClientStatsMsg(double fps, int rttMs, string rx = "") =>
        Serialize(new { type = "client_stats", fps, rtt_ms = rttMs, rx });

    public static byte[] NetHint(bool lan) =>
        Serialize(new { type = "net_hint", lan });

    public static byte[] CtrlAltDel() =>
        Serialize(new { type = "ctrl_alt_del" });

    public static byte[] LockScreen() =>
        Serialize(new { type = "lock_screen" });

    public static byte[] Logout() =>
        Serialize(new { type = "logout" });

    public static byte[] Restart() =>
        Serialize(new { type = "restart" });

    public static byte[] PowerAction(string action) =>
        Serialize(new { type = "power_action", action });
}

/// <summary>
/// Parsed server -> client JSON messages.
/// </summary>
public abstract record ServerMessage
{
    public sealed record Hello(
        string Version,
        string Os,
        string? Pubkey,
        string ComputerName,
        string ModelId,
        bool? InputLocked
    ) : ServerMessage;

    public sealed record CryptoOk : ServerMessage;
    public sealed record AuthOk(string? Token, string? Username) : ServerMessage;
    public sealed record StreamStarted(StreamInfo Info) : ServerMessage;
    public sealed record CodecChanged(VideoCodecType Codec) : ServerMessage;
    public sealed record QualityActive(int Fps, int Bitrate) : ServerMessage;
    public sealed record ChromaActive(ChromaMode Mode) : ServerMessage;
    public sealed record HdrActive(bool Enabled) : ServerMessage;
    public sealed record ForceCanvas(bool Enabled) : ServerMessage;
    public sealed record UdpOffer(int Port, string SessionTokenHex, bool Encrypted = false) : ServerMessage;
    public sealed record UdpActive(bool Enabled) : ServerMessage;
    public sealed record InputLockChanged(bool Locked) : ServerMessage;
    public sealed record CursorShape(CursorShapeInfo Cursor) : ServerMessage;
    public sealed record Pong(int EncodeMs) : ServerMessage;
    public sealed record ServerStatsMsg(ServerStats Stats) : ServerMessage;
    public sealed record FileStart(string Id, string Name, long Size) : ServerMessage;
    public sealed record FileEnd(string Id) : ServerMessage;
    public sealed record DirListing(string Path, DirEntry[] Entries) : ServerMessage;
    public sealed record ClipboardFromTarget(ClipboardData Data) : ServerMessage;
    public sealed record Keepalive : ServerMessage;
    public sealed record HostDisconnected : ServerMessage;
    public sealed record ErrorMsg(string Code, string Message) : ServerMessage;
    public sealed record Unknown(string Type) : ServerMessage;

    public static ServerMessage Parse(JsonElement root)
    {
        if (root.ValueKind != JsonValueKind.Object)
            return new Unknown("");

        var type = root.ReadString("type");
        return type switch
        {
            "hello" => new Hello(
                Version: root.ReadString("version"),
                Os: root.ReadString("os"),
                Pubkey: root.ReadNullableString("pubkey"),
                ComputerName: root.ReadString("computerName"),
                ModelId: root.ReadString("modelId"),
                InputLocked: root.ReadNullableBool("inputLocked")),

            "crypto_ok" => new CryptoOk(),

            "auth_ok" or "connected" => new AuthOk(
                Token: root.ReadNullableString("token"),
                Username: root.ReadNullableString("username")),

            "stream_started" => ParseStreamStarted(root),

            "codec_changed" => new CodecChanged(
                ProtocolHelpers.ParseCodec(root.ReadNullableString("codec"))),

            "quality_active" => new QualityActive(
                Fps: root.ReadInt("fps"),
                Bitrate: root.ReadInt("bitrate")),

            "chroma_active" => new ChromaActive(
                ProtocolHelpers.ParseChroma(root.ReadNullableString("mode"))),

            "hdr_active" => new HdrActive(root.ReadBool("enabled")),

            "force_canvas" => new ForceCanvas(root.ReadBool("enabled")),

            "udp_offer" => new UdpOffer(
                Port: root.ReadInt("port"),
                SessionTokenHex: root.ReadString("session_token"),
                Encrypted: root.ReadBool("encrypted", defaultValue: false)),

            "udp_active" => new UdpActive(root.ReadBool("enabled")),

            "input_lock_changed" => new InputLockChanged(root.ReadBool("locked")),

            "cursor_shape" => ParseCursorShape(root),

            "pong" => new Pong(root.ReadInt("encode_ms")),

            "stats" => new ServerStatsMsg(new ServerStats(
                Fps: root.ReadInt("fps"),
                UploadSpeed: root.ReadString("uploadSpeed"),
                Quality: root.ReadInt("quality"))),

            "file_start" => new FileStart(
                Id: root.ReadString("id"),
                Name: root.ReadString("name"),
                Size: root.ReadLong("size")),

            "file_end" => new FileEnd(root.ReadString("id")),

            "dir_listing" => ParseDirListing(root),

            "clipboard_from_target" => ParseClipboardFromTarget(root),

            "keepalive" => new Keepalive(),

            "host_disconnected" => new HostDisconnected(),

            "error" => new ErrorMsg(
                Code: root.ReadString("code"),
                Message: root.ReadNullableString("message") ?? root.ReadString("code")),

            _ => new Unknown(type),
        };
    }

    private static StreamStarted ParseStreamStarted(JsonElement root)
    {
        int width = root.ReadInt("width");
        int height = root.ReadInt("height");
        var codec = ProtocolHelpers.ParseCodec(root.ReadNullableString("codec"));
        int fps = root.ReadInt("fps", 60);
        uint activeDisplay = root.ReadUInt("display");

        DisplayInfo[] displays = Array.Empty<DisplayInfo>();
        if (root.TryGetProperty("displays", out var arr) && arr.ValueKind == JsonValueKind.Array)
        {
            var list = new List<DisplayInfo>();
            foreach (var item in arr.EnumerateArray())
            {
                if (item.ValueKind != JsonValueKind.Object) continue;
                list.Add(new DisplayInfo(
                    Id: item.ReadUInt("id"),
                    Name: item.ReadString("name"),
                    Width: item.ReadInt("width"),
                    Height: item.ReadInt("height")));
            }
            displays = list.ToArray();
        }

        return new StreamStarted(new StreamInfo(width, height, codec, fps, displays, activeDisplay));
    }

    private static CursorShape ParseCursorShape(JsonElement root)
    {
        var pngBase64 = root.ReadString("png");
        byte[] pngBytes = Array.Empty<byte>();
        if (!string.IsNullOrEmpty(pngBase64))
        {
            try { pngBytes = Convert.FromBase64String(pngBase64); }
            catch { /* ignore malformed base64 */ }
        }
        return new CursorShape(new CursorShapeInfo(
            PngBytes: pngBytes,
            PngBase64: pngBase64,
            HotX: root.ReadInt("hot_x"),
            HotY: root.ReadInt("hot_y"),
            Width: root.ReadInt("width"),
            Height: root.ReadInt("height"),
            IsVisible: root.ReadBool("visible", defaultValue: true)));
    }

    private static DirListing ParseDirListing(JsonElement root)
    {
        var path = root.ReadString("path");
        var list = new List<DirEntry>();
        if (root.TryGetProperty("entries", out var arr) && arr.ValueKind == JsonValueKind.Array)
        {
            foreach (var item in arr.EnumerateArray())
            {
                if (item.ValueKind != JsonValueKind.Object) continue;
                list.Add(new DirEntry(
                    Name: item.ReadString("name"),
                    Size: item.ReadLong("size"),
                    IsDir: item.ReadBool("isDir"),
                    ModifiedMs: item.ReadLong("modified")));
            }
        }
        return new DirListing(path, list.ToArray());
    }

    private static ClipboardFromTarget ParseClipboardFromTarget(JsonElement root)
    {
        var text = root.ReadNullableString("text");
        var imageBase64 = root.ReadNullableString("image");
        byte[]? imageBytes = null;
        if (!string.IsNullOrEmpty(imageBase64))
        {
            try { imageBytes = Convert.FromBase64String(imageBase64); }
            catch { /* ignore malformed base64 */ }
        }
        return new ClipboardFromTarget(new ClipboardData(text, imageBytes, imageBase64));
    }
}

internal static class JsonElementExtensions
{
    public static string ReadString(this JsonElement e, string key) =>
        e.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String
            ? v.GetString() ?? ""
            : "";

    public static string? ReadNullableString(this JsonElement e, string key) =>
        e.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String
            ? v.GetString()
            : null;

    public static bool ReadBool(this JsonElement e, string key, bool defaultValue = false)
    {
        if (!e.TryGetProperty(key, out var v)) return defaultValue;
        return v.ValueKind switch
        {
            JsonValueKind.True => true,
            JsonValueKind.False => false,
            _ => defaultValue,
        };
    }

    public static bool? ReadNullableBool(this JsonElement e, string key)
    {
        if (!e.TryGetProperty(key, out var v)) return null;
        return v.ValueKind switch
        {
            JsonValueKind.True => true,
            JsonValueKind.False => false,
            _ => null,
        };
    }

    public static int ReadInt(this JsonElement e, string key, int defaultValue = 0)
    {
        if (!e.TryGetProperty(key, out var v) || v.ValueKind != JsonValueKind.Number)
            return defaultValue;
        if (v.TryGetInt32(out int i)) return i;
        if (v.TryGetDouble(out double d)) return (int)Math.Round(d);
        return defaultValue;
    }

    public static uint ReadUInt(this JsonElement e, string key, uint defaultValue = 0)
    {
        if (!e.TryGetProperty(key, out var v) || v.ValueKind != JsonValueKind.Number)
            return defaultValue;
        if (v.TryGetUInt32(out uint u)) return u;
        if (v.TryGetInt64(out long l) && l >= 0) return (uint)l;
        if (v.TryGetDouble(out double d) && d >= 0) return (uint)Math.Round(d);
        return defaultValue;
    }

    public static long ReadLong(this JsonElement e, string key, long defaultValue = 0)
    {
        if (!e.TryGetProperty(key, out var v) || v.ValueKind != JsonValueKind.Number)
            return defaultValue;
        if (v.TryGetInt64(out long l)) return l;
        if (v.TryGetDouble(out double d)) return (long)Math.Round(d);
        return defaultValue;
    }
}
