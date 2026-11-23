using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;

namespace RemoterWinClient;

/// <summary>
/// Persists saved remote devices and client preferences in
/// %APPDATA%\RemoterWinClient\devices.json.
/// </summary>
public sealed class DeviceStore
{
    private sealed class StorePayload
    {
        public List<SavedDevice> Devices { get; set; } = new();
        public ClientSettings Settings { get; set; } = new();
    }

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNameCaseInsensitive = true,
    };

    private readonly object _sync = new();
    private readonly string _filePath;
    private StorePayload _data = new();

    public static DeviceStore Shared { get; } = new();

    public DeviceStore(string? customFilePath = null)
    {
        if (!string.IsNullOrWhiteSpace(customFilePath))
        {
            _filePath = customFilePath;
        }
        else
        {
            var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
            _filePath = Path.Combine(appData, "RemoterWinClient", "devices.json");
        }
        Load();
    }

    public void Load()
    {
        lock (_sync)
        {
            try
            {
                if (!File.Exists(_filePath))
                {
                    _data = new StorePayload();
                    return;
                }
                var json = File.ReadAllText(_filePath);
                var parsed = JsonSerializer.Deserialize<StorePayload>(json, JsonOptions);
                _data = parsed ?? new StorePayload();
                _data.Devices ??= new List<SavedDevice>();
                _data.Settings ??= new ClientSettings();
            }
            catch
            {
                _data = new StorePayload();
            }
        }
    }

    public void Save()
    {
        lock (_sync)
        {
            SaveLocked();
        }
    }

    public List<SavedDevice> GetDevices()
    {
        lock (_sync)
        {
            return _data.Devices
                .OrderByDescending(d => d.LastConnectedUtc)
                .ToList();
        }
    }

    public SavedDevice? FindByHost(string host, int port)
    {
        lock (_sync)
        {
            return _data.Devices.FirstOrDefault(d =>
                string.Equals(d.Host, host, StringComparison.OrdinalIgnoreCase) &&
                d.Port == port);
        }
    }

    public void UpsertDevice(SavedDevice device)
    {
        lock (_sync)
        {
            var existing = _data.Devices.FirstOrDefault(d =>
                d.Id == device.Id ||
                (string.Equals(d.Host, device.Host, StringComparison.OrdinalIgnoreCase) &&
                 d.Port == device.Port));

            if (existing != null)
            {
                existing.Name = string.IsNullOrWhiteSpace(device.Name) ? existing.Name : device.Name;
                existing.Host = device.Host;
                existing.Port = device.Port;
                existing.UseTls = device.UseTls;
                existing.AuthMethod = device.AuthMethod;
                if (device.Pin != null) existing.Pin = device.Pin;
                if (device.Username != null) existing.Username = device.Username;
                if (device.Token != null) existing.Token = device.Token;
                if (!string.IsNullOrWhiteSpace(device.ComputerName)) existing.ComputerName = device.ComputerName;
                if (!string.IsNullOrWhiteSpace(device.ModelId)) existing.ModelId = device.ModelId;
                if (!string.IsNullOrWhiteSpace(device.ServerOs)) existing.ServerOs = device.ServerOs;
                existing.LastConnectedUtc = device.LastConnectedUtc == default
                    ? DateTime.UtcNow
                    : device.LastConnectedUtc;
            }
            else
            {
                if (string.IsNullOrWhiteSpace(device.Id))
                    device.Id = Guid.NewGuid().ToString("N");
                if (device.LastConnectedUtc == default)
                    device.LastConnectedUtc = DateTime.UtcNow;
                _data.Devices.Add(device);
            }

            SaveLocked();
        }
    }

    public bool RemoveDevice(string id)
    {
        lock (_sync)
        {
            int removed = _data.Devices.RemoveAll(d => d.Id == id);
            if (removed > 0) SaveLocked();
            return removed > 0;
        }
    }

    public void UpdateMachineInfo(string host, int port, string? computerName, string? modelId, string? serverOs)
    {
        lock (_sync)
        {
            var existing = _data.Devices.FirstOrDefault(d =>
                string.Equals(d.Host, host, StringComparison.OrdinalIgnoreCase) &&
                d.Port == port);
            if (existing == null) return;

            if (!string.IsNullOrWhiteSpace(computerName)) existing.ComputerName = computerName;
            if (!string.IsNullOrWhiteSpace(modelId)) existing.ModelId = modelId;
            if (!string.IsNullOrWhiteSpace(serverOs)) existing.ServerOs = serverOs;
            SaveLocked();
        }
    }

    public void UpdateToken(string host, int port, string username, string token)
    {
        lock (_sync)
        {
            var existing = _data.Devices.FirstOrDefault(d =>
                string.Equals(d.Host, host, StringComparison.OrdinalIgnoreCase) &&
                d.Port == port);
            if (existing == null) return;

            existing.Username = username;
            existing.Token = token;
            existing.LastConnectedUtc = DateTime.UtcNow;
            SaveLocked();
        }
    }

    public ClientSettings GetSettings()
    {
        lock (_sync)
        {
            // Return a shallow copy so callers mutate safely before SaveSettings.
            var s = _data.Settings;
            return new ClientSettings
            {
                ScaleMode = s.ScaleMode,
                ResolutionTier = s.ResolutionTier,
                PreferredCodec = s.PreferredCodec,
                Fps = s.Fps,
                AutoFps = s.AutoFps,
                BitrateBps = s.BitrateBps,
                AutoBitrate = s.AutoBitrate,
                AudioEnabled = s.AudioEnabled,
                ClipboardSyncEnabled = s.ClipboardSyncEnabled,
                VSyncEnabled = s.VSyncEnabled,
                HardwareDecode = s.HardwareDecode,
                ImeOffsets = s.ImeOffsets != null
                    ? s.ImeOffsets.ToDictionary(
                        kv => kv.Key,
                        kv => new ImeOffset { X = kv.Value.X, Y = kv.Value.Y })
                    : new Dictionary<string, ImeOffset>(),
                DownloadDirectory = s.DownloadDirectory,
            };
        }
    }

    public void SaveSettings(ClientSettings settings)
    {
        lock (_sync)
        {
            _data.Settings = settings ?? new ClientSettings();
            SaveLocked();
        }
    }

    private void SaveLocked()
    {
        try
        {
            var dir = Path.GetDirectoryName(_filePath);
            if (!string.IsNullOrEmpty(dir))
                Directory.CreateDirectory(dir);

            var tmpPath = _filePath + ".tmp";
            var json = JsonSerializer.Serialize(_data, JsonOptions);
            File.WriteAllText(tmpPath, json);
            File.Move(tmpPath, _filePath, overwrite: true);
        }
        catch
        {
            // Best-effort persistence; never crash UI on disk errors.
        }
    }
}
