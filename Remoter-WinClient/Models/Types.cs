using System;
using System.Text.Json.Serialization;

namespace RemoterWinClient;

public enum ConnectMode
{
    Direct,
    Relay,
}

public enum AuthMethod
{
    Pin,
    Credentials,
    Token,
}

public enum ConnectionState
{
    Idle,
    Connecting,
    Authenticating,
    Streaming,
    Reconnecting,
    Disconnected,
    Error,
}

public enum ScaleMode
{
    Fit,
    Stretch,
    Original,
}

public enum ResolutionTier
{
    Match,
    Native,
    Res1080,
    Res2K,
}

public enum VideoCodecType
{
    H264,
    H265,
    Jpeg,
}

public enum ChromaMode
{
    Yuv420,
    Yuv444,
}

public enum QualityPreset
{
    Auto,
    Smooth,
    Hd,
    Original,
}

public enum SharpnessLevel
{
    Off,
    Low,
    Medium,
    High,
}

public enum FileTransferDirection
{
    Upload,
    Download,
}

public sealed record DisplayInfo(
    uint Id,
    string Name,
    int Width,
    int Height
);

public sealed record StreamInfo(
    int Width,
    int Height,
    VideoCodecType Codec,
    int Fps,
    DisplayInfo[] Displays,
    uint ActiveDisplayId
);

public sealed class ConnectParams
{
    public ConnectMode Mode { get; set; } = ConnectMode.Direct;
    public string Host { get; set; } = "";
    public int Port { get; set; } = 7788;
    public bool UseTls { get; set; } = true;
    public string? DirectUrl { get; set; }
    public string? RelayUrl { get; set; }
    public string? SessionId { get; set; }
    public string Pin { get; set; } = "";
    public string? Label { get; set; }
    public AuthMethod AuthMethod { get; set; } = AuthMethod.Pin;
    public string? Username { get; set; }
    public string? Password { get; set; }
    public string? Token { get; set; }
    public bool RememberDevice { get; set; } = true;

    public Uri BuildWebSocketUri()
    {
        if (Mode == ConnectMode.Direct)
        {
            if (!string.IsNullOrWhiteSpace(DirectUrl))
            {
                var raw = DirectUrl.Trim();
                if (!raw.StartsWith("ws://", StringComparison.OrdinalIgnoreCase) &&
                    !raw.StartsWith("wss://", StringComparison.OrdinalIgnoreCase))
                {
                    var scheme = UseTls ? "wss" : "ws";
                    raw = $"{scheme}://{raw}";
                }
                return new Uri(raw);
            }

            var host = Host.Trim();
            if (host.StartsWith("ws://", StringComparison.OrdinalIgnoreCase) ||
                host.StartsWith("wss://", StringComparison.OrdinalIgnoreCase))
            {
                return new Uri(host);
            }

            var proto = UseTls ? "wss" : "ws";
            // Bracket bare IPv6 addresses
            if (host.Contains(':') && !host.StartsWith('['))
            {
                host = $"[{host}]";
            }
            return new Uri($"{proto}://{host}:{Port}");
        }
        else
        {
            var baseUrl = (RelayUrl ?? "").Trim().TrimEnd('/');
            var sid = Uri.EscapeDataString(SessionId ?? "");
            var pin = Uri.EscapeDataString(Pin ?? "");
            return new Uri($"{baseUrl}?role=client&session={sid}&pin={pin}");
        }
    }
}

public sealed class SavedDevice
{
    public string Id { get; set; } = Guid.NewGuid().ToString("N");
    public string Name { get; set; } = "";
    public string Host { get; set; } = "";
    public int Port { get; set; } = 7788;
    public bool UseTls { get; set; } = true;

    [JsonConverter(typeof(JsonStringEnumConverter))]
    public AuthMethod AuthMethod { get; set; } = AuthMethod.Pin;

    public string? Pin { get; set; }
    public string? Username { get; set; }
    public string? Token { get; set; }
    public string? ComputerName { get; set; }
    public string? ModelId { get; set; }
    public string? ServerOs { get; set; }
    public DateTime LastConnectedUtc { get; set; } = DateTime.UtcNow;

