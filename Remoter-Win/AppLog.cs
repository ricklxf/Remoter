namespace RemoterWin;

// Thread-safe rolling file logger.
// Subscribers (e.g. AdminServer SSE) attach via OnLog.
static class AppLog
{
    public static event Action<string>? OnLog;

    private static readonly string _path = Path.Combine(
        AppContext.BaseDirectory, "remoter.log");
    private static readonly object _lock = new();
    private const long MaxBytes = 10 * 1024 * 1024; // 10 MB

    public static void Write(string msg)
    {
        var line = $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] {msg}";
        lock (_lock)
        {
            try
            {
                var fi = new FileInfo(_path);
                if (fi.Exists && fi.Length > MaxBytes)
                    File.Move(_path, _path + ".bak", overwrite: true);
                File.AppendAllText(_path, line + "\n");
            }
            catch { /* log write failure must never crash the server */ }
        }
        try { OnLog?.Invoke(line); } catch { }
    }
}
