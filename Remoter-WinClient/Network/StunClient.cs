using System;
using System.Buffers.Binary;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;

namespace RemoterWinClient;

/// <summary>
/// Lightweight RFC 5389 STUN Binding Client over UDP.
/// Discovers the external NAT-mapped (Ip, Port) via XOR-MAPPED-ADDRESS (0x0020)
/// with IPv4 MAPPED-ADDRESS (0x0001) fallback.
/// </summary>
public static class StunClient
{
    public const uint MagicCookie = 0x2112A442;
    public const ushort BindingRequestType = 0x0001;
    public const ushort BindingSuccessResponseType = 0x0101;
    public const ushort AttrMappedAddress = 0x0001;
    public const ushort AttrXorMappedAddress = 0x0020;

    private static readonly (string Host, int Port)[] DefaultServers =
    {
        ("stun.cloudflare.com", 3478),
        ("stun.l.google.com", 19302),
    };

    /// <summary>
    /// Builds a 20-byte RFC 5389 STUN Binding Request with magic cookie 0x2112A442 and 12-byte transaction ID.
    /// </summary>
    public static byte[] BuildBindingRequest(ReadOnlySpan<byte> txId)
    {
        byte[] packet = new byte[20];
        BinaryPrimitives.WriteUInt16BigEndian(packet.AsSpan(0, 2), BindingRequestType);
        BinaryPrimitives.WriteUInt16BigEndian(packet.AsSpan(2, 2), 0);
        BinaryPrimitives.WriteUInt32BigEndian(packet.AsSpan(4, 4), MagicCookie);
        int copyLen = Math.Min(txId.Length, 12);
        if (copyLen > 0)
        {
            txId[..copyLen].CopyTo(packet.AsSpan(8, copyLen));
        }
        return packet;
    }

    /// <summary>
    /// Parses an RFC 5389 STUN Binding Success Response (0x0101), preferring XOR-MAPPED-ADDRESS (0x0020)
    /// and falling back to MAPPED-ADDRESS (0x0001) for IPv4.
    /// </summary>
    public static (string Ip, int Port)? ParseBindingResponse(ReadOnlySpan<byte> data, ReadOnlySpan<byte> expectedTxId)
    {
        if (data.Length < 20 || expectedTxId.Length != 12) return null;

        ushort msgType = BinaryPrimitives.ReadUInt16BigEndian(data.Slice(0, 2));
        if (msgType != BindingSuccessResponseType) return null;

        int msgLen = BinaryPrimitives.ReadUInt16BigEndian(data.Slice(2, 2));
        if (data.Length < 20 + msgLen) return null;

        uint cookie = BinaryPrimitives.ReadUInt32BigEndian(data.Slice(4, 4));
        if (cookie != MagicCookie) return null;

        if (!data.Slice(8, 12).SequenceEqual(expectedTxId)) return null;

        (string Ip, int Port)? fallbackMapped = null;
        int offset = 20;
        int endOffset = 20 + msgLen;

        while (offset + 4 <= endOffset)
        {
            ushort attrType = BinaryPrimitives.ReadUInt16BigEndian(data.Slice(offset, 2));
            int attrLen = BinaryPrimitives.ReadUInt16BigEndian(data.Slice(offset + 2, 2));
            int valStart = offset + 4;
            if (valStart + attrLen > endOffset) break;

            if (attrType == AttrXorMappedAddress && attrLen >= 8)
            {
                byte family = data[valStart + 1];
                if (family == 0x01) // IPv4
                {
                    ushort xPort = BinaryPrimitives.ReadUInt16BigEndian(data.Slice(valStart + 2, 2));
                    int port = xPort ^ (ushort)((MagicCookie >> 16) & 0xFFFF);
                    uint xIp = BinaryPrimitives.ReadUInt32BigEndian(data.Slice(valStart + 4, 4));
                    uint ip = xIp ^ MagicCookie;
                    string ipStr = $"{(ip >> 24) & 0xFF}.{(ip >> 16) & 0xFF}.{(ip >> 8) & 0xFF}.{ip & 0xFF}";
                    return (ipStr, port);
                }
            }
            else if (attrType == AttrMappedAddress && attrLen >= 8 && fallbackMapped == null)
            {
                byte family = data[valStart + 1];
                if (family == 0x01) // IPv4
                {
                    int port = BinaryPrimitives.ReadUInt16BigEndian(data.Slice(valStart + 2, 2));
                    string ipStr = $"{data[valStart + 4]}.{data[valStart + 5]}.{data[valStart + 6]}.{data[valStart + 7]}";
                    fallbackMapped = (ipStr, port);
                }
            }

            int paddedLen = (attrLen + 3) & ~3;
            offset = valStart + paddedLen;
        }

        return fallbackMapped;
    }

    /// <summary>
    /// Probes STUN servers using an existing unconnected UdpClient (or a temporary one if null)
    /// with a 1.5s timeout per server. Returns (Ip, Port) or null on timeout/failure.
    /// </summary>
    public static async Task<(string Ip, int Port)?> DiscoverPublicEndpointAsync(
        UdpClient? existingUdp = null,
        CancellationToken ct = default,
        int timeoutMs = 1500)
    {
        bool ownsSocket = existingUdp == null;
        UdpClient udp = existingUdp ?? new UdpClient(0, AddressFamily.InterNetwork);

        try
        {
            byte[] txId = new byte[12];
            foreach (var (host, port) in DefaultServers)
            {
                if (ct.IsCancellationRequested) return null;

                IPAddress? targetIp = await ResolveIPv4Async(host, ct).ConfigureAwait(false);
                if (targetIp == null) continue;

                RandomNumberGenerator.Fill(txId);
                byte[] request = BuildBindingRequest(txId);
                var remoteEndPoint = new IPEndPoint(targetIp, port);

                try
                {
                    await udp.SendAsync(request, request.Length, remoteEndPoint).ConfigureAwait(false);
                }
                catch
                {
                    continue;
                }

                using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
                timeoutCts.CancelAfter(timeoutMs);

                try
                {
                    while (!timeoutCts.IsCancellationRequested)
                    {
                        UdpReceiveResult res = await udp.ReceiveAsync(timeoutCts.Token).ConfigureAwait(false);
                        var parsed = ParseBindingResponse(res.Buffer, txId);
                        if (parsed.HasValue)
                        {
                            return parsed;
                        }
                    }
                }
                catch (OperationCanceledException) when (!ct.IsCancellationRequested)
                {
                    // Timeout for this STUN server; try next server
                }
                catch (SocketException)
                {
                    // Try next STUN server
                }
                catch (ObjectDisposedException)
                {
                    return null;
                }
            }

            return null;
        }
        finally
        {
            if (ownsSocket)
            {
                try { udp.Close(); } catch { }
                try { udp.Dispose(); } catch { }
            }
        }
    }

    private static async Task<IPAddress?> ResolveIPv4Async(string host, CancellationToken ct)
    {
        try
        {
            if (IPAddress.TryParse(host, out var parsed) && parsed.AddressFamily == AddressFamily.InterNetwork)
            {
                return parsed;
            }
            var addresses = await Dns.GetHostAddressesAsync(host, AddressFamily.InterNetwork, ct).ConfigureAwait(false);
            return addresses.Length > 0 ? addresses[0] : null;
        }
        catch
        {
            return null;
        }
    }
}
