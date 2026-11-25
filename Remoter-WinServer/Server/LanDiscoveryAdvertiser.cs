using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace RemoterWin;

/// <summary>
/// Zero-dependency RFC 6762 mDNS advertiser &amp; responder on 224.0.0.251:5353
/// announcing <c>_remoter._tcp.local.</c> (PTR + SRV + TXT + A) so MacClient
/// and WinClient automatically discover this Windows host on the LAN.
/// </summary>
sealed class LanDiscoveryAdvertiser : IDisposable
{
    public static readonly LanDiscoveryAdvertiser Shared = new();

    private static readonly IPAddress MulticastAddress = IPAddress.Parse("224.0.0.251");
    private static readonly IPEndPoint MulticastEndPoint = new(MulticastAddress, 5353);
    private const int MdnsPort = 5353;
    private const string ServiceType = "_remoter._tcp.local";
    private const uint DefaultTtlSeconds = 120;

    private const ushort TypeA   = 1;
    private const ushort TypePtr = 12;
    private const ushort TypeTxt = 16;
    private const ushort TypeSrv = 33;
    private const ushort TypeAny = 255;
    private const ushort ClassIn = 1;
    private const ushort ClassInCacheFlush = 0x8001;

    private readonly object _lock = new();
    private UdpClient? _udp;
    private CancellationTokenSource? _cts;
    private bool _running;

    private string _instanceName = "";
    private string _serviceFullName = "";
    private string _hostFullName = "";
    private int _wsPort = 7788;
    private int _udpPort = 7789;
    private string _version = "1.0.0";

    private LanDiscoveryAdvertiser() { }

    public void Start(int wsPort = 7788, int udpPort = 7789, string? version = null)
    {
        lock (_lock)
        {
            if (_running) return;

            _wsPort = wsPort;
            _udpPort = udpPort;
            _version = string.IsNullOrWhiteSpace(version)
                ? (typeof(LanDiscoveryAdvertiser).Assembly.GetName().Version?.ToString(3) ?? "1.0.0")
                : version;

            string rawMachine = SanitizeLabel(Environment.MachineName);
            _instanceName = rawMachine;
            _serviceFullName = $"{_instanceName}.{ServiceType}";
            _hostFullName = $"{rawMachine}.local";

            UdpClient? udp = null;
            try
            {
                udp = new UdpClient();
                udp.ExclusiveAddressUse = false;
                udp.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
                udp.Client.Bind(new IPEndPoint(IPAddress.Any, MdnsPort));
                udp.MulticastLoopback = true;
                udp.JoinMulticastGroup(MulticastAddress);
            }
            catch (Exception ex)
            {
                AppLog.Write($"[LanDiscovery] mDNS bind/join failed (non-fatal): {ex.Message}");
                try { udp?.Dispose(); } catch { }
                return;
            }

            _udp = udp;
            _cts = new CancellationTokenSource();
            _running = true;

            var ct = _cts.Token;
            _ = Task.Run(() => ReceiveLoopAsync(udp, ct), ct);
            _ = Task.Run(() => AnnounceLoopAsync(udp, ct), ct);

            AppLog.Write($"[LanDiscovery] Advertising {_serviceFullName} (ws={_wsPort}, udp={_udpPort}, ver={_version})");
        }
    }

    public void Stop()
    {
        UdpClient? udp;
        CancellationTokenSource? cts;
        lock (_lock)
        {
            if (!_running) return;
            _running = false;
            udp = _udp;
            _udp = null;
            cts = _cts;
            _cts = null;
        }

        // Send goodbye packet (TTL = 0) before closing
        if (udp != null)
        {
            try
            {
                byte[] goodbye = BuildAnnouncementPacket(ttl: 0);
                udp.Send(goodbye, goodbye.Length, MulticastEndPoint);
            }
            catch { }
        }

        try { cts?.Cancel(); } catch { }
        try { udp?.DropMulticastGroup(MulticastAddress); } catch { }
        try { udp?.Close(); } catch { }
        try { udp?.Dispose(); } catch { }
        try { cts?.Dispose(); } catch { }
    }

    public void Dispose() => Stop();

    private async Task AnnounceLoopAsync(UdpClient udp, CancellationToken ct)
    {
        try
        {
            // RFC 6762 startup burst: 0ms, 1s, 3s
            SendAnnouncement(udp);
            await Task.Delay(1000, ct).ConfigureAwait(false);
            SendAnnouncement(udp);
            await Task.Delay(2000, ct).ConfigureAwait(false);
            SendAnnouncement(udp);

            using var timer = new PeriodicTimer(TimeSpan.FromSeconds(60));
            while (await timer.WaitForNextTickAsync(ct).ConfigureAwait(false))
            {
                SendAnnouncement(udp);
            }
        }
        catch (OperationCanceledException) { }
        catch (ObjectDisposedException) { }
    }

