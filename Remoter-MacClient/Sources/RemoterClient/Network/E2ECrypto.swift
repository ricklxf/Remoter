import Foundation
import CryptoKit

/// P-256 ECDH key exchange + AES-256-GCM end-to-end encryption.
/// Wire-compatible with Remoter-Mac (CryptoKit), Remoter-Win, and Remoter-WinClient:
/// - Key format : x9.63 uncompressed (65 bytes: 0x04 || X(32B) || Y(32B)), Base64
/// - KDF        : HKDF-SHA256, salt="remoter-e2e-v1", info="aes-256-gcm", 32 bytes
/// - Cipher     : AES-256-GCM, 12-byte nonce, 16-byte tag
/// - Frame      : [12B nonce][ciphertext][16B tag]
public final class E2ECrypto: @unchecked Sendable {
    public enum E2EError: Error, Equatable {
        case invalidKey
        case notReady
        case invalidCiphertext
    }

    private let lock = NSLock()
    private var privateKey: P256.KeyAgreement.PrivateKey?
    private var symmetricKey: SymmetricKey?

    public init() {}

    public var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return symmetricKey != nil
    }

    /// Raw 32-byte AES-256 symmetric key (for direct UDP AES-256-GCM channel).
    public var rawKeyData: Data? {
        lock.lock()
        defer { lock.unlock() }
        guard let key = symmetricKey else { return nil }
        return key.withUnsafeBytes { Data($0) }
    }

    public func reset() {
        lock.lock()
        privateKey = nil
        symmetricKey = nil
        lock.unlock()
    }

    /// Generates a fresh P-256 keypair and returns the 65-byte uncompressed x9.63 public key in Base64.
    public func generateKeyPairAndGetPublicKeyBase64() -> String {
        lock.lock()
        defer { lock.unlock() }
        let key = P256.KeyAgreement.PrivateKey()
        self.privateKey = key
        self.symmetricKey = nil
        return key.publicKey.x963Representation.base64EncodedString()
    }

    /// Derives the shared 256-bit AES-GCM key from the peer's Base64 x9.63 uncompressed P-256 public key.
    public func deriveSharedKey(peerBase64: String) throws {
        guard let peerData = Data(base64Encoded: peerBase64),
              peerData.count == 65,
              peerData.first == 0x04 else {
            throw E2EError.invalidKey
        }
        let peerKey: P256.KeyAgreement.PublicKey
        do {
            peerKey = try P256.KeyAgreement.PublicKey(x963Representation: peerData)
        } catch {
            throw E2EError.invalidKey
        }

        lock.lock()
        defer { lock.unlock() }
        guard let privateKey else {
            throw E2EError.notReady
        }
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peerKey)
        self.symmetricKey = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("remoter-e2e-v1".utf8),
            sharedInfo: Data("aes-256-gcm".utf8),
            outputByteCount: 32
        )
    }

    /// Encrypts plaintext into `[12B nonce][ciphertext][16B GCM tag]`.
    public func encrypt(_ plaintext: Data) throws -> Data {
        let key: SymmetricKey
        lock.lock()
        guard let k = symmetricKey else {
            lock.unlock()
            throw E2EError.notReady
        }
        key = k
        lock.unlock()

        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else {
            throw E2EError.invalidCiphertext
        }
        return combined
    }

    /// Decrypts `[12B nonce][ciphertext][16B GCM tag]` back into plaintext bytes.
    public func decrypt(_ combined: Data) throws -> Data {
        guard combined.count >= 28 else {
            throw E2EError.invalidCiphertext
        }
        let key: SymmetricKey
        lock.lock()
        guard let k = symmetricKey else {
            lock.unlock()
            throw E2EError.notReady
        }
        key = k
        lock.unlock()

        let box = try AES.GCM.SealedBox(combined: combined)
        return try AES.GCM.open(box, using: key)
    }
}
