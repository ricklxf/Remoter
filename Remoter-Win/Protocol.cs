using System.Text.Json;

namespace RemoterWin;

// Mirrors the Mac agent's ClientMessage enum.
// Discriminated union via C# record hierarchy.
public abstract record ClientMsg
{
    public record Auth(string Pin) : ClientMsg;
    public record MouseMove(double X, double Y) : ClientMsg;
    public record MouseButton(string Button, bool Down, double X, double Y) : ClientMsg;
    public record MouseScroll(int Dx, int Dy) : ClientMsg;
    public record KeyEvent(string Code, bool Down, string[] Mods) : ClientMsg;
    public record ClipboardSet(string Text) : ClientMsg;
    public record FileStart(string Id, string Name, long Size) : ClientMsg;
    public record FileEnd(string Id) : ClientMsg;
    public record QualitySet(int Fps, int Bitrate) : ClientMsg;   // legacy clients (≤ v1.0.204)
    public record FpsSet(int Fps, bool Auto) : ClientMsg;
    public record BitrateSet(int Bitrate, bool Auto) : ClientMsg;
    public record ResolutionSet(string Tier) : ClientMsg;
    public record Ping : ClientMsg;
    public record RequestKeyframe : ClientMsg;
    public record WebRtcOffer(string Sdp) : ClientMsg;
    public record WebRtcIce(string Candidate) : ClientMsg;
    public record ClientStats(double Fps, int RttMs) : ClientMsg;
    public record SetCodec(string Codec) : ClientMsg;
    public record CryptoHello(string Pubkey) : ClientMsg;
    public record ListDir(string Path) : ClientMsg;
    public record RequestFile(string Path) : ClientMsg;
    public record SetMuted(bool Muted) : ClientMsg;
    public record CtrlAltDel : ClientMsg;
    public record SetInputEnabled(bool Enabled) : ClientMsg;
    public record ClipboardSetImage(string Data) : ClientMsg;
    public record LockScreen : ClientMsg;
    public record Logout : ClientMsg;
    public record Restart : ClientMsg;
    public record AuthCredentials(string Username, string Password) : ClientMsg;
    public record AuthToken(string Token) : ClientMsg;
    public record MouseDoubleClick(string Button, double X, double Y) : ClientMsg;
    public record Unknown : ClientMsg;

    public static ClientMsg Parse(JsonElement e)
    {
        var type = e.Str("type");
        return type switch
        {
            "auth"              => new Auth(e.Str("pin")),
            "mouse_move"        => new MouseMove(e.Dbl("x"), e.Dbl("y")),
            "mouse_button"      => new MouseButton(e.Str("button"), e.Bool("down"), e.Dbl("x"), e.Dbl("y")),
            "mouse_scroll"      => new MouseScroll(e.Int("dx"), e.Int("dy")),
            "key"               => new KeyEvent(e.Str("code"), e.Bool("down"), e.StrArr("modifiers")),
            "clipboard_set"     => new ClipboardSet(e.Str("text")),
            "file_start"        => new FileStart(e.Str("id"), e.Str("name"), e.Long("size")),
            "file_end"          => new FileEnd(e.Str("id")),
            "quality"           => new QualitySet(e.Int("fps"), e.Int("bitrate")),
            "fps"               => new FpsSet(e.Int("fps"), e.Bool("auto")),
            "bitrate"           => new BitrateSet(e.Int("bitrate"), e.Bool("auto")),
            "resolution"        => new ResolutionSet(e.Str("tier")),
            "ping"              => new Ping(),
            "request_keyframe"  => new RequestKeyframe(),
            "webrtc_offer"      => new WebRtcOffer(e.Str("sdp")),
            "webrtc_ice"        => new WebRtcIce(e.Str("candidate")),
            "client_stats"      => new ClientStats(e.Dbl("fps"), e.Int("rtt_ms")),
            "set_codec"         => new SetCodec(e.Str("codec")),
            "crypto_hello"      => new CryptoHello(e.Str("pubkey")),
            "list_dir"          => new ListDir(e.Str("path")),
            "request_file"      => new RequestFile(e.Str("path")),
            "set_muted"         => new SetMuted(e.Bool("muted")),
            "ctrl_alt_del"      => new CtrlAltDel(),
            "set_input_enabled"       => new SetInputEnabled(e.Bool("enabled")),
            "clipboard_set_image"     => new ClipboardSetImage(e.Str("data")),
            "lock_screen"             => new LockScreen(),
            "logout"                  => new Logout(),
            "restart"                 => new Restart(),
            "auth_credentials"        => new AuthCredentials(e.Str("username"), e.Str("password")),
            "auth_token"              => new AuthToken(e.Str("token")),
            "mouse_double_click"      => new MouseDoubleClick(e.Str("button"), e.Dbl("x"), e.Dbl("y")),
            _                         => new Unknown(),
        };
    }
}

// Helpers to read optional JSON properties with defaults
static class JsonExt
{
    public static string  Str (this JsonElement e, string k) =>
        e.TryGetProperty(k, out var v) ? v.GetString() ?? "" : "";
    public static bool    Bool(this JsonElement e, string k) =>
        e.TryGetProperty(k, out var v) && v.GetBoolean();
    public static double  Dbl (this JsonElement e, string k) =>
        e.TryGetProperty(k, out var v) ? v.GetDouble() : 0;
    public static int     Int (this JsonElement e, string k) =>
        e.TryGetProperty(k, out var v) ? v.GetInt32() : 0;
    public static long    Long(this JsonElement e, string k) =>
        e.TryGetProperty(k, out var v) ? v.GetInt64() : 0;
    public static string[] StrArr(this JsonElement e, string k)
    {
        if (!e.TryGetProperty(k, out var v) || v.ValueKind != JsonValueKind.Array) return [];
        return [.. v.EnumerateArray().Select(x => x.GetString() ?? "")];
    }
}

// Binary frame header (same as Mac agent)
static class FrameType
{
    public const byte VideoFrame = 0x01;
    public const byte FileChunk  = 0x02;
    public const byte Encrypted  = 0xE0;
}

static class FrameBuilder
{
    public static byte[] VideoFramePacket(byte[] jpeg, uint frameId, uint ptsMs, bool keyframe)
    {
        var pkt = new byte[10 + jpeg.Length];
        pkt[0] = FrameType.VideoFrame;
        WriteUInt32BE(pkt, 1, frameId);
        WriteUInt32BE(pkt, 5, ptsMs);
        pkt[9] = keyframe ? (byte)1 : (byte)0;
        Buffer.BlockCopy(jpeg, 0, pkt, 10, jpeg.Length);
        return pkt;
    }

    private static void WriteUInt32BE(byte[] buf, int offset, uint value)
    {
        buf[offset]     = (byte)(value >> 24);
        buf[offset + 1] = (byte)(value >> 16);
        buf[offset + 2] = (byte)(value >> 8);
        buf[offset + 3] = (byte)(value);
    }
}
