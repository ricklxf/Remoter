using System.Threading.Channels;

namespace RemoterWin;

// Thread-safe rolling file logger.
// Subscribers (e.g. AdminServer SSE) attach via OnLog.
// 磁盘写入放到后台线程做，避免高频调用方（截屏/输入循环）阻塞在文件 I/O 上。
static class AppLog
{
    public static event Action<string>? OnLog;

    private static readonly string _path = Path.Combine(
        AppContext.BaseDirectory, "remoter.log");
    private const long MaxBytes = 10 * 1024 * 1024; // 10 MB

    private static readonly Channel<string> _queue = Channel.CreateUnbounded<string>();

    static AppLog()
    {
        _ = Task.Run(WriterLoopAsync);
    }

    public static void Write(string msg)
    {
        var line = $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] {msg}";
        _queue.Writer.TryWrite(line);
        try { OnLog?.Invoke(line); } catch { }
    }

    private static async Task WriterLoopAsync()
    {
        await foreach (var line in _queue.Reader.ReadAllAsync())
        {
            try
            {
                var fi = new FileInfo(_path);
                if (fi.Exists && fi.Length > MaxBytes)
                    File.Move(_path, _path + ".bak", overwrite: true);
                await File.AppendAllTextAsync(_path, line + "\n");
            }
            catch { /* log write failure must never crash the server */ }
        }
    }
}
