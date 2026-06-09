// P-256 ECDH + AES-256-GCM 端到端加密
// 使用浏览器内置 SubtleCrypto API（Electron Chromium 支持）
//
// 握手流程：
//   Mac → Client : hello { pubkey: "<base64 P-256 uncompressed 65B>" }
//   Client → Mac : crypto_hello { pubkey: "<base64>" }
//   双方推导共享密钥 HKDF-SHA256，之后所有 JSON 消息用 AES-256-GCM 加密
//   加密消息以 0xE0 字节开头作为二进制 WebSocket 帧发送

const SALT     = new TextEncoder().encode('remoter-e2e-v1')
const INFO     = new TextEncoder().encode('aes-256-gcm')
const NONCE_LEN = 12

export class E2ECrypto {
  private privateKey: CryptoKey | null = null
  private publicKey: CryptoKey | null = null
  private symmetricKey: CryptoKey | null = null

  get isReady(): boolean { return this.symmetricKey !== null }

  /** 重置所有密钥状态，在每次新连接前调用 */
  reset(): void {
    this.privateKey   = null
    this.publicKey    = null
    this.symmetricKey = null
  }

  // MARK: - 密钥生成

  async generateKeyPair(): Promise<void> {
    const pair = await crypto.subtle.generateKey(
      { name: 'ECDH', namedCurve: 'P-256' },
      false,  // privateKey 不可导出（安全要求）
      ['deriveKey', 'deriveBits']
    )
    this.privateKey = pair.privateKey
    this.publicKey  = pair.publicKey
  }

  /** 返回 x9.63 格式（0x04 + X + Y）的 Base64，与 CryptoKit 一致 */
  async getPublicKeyBase64(): Promise<string> {
    if (!this.publicKey) throw new Error('Key pair not generated')
    // SubtleCrypto 导出 raw = 65 字节 uncompressed point (与 x9.63 相同)
    const raw = await crypto.subtle.exportKey('raw', this.publicKey)
    return btoa(String.fromCharCode(...new Uint8Array(raw)))
  }

  // MARK: - 密钥协商

  async deriveSharedKey(peerBase64: string): Promise<void> {
    if (!this.privateKey) throw new Error('Key pair not generated')

    const peerBytes = Uint8Array.from(atob(peerBase64), c => c.charCodeAt(0))
    const peerKey   = await crypto.subtle.importKey(
      'raw', peerBytes,
      { name: 'ECDH', namedCurve: 'P-256' },
      false, []
    )

    // ECDH 推导原始共享秘密 (bits)
    const sharedBits = await crypto.subtle.deriveBits(
      { name: 'ECDH', public: peerKey },
      this.privateKey,
      256
    )

    // HKDF-SHA256 → 32 字节 AES-GCM 密钥（与 Swift HKDF 参数完全一致）
    const hkdfKey = await crypto.subtle.importKey(
      'raw', sharedBits,
      { name: 'HKDF' },
      false, ['deriveKey']
    )
    this.symmetricKey = await crypto.subtle.deriveKey(
      {
        name:   'HKDF',
        hash:   'SHA-256',
        salt:   SALT,
        info:   INFO
      },
      hkdfKey,
      { name: 'AES-GCM', length: 256 },
      false,
      ['encrypt', 'decrypt']
    )
  }

  // MARK: - 加密 / 解密

  /** 加密 Uint8Array → [12B nonce][ciphertext+16B GCM tag] */
  async encrypt(plaintext: Uint8Array): Promise<Uint8Array> {
    if (!this.symmetricKey) throw new Error('Symmetric key not ready')
    const nonce = crypto.getRandomValues(new Uint8Array(NONCE_LEN))
    const ct    = await crypto.subtle.encrypt(
      { name: 'AES-GCM', iv: nonce },
      this.symmetricKey,
      plaintext
    )
    const out = new Uint8Array(NONCE_LEN + ct.byteLength)
    out.set(nonce, 0)
    out.set(new Uint8Array(ct), NONCE_LEN)
    return out
  }

  /** 解密 [12B nonce][ciphertext+16B tag] → 原始 Uint8Array */
  async decrypt(ciphertext: Uint8Array): Promise<Uint8Array> {
    if (!this.symmetricKey) throw new Error('Symmetric key not ready')
    if (ciphertext.length < NONCE_LEN + 16) throw new Error('Ciphertext too short')
    const nonce = ciphertext.slice(0, NONCE_LEN)
    const ct    = ciphertext.slice(NONCE_LEN)
    const plain = await crypto.subtle.decrypt(
      { name: 'AES-GCM', iv: nonce },
      this.symmetricKey,
      ct
    )
    return new Uint8Array(plain)
  }

  /** 便捷方法：加密 JSON 对象 → Uint8Array */
  async encryptJson(obj: object): Promise<Uint8Array> {
    const text = JSON.stringify(obj)
    return this.encrypt(new TextEncoder().encode(text))
  }

  /** 便捷方法：解密 → JSON 对象 */
  async decryptJson(ciphertext: Uint8Array): Promise<Record<string, unknown>> {
    const plain = await this.decrypt(ciphertext)
    const text  = new TextDecoder().decode(plain)
    return JSON.parse(text) as Record<string, unknown>
  }
}
