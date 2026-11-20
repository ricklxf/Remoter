import Foundation
import CryptoKit

// P-256 ECDH 密钥交换 + AES-256-GCM 消息加密
// 握手流程：
//   Mac → Client : hello { pubkey: "<base64 P-256 uncompressed>" }
//   Client → Mac : crypto_hello { pubkey: "<base64>" }
//   双方推导共享密钥（HKDF-SHA256），之后所有 JSON 消息用 AES-256-GCM 加密
//   加密消息以 0xE0 字节开头作为二进制 WebSocket 帧发送

final class E2ECrypto {
    private let privateKey = P256.KeyAgreement.PrivateKey()
    private var symmetricKey: SymmetricKey?

    var isReady: Bool { symmetricKey != nil }

    /// Mac 的 P-256 公钥（65 字节 x9.63 格式，Base64 编码）
    var publicKeyBase64: String {
        privateKey.publicKey.x963Representation.base64EncodedString()
    }

    /// 收到对端公钥后推导共享对称密钥
    func deriveSharedKey(peerBase64: String) throws {
        guard let peerData = Data(base64Encoded: peerBase64) else {
            throw E2EError.invalidKey
        }
        let peerKey = try P256.KeyAgreement.PublicKey(x963Representation: peerData)
        let shared  = try privateKey.sharedSecretFromKeyAgreement(with: peerKey)
        symmetricKey = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt:       Data("remoter-e2e-v1".utf8),
            sharedInfo: Data("aes-256-gcm".utf8),
            outputByteCount: 32
        )
    }

    // MARK: - Encrypt / Decrypt

    /// 加密任意 Data → [12B nonce][ciphertext][16B GCM tag]
    func encrypt(_ plaintext: Data) throws -> Data {
        guard let key = symmetricKey else { throw E2EError.notReady }
        return try AES.GCM.seal(plaintext, using: key).combined!
    }

    /// 解密 [12B nonce][ciphertext][16B GCM tag] → 原始 Data
    func decrypt(_ ciphertext: Data) throws -> Data {
        guard let key = symmetricKey else { throw E2EError.notReady }
        return try AES.GCM.open(AES.GCM.SealedBox(combined: ciphertext), using: key)
    }
}

enum E2EError: Error {
    case invalidKey, notReady
}
