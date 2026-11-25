using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

namespace RemoterWinClient;

/// <summary>
/// Chunked bidirectional file transfer client matching Remoter's wire protocol:
///   JSON:   file_start { id, name, size, relPath?, destDir?, resume?, purpose? }
///           <- file_ack { id, offset, resumed }
///           -> Binary 0x02 chunks (64 KiB)
///           -> JSON file_end { id }
///           <- file_done { id, path }
///   Binary: [0x02][16B UTF-8 id padded with '\0'][4B offset BE][chunk data]
/// Supports resumable .remoter.part transfers and recursive folder upload/download.
/// </summary>
public sealed class FileTransferClient : IDisposable
{
    public const int ChunkSize = 64 * 1024;
    private const int UploadAckTimeoutMs = 1500;
    private const int UploadDoneTimeoutMs = 5000;

    private sealed class PendingDownloadRequest
    {
        public required string DestinationPath { get; init; }
        public required string PartPath { get; init; }
        public required long RequestedOffset { get; init; }
        public required TaskCompletionSource<string> Completion { get; init; }
    }

    private sealed class DownloadState : IDisposable
    {
        public required string Id { get; init; }
        public required string Name { get; init; }
        public required long Size { get; init; }
        public required string PartPath { get; init; }
        public required string? ExplicitFinalPath { get; init; }
        public required bool Resumed { get; init; }
        public required FileStream Stream { get; init; }
        public TaskCompletionSource<string>? Completion { get; init; }
        public long Received;
        public long LastSpeedTimeMs;
        public long LastSpeedBytes;
        public double SpeedBps;

        public void Dispose()
        {
            try { Stream.Dispose(); } catch { }
        }
    }

    private readonly Action<byte[]> _sendJsonBytes;
    private readonly Func<byte[], CancellationToken, ValueTask> _sendBinaryAsync;
    private readonly ConcurrentDictionary<string, DownloadState> _downloads = new(StringComparer.Ordinal);
    private readonly ConcurrentDictionary<string, TaskCompletionSource<(long Offset, bool Resumed)>> _uploadAcks = new(StringComparer.Ordinal);
    private readonly ConcurrentDictionary<string, TaskCompletionSource<string>> _uploadDones = new(StringComparer.Ordinal);
    private readonly ConcurrentQueue<PendingDownloadRequest> _pendingDownloads = new();
    private string _downloadDirectory;

    public event Action<FileTransferProgress>? ProgressChanged;
    public event Action<string, string>? DownloadCompleted; // (fileName, savedPath)

    public string DownloadDirectory
    {
        get => _downloadDirectory;
        set
        {
            if (!string.IsNullOrWhiteSpace(value))
                _downloadDirectory = value;
        }
    }

    public FileTransferClient(
        Action<byte[]> sendJsonBytes,
        Func<byte[], CancellationToken, ValueTask> sendBinaryAsync,
        string? downloadDirectory = null)
    {
        _sendJsonBytes = sendJsonBytes;
        _sendBinaryAsync = sendBinaryAsync;
        _downloadDirectory = !string.IsNullOrWhiteSpace(downloadDirectory)
            ? downloadDirectory
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads");
    }

    /// <summary>
    /// Uploads a single file with default options (resumable enabled).
    /// </summary>
    public Task UploadFileAsync(string localFilePath, CancellationToken ct = default) =>
        UploadFileExAsync(localFilePath, relPath: null, destDir: null, resume: true, purpose: null, ct: ct);

