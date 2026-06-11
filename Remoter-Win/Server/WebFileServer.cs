using System.Net;

namespace RemoterWin;

// Serves the built web client from {exeDir}/web/ on a fixed HTTP port.
// If the web/ directory does not exist, Start() is a no-op (isEnabled = false).
sealed class WebFileServer
{
    public const int Port = 7799;

    public bool IsEnabled { get; private set; }

    private static readonly Dictionary<string, string> Mime = new(StringComparer.OrdinalIgnoreCase)
    {
        [".html"]  = "text/html; charset=utf-8",
        [".js"]    = "application/javascript",
        [".css"]   = "text/css",
        [".svg"]   = "image/svg+xml",
        [".png"]   = "image/png",
        [".ico"]   = "image/x-icon",
        [".woff2"] = "font/woff2",
        [".woff"]  = "font/woff",
        [".json"]  = "application/json",
    };

    private readonly string _root;
    private HttpListener?   _http;

    public WebFileServer()
    {
        _root = Path.Combine(AppContext.BaseDirectory, "web");
    }

    public void Start()
    {
        if (!Directory.Exists(_root)) return;

        _http = new HttpListener();
        try { _http.Prefixes.Add($"http://*:{Port}/"); }
        catch { _http.Prefixes.Add($"http://localhost:{Port}/"); }

        try
        {
            _http.Start();
            IsEnabled = true;
            _ = AcceptLoopAsync();
            AppLog.Write($"[Web] Client at http://localhost:{Port}/");
        }
        catch (Exception ex)
        {
            AppLog.Write($"[Web] Could not start file server: {ex.Message}");
        }
    }

    public void Stop() { try { _http?.Stop(); } catch { } }

    private async Task AcceptLoopAsync()
    {
        while (_http!.IsListening)
        {
            HttpListenerContext ctx;
            try { ctx = await _http.GetContextAsync(); }
            catch { break; }
            _ = Task.Run(() => Handle(ctx));
        }
    }

    private void Handle(HttpListenerContext ctx)
    {
        var resp = ctx.Response;
        try
        {
            var rawPath = ctx.Request.Url?.AbsolutePath ?? "/";
            // Strip leading slash; empty → index.html
            var rel      = rawPath.TrimStart('/');
            var filePath = string.IsNullOrEmpty(rel)
                ? Path.Combine(_root, "index.html")
                : Path.Combine(_root, rel.Replace('/', Path.DirectorySeparatorChar));

            // SPA fallback: unknown asset paths → index.html
            if (!File.Exists(filePath))
                filePath = Path.Combine(_root, "index.html");

            var ext  = Path.GetExtension(filePath);
            var ct   = Mime.TryGetValue(ext, out var m) ? m : "application/octet-stream";
            var data = File.ReadAllBytes(filePath);

            resp.StatusCode       = 200;
            resp.ContentType      = ct;
            resp.ContentLength64  = data.Length;
            resp.OutputStream.Write(data);
        }
        catch
        {
            resp.StatusCode = 404;
        }
        finally
        {
            try { resp.Close(); } catch { }
        }
    }
}
