using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;

namespace RemoterWin;

// Raw TCP WebSocket server — no HttpListener, no admin required.
// Handles the HTTP upgrade handshake and WebSocket framing manually.
sealed class WebSocketServer
{
    public Action<IWsConn>?         OnConnect;
    public Action<IWsConn, string>? OnText;
    public Action<IWsConn, byte[]>? OnBinary;
    public Action<IWsConn>?         OnDisconnect;

    private TcpListener? _listener;

    public void Start(int port)
    {
        _listener = new TcpListener(IPAddress.Any, port);
        _listener.Start();
        AppLog.Write($"[Server] Listening on :{port}");
        _ = AcceptLoopAsync();
    }

    public void Stop() => _listener?.Stop();

    private async Task AcceptLoopAsync()
    {
        while (true)
        {
            TcpClient client;
            try { client = await _listener!.AcceptTcpClientAsync(); }
            catch { break; }
            client.NoDelay = true;
            _ = HandleClientAsync(client);
        }
    }

    private async Task HandleClientAsync(TcpClient tcp)
    {
        var stream = tcp.GetStream();
        WsConn? conn = null;
        bool isHttpRequest = false;
        try
        {
            (conn, isHttpRequest) = await DoHandshakeAsync(stream, tcp);
            if (conn == null) 
            { 
                // If it was an HTTP request, wait a bit for data to be sent
                if (isHttpRequest)
                    await Task.Delay(500);
                tcp.Close(); 
                return; 
            }

            OnConnect?.Invoke(conn);  // fired before first message arrives
            await ReceiveLoopAsync(conn, stream);
        }
        catch (Exception ex) { AppLog.Write($"[WS] {conn?.RemoteAddr ?? "?"} error: {ex.GetType().Name}: {ex.Message}"); }
        finally
        {
            if (conn != null) OnDisconnect?.Invoke(conn);
            tcp.Close();
        }
    }

