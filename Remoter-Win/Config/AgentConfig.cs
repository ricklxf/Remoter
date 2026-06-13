using System.Text.Json;

namespace RemoterWin;

// Persisted config — %LOCALAPPDATA%\Remoter\config.json
// CLI args always take precedence over this file.
sealed class AgentConfig
{
    public ushort Port     { get; set; } = 7788;
    public string Pin      { get; set; } = "";
    public string RelayUrl { get; set; } = "";

    private static readonly string _path = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Remoter", "config.json");
    private static readonly object _lock = new();

    public static AgentConfig Load()
    {
        lock (_lock)
        {
            try
            {
                if (!File.Exists(_path)) return new();
                var json = File.ReadAllText(_path);
                return JsonSerializer.Deserialize<AgentConfig>(json,
                    new JsonSerializerOptions { PropertyNameCaseInsensitive = true }) ?? new();
            }
            catch { return new(); }
        }
    }

    public void Save()
    {
        lock (_lock)
        {
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
                File.WriteAllText(_path, JsonSerializer.Serialize(this,
                    new JsonSerializerOptions { WriteIndented = true }));
            }
            catch { }
        }
    }
}
