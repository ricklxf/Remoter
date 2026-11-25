using System;
using System.Buffers.Binary;
using System.Security.Cryptography;

namespace RemoterWin;

/// <summary>
/// Minimal zero-dependency RFC 5389 STUN Binding Request builder &amp; response parser
/// for WAN P2P UDP hole punching. Matches MacServer/MacClient StunClient bit-for-bit.
/// </summary>
static class StunClient
{
    public const int HeaderSize = 20;
    public const int TransactionIdSize = 12;

    private const ushort MsgTypeBindingRequest = 0x0001;
    private const ushort MsgTypeBindingSuccess = 0x0101;
    private const uint MagicCookie = 0x2112A442;

    private const ushort AttrMappedAddress    = 0x0001;
    private const ushort AttrXorMappedAddress = 0x0020;

    public static readonly (string Host, int Port)[] DefaultServers =
    {
        ("stun.cloudflare.com", 3478),
        ("stun.l.google.com", 19302),
    };

    public static byte[] CreateTransactionId() => RandomNumberGenerator.GetBytes(TransactionIdSize);

    public static byte[] BuildBindingRequest(ReadOnlySpan<byte> txId)
    {
        if (txId.Length != TransactionIdSize)
            throw new ArgumentException("STUN transaction ID must be 12 bytes.", nameof(txId));

        var req = new byte[HeaderSize];
        BinaryPrimitives.WriteUInt16BigEndian(req.AsSpan(0, 2), MsgTypeBindingRequest);
        BinaryPrimitives.WriteUInt16BigEndian(req.AsSpan(2, 2), 0); // Message Length = 0
        BinaryPrimitives.WriteUInt32BigEndian(req.AsSpan(4, 4), MagicCookie);
        txId.CopyTo(req.AsSpan(8, TransactionIdSize));
        return req;
    }

    public static bool IsStunSuccessResponse(ReadOnlySpan<byte> buf)
    {
        return buf.Length >= HeaderSize
            && buf[0] == 0x01 && buf[1] == 0x01
            && buf[4] == 0x21 && buf[5] == 0x12 && buf[6] == 0xA4 && buf[7] == 0x42;
    }

    public static bool TryParseBindingResponse(
        ReadOnlySpan<byte> buf,
        ReadOnlySpan<byte> expectedTxId,
        out string ip,
        out int port)
    {
        ip = "";
        port = 0;

        if (!IsStunSuccessResponse(buf)) return false;
        if (expectedTxId.Length == TransactionIdSize &&
            !buf.Slice(8, TransactionIdSize).SequenceEqual(expectedTxId))
        {
            return false;
        }

        int msgLen = BinaryPrimitives.ReadUInt16BigEndian(buf.Slice(2, 2));
        int end = Math.Min(buf.Length, HeaderSize + msgLen);

        string? fallbackIp = null;
        int fallbackPort = 0;

        int offset = HeaderSize;
        while (offset + 4 <= end)
        {
            ushort attrType = BinaryPrimitives.ReadUInt16BigEndian(buf.Slice(offset, 2));
            ushort attrLen = BinaryPrimitives.ReadUInt16BigEndian(buf.Slice(offset + 2, 2));
            offset += 4;
            if (offset + attrLen > end) break;

            if (attrType == AttrXorMappedAddress && attrLen >= 8)
            {
                byte family = buf[offset + 1];
                if (family == 0x01) // IPv4
                {
                    ushort xPort = BinaryPrimitives.ReadUInt16BigEndian(buf.Slice(offset + 2, 2));
                    int p = xPort ^ (int)(MagicCookie >> 16);
                    byte b0 = (byte)(buf[offset + 4] ^ 0x21);
                    byte b1 = (byte)(buf[offset + 5] ^ 0x12);
                    byte b2 = (byte)(buf[offset + 6] ^ 0xA4);
                    byte b3 = (byte)(buf[offset + 7] ^ 0x42);
                    if (p > 0)
                    {
                        ip = $"{b0}.{b1}.{b2}.{b3}";
                        port = p;
                        return true;
                    }
                }
            }
            else if (attrType == AttrMappedAddress && attrLen >= 8 && fallbackIp == null)
            {
                byte family = buf[offset + 1];
                if (family == 0x01) // IPv4
                {
                    int p = BinaryPrimitives.ReadUInt16BigEndian(buf.Slice(offset + 2, 2));
                    if (p > 0)
                    {
                        fallbackIp = $"{buf[offset + 4]}.{buf[offset + 5]}.{buf[offset + 6]}.{buf[offset + 7]}";
                        fallbackPort = p;
                    }
                }
            }

            // Attributes are padded to 4-byte boundaries
            int padded = (attrLen + 3) & ~3;
            offset += padded;
        }

        if (fallbackIp != null && fallbackPort > 0)
        {
            ip = fallbackIp;
            port = fallbackPort;
            return true;
        }

        return false;
    }
}