    // HTTP/WebSocket upgrade handshake
    // Returns (connection, isHttpRequest)
    private static async Task<(WsConn? conn, bool isHttp)> DoHandshakeAsync(NetworkStream stream, TcpClient tcp)
    {
        var buf  = new byte[4096];
        int read = 0;
        while (read < buf.Length)
        {
            int n = await stream.ReadAsync(buf.AsMemory(read));
            if (n == 0) return (null, false);
            read += n;
            var req = Encoding.ASCII.GetString(buf, 0, read);
            if (req.Contains("\r\n\r\n")) break;
        }

        var request = Encoding.ASCII.GetString(buf, 0, read);
        var key = ExtractHeader(request, "Sec-WebSocket-Key");
        if (key == null)
        {
            // Not a WebSocket upgrade — serve as HTTP GET if possible
            var served = await ServeFileAsync(stream, request);
            if (served)
            {
                return (null, true);
            }
            return (null, false);
        }

        var accept = Convert.ToBase64String(
            SHA1.HashData(Encoding.ASCII.GetBytes(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
        );

        var response = Encoding.ASCII.GetBytes(
            "HTTP/1.1 101 Switching Protocols\r\n" +
            "Upgrade: websocket\r\n" +
            "Connection: Upgrade\r\n" +
            $"Sec-WebSocket-Accept: {accept}\r\n\r\n"
        );
        await stream.WriteAsync(response);
        return (new WsConn(stream, tcp), false);
    }

    private async Task ReceiveLoopAsync(WsConn conn, NetworkStream stream)
    {
        while (true)
        {
            var (opcode, payload) = await ReadFrameAsync(stream);
            switch (opcode)
            {
                case 0x1: // text
                    OnText?.Invoke(conn, Encoding.UTF8.GetString(payload));
                    break;
                case 0x2: // binary
                    OnBinary?.Invoke(conn, payload);
                    break;
                case 0x8: // close
                    AppLog.Write($"[WS] {conn.RemoteAddr} sent close frame");
                    return;
                case 0x9: // ping → pong
                    await conn.SendRawAsync(0xA, payload);
                    break;
            }
        }
    }

    // Returns (opcode, unmasked payload). Handles fragmented frames.
    private static async Task<(int opcode, byte[] payload)> ReadFrameAsync(NetworkStream stream)
    {
        var fullPayload = new MemoryStream();
        int finalOpcode = 0;

        while (true)
        {
            byte b0 = await ReadByteAsync(stream);
            byte b1 = await ReadByteAsync(stream);
            bool fin    = (b0 & 0x80) != 0;
            int  opcode = b0 & 0x0F;
            bool masked = (b1 & 0x80) != 0;
            long len    = b1 & 0x7F;

            if (len == 126)
            {
                var tmp = await ReadExactAsync(stream, 2);
                len = (tmp[0] << 8) | tmp[1];
            }
            else if (len == 127)
            {
                var tmp = await ReadExactAsync(stream, 8);
                len = 0;
                for (int i = 0; i < 8; i++) len = (len << 8) | tmp[i];
            }

            byte[]? mask = masked ? await ReadExactAsync(stream, 4) : null;
            var payload  = await ReadExactAsync(stream, (int)len);
            if (mask != null)
                for (int i = 0; i < payload.Length; i++)
                    payload[i] ^= mask[i & 3];

            if (opcode != 0) finalOpcode = opcode;
            fullPayload.Write(payload);
            if (fin) return (finalOpcode, fullPayload.ToArray());
        }
    }

    private static async Task<byte> ReadByteAsync(NetworkStream s)
    {
        var b = new byte[1];
        if (await s.ReadAsync(b.AsMemory(0, 1)) != 1) throw new EndOfStreamException();
        return b[0];
    }

    private static async Task<byte[]> ReadExactAsync(NetworkStream s, int count)
    {
        var buf = new byte[count];
        int offset = 0;
        while (offset < count)
        {
            int n = await s.ReadAsync(buf.AsMemory(offset, count - offset));
            if (n == 0) throw new EndOfStreamException();
            offset += n;
        }
        return buf;
    }

    private static async Task<bool> ServeFileAsync(NetworkStream stream, string request)
    {
        try
        {
            var firstLine = request.Split("\r\n")[0];
            var parts     = firstLine.Split(' ');
            if (parts.Length < 2 || parts[0] != "GET") return false;

            var rawPath = parts[1].Split('?')[0];
            var webRoot = Path.Combine(AppContext.BaseDirectory, "web");
            if (!Directory.Exists(webRoot)) return false;

            var rel      = rawPath.TrimStart('/').Replace('/', Path.DirectorySeparatorChar);
            var filePath = string.IsNullOrEmpty(rel)
                ? Path.Combine(webRoot, "index.html")
                : Path.Combine(webRoot, rel);

            if (!File.Exists(filePath))
                filePath = Path.Combine(webRoot, "index.html");
            if (!File.Exists(filePath)) return false;

            var ext  = Path.GetExtension(filePath);
            var mime = GetMime(ext);
            var data = await File.ReadAllBytesAsync(filePath);

            var header = Encoding.ASCII.GetBytes(
                $"HTTP/1.1 200 OK\r\nContent-Type: {mime}\r\nContent-Length: {data.Length}\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n");
            
            // Send header and data
            await stream.WriteAsync(header, 0, header.Length);
            await stream.WriteAsync(data, 0, data.Length);
            await stream.FlushAsync();
            
            // Wait to ensure data is sent before connection is closed
            await Task.Delay(300);
            
            return true;
        }
        catch { /* ignore broken connections */ }
        return false;
    }

    private static string GetMime(string ext) => ext.ToLowerInvariant() switch
    {
        ".html"  => "text/html; charset=utf-8",
        ".js"    => "application/javascript",
        ".css"   => "text/css",
        ".svg"   => "image/svg+xml",
        ".png"   => "image/png",
        ".ico"   => "image/x-icon",
        ".woff2" => "font/woff2",
        ".woff"  => "font/woff",
        ".json"  => "application/json",
        _        => "application/octet-stream",
    };

    private static string? ExtractHeader(string request, string name)
    {
        var prefix = name + ": ";
        foreach (var line in request.Split("\r\n"))
            if (line.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
                return line[prefix.Length..].Trim();
        return null;
    }
}

sealed class WsConn : IWsConn
{
    private readonly NetworkStream _stream;
    private readonly TcpClient     _tcp;
    private readonly SemaphoreSlim _sendLock = new(1, 1);

    public string RemoteAddr => _tcp.Client.RemoteEndPoint?.ToString() ?? "?";

    public WsConn(NetworkStream stream, TcpClient tcp)
    {
        _stream = stream;
        _tcp    = tcp;
    }

    public async Task SendTextAsync(string text)
    {
        using var frame = BuildFrame(0x1, Encoding.UTF8.GetBytes(text));
        await _sendLock.WaitAsync();
        try
        {
            await _stream.WriteAsync(frame.GetBuffer().AsMemory(0, (int)frame.Length)).ConfigureAwait(false);
        }
        finally { _sendLock.Release(); }
    }

    public async Task SendBinaryAsync(byte[] data)
    {
        using var frame = BuildFrame(0x2, data);
        await _sendLock.WaitAsync();
        try
        {
            await _stream.WriteAsync(frame.GetBuffer().AsMemory(0, (int)frame.Length)).ConfigureAwait(false);
        }
        finally { _sendLock.Release(); }
    }

    public void Disconnect()
    {
        try
        {
            // Send close frame to client
            var closeFrame = new byte[] { 0x88, 0x00 }; // FIN=1, opcode=0x8 (close), length=0
            _stream.Write(closeFrame, 0, closeFrame.Length);
            _stream.Flush();
        }
        catch
        {
            // Ignore errors when sending close frame
        }
        finally
        {
            // Close TCP connection
            _tcp.Close();
        }
    }

    // Sends a WebSocket frame (server → client, no mask, single fragment)
    internal async Task SendRawAsync(byte opcode, byte[] payload)
    {
        using var frame = BuildFrame(opcode, payload);
        await _sendLock.WaitAsync();
        try
        {
            await _stream.WriteAsync(frame.GetBuffer().AsMemory(0, (int)frame.Length)).ConfigureAwait(false);
        }
        finally { _sendLock.Release(); }
    }

    private static MemoryStream BuildFrame(byte opcode, byte[] payload)
    {
        var ms = new MemoryStream(10 + payload.Length);
        ms.WriteByte((byte)(0x80 | opcode)); // FIN=1
        if (payload.Length < 126)
        {
            ms.WriteByte((byte)payload.Length);
        }
        else if (payload.Length < 65536)
        {
            ms.WriteByte(126);
            ms.WriteByte((byte)(payload.Length >> 8));
            ms.WriteByte((byte)(payload.Length));
        }
        else
        {
            ms.WriteByte(127);
            long len64 = payload.Length;
            for (int i = 7; i >= 0; i--)
                ms.WriteByte((byte)(len64 >> (i * 8)));
        }
        ms.Write(payload);
        return ms;
    }
}
