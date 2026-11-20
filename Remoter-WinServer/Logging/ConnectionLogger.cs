namespace RemoterWin;

// Persistent connection log — mirrors Mac agent ConnectionLogger.
// Written to: %LOCALAPPDATA%\Remoter\logs\connections.log
sealed class ConnectionLogger
{
    public static readonly ConnectionLogger Shared = new();

    private readonly string _path;
    private readonly object _lock = new();

    private ConnectionLogger()
    {
        var dir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Remoter", "logs");
        try { Directory.CreateDirectory(dir); } catch { }
        _path = Path.Combine(dir, "connections.log");
    }

    public void LogAgentStarted(int port, string? relayUrl = null)
    {
        var extras = new List<string> { $"port={port}" };
        if (relayUrl != null) extras.Add($"relay={relayUrl}");
        Write("agent_started", extras);
    }

    public void LogClientConnected(string sessionId, string remote) =>
        Write("client_connected", [$"session={S(sessionId)}", $"remote={remote}"]);

    public void LogAuthSuccess(string sessionId) =>
        Write("auth_success", [$"session={S(sessionId)}"]);

    public void LogAuthFailed(string sessionId) =>
        Write("auth_failed", [$"session={S(sessionId)}"]);

    public void LogCaptureError(string sessionId, string error) =>
        Write("capture_error", [$"session={S(sessionId)}", $"error={error}"]);

    public void LogConnected(string sessionId, string codec, bool encrypted) =>
        Write("stream_started", [$"session={S(sessionId)}", $"codec={codec}", $"encrypted={encrypted}"]);

    public void LogDisconnected(string sessionId, int durationSecs, double sentMb, double recvMb) =>
        Write("disconnected", [
            $"session={S(sessionId)}",
            $"duration_s={durationSecs}",
            $"sent_mb={sentMb:F2}",
            $"recv_mb={recvMb:F2}",
        ]);

    public void LogStep(string sessionId, string step, string? detail = null)
    {
        var extras = new List<string> { $"session={S(sessionId)}" };
        if (detail != null) extras.Add($"detail={detail}");
        Write($"step/{step}", extras);
    }

    private static string S(string id) => id.Length >= 8 ? id[..8] : id;

    private void Write(string tag, IEnumerable<string> extras)
    {
        var ts   = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss");
        var line = $"{ts}  {tag.PadRight(24)}  {string.Join("  ", extras)}";
        lock (_lock)
        {
            try { File.AppendAllText(_path, line + "\n"); } catch { }
        }
    }
}
