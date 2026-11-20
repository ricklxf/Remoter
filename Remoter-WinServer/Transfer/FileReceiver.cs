namespace RemoterWin;

// Receives chunked file uploads (client → host), writes to Downloads folder.
sealed class FileReceiver
{
    private record Transfer(string Name, long Size, FileStream Stream);
    private readonly Dictionary<string, Transfer> _transfers = new();
    private readonly string _destDir =
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) + @"\Downloads";

    public void Start(string id, string name, long size)
    {
        try
        {
            Directory.CreateDirectory(_destDir);
            var path = Path.Combine(_destDir, SanitizeName(name));
            var fs   = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.None);
            _transfers[id] = new Transfer(name, size, fs);
            AppLog.Write($"[FileReceiver] Receiving {name} ({size} bytes) → {path}");
        }
        catch (Exception ex) { AppLog.Write($"[FileReceiver] Start error: {ex.Message}"); }
    }

    public void Receive(string id, long offset, byte[] chunk)
    {
        if (!_transfers.TryGetValue(id, out var t)) return;
        t.Stream.Seek(offset, SeekOrigin.Begin);
        t.Stream.Write(chunk);
    }

    public void Finish(string id)
    {
        if (!_transfers.TryGetValue(id, out var t)) return;
        _transfers.Remove(id);
        t.Stream.Flush();
        t.Stream.Dispose();
        AppLog.Write($"[FileReceiver] Completed {t.Name}");
    }

    private static string SanitizeName(string name)
    {
        foreach (var c in Path.GetInvalidFileNameChars())
            name = name.Replace(c, '_');
        return name;
    }
}
