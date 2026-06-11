using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using RemoterWin;

// ── Arg parsing ───────────────────────────────────────────────────────────

static (string pin, ushort port) ParseArgs(string[] args)
{
    string pin  = "";
    ushort port = 7788;
    for (int i = 0; i + 1 < args.Length; i++)
    {
        if (args[i] == "--pin")  pin  = args[i + 1];
        if (args[i] == "--port") ushort.TryParse(args[i + 1], out port);
    }
    if (string.IsNullOrEmpty(pin))
        pin = Random.Shared.Next(100_000, 999_999).ToString();
    return (pin, port);
}

static List<string> GetLocalIPs()
{
    var ips = new List<string>();
    foreach (var ni in NetworkInterface.GetAllNetworkInterfaces())
    {
        if (ni.OperationalStatus != OperationalStatus.Up) continue;
        foreach (var ua in ni.GetIPProperties().UnicastAddresses)
            if (ua.Address.AddressFamily == AddressFamily.InterNetwork
                && !IPAddress.IsLoopback(ua.Address))
                ips.Add(ua.Address.ToString());
    }
    return ips;
}

// ── Agent bootstrap ───────────────────────────────────────────────────────

var (pin, port) = ParseArgs(args);
var sessions    = new Dictionary<WsConn, Session>();
var server      = new WebSocketServer();

server.OnConnect = (conn) =>
{
    var s = new Session(conn, pin);
    lock (sessions) sessions[conn] = s;
    s.Start();  // sends Hello immediately after TCP+WebSocket handshake
    Console.WriteLine($"[Agent] {conn.RemoteAddr} connected ({sessions.Count} active)");
};

server.OnText = (conn, text) =>
{
    Session? s;
    lock (sessions) sessions.TryGetValue(conn, out s);
    s?.HandleText(text);
};

server.OnBinary = (conn, data) =>
{
    Session? s;
    lock (sessions) sessions.TryGetValue(conn, out s);
    s?.HandleBinary(data);
};

server.OnDisconnect = (conn) =>
{
    Session? s;
    lock (sessions)
    {
        sessions.TryGetValue(conn, out s);
        sessions.Remove(conn);
    }
    s?.Close();
    Console.WriteLine($"[Agent] {conn.RemoteAddr} disconnected ({sessions.Count} active)");
};

server.Start(port);

var ips = GetLocalIPs();
Console.WriteLine("╔══════════════════════════════════╗");
Console.WriteLine("║      Remoter Windows Agent        ║");
Console.WriteLine("╚══════════════════════════════════╝");
Console.WriteLine($"  PIN : {pin}");
Console.WriteLine($"  Port: {port}");
foreach (var ip in ips)
    Console.WriteLine($"  LAN : ws://{ip}:{port}");
Console.WriteLine("\nReady. Waiting for connections…\n");

Console.CancelKeyPress += (_, e) => { e.Cancel = true; server.Stop(); };
await Task.Delay(Timeout.Infinite);
