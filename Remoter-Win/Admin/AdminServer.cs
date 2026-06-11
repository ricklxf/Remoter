using System.Net;
using System.Text;
using System.Text.Json;

namespace RemoterWin;

// Lightweight HTTP admin console on port (agentPort + 2).
// Serves a single-page dashboard with live SSE log stream.
sealed class AdminServer
{
    private readonly HttpListener _http = new();
    private readonly int          _agentPort;
    private string                _pin;
    private int                   _connCount = 0;

    private readonly List<string>              _logBuf = new(500);
    private readonly List<StreamWriter>        _sseClients = new();
    private readonly object                    _lock = new();

    public Action<string>? OnPinChange;

    public AdminServer(int agentPort, string pin)
    {
        _agentPort = agentPort;
        _pin       = pin;
        int adminPort = agentPort + 2;
        _http.Prefixes.Add($"http://*:{adminPort}/");
    }

    public void UpdatePin(string pin)  { lock (_lock) _pin = pin; }
    public void SetConnCount(int n)    { _connCount = n; }

    public void Log(string line)
    {
        var ts  = DateTime.Now.ToString("HH:mm:ss");
        var msg = $"[{ts}] {line}";
        lock (_lock)
        {
            _logBuf.Add(msg);
            if (_logBuf.Count > 500) _logBuf.RemoveAt(0);
            foreach (var w in _sseClients)
                TrySendSse(w, msg);
        }
    }

    public void Start()
    {
        // Try wildcard first; if denied (non-admin), fall back to localhost
        int adminPort = _agentPort + 2;
        try
        {
            _http.Start();
            AppLog.Write($"[Admin] Console at http://localhost:{adminPort}/");
            _ = AcceptLoopAsync();
        }
        catch (HttpListenerException)
        {
            _http.Close();
            var fallback = new HttpListener();
            fallback.Prefixes.Add($"http://localhost:{adminPort}/");
            // replace the field — use a local reference for the Accept loop
            try
            {
                fallback.Start();
                AppLog.Write($"[Admin] Console at http://localhost:{adminPort}/ (localhost only)");
                _ = AcceptLoopAsync(fallback);
            }
            catch (Exception ex2)
            {
                AppLog.Write($"[Admin] Could not start admin server: {ex2.Message}");
            }
        }
    }

    public void Stop() { try { _http.Stop(); } catch { } }

    private async Task AcceptLoopAsync(HttpListener? listener = null)
    {
        var http = listener ?? _http;
        while (http.IsListening)
        {
            HttpListenerContext ctx;
            try { ctx = await http.GetContextAsync(); }
            catch { break; }
            _ = Task.Run(() => HandleAsync(ctx));
        }
    }

    private void HandleAsync(HttpListenerContext ctx)
    {
        var req  = ctx.Request;
        var resp = ctx.Response;
        resp.Headers["Access-Control-Allow-Origin"] = "*";

        try
        {
            switch (req.Url?.AbsolutePath)
            {
                case "/":
                case "/index.html":
                    Serve(resp, "text/html; charset=utf-8", Encoding.UTF8.GetBytes(HtmlPage()));
                    break;

                case "/status":
                    var status = JsonSerializer.Serialize(new
                    {
                        pin         = _pin,
                        agentPort   = _agentPort,
                        connections = _connCount,
                        uptime      = Environment.TickCount64 / 1000,
                    });
                    Serve(resp, "application/json", Encoding.UTF8.GetBytes(status));
                    break;

                case "/logs":
                    ServeSse(ctx);
                    return; // SSE handler keeps connection open, do NOT dispose here

                case "/setpin":
                    if (req.HttpMethod == "POST")
                    {
                        using var sr = new StreamReader(req.InputStream);
                        var body = sr.ReadToEnd();
                        var doc  = JsonDocument.Parse(body);
                        if (doc.RootElement.TryGetProperty("pin", out var pv))
                        {
                            var newPin = pv.GetString() ?? "";
                            if (newPin.Length >= 4)
                            {
                                UpdatePin(newPin);
                                OnPinChange?.Invoke(newPin);
                                Log($"[Admin] PIN changed");
                                Serve(resp, "application/json", "{\"ok\":true}"u8.ToArray());
                                break;
                            }
                        }
                        resp.StatusCode = 400;
                        Serve(resp, "application/json", "{\"ok\":false}"u8.ToArray());
                    }
                    break;

                case "/stop":
                    if (req.HttpMethod == "POST")
                    {
                        Log("[Admin] Shutdown requested via admin console");
                        Serve(resp, "application/json", "{\"ok\":true}"u8.ToArray());
                        _ = Task.Delay(300).ContinueWith(_ => Environment.Exit(0));
                    }
                    break;

                default:
                    resp.StatusCode = 404;
                    resp.Close();
                    break;
            }
        }
        catch { try { resp.Close(); } catch { } }
    }

    private static void Serve(HttpListenerResponse resp, string ct, byte[] body)
    {
        resp.ContentType   = ct;
        resp.ContentLength64 = body.Length;
        resp.OutputStream.Write(body);
        resp.Close();
    }

    private void ServeSse(HttpListenerContext ctx)
    {
        var resp = ctx.Response;
        resp.ContentType     = "text/event-stream";
        resp.Headers["Cache-Control"]       = "no-cache";
        resp.Headers["X-Accel-Buffering"]   = "no";
        resp.SendChunked = true;

        var writer = new StreamWriter(resp.OutputStream, Encoding.UTF8, leaveOpen: true) { AutoFlush = true };

        // Send buffered log history first
        lock (_lock)
        {
            foreach (var line in _logBuf)
                TrySendSse(writer, line);
            _sseClients.Add(writer);
        }

        // Keep alive until client disconnects
        try
        {
            while (ctx.Request.IsWebSocketRequest == false)
            {
                Thread.Sleep(5000);
                writer.Write(":\n\n"); // SSE keepalive comment
            }
        }
        catch { }
        finally
        {
            lock (_lock) _sseClients.Remove(writer);
            try { writer.Dispose(); } catch { }
            try { resp.Close(); } catch { }
        }
    }

