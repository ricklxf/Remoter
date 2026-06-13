using System.Text.Json;

namespace RemoterWin;

// Persistent token store — %LOCALAPPDATA%\Remoter\tokens.json
// Format: { "token": "username" }  — permanent, no expiry.
static class TokenStore
{
    private static readonly string _path = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Remoter", "tokens.json");
    private static readonly object _lock = new();

    public static string Generate(string username)
    {
        var token  = Guid.NewGuid().ToString("N");
        lock (_lock)
        {
            var tokens = Load();
            tokens[token] = username;
            Save(tokens);
        }
        return token;
    }

    public static string? Lookup(string token)
    {
        lock (_lock)
        {
            var tokens = Load();
            return tokens.TryGetValue(token, out var name) ? name : null;
        }
    }

    private static Dictionary<string, string> Load()
    {
        try
        {
            if (!File.Exists(_path)) return new();
            var json = File.ReadAllText(_path);
            return JsonSerializer.Deserialize<Dictionary<string, string>>(json) ?? new();
        }
        catch { return new(); }
    }

    private static void Save(Dictionary<string, string> tokens)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
            File.WriteAllText(_path, JsonSerializer.Serialize(tokens));
        }
        catch { }
    }
}
