using System.Net.WebSockets;
using System.Text;
using System.Text.Json;

namespace RemoterWin;

// Connects to the relay server as a host, forwards messages to/from a Session.
// Mirrors Mac RelayClient.swift — same protocol, same reconnect behaviour.
sealed class RelayClient
{
    private readonly string _relayUrl;
    private string          _pin;

    private Session?   _session;
    private RelayConn? _conn;

    public string? SessionId { get; private set; }

    public RelayClient(string relayUrl, string pin)
    {
        _relayUrl = relayUrl;
        _pin      = pin;
    }

    public void UpdatePin(string pin) { _pin = pin; }

    public void Start() { _ = RunLoopAsync(); }

    // ── Connection loop ──────────────────────────────────────────────────

    private async Task RunLoopAsync()
    {
        while (true)
        {
            try { await ConnectAsync(); }
            catch (Exception ex) { AppLog.Write($"[Relay] Error: {ex.Message}"); }

            CloseSession();
            SessionId = null;

            AppLog.Write("[Relay] Disconnected, retrying in 5s…");
            await Task.Delay(5_000);
        }
    }

    private async Task ConnectAsync()
    {
        var url = $"{_relayUrl.TrimEnd('/')}?role=host&pin={Uri.EscapeDataString(_pin)}";
        AppLog.Write($"[Relay] Connecting to {_relayUrl}…");

        var ws = new ClientWebSocket();
        try
        {
            await ws.ConnectAsync(new Uri(url), CancellationToken.None);
            AppLog.Write("[Relay] Connected");
            _conn = new RelayConn(ws);
            await ReceiveLoopAsync(ws);
        }
        finally
        {
            ws.Dispose();
        }
    }

    private async Task ReceiveLoopAsync(ClientWebSocket ws)
    {
        var buf = new byte[65_536];
        while (ws.State == WebSocketState.Open)
        {
            using var ms = new MemoryStream();
            WebSocketReceiveResult result;
            do
            {
                result = await ws.ReceiveAsync(buf, CancellationToken.None);
                if (result.MessageType == WebSocketMessageType.Close) return;
                ms.Write(buf, 0, result.Count);
            }
            while (!result.EndOfMessage);

            var payload = ms.ToArray();
            if (result.MessageType == WebSocketMessageType.Text)
                HandleText(Encoding.UTF8.GetString(payload));
            else
                _session?.HandleBinary(payload);
        }
    }

    // ── Message routing ──────────────────────────────────────────────────

    private void HandleText(string text)
    {
        try
        {
            using var doc  = JsonDocument.Parse(text);
            var root       = doc.RootElement;
            var type       = root.TryGetProperty("type", out var tp) ? tp.GetString() : null;

            switch (type)
            {
                case "registered":
                    SessionId = root.GetProperty("session_id").GetString()!;
                    AppLog.Write($"[Relay] Session ID: {SessionId}");
                    break;

                case "client_connected":
                    AppLog.Write("[Relay] Client connected");
                    CloseSession();
                    _session = new Session(_conn!, _pin);
                    _session.Start();
                    break;

                case "client_disconnected":
                case "host_disconnected":
                    AppLog.Write("[Relay] Client disconnected");
                    CloseSession();
                    break;

                default:
                    _session?.HandleText(text);
                    break;
            }
        }
        catch (Exception ex) { AppLog.Write($"[Relay] HandleText error: {ex.Message}"); }
    }

    private void CloseSession()
    {
        _session?.Close();
        _session = null;
    }
}

// ── Relay transport (IWsConn over ClientWebSocket) ───────────────────────────

sealed class RelayConn : IWsConn
{
    private readonly ClientWebSocket _ws;
    private readonly SemaphoreSlim   _sendLock = new(1, 1);

    public string RemoteAddr => "relay";

    public RelayConn(ClientWebSocket ws) { _ws = ws; }

    public Task SendTextAsync(string text) =>
        SendAsync(Encoding.UTF8.GetBytes(text), WebSocketMessageType.Text);

    public Task SendBinaryAsync(byte[] data) =>
        SendAsync(data, WebSocketMessageType.Binary);

    private async Task SendAsync(byte[] data, WebSocketMessageType type)
    {
        await _sendLock.WaitAsync();
        try
        {
            if (_ws.State == WebSocketState.Open)
                await _ws.SendAsync(data, type, true, CancellationToken.None);
        }
        catch { /* relay disconnected, RunLoopAsync will reconnect */ }
        finally { _sendLock.Release(); }
    }
}