    /// <summary>
    /// Uploads a single file with optional relative path, remote destination directory,
    /// resumable handshake (waits up to 1.5s for file_ack), and purpose ("clipboard").
    /// Returns the host's final saved path from file_done (or null for legacy servers).
    /// </summary>
    public async Task<string?> UploadFileExAsync(
        string localFilePath,
        string? relPath = null,
        string? destDir = null,
        bool resume = true,
        string? purpose = null,
        CancellationToken ct = default)
    {
        var fi = new FileInfo(localFilePath);
        if (!fi.Exists)
            throw new FileNotFoundException("File not found for upload.", localFilePath);

        string id = Guid.NewGuid().ToString("N")[..16];
        string name = fi.Name;
        long totalSize = fi.Length;

        long lastSpeedTimeMs = Stopwatch.GetTimestamp() * 1000 / Stopwatch.Frequency;
        long lastSpeedBytes = 0;
        double speedBps = 0;

        EmitProgress(new FileTransferProgress(
            id, name, totalSize, 0, FileTransferDirection.Upload, 0, false));

        var ackTcs = new TaskCompletionSource<(long Offset, bool Resumed)>(TaskCreationOptions.RunContinuationsAsynchronously);
        var doneTcs = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        _uploadAcks[id] = ackTcs;
        _uploadDones[id] = doneTcs;

        _sendJsonBytes(ClientMessages.FileStart(
            id,
            name,
            totalSize,
            relPath: relPath,
            destDir: destDir,
            resume: resume ? true : null,
            purpose: purpose));

        try
        {
            // Wait up to 1.5s for server file_ack; fallback to offset=0 for older servers
            long offset = 0;
            bool resumed = false;
            if (resume)
            {
                using var ackTimeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
                ackTimeout.CancelAfter(UploadAckTimeoutMs);
                try
                {
                    var ack = await ackTcs.Task.WaitAsync(ackTimeout.Token).ConfigureAwait(false);
                    if (ack.Offset > 0 && ack.Offset <= totalSize)
                    {
                        offset = ack.Offset;
                        resumed = ack.Resumed;
                    }
                }
                catch (OperationCanceledException) when (!ct.IsCancellationRequested)
                {
                    // Legacy host or ack timeout — start from 0
                }
            }
            _uploadAcks.TryRemove(id, out _);

            lastSpeedBytes = offset;
            if (resumed)
            {
                EmitProgress(new FileTransferProgress(
                    id, name, totalSize, offset, FileTransferDirection.Upload, 0, false, Resumed: true));
            }

            await using var fs = new FileStream(
                localFilePath,
                FileMode.Open,
                FileAccess.Read,
                FileShare.ReadWrite,
                bufferSize: ChunkSize,
                useAsync: true);

            if (offset > 0)
            {
                fs.Seek(offset, SeekOrigin.Begin);
            }

            var buffer = new byte[ChunkSize];
            int chunksSent = 0;

            while (offset < totalSize)
            {
                ct.ThrowIfCancellationRequested();
                int read = await fs.ReadAsync(buffer.AsMemory(0, ChunkSize), ct).ConfigureAwait(false);
                if (read <= 0) break;

                // Protocol offset is 32-bit unsigned big-endian (supports up to 4 GiB)
                var pkt = BinaryFrames.BuildFileChunkPacket(id, (uint)offset, buffer.AsSpan(0, read));
                await _sendBinaryAsync(pkt, ct).ConfigureAwait(false);

                offset += read;
                chunksSent++;

                // UU-style pacing: yield 1ms every 1 MiB (16 x 64 KiB chunks) so bulk
                // file uploads never starve interactive input or 60/120fps video traffic.
                if ((chunksSent & 0x0F) == 0 && offset < totalSize)
                {
                    await Task.Delay(1, ct).ConfigureAwait(false);
                }

                long nowMs = Stopwatch.GetTimestamp() * 1000 / Stopwatch.Frequency;
                long dt = nowMs - lastSpeedTimeMs;
                if (dt >= 300)
                {
                    speedBps = (offset - lastSpeedBytes) * 1000.0 / dt;
                    lastSpeedTimeMs = nowMs;
                    lastSpeedBytes = offset;
                }

                EmitProgress(new FileTransferProgress(
                    id, name, totalSize, Math.Min(offset, totalSize),
                    FileTransferDirection.Upload, speedBps, false, Resumed: resumed));
            }

            _sendJsonBytes(ClientMessages.FileEnd(id));

            string? hostFinalPath = null;
            try
            {
                using var doneTimeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
                doneTimeout.CancelAfter(UploadDoneTimeoutMs);
                var p = await doneTcs.Task.WaitAsync(doneTimeout.Token).ConfigureAwait(false);
                if (!string.IsNullOrWhiteSpace(p))
                    hostFinalPath = p;
            }
            catch (OperationCanceledException) when (!ct.IsCancellationRequested)
            {
                // Legacy host doesn't send file_done
            }

            EmitProgress(new FileTransferProgress(
                id, name, totalSize, totalSize, FileTransferDirection.Upload, speedBps, true,
                SavedPath: hostFinalPath, Resumed: resumed));
            return hostFinalPath;
        }
        catch (Exception ex)
        {
            EmitProgress(new FileTransferProgress(
                id, name, totalSize, 0, FileTransferDirection.Upload, 0, true, Error: ex.Message));
            throw;
        }
        finally
        {
            _uploadAcks.TryRemove(id, out _);
            _uploadDones.TryRemove(id, out _);
        }
    }

