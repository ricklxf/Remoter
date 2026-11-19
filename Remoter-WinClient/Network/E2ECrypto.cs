using System;
using System.Security.Cryptography;

namespace RemoterWinClient;

/// <summary>
/// P-256 ECDH key exchange + AES-256-GCM end-to-end encryption.
/// Wire-compatible with Remoter-Mac (CryptoKit), Remoter-Win, and Remoter-Client (WebCrypto):
///   Key format : x9.63 uncompressed (65 bytes: 0x04 || X(32B) || Y(32B)), Base64
///   KDF        : HKDF-SHA256, salt="remoter-e2e-v1", info="aes-256-gcm", 32 bytes
///   Cipher     : AES-256-GCM, 12-byte nonce, 16-byte tag
///   Frame      : [12B nonce][ciphertext][16B tag]
/// </summary>
public sealed class E2ECrypto : IDisposable
{
    private readonly object _sync = new();
    private ECDiffieHellman? _ecdh;
    private AesGcm? _aes;
    private bool _disposed;

    public bool IsReady
    {
        get
        {
            lock (_sync)
            {
                return _aes != null;
            }
        }
    }

    public void Reset()
    {
        lock (_sync)
        {
            _aes?.Dispose();
            _aes = null;
            _ecdh?.Dispose();
            _ecdh = null;
        }
    }

    public string GenerateKeyPairAndGetPublicKeyBase64()
    {
        lock (_sync)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            _aes?.Dispose();
            _aes = null;
            _ecdh?.Dispose();
            _ecdh = ECDiffieHellman.Create(ECCurve.NamedCurves.nistP256);

            var p = _ecdh.ExportParameters(includePrivateParameters: false);
            var raw = new byte[65];
            raw[0] = 0x04;
            CopyPad(p.Q.X!, raw, 1, 32);
            CopyPad(p.Q.Y!, raw, 33, 32);
            return Convert.ToBase64String(raw);
        }
    }

    public void DeriveSharedKey(string peerBase64)
    {
        var peerBytes = Convert.FromBase64String(peerBase64);
        if (peerBytes.Length != 65 || peerBytes[0] != 0x04)
            throw new CryptographicException("Invalid peer public key format (expected 65-byte uncompressed P-256 point).");

        var x = peerBytes[1..33];
        var y = peerBytes[33..65];

        lock (_sync)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            if (_ecdh == null)
                throw new InvalidOperationException("Key pair not generated.");

            using var peerKey = ECDiffieHellman.Create(new ECParameters
            {
                Curve = ECCurve.NamedCurves.nistP256,
                Q = new ECPoint { X = x, Y = y },
            });

            var rawSecret = _ecdh.DeriveRawSecretAgreement(peerKey.PublicKey);
            var key = HKDF.DeriveKey(
                hashAlgorithmName: HashAlgorithmName.SHA256,
                ikm: rawSecret,
                outputLength: 32,
                salt: "remoter-e2e-v1"u8.ToArray(),
                info: "aes-256-gcm"u8.ToArray());

            _aes?.Dispose();
            _aes = new AesGcm(key, tagSizeInBytes: 16);
        }
    }

    /// <summary>
    /// Encrypts plaintext into [12B nonce][ciphertext][16B GCM tag].
    /// </summary>
    public byte[] Encrypt(ReadOnlySpan<byte> plaintext)
    {
        var combined = new byte[12 + plaintext.Length + 16];
        var nonce = combined.AsSpan(0, 12);
        var ciphertext = combined.AsSpan(12, plaintext.Length);
        var tag = combined.AsSpan(12 + plaintext.Length, 16);

        RandomNumberGenerator.Fill(nonce);

        lock (_sync)
        {
            if (_aes == null)
                throw new InvalidOperationException("E2E symmetric key not ready.");
            _aes.Encrypt(nonce, plaintext, ciphertext, tag);
        }

        return combined;
    }

    /// <summary>
    /// Decrypts [12B nonce][ciphertext][16B GCM tag] back into plaintext bytes.
    /// </summary>
    public byte[] Decrypt(ReadOnlySpan<byte> combined)
    {
        if (combined.Length < 28)
            throw new ArgumentException("Ciphertext too short for AES-GCM frame.", nameof(combined));

        var nonce = combined[..12];
        var ciphertext = combined[12..^16];
        var tag = combined[^16..];
        var plaintext = new byte[ciphertext.Length];

        lock (_sync)
        {
            if (_aes == null)
                throw new InvalidOperationException("E2E symmetric key not ready.");
            _aes.Decrypt(nonce, ciphertext, tag, plaintext);
        }

        return plaintext;
    }

    public void Dispose()
    {
        lock (_sync)
        {
            if (_disposed) return;
            _disposed = true;
            _aes?.Dispose();
            _aes = null;
            _ecdh?.Dispose();
            _ecdh = null;
        }
    }

    private static void CopyPad(byte[] src, byte[] dst, int offset, int len)
    {
        if (src.Length >= len)
        {
            Buffer.BlockCopy(src, src.Length - len, dst, offset, len);
        }
        else
        {
            int pad = len - src.Length;
            Buffer.BlockCopy(src, 0, dst, offset + pad, src.Length);
        }
    }
}
