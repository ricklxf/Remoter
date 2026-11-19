using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

namespace RemoterWinClient;

/// <summary>
/// Chunked bidirectional file transfer client matching Remoter's wire protocol:
///   JSON:   file_start { id, name, size } -> Binary 0x02 chunks (64 KiB) -> JSON file_end { id }
///   Binary: [0x02][16B UTF-8 id padded with '\0'][4B offset BE][chunk data]
/// </summary>
public sealed class FileTransferClient : IDisposable
{
    public const int ChunkSize = 64 * 1024;

    private sealed class DownloadState : IDisposable
    {
        public required string Id { get; init; }
        public required string Name { get; init; }
        public required long Size { get; init; }
        public required string TempPath { get; init; }
        public required FileStream Stream { get; init; }
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

    public async Task UploadFileAsync(string localFilePath, CancellationToken ct = default)
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

        _sendJsonBytes(ClientMessages.FileStart(id, name, totalSize));

        try
        {
            await using var fs = new FileStream(
                localFilePath,
                FileMode.Open,
                FileAccess.Read,
                FileShare.Read,
                bufferSize: ChunkSize,
                useAsync: true);

            var buffer = new byte[ChunkSize];
            long offset = 0;
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
                    FileTransferDirection.Upload, speedBps, false));
            }

            _sendJsonBytes(ClientMessages.FileEnd(id));
            EmitProgress(new FileTransferProgress(
                id, name, totalSize, totalSize, FileTransferDirection.Upload, speedBps, true));
        }
        catch (Exception ex)
        {
            EmitProgress(new FileTransferProgress(
                id, name, totalSize, 0, FileTransferDirection.Upload, 0, true, Error: ex.Message));
            throw;
        }
    }

    internal void HandleFileStart(string id, string name, long size)
    {
        if (string.IsNullOrEmpty(id)) return;
        string safeName = SanitizeFileName(name);

        try
        {
            Directory.CreateDirectory(_downloadDirectory);
            string tempPath = Path.Combine(_downloadDirectory, $".remoter_dl_{id}_{Guid.NewGuid():N}.part");
            var stream = new FileStream(tempPath, FileMode.Create, FileAccess.Write, FileShare.None, ChunkSize);
            if (size > 0)
                stream.SetLength(size);

            long nowMs = Stopwatch.GetTimestamp() * 1000 / Stopwatch.Frequency;
            var state = new DownloadState
            {
                Id = id,
                Name = safeName,
                Size = size,
                TempPath = tempPath,
                Stream = stream,
                LastSpeedTimeMs = nowMs,
            };

            if (_downloads.TryRemove(id, out var old))
            {
                old.Dispose();
                TryDelete(old.TempPath);
            }

            _downloads[id] = state;
            EmitProgress(new FileTransferProgress(
                id, safeName, size, 0, FileTransferDirection.Download, 0, false));
        }
        catch (Exception ex)
        {
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
                state.Received += chunk.Length;

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
                    FileTransferDirection.Download, state.SpeedBps, false));
            }
        }
        catch (Exception ex)
        {
            if (_downloads.TryRemove(id, out var failed))
            {
                failed.Dispose();
                TryDelete(failed.TempPath);
            }
            EmitProgress(new FileTransferProgress(
                id, state.Name, state.Size, state.Received,
                FileTransferDirection.Download, 0, true, Error: ex.Message));
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

            finalPath = GetUniqueDestinationPath(_downloadDirectory, state.Name);
            File.Move(state.TempPath, finalPath, overwrite: false);

            EmitProgress(new FileTransferProgress(
                id, state.Name, state.Size, state.Size,
                FileTransferDirection.Download, 0, true, SavedPath: finalPath));
            DownloadCompleted?.Invoke(state.Name, finalPath);
        }
        catch (Exception ex)
        {
            state.Dispose();
            TryDelete(state.TempPath);
            EmitProgress(new FileTransferProgress(
                id, state.Name, state.Size, state.Received,
                FileTransferDirection.Download, 0, true, Error: ex.Message));
        }
    }

    public void CancelAllDownloads()
    {
        foreach (var kvp in _downloads)
        {
            if (_downloads.TryRemove(kvp.Key, out var state))
            {
                state.Dispose();
                TryDelete(state.TempPath);
            }
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

    private static void TryDelete(string path)
    {
        try
        {
            if (File.Exists(path)) File.Delete(path);
        }
        catch { }
    }
}