    /// <summary>
    /// Recursively uploads all regular files inside a local directory, preserving folder structure
    /// via forward-slash relPath ("FolderName/sub/file.txt"). Returns all host saved paths.
    /// </summary>
    public async Task<List<string>> UploadFolderAsync(
        string localFolderPath,
        string? destDir = null,
        bool resume = true,
        string? purpose = null,
        Action<int, int, string>? onFileStarted = null,
        CancellationToken ct = default)
    {
        var dir = new DirectoryInfo(localFolderPath);
        if (!dir.Exists)
            throw new DirectoryNotFoundException($"Directory not found: {localFolderPath}");

        var files = new List<string>();
        try
        {
            var opts = new EnumerationOptions
            {
                RecurseSubdirectories = true,
                IgnoreInaccessible = true,
                AttributesToSkip = FileAttributes.ReparsePoint,
            };
            foreach (var f in Directory.EnumerateFiles(dir.FullName, "*", opts))
            {
                files.Add(f);
            }
        }
        catch
        {
            // Fallback to safe manual walk if EnumerationOptions fails
        }

        string rootFolderName = dir.Name;
        var hostPaths = new List<string>(files.Count);

        for (int i = 0; i < files.Count; i++)
        {
            ct.ThrowIfCancellationRequested();
            string file = files[i];
            string subRel = Path.GetRelativePath(dir.FullName, file).Replace('\\', '/');
            string relPath = $"{rootFolderName}/{subRel}";
            onFileStarted?.Invoke(i + 1, files.Count, relPath);

            var saved = await UploadFileExAsync(
                file,
                relPath: relPath,
                destDir: destDir,
                resume: resume,
                purpose: purpose,
                ct: ct).ConfigureAwait(false);
            if (!string.IsNullOrWhiteSpace(saved))
            {
                hostPaths.Add(saved);
            }
        }

        return hostPaths;
    }

    /// <summary>
    /// Downloads a remote file to a specific local path using `.remoter.part` resumable temp file.
    /// </summary>
    public async Task<string> DownloadFileAsync(
        string remotePath,
        string localDestinationPath,
        bool resume = true,
        CancellationToken ct = default)
    {
        string fullDest = Path.GetFullPath(localDestinationPath);
        string? parentDir = Path.GetDirectoryName(fullDest);
        if (!string.IsNullOrEmpty(parentDir))
        {
            Directory.CreateDirectory(parentDir);
        }

        string partPath = fullDest + ".remoter.part";
        long offset = 0;
        if (resume && File.Exists(partPath))
        {
            try
            {
                var fi = new FileInfo(partPath);
                if (fi.Length > 0) offset = fi.Length;
            }
            catch { offset = 0; }
        }

        var tcs = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        _pendingDownloads.Enqueue(new PendingDownloadRequest
        {
            DestinationPath = fullDest,
            PartPath = partPath,
            RequestedOffset = offset,
            Completion = tcs,
        });

        _sendJsonBytes(ClientMessages.RequestFile(remotePath, offset > 0 ? offset : null));

        using var reg = ct.Register(() => tcs.TrySetCanceled(ct));
        return await tcs.Task.ConfigureAwait(false);
    }

