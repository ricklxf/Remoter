using System.Threading.Channels;

namespace RemoterWin;

// Thread-safe rolling file logger.
// 磁盘写入放到后台线程做，避免高频调用方（截屏/输入循环）阻塞在文件 I/O 上。
// 统一输出到 %LOCALAPPDATA%\Remoter\logs\remoter.log（与 ConnectionLogger 同目录）。
static class AppLog
{
    public static readonly string LogDir = ResolveLogDir();
    public static readonly string LogPath = Path.Combine(LogDir, "remoter.log");
    private const long MaxBytes = 10 * 1024 * 1024; // 10 MB

    private static readonly Channel<string> _queue = Channel.CreateUnbounded<string>();

    static AppLog()
    {
        try { Directory.CreateDirectory(LogDir); } catch { }
        _ = Task.Run(WriterLoopAsync);
    }

    private static string ResolveLogDir()
    {
        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        return string.IsNullOrWhiteSpace(localAppData)
            ? Path.Combine(AppContext.BaseDirectory, "logs")
            : Path.Combine(localAppData, "Remoter", "logs");
    }

    public static void Write(string msg)
    {
        var line = $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] {msg}";
        _queue.Writer.TryWrite(line);
    }

    private static async Task WriterLoopAsync()
    {
        await foreach (var line in _queue.Reader.ReadAllAsync())
        {
            try
            {
                Directory.CreateDirectory(LogDir);
                var fi = new FileInfo(LogPath);
                if (fi.Exists && fi.Length > MaxBytes)
                    File.Move(LogPath, LogPath + ".bak", overwrite: true);
                await File.AppendAllTextAsync(LogPath, line + "\n");
            }
            catch { /* log write failure must never crash the server */ }
        }
    }
}
