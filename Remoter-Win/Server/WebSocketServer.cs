using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;

namespace RemoterWin;

// Raw TCP WebSocket server — no HttpListener, no admin required.
// Handles the HTTP upgrade handshake and WebSocket framing manually.
sealed class WebSocketServer
{
    public Action<WsConn>?         OnConnect;
    public Action<WsConn, string>? OnText;
    public Action<WsConn, byte[]>? OnBinary;
    public Action<WsConn>?         OnDisconnect;

    private TcpListener? _listener;

    public void Start(int port)
    {
        _listener = new TcpListener(IPAddress.Any, port);
        _listener.Start();
        Console.WriteLine($"[Server] Listening on :{port}");
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
        try
        {
            conn = await DoHandshakeAsync(stream, tcp);
            if (conn == null) { tcp.Close(); return; }

            OnConnect?.Invoke(conn);  // fired before first message arrives
            await ReceiveLoopAsync(conn, stream);
        }
        catch { /* connection reset */ }
        finally
        {
            if (conn != null) OnDisconnect?.Invoke(conn);
            tcp.Close();
        }
    }

    // HTTP/WebSocket upgrade handshake
    private static async Task<WsConn?> DoHandshakeAsync(NetworkStream stream, TcpClient tcp)
    {
        var buf  = new byte[4096];
        int read = 0;
        while (read < buf.Length)
        {
            int n = await stream.ReadAsync(buf.AsMemory(read));
            if (n == 0) return null;
            read += n;
            var req = Encoding.ASCII.GetString(buf, 0, read);
            if (req.Contains("\r\n\r\n")) break;
        }

        var request = Encoding.ASCII.GetString(buf, 0, read);
        var key = ExtractHeader(request, "Sec-WebSocket-Key");
        if (key == null) return null;

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
        return new WsConn(stream, tcp);
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

    private static string? ExtractHeader(string request, string name)
    {
        var prefix = name + ": ";
        foreach (var line in request.Split("\r\n"))
            if (line.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
                return line[prefix.Length..].Trim();
        return null;
    }
}

sealed class WsConn
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

    public Task SendTextAsync(string text) =>
        SendRawAsync(0x1, Encoding.UTF8.GetBytes(text));

    public Task SendBinaryAsync(byte[] data) =>
        SendRawAsync(0x2, data);

    // Sends a WebSocket frame (server → client, no mask, single fragment)
    public async Task SendRawAsync(byte opcode, byte[] payload)
    {
        await _sendLock.WaitAsync();
        try
        {
            using var frame = BuildFrame(opcode, payload);
            await _stream.WriteAsync(frame.GetBuffer().AsMemory(0, (int)frame.Length));
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
            for (int i = 7; i >= 0; i--)
                ms.WriteByte((byte)(payload.Length >> (i * 8)));
        }
        ms.Write(payload);
        return ms;
    }
}