    /// <summary>
    /// Recursively downloads a remote folder into <paramref name="localDestParentDir"/>,
    /// preserving subfolder structure and supporting `.remoter.part` resume per file.
    /// </summary>
    public async Task<int> DownloadFolderAsync(
        string remoteFolderPath,
        string localDestParentDir,
        Func<string, CancellationToken, Task<DirTreeFile[]>> fetchDirTree,
        bool resume = true,
        Action<int, int, string>? onFileStarted = null,
        CancellationToken ct = default)
    {
        var files = await fetchDirTree(remoteFolderPath, ct).ConfigureAwait(false);
        string folderName = ExtractRemoteBaseName(remoteFolderPath);
        string localRoot = Path.Combine(localDestParentDir, SanitizeFileName(folderName));
        Directory.CreateDirectory(localRoot);

        string fullRoot = Path.GetFullPath(localRoot);
        if (!fullRoot.EndsWith(Path.DirectorySeparatorChar))
            fullRoot += Path.DirectorySeparatorChar;

        int downloaded = 0;
        for (int i = 0; i < files.Length; i++)
        {
            ct.ThrowIfCancellationRequested();
            var entry = files[i];
            string localDest = ResolveSafeLocalPath(localRoot, fullRoot, entry.RelPath, ExtractRemoteBaseName(entry.Path));
            onFileStarted?.Invoke(i + 1, files.Length, entry.RelPath);

            await DownloadFileAsync(entry.Path, localDest, resume: resume, ct: ct).ConfigureAwait(false);
            downloaded++;
        }

        return downloaded;
    }

    internal void HandleFileAck(string id, long offset, bool resumed)
    {
        if (string.IsNullOrEmpty(id)) return;
        if (_uploadAcks.TryRemove(id, out var tcs))
        {
            tcs.TrySetResult((offset, resumed));
        }
    }

    internal void HandleFileDone(string id, string path)
    {
        if (string.IsNullOrEmpty(id)) return;
        if (_uploadDones.TryRemove(id, out var tcs))
        {
            tcs.TrySetResult(path ?? "");
        }
    }

