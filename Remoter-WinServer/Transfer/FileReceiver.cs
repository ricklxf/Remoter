namespace RemoterWin;

// Receives chunked file uploads (client → host), supporting folder relative paths,
// custom destination directories, clipboard staging, and resumable .remoter.part transfers.
sealed class FileReceiver
{
    private record Transfer(string Name, long Size, string PartPath, string FinalPath, FileStream Stream);
    private readonly object _lock = new();
    private readonly Dictionary<string, Transfer> _transfers = new();
    private readonly string _defaultDownloadsDir =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads");

    public (long Offset, bool Resumed) Start(
        string id,
        string name,
        long size,
        string? relPath = null,
        string? destDir = null,
        bool resume = false,
        string? purpose = null)
    {
        try
        {
            string baseDir;
            if (string.Equals(purpose, "clipboard", StringComparison.OrdinalIgnoreCase))
            {
                baseDir = Path.Combine(_defaultDownloadsDir, "Remoter-Clipboard");
            }
            else if (!string.IsNullOrWhiteSpace(destDir) && Directory.Exists(destDir))
            {
                baseDir = destDir;
            }
            else
            {
                baseDir = _defaultDownloadsDir;
            }

            Directory.CreateDirectory(baseDir);

            string finalPath = ResolveFinalPath(baseDir, name, relPath);
            string? parentDir = Path.GetDirectoryName(finalPath);
            if (!string.IsNullOrEmpty(parentDir))
            {
                Directory.CreateDirectory(parentDir);
            }

            string partPath = finalPath + ".remoter.part";

            lock (_lock)
            {
                if (_transfers.Remove(id, out var existing))
                {
                    try { existing.Stream.Dispose(); } catch { }
                }

                long startOffset = 0;
                bool resumed = false;
                FileStream fs;

                if (resume && File.Exists(partPath))
                {
                    var fi = new FileInfo(partPath);
                    if (fi.Length > 0 && fi.Length < size)
                    {
                        fs = new FileStream(partPath, FileMode.Open, FileAccess.Write, FileShare.None);
                        fs.Seek(fi.Length, SeekOrigin.Begin);
                        startOffset = fi.Length;
                        resumed = true;
                    }
                    else
                    {
                        fs = new FileStream(partPath, FileMode.Create, FileAccess.Write, FileShare.None);
                    }
                }
                else
                {
                    fs = new FileStream(partPath, FileMode.Create, FileAccess.Write, FileShare.None);
                }

                _transfers[id] = new Transfer(name, size, partPath, finalPath, fs);
                AppLog.Write($"[FileReceiver] Receiving {name} ({size} bytes, offset={startOffset}, resumed={resumed}) → {finalPath}");
                return (startOffset, resumed);
            }
        }
        catch (Exception ex)
        {
            AppLog.Write($"[FileReceiver] Start error: {ex.Message}");
            return (0L, false);
        }
    }

    public void Receive(string id, long offset, byte[] chunk)
    {
        lock (_lock)
        {
            if (!_transfers.TryGetValue(id, out var t)) return;
            t.Stream.Seek(offset, SeekOrigin.Begin);
            t.Stream.Write(chunk);
        }
    }

    public string? Finish(string id)
    {
        Transfer? t;
        lock (_lock)
        {
            if (!_transfers.Remove(id, out t)) return null;
        }

        try
        {
            t.Stream.Flush();
            t.Stream.Dispose();
            File.Move(t.PartPath, t.FinalPath, overwrite: true);
            AppLog.Write($"[FileReceiver] Completed {t.Name} → {t.FinalPath}");
            return t.FinalPath;
        }
        catch (Exception ex)
        {
            AppLog.Write($"[FileReceiver] Finish error ({t.Name}): {ex.Message}");
            return null;
        }
    }

    private static string ResolveFinalPath(string baseDir, string name, string? relPath)
    {
        string fullBase = Path.GetFullPath(baseDir);
        if (!fullBase.EndsWith(Path.DirectorySeparatorChar))
        {
            fullBase += Path.DirectorySeparatorChar;
        }

        if (!string.IsNullOrWhiteSpace(relPath))
        {
            var rawSegments = relPath.Split(['/', '\\'], StringSplitOptions.RemoveEmptyEntries);
            var safeSegments = new List<string>(rawSegments.Length);
            foreach (var rawSeg in rawSegments)
            {
                var trimmed = rawSeg.Trim();
                if (string.IsNullOrEmpty(trimmed) || trimmed == "." || trimmed == "..") continue;
                if (trimmed.Contains(':')) continue; // Reject rooted drive letters like "C:"
                var clean = SanitizeName(trimmed);
                if (!string.IsNullOrEmpty(clean) && clean != "." && clean != "..")
                {
                    safeSegments.Add(clean);
                }
            }

            if (safeSegments.Count > 0)
            {
                var parts = new string[safeSegments.Count + 1];
                parts[0] = baseDir;
                for (int i = 0; i < safeSegments.Count; i++)
                {
                    parts[i + 1] = safeSegments[i];
                }
                var candidate = Path.GetFullPath(Path.Combine(parts));
                if (candidate.StartsWith(fullBase, StringComparison.OrdinalIgnoreCase))
                {
                    return candidate;
                }
            }
        }

        var safeName = SanitizeName(string.IsNullOrWhiteSpace(name) ? "file" : name);
        return Path.Combine(baseDir, safeName);
    }

    private static string SanitizeName(string name)
    {
        foreach (var c in Path.GetInvalidFileNameChars())
            name = name.Replace(c, '_');
        return name;
    }
}