    private async Task ReceiveLoopAsync(UdpClient udp, CancellationToken ct)
    {
        try
        {
            while (!ct.IsCancellationRequested)
            {
                var res = await udp.ReceiveAsync(ct).ConfigureAwait(false);
                if (IsMatchingQuery(res.Buffer))
                {
                    SendAnnouncement(udp);
                }
            }
        }
        catch (OperationCanceledException) { }
        catch (ObjectDisposedException) { }
        catch (SocketException) { }
    }

    private void SendAnnouncement(UdpClient udp)
    {
        try
        {
            byte[] pkt = BuildAnnouncementPacket(DefaultTtlSeconds);
            udp.Send(pkt, pkt.Length, MulticastEndPoint);
        }
        catch { }
    }

    private bool IsMatchingQuery(byte[] buf)
    {
        if (buf.Length < 12) return false;
        ushort flags = BinaryPrimitives.ReadUInt16BigEndian(buf.AsSpan(2, 2));
        // QR bit (0x8000) == 0 means Query
        if ((flags & 0x8000) != 0) return false;

        ushort qdCount = BinaryPrimitives.ReadUInt16BigEndian(buf.AsSpan(4, 2));
        if (qdCount == 0) return false;

        int offset = 12;
        for (int i = 0; i < qdCount; i++)
        {
            if (!TryReadDnsName(buf, ref offset, out string qname)) return false;
            if (offset + 4 > buf.Length) return false;
            ushort qtype = BinaryPrimitives.ReadUInt16BigEndian(buf.AsSpan(offset, 2));
            offset += 4; // qtype + qclass

            if ((qtype == TypePtr || qtype == TypeAny) &&
                qname.Equals(ServiceType, StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
            if ((qtype == TypeSrv || qtype == TypeTxt || qtype == TypeAny) &&
                qname.Equals(_serviceFullName, StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
            if ((qtype == TypeA || qtype == TypeAny) &&
                qname.Equals(_hostFullName, StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }
        return false;
    }

    private byte[] BuildAnnouncementPacket(uint ttl)
    {
        var ipv4s = GetLocalIPv4Addresses();
        int answerCount = 3 + ipv4s.Count; // PTR + SRV + TXT + A(s)

        using var ms = new MemoryStream(512);

        // DNS Header (12 bytes): ID=0, Flags=0x8400 (Response + Authoritative), QD=0, AN=answerCount, NS=0, AR=0
        WriteUInt16BE(ms, 0x0000);
        WriteUInt16BE(ms, 0x8400);
        WriteUInt16BE(ms, 0);
        WriteUInt16BE(ms, (ushort)answerCount);
        WriteUInt16BE(ms, 0);
        WriteUInt16BE(ms, 0);

        // 1. PTR: _remoter._tcp.local -> <instance>._remoter._tcp.local
        WriteDnsName(ms, ServiceType);
        WriteUInt16BE(ms, TypePtr);
        WriteUInt16BE(ms, ClassIn);
        WriteUInt32BE(ms, ttl);
        byte[] ptrRdata = EncodeDnsName(_serviceFullName);
        WriteUInt16BE(ms, (ushort)ptrRdata.Length);
        ms.Write(ptrRdata, 0, ptrRdata.Length);

        // 2. SRV: <instance>._remoter._tcp.local -> 0 0 <wsPort> <host>.local
        WriteDnsName(ms, _serviceFullName);
        WriteUInt16BE(ms, TypeSrv);
        WriteUInt16BE(ms, ClassInCacheFlush);
        WriteUInt32BE(ms, ttl);
        byte[] targetEncoded = EncodeDnsName(_hostFullName);
        WriteUInt16BE(ms, (ushort)(6 + targetEncoded.Length));
        WriteUInt16BE(ms, 0); // priority
        WriteUInt16BE(ms, 0); // weight
        WriteUInt16BE(ms, (ushort)_wsPort);
        ms.Write(targetEncoded, 0, targetEncoded.Length);

        // 3. TXT: os=windows, wsPort=..., udpPort=..., ver=...
        WriteDnsName(ms, _serviceFullName);
        WriteUInt16BE(ms, TypeTxt);
        WriteUInt16BE(ms, ClassInCacheFlush);
        WriteUInt32BE(ms, ttl);
        byte[] txtRdata = EncodeTxtRecords(new[]
        {
            "os=windows",
            $"wsPort={_wsPort}",
            $"udpPort={_udpPort}",
            $"ver={_version}"
        });
        WriteUInt16BE(ms, (ushort)txtRdata.Length);
        ms.Write(txtRdata, 0, txtRdata.Length);

        // 4. A records: <host>.local -> IPv4
        foreach (var ip in ipv4s)
        {
            byte[] ipBytes = ip.GetAddressBytes();
            if (ipBytes.Length != 4) continue;
            WriteDnsName(ms, _hostFullName);
            WriteUInt16BE(ms, TypeA);
            WriteUInt16BE(ms, ClassInCacheFlush);
            WriteUInt32BE(ms, ttl);
            WriteUInt16BE(ms, 4);
            ms.Write(ipBytes, 0, 4);
        }

        return ms.ToArray();
    }

    private static List<IPAddress> GetLocalIPv4Addresses()
    {
        var result = new List<IPAddress>();
        try
        {
            foreach (var ni in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (ni.OperationalStatus != OperationalStatus.Up) continue;
                if (ni.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
                var props = ni.GetIPProperties();
                foreach (var ua in props.UnicastAddresses)
                {
                    if (ua.Address.AddressFamily != AddressFamily.InterNetwork) continue;
                    byte[] b = ua.Address.GetAddressBytes();
                    if (b[0] == 127) continue;
                    if (b[0] == 169 && b[1] == 254) continue; // skip APIPA link-local
                    result.Add(ua.Address);
                }
            }
        }
        catch { }
        return result;
    }

    private static string SanitizeLabel(string raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return "RemoterWin";
        var sb = new StringBuilder(raw.Length);
        foreach (char c in raw.Trim())
        {
            if (char.IsLetterOrDigit(c) || c == '-' || c == '_') sb.Append(c);
            else if (c == ' ') sb.Append('-');
        }
        string s = sb.ToString();
        if (string.IsNullOrEmpty(s)) return "RemoterWin";
        return s.Length > 60 ? s[..60] : s;
    }

    private static byte[] EncodeDnsName(string name)
    {
        using var ms = new MemoryStream(name.Length + 2);
        WriteDnsName(ms, name);
        return ms.ToArray();
    }

    private static void WriteDnsName(MemoryStream ms, string name)
    {
        string trimmed = name.TrimEnd('.');
        foreach (string label in trimmed.Split('.'))
        {
            byte[] bytes = Encoding.UTF8.GetBytes(label);
            int len = Math.Min(bytes.Length, 63);
            ms.WriteByte((byte)len);
            ms.Write(bytes, 0, len);
        }
        ms.WriteByte(0);
    }

    private static byte[] EncodeTxtRecords(string[] entries)
    {
        using var ms = new MemoryStream(128);
        foreach (var entry in entries)
        {
            byte[] bytes = Encoding.UTF8.GetBytes(entry);
            int len = Math.Min(bytes.Length, 255);
            ms.WriteByte((byte)len);
            ms.Write(bytes, 0, len);
        }
        return ms.ToArray();
    }

    private static bool TryReadDnsName(byte[] buf, ref int offset, out string name)
    {
        name = "";
        var labels = new List<string>();
        int pos = offset;
        bool jumped = false;
        int guard = 0;

        while (pos < buf.Length && guard++ < 64)
        {
            byte len = buf[pos];
            if (len == 0)
            {
                if (!jumped) offset = pos + 1;
                name = string.Join('.', labels);
                return true;
            }
            if ((len & 0xC0) == 0xC0)
            {
                if (pos + 1 >= buf.Length) return false;
                int ptr = ((len & 0x3F) << 8) | buf[pos + 1];
                if (!jumped) offset = pos + 2;
                pos = ptr;
                jumped = true;
                continue;
            }
            pos++;
            if (pos + len > buf.Length) return false;
            labels.Add(Encoding.UTF8.GetString(buf, pos, len));
            pos += len;
        }
        return false;
    }

    private static void WriteUInt16BE(MemoryStream ms, ushort val)
    {
        ms.WriteByte((byte)(val >> 8));
        ms.WriteByte((byte)(val & 0xFF));
    }

    private static void WriteUInt32BE(MemoryStream ms, uint val)
    {
        ms.WriteByte((byte)(val >> 24));
        ms.WriteByte((byte)((val >> 16) & 0xFF));
        ms.WriteByte((byte)((val >> 8) & 0xFF));
        ms.WriteByte((byte)(val & 0xFF));
    }
}