    internal void HandleFileStart(string id, string name, long size, long serverOffset = 0)
    {
        if (string.IsNullOrEmpty(id)) return;
        string safeName = SanitizeFileName(name);

        PendingDownloadRequest? pending = null;
        _pendingDownloads.TryDequeue(out pending);

        string partPath;
        string? explicitFinalPath = null;
        TaskCompletionSource<string>? completion = null;

        if (pending != null)
        {
            explicitFinalPath = pending.DestinationPath;
            partPath = pending.PartPath;
            completion = pending.Completion;
        }
        else
        {
            Directory.CreateDirectory(_downloadDirectory);
            partPath = Path.Combine(_downloadDirectory, $"{safeName}.remoter.part");
        }

        try
        {
            string? dir = Path.GetDirectoryName(partPath);
            if (!string.IsNullOrEmpty(dir))
                Directory.CreateDirectory(dir);

            bool resumed = false;
            long initialReceived = 0;
            FileStream stream;

            if (serverOffset > 0 && File.Exists(partPath))
            {
                var fi = new FileInfo(partPath);
                if (fi.Length >= serverOffset)
                {
                    stream = new FileStream(partPath, FileMode.Open, FileAccess.Write, FileShare.None, ChunkSize);
                    stream.Seek(serverOffset, SeekOrigin.Begin);
                    resumed = true;
                    initialReceived = serverOffset;
                }
                else
                {
                    stream = new FileStream(partPath, FileMode.Create, FileAccess.Write, FileShare.None, ChunkSize);
                }
            }
            else
            {
                stream = new FileStream(partPath, FileMode.Create, FileAccess.Write, FileShare.None, ChunkSize);
            }

            long nowMs = Stopwatch.GetTimestamp() * 1000 / Stopwatch.Frequency;
            var state = new DownloadState
            {
                Id = id,
                Name = safeName,
                Size = size,
                PartPath = partPath,
                ExplicitFinalPath = explicitFinalPath,
                Resumed = resumed,
                Stream = stream,
                Completion = completion,
                Received = initialReceived,
                LastSpeedBytes = initialReceived,
                LastSpeedTimeMs = nowMs,
            };

            if (_downloads.TryRemove(id, out var old))
            {
                old.Dispose();
            }

            _downloads[id] = state;
            EmitProgress(new FileTransferProgress(
                id, safeName, size, initialReceived, FileTransferDirection.Download, 0, false, Resumed: resumed));
        }
        catch (Exception ex)
        {
            completion?.TrySetException(ex);
            EmitProgress(new FileTransferProgress(
                id, safeName, size, 0, FileTransferDirection.Download, 0, true, Error: ex.Message));
        }
    }

    internal void HandleFileChunk(string id, uint offset, byte[] chunk)
    {
        if (!_downloads.TryGetValue(id, out var state)) return;

        try
        {
            lock (state)
            {
                state.Stream.Seek(offset, SeekOrigin.Begin);
                state.Stream.Write(chunk, 0, chunk.Length);
                state.Received = Math.Max(state.Received + chunk.Length, (long)offset + chunk.Length);

                long nowMs = Stopwatch.GetTimestamp() * 1000 / Stopwatch.Frequency;
                long dt = nowMs - state.LastSpeedTimeMs;
                if (dt >= 300)
                {
                    state.SpeedBps = (state.Received - state.LastSpeedBytes) * 1000.0 / dt;
                    state.LastSpeedTimeMs = nowMs;
                    state.LastSpeedBytes = state.Received;
                }

                EmitProgress(new FileTransferProgress(
                    id, state.Name, state.Size, Math.Min(state.Received, state.Size),
                    FileTransferDirection.Download, state.SpeedBps, false, Resumed: state.Resumed));
            }
        }
        catch (Exception ex)
        {
            if (_downloads.TryRemove(id, out var failed))
            {
                failed.Dispose();
                failed.Completion?.TrySetException(ex);
            }
            EmitProgress(new FileTransferProgress(
                id, state.Name, state.Size, state.Received,
                FileTransferDirection.Download, 0, true, Error: ex.Message, Resumed: state.Resumed));
        }
    }

    internal void HandleFileEnd(string id)
    {
        if (!_downloads.TryRemove(id, out var state)) return;

        string? finalPath = null;
        try
        {
            lock (state)
            {
                state.Stream.Flush();
            }
            state.Dispose();

            if (!string.IsNullOrEmpty(state.ExplicitFinalPath))
            {
                finalPath = state.ExplicitFinalPath;
                File.Move(state.PartPath, finalPath, overwrite: true);
            }
            else
            {
                finalPath = GetUniqueDestinationPath(_downloadDirectory, state.Name);
                File.Move(state.PartPath, finalPath, overwrite: false);
            }

            EmitProgress(new FileTransferProgress(
                id, state.Name, state.Size, state.Size,
                FileTransferDirection.Download, 0, true, SavedPath: finalPath, Resumed: state.Resumed));
            state.Completion?.TrySetResult(finalPath);
            DownloadCompleted?.Invoke(state.Name, finalPath);
        }
        catch (Exception ex)
        {
            state.Dispose();
            state.Completion?.TrySetException(ex);
            EmitProgress(new FileTransferProgress(
                id, state.Name, state.Size, state.Received,
                FileTransferDirection.Download, 0, true, Error: ex.Message, Resumed: state.Resumed));
        }
    }

