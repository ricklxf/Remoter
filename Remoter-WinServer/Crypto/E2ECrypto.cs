using System.Security.Cryptography;
using System.Text;

namespace RemoterWin;

// P-256 ECDH key exchange + AES-256-GCM message encryption.
// Protocol identical to Mac agent (CryptoKit) and client (WebCrypto):
//   Key format : x9.63 uncompressed (65 bytes: 0x04 || X || Y), Base64
//   KDF        : HKDF-SHA256, salt="remoter-e2e-v1", info="aes-256-gcm", 32 bytes
//   Cipher     : AES-256-GCM, 12-byte nonce, 16-byte tag
//   Frame      : [12B nonce][ciphertext][16B tag]  (matches CryptoKit AES.GCM.seal().combined)
sealed class E2ECrypto : IDisposable
{
    private readonly ECDiffieHellman _ecdh;
    private byte[]? _key; // 32-byte AES key
    private AesGcm? _aes;

    public bool IsReady => _aes != null;

    public E2ECrypto()
    {
        _ecdh = ECDiffieHellman.Create(ECCurve.NamedCurves.nistP256);
    }

    // Returns base64-encoded x9.63 uncompressed public key (65 bytes)
    public string PublicKeyBase64()
    {
        var p = _ecdh.ExportParameters(includePrivateParameters: false);
        var raw = new byte[65];
        raw[0] = 0x04;
        CopyPad(p.Q.X!, raw, 1, 32);
        CopyPad(p.Q.Y!, raw, 33, 32);
        return Convert.ToBase64String(raw);
    }

    // Derives shared key from peer's base64 x9.63 public key
    public void DeriveSharedKey(string peerBase64)
    {
        var peerBytes = Convert.FromBase64String(peerBase64);
        if (peerBytes.Length != 65 || peerBytes[0] != 0x04)
            throw new CryptographicException("Invalid peer public key format");

        var x = peerBytes[1..33];
        var y = peerBytes[33..65];
        using var peerKey = ECDiffieHellman.Create(new ECParameters
        {
            Curve = ECCurve.NamedCurves.nistP256,
            Q = new ECPoint { X = x, Y = y }
        });

        // Raw ECDH shared secret (X coordinate of the shared point)
        var rawSecret = _ecdh.DeriveRawSecretAgreement(peerKey.PublicKey);

        // HKDF-SHA256 matching Mac's CryptoKit derivation
        _key = HKDF.DeriveKey(
            hashAlgorithmName: HashAlgorithmName.SHA256,
            ikm:               rawSecret,
            outputLength:      32,
            salt:              "remoter-e2e-v1"u8.ToArray(),
            info:              "aes-256-gcm"u8.ToArray()
        );

        _aes?.Dispose();
        _aes = new AesGcm(_key, tagSizeInBytes: 16);
    }

    // Returns [12B nonce][ciphertext][16B GCM tag]
    public byte[] Encrypt(byte[] plaintext)
    {
        if (_aes == null) throw new InvalidOperationException("E2E not ready");
        var nonce      = new byte[12];
        var ciphertext = new byte[plaintext.Length];
        var tag        = new byte[16];
        RandomNumberGenerator.Fill(nonce);
        _aes.Encrypt(nonce, plaintext, ciphertext, tag);

        var combined = new byte[12 + ciphertext.Length + 16];
        Buffer.BlockCopy(nonce,      0, combined, 0,                   12);
        Buffer.BlockCopy(ciphertext, 0, combined, 12,                  ciphertext.Length);
        Buffer.BlockCopy(tag,        0, combined, 12 + ciphertext.Length, 16);
        return combined;
    }

    // Decrypts [12B nonce][ciphertext][16B GCM tag]
    public byte[] Decrypt(byte[] combined)
    {
        if (_aes == null) throw new InvalidOperationException("E2E not ready");
        if (combined.Length < 28) throw new ArgumentException("Too short");
        var nonce      = combined[..12];
        var tag        = combined[^16..];
        var ciphertext = combined[12..^16];
        var plaintext  = new byte[ciphertext.Length];
        _aes.Decrypt(nonce, ciphertext, tag, plaintext);
        return plaintext;
    }

    public void Dispose()
    {
        _ecdh.Dispose();
        _aes?.Dispose();
    }

    // Copy src into dst at offset, right-padding / left-trimming to exactly `len` bytes
    private static void CopyPad(byte[] src, byte[] dst, int offset, int len)
    {
        if (src.Length >= len)
            Buffer.BlockCopy(src, src.Length - len, dst, offset, len);
        else
        {
            int pad = len - src.Length;
            Buffer.BlockCopy(src, 0, dst, offset + pad, src.Length);
        }
    }
}