    [JsonIgnore]
    public string DisplayName =>
        !string.IsNullOrWhiteSpace(Name) ? Name :
        !string.IsNullOrWhiteSpace(ComputerName) ? ComputerName :
        $"{Host}:{Port}";
}

public sealed class ImeOffset
{
    /// <summary>Left-edge horizontal offset in logical px from viewport horizontal center (matches Web calc(50% + x)).</summary>
    public int X { get; set; } = -120;

    /// <summary>Vertical clearance in logical px from viewport bottom (min 80).</summary>
    public int Y { get; set; } = 120;
}

public sealed class ClientSettings
{
    [JsonConverter(typeof(JsonStringEnumConverter))]
    public ScaleMode ScaleMode { get; set; } = ScaleMode.Fit;

    [JsonConverter(typeof(JsonStringEnumConverter))]
    public ResolutionTier ResolutionTier { get; set; } = ResolutionTier.Native;

    [JsonConverter(typeof(JsonStringEnumConverter))]
    public VideoCodecType PreferredCodec { get; set; } = VideoCodecType.H264;

    [JsonConverter(typeof(JsonStringEnumConverter))]
    public QualityPreset QualityPreset { get; set; } = QualityPreset.Auto;

    [JsonConverter(typeof(JsonStringEnumConverter))]
    public SharpnessLevel Sharpness { get; set; } = SharpnessLevel.Low;

    [JsonConverter(typeof(JsonStringEnumConverter))]
    public ChromaMode ChromaMode { get; set; } = ChromaMode.Yuv420;

    public bool HdrEnabled { get; set; } = false;
    public bool ToneMapEnabled { get; set; } = false;
    public bool LowLatencyEnabled { get; set; } = false;

    public int Fps { get; set; } = 60;
    public bool AutoFps { get; set; } = true;
    public int BitrateBps { get; set; } = 8_000_000;
    public bool AutoBitrate { get; set; } = true;
    public bool AudioEnabled { get; set; } = true;
    public bool ClipboardSyncEnabled { get; set; } = true;
    public bool VSyncEnabled { get; set; } = false;
    // Default false: avoids Windows GPU driver DXVA H.264 macroblock garbling on fast scroll
    // while keeping ~1ms CPU MediaFoundation decode + full D3D11 GPU NV12 shader rendering.
    public bool HardwareDecode { get; set; } = false;
    public Dictionary<string, ImeOffset> ImeOffsets { get; set; } = new();
    public string? DownloadDirectory { get; set; }
}

public readonly record struct ClientStats(
    double Fps,
    int RttMs,
    int BitrateKbps,
    int EncodeMs,
    int DecodeMs,
    string Transport,
    VideoCodecType Codec
);

public readonly record struct ServerStats(
    int Fps,
    string UploadSpeed,
    int Quality
);

public readonly record struct VideoFramePacket(
    byte[] Data,
    uint FrameId,
    uint PtsMs,
    bool IsKeyframe,
    VideoCodecType Codec
);

public readonly record struct AudioFramePacket(
    byte[] Data
);

public sealed record CursorShapeInfo(
    byte[] PngBytes,
    string PngBase64,
    int HotX,
    int HotY,
    int Width,
    int Height,
    bool IsVisible = true
);

public sealed record ClipboardData(
    string? Text,
    byte[]? ImagePngBytes,
    string? ImageBase64
);

public sealed record DirEntry(
    string Name,
    long Size,
    bool IsDir,
    long ModifiedMs
);

public sealed record DirTreeFile(
    string RelPath,
    string Path,
    long Size
);

public sealed record RemoteClipboardFile(
    string Name,
    string Path,
    long Size,
    bool IsDir
);

public sealed record FileTransferProgress(
    string Id,
    string Name,
    long Size,
    long Transferred,
    FileTransferDirection Direction,
    double SpeedBps,
    bool Done,
    string? SavedPath = null,
    string? Error = null,
    bool Resumed = false
);