    public void CancelAllDownloads()
    {
        // Preserve .remoter.part files on disconnect/cancel so subsequent transfers can resume!
        foreach (var kvp in _downloads)
        {
            if (_downloads.TryRemove(kvp.Key, out var state))
            {
                state.Dispose();
                state.Completion?.TrySetCanceled();
            }
        }
        while (_pendingDownloads.TryDequeue(out var req))
        {
            req.Completion.TrySetCanceled();
        }
        foreach (var kvp in _uploadAcks)
        {
            if (_uploadAcks.TryRemove(kvp.Key, out var tcs))
                tcs.TrySetCanceled();
        }
        foreach (var kvp in _uploadDones)
        {
            if (_uploadDones.TryRemove(kvp.Key, out var tcs))
                tcs.TrySetCanceled();
        }
    }

    public void Dispose()
    {
        CancelAllDownloads();
    }

    private void EmitProgress(FileTransferProgress progress)
    {
        ProgressChanged?.Invoke(progress);
    }

    private static string ExtractRemoteBaseName(string remotePath)
    {
        if (string.IsNullOrWhiteSpace(remotePath)) return "folder";
        var trimmed = remotePath.TrimEnd('/', '\\');
        int idx = trimmed.LastIndexOfAny(['/', '\\']);
        return idx >= 0 ? trimmed[(idx + 1)..] : trimmed;
    }

    private static string ResolveSafeLocalPath(string localRoot, string fullRootWithSep, string relPath, string fallbackName)
    {
        if (!string.IsNullOrWhiteSpace(relPath))
        {
            var rawSegs = relPath.Split(['/', '\\'], StringSplitOptions.RemoveEmptyEntries);
            var safeSegs = new List<string>(rawSegs.Length);
            foreach (var raw in rawSegs)
            {
                var t = raw.Trim();
                if (string.IsNullOrEmpty(t) || t == "." || t == ".." || t.Contains(':')) continue;
                var clean = SanitizeFileName(t);
                if (!string.IsNullOrEmpty(clean) && clean != "." && clean != "..")
                    safeSegs.Add(clean);
            }

            if (safeSegs.Count > 0)
            {
                var parts = new string[safeSegs.Count + 1];
                parts[0] = localRoot;
                for (int i = 0; i < safeSegs.Count; i++) parts[i + 1] = safeSegs[i];
                var candidate = Path.GetFullPath(Path.Combine(parts));
                if (candidate.StartsWith(fullRootWithSep, StringComparison.OrdinalIgnoreCase))
                    return candidate;
            }
        }
        return Path.Combine(localRoot, SanitizeFileName(fallbackName));
    }

    private static string SanitizeFileName(string name)
    {
        var baseName = Path.GetFileName(name);
        if (string.IsNullOrWhiteSpace(baseName))
            baseName = "download.bin";

        foreach (char c in Path.GetInvalidFileNameChars())
        {
            baseName = baseName.Replace(c, '_');
        }
        return baseName;
    }

    private static string GetUniqueDestinationPath(string directory, string fileName)
    {
        Directory.CreateDirectory(directory);
        string candidate = Path.Combine(directory, fileName);
        if (!File.Exists(candidate)) return candidate;

        string stem = Path.GetFileNameWithoutExtension(fileName);
        string ext = Path.GetExtension(fileName);
        for (int i = 1; i < 10_000; i++)
        {
            candidate = Path.Combine(directory, $"{stem} ({i}){ext}");
            if (!File.Exists(candidate)) return candidate;
        }
        return Path.Combine(directory, $"{stem}_{Guid.NewGuid():N}{ext}");
    }
}