    private static void TrySendSse(StreamWriter w, string line)
    {
        try { w.Write($"data: {line}\n\n"); } catch { }
    }

    // ── Embedded single-page dashboard ───────────────────────────────────

    private string HtmlPage() => $$"""
<!DOCTYPE html>
<html lang="zh">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Remoter Agent</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:#0f0f1a;color:#eaeaea;height:100vh;display:flex;flex-direction:column}
header{background:#1a1a2e;padding:16px 24px;display:flex;align-items:center;gap:16px;border-bottom:1px solid #2a2a3e}
header h1{font-size:18px;font-weight:700;letter-spacing:-.3px}
.badge{background:#0d9488;color:#fff;font-size:11px;font-weight:700;padding:3px 8px;border-radius:4px}
.cards{display:flex;gap:12px;padding:16px 24px;background:#14142a;border-bottom:1px solid #2a2a3e}
.card{background:#1a1a2e;border-radius:8px;padding:14px 18px;min-width:140px}
.card-label{font-size:11px;color:#a0a0b0;text-transform:uppercase;letter-spacing:.05em;margin-bottom:6px}
.card-value{font-size:22px;font-weight:700;font-variant-numeric:tabular-nums;letter-spacing:-.5px}
.pin-row{display:flex;align-items:center;gap:8px}
.pin-input{background:#0f0f1a;border:1px solid #333344;color:#eaeaea;border-radius:6px;padding:6px 10px;font-size:14px;font-family:monospace;width:100px}
.pin-btn{background:#0d9488;color:#fff;border:none;border-radius:6px;padding:6px 12px;font-size:13px;cursor:pointer}
.pin-btn:hover{opacity:.85}
.stop-btn{background:#7f1d1d;color:#fca5a5;border:1px solid #991b1b;border-radius:6px;padding:6px 14px;font-size:13px;cursor:pointer;margin-left:auto}
.stop-btn:hover{background:#991b1b}
#logs{flex:1;overflow-y:auto;padding:12px 24px;font-family:'Menlo','Consolas',monospace;font-size:12px;line-height:1.7}
.log-line{padding:1px 0;border-bottom:1px solid rgba(255,255,255,.04)}
.log-line:last-child{border-bottom:none}
footer{padding:8px 24px;font-size:11px;color:#555;background:#1a1a2e;border-top:1px solid #2a2a3e}
</style>
</head>
<body>
<header>
  <h1>Remoter Agent</h1>
  <span class="badge" id="connBadge">0 连接</span>
  <button class="stop-btn" onclick="stopAgent()">停止服务</button>
</header>
<div class="cards">
  <div class="card">
    <div class="card-label">PIN</div>
    <div class="pin-row">
      <input class="pin-input" id="pinInput" type="text" maxlength="10">
      <button class="pin-btn" onclick="setPin()">更新</button>
    </div>
  </div>
  <div class="card">
    <div class="card-label">端口</div>
    <div class="card-value" id="portVal">—</div>
  </div>
  <div class="card">
    <div class="card-label">运行时间</div>
    <div class="card-value" id="uptimeVal">—</div>
  </div>
</div>
<div id="logs"></div>
<footer>Agent 控制台 · 日志保留最近 500 条 · <a href="/status" style="color:#0d9488">status JSON</a></footer>
<script>
const logsEl = document.getElementById('logs');
let autoScroll = true;
logsEl.addEventListener('scroll', () => {
  autoScroll = logsEl.scrollTop + logsEl.clientHeight >= logsEl.scrollHeight - 8;
});
function appendLog(text) {
  const d = document.createElement('div');
  d.className = 'log-line';
  d.textContent = text;
  logsEl.appendChild(d);
  if (logsEl.children.length > 600) logsEl.removeChild(logsEl.firstChild);
  if (autoScroll) logsEl.scrollTop = logsEl.scrollHeight;
}
function fmtUptime(s) {
  if (s < 60) return s + 's';
  if (s < 3600) return Math.floor(s/60) + 'm ' + (s%60) + 's';
  return Math.floor(s/3600) + 'h ' + Math.floor((s%3600)/60) + 'm';
}
async function loadStatus() {
  try {
    const r = await fetch('/status');
    const d = await r.json();
    document.getElementById('pinInput').value  = d.pin;
    document.getElementById('portVal').textContent   = d.agentPort;
    document.getElementById('uptimeVal').textContent = fmtUptime(d.uptime);
    document.getElementById('connBadge').textContent = d.connections + ' 连接';
  } catch {}
}
async function setPin() {
  const pin = document.getElementById('pinInput').value.trim();
  if (pin.length < 4) return alert('PIN 至少 4 位');
  const r = await fetch('/setpin', { method:'POST', body: JSON.stringify({pin}), headers:{'Content-Type':'application/json'} });
  const d = await r.json();
  if (d.ok) loadStatus(); else alert('修改失败');
}
loadStatus();
setInterval(loadStatus, 5000);
const es = new EventSource('/logs');
es.onmessage = e => appendLog(e.data);
es.onerror   = () => setTimeout(() => location.reload(), 3000);
</script>
</body>
</html>
""";
}
