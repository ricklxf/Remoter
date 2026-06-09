import { ConnectParams, ConnectionState, StreamInfo } from '../types'
import { WebRTCClient } from '../webrtc/WebRTCClient'
import { E2ECrypto } from '../crypto/E2ECrypto'
import { VideoDecoder_, VideoCodec } from '../video/Decoder'

export interface ConnStats {
  fps: number
  rttMs: number
  bitrateKbps: number
  transport: 'UDP' | 'TCP'
}

export type ConnEvent =
  | { type: 'state'; state: ConnectionState }
  | { type: 'stream_started'; info: StreamInfo; codec: VideoCodec }
  | { type: 'video_frame'; data: ArrayBuffer; frameId: number; ptsMs: number; keyframe: boolean }
  | { type: 'codec_changed'; codec: VideoCodec }
  | { type: 'clipboard'; text: string }
  | { type: 'error'; message: string }
  | { type: 'stats'; stats: ConnStats }

const VIDEO_FRAME   = 0x01
const ENCRYPTED_MSG = 0xE0

export class Connection {
  private ws: WebSocket | null = null
  private webrtc: WebRTCClient | null = null
  private params: ConnectParams | null = null
  private statsTimer: ReturnType<typeof setInterval> | null = null
  private readonly e2e = new E2ECrypto()

  // 发送队列：保证加密消息有序（async 链式 Promise）
  private sendQueue: Promise<void> = Promise.resolve()

  // Stream dimensions (needed for codec switch)
  private streamWidth  = 0
  private streamHeight = 0

  // Stats counters (reset every 2s)
  private _frameCount  = 0
  private _bytesCount  = 0
  private _rttMs       = 0
  private _pingTs      = 0

  onEvent: ((e: ConnEvent) => void) | null = null

  // MARK: - 连接 / 断开

  connect(params: ConnectParams): void {
    this.params = params
    // 每次新连接重置 E2E 状态，避免旧加密密钥影响新 Session
    this.e2e.reset()
    this.sendQueue = Promise.resolve()
    this.emit({ type: 'state', state: 'connecting' })

    let url: string
    if (params.mode === 'direct') {
      url = params.directUrl!
    } else {
      const base = params.relayUrl!.replace(/\/$/, '')
      url = `${base}?role=client&session=${params.sessionId}&pin=${encodeURIComponent(params.pin)}`
    }

    const ws = new WebSocket(url)
    ws.binaryType = 'arraybuffer'
    this.ws = ws

    ws.onopen = () => {
      this.emit({ type: 'state', state: 'authenticating' })
      if (params.mode === 'direct') {
        this.sendJson({ type: 'auth', pin: params.pin })
      }
    }
    ws.onmessage = (ev) => {
      if (typeof ev.data === 'string') {
        this.handleText(ev.data)
      } else {
        this.handleBinary(ev.data as ArrayBuffer)
      }
    }
    ws.onclose = () => {
      this.webrtc?.close()
      this.webrtc = null
      this.emit({ type: 'state', state: 'disconnected' })
    }
    ws.onerror = () => {
      this.emit({ type: 'error', message: 'Connection failed' })
      this.emit({ type: 'state', state: 'error' })
    }
  }

  disconnect(): void {
    if (this.statsTimer) { clearInterval(this.statsTimer); this.statsTimer = null }
    this.webrtc?.close()
    this.webrtc = null
    this.ws?.close()
    this.ws = null
  }

  // MARK: - 输入事件（走 WebSocket，控制消息需要可靠性）

  sendMouseMove(x: number, y: number): void {
    this.sendJson({ type: 'mouse_move', x, y })
  }
  sendMouseButton(button: string, down: boolean, x: number, y: number): void {
    this.sendJson({ type: 'mouse_button', button, down, x, y })
  }
  sendMouseScroll(dx: number, dy: number): void {
    this.sendJson({ type: 'mouse_scroll', dx, dy })
  }
  sendKey(code: string, down: boolean, modifiers: string[]): void {
    this.sendJson({ type: 'key', code, down, modifiers })
  }
  sendClipboard(text: string): void {
    this.sendJson({ type: 'clipboard_set', text })
  }
  sendQuality(fps: number, bitrate: number): void {
    this.sendJson({ type: 'quality', fps, bitrate })
  }

  /**
   * 发送 JSON 消息。
   * E2E 握手完成后，所有消息先加密再以 0xE0 二进制帧发出。
   * 通过 sendQueue 保证加密的异步操作有序。
   */
  sendJson(obj: object): void {
    if (this.e2e.isReady) {
      this.sendQueue = this.sendQueue.then(async () => {
        try {
          const ct = await this.e2e.encryptJson(obj)
          const frame = new Uint8Array(1 + ct.length)
          frame[0] = ENCRYPTED_MSG
          frame.set(ct, 1)
          this.ws?.send(frame.buffer)
        } catch (e) {
          console.warn('[Conn] encrypt failed:', e)
        }
      })
    } else {
      this.ws?.send(JSON.stringify(obj))
    }
  }

  /** 发送原始二进制（文件块等，不加密）*/
  sendBinary(data: ArrayBuffer): void {
    if (this.ws?.readyState === WebSocket.OPEN) this.ws.send(data)
  }

  // 文件传输（走 WebSocket 二进制，可靠传输）
  async sendFile(file: File): Promise<void> {
    const id = crypto.randomUUID()
    this.sendJson({ type: 'file_start', id, name: file.name, size: file.size })
    const CHUNK = 64 * 1024
    let offset = 0
    while (offset < file.size) {
      const buf  = await file.slice(offset, offset + CHUNK).arrayBuffer()
      const idB  = new TextEncoder().encode(id.padEnd(16, '\0').slice(0, 16))
      const hdr  = new Uint8Array(1 + 16 + 4)
      hdr[0] = 0x02
      hdr.set(idB, 1)
      new DataView(hdr.buffer).setUint32(17, offset, false)
      const pkt = new Uint8Array(hdr.length + buf.byteLength)
      pkt.set(hdr)
      pkt.set(new Uint8Array(buf), hdr.length)
      this.sendBinary(pkt.buffer)
      offset += CHUNK
      await new Promise(r => setTimeout(r, 0))
    }
    this.sendJson({ type: 'file_end', id })
  }

  // MARK: - WebRTC 信令

  private async initiateWebRTC(): Promise<void> {
    const rtc = new WebRTCClient()
    this.webrtc = rtc

    rtc.onVideoFrame = (data, keyframe, bytes) => {
      this._frameCount++
      this._bytesCount += bytes
      this.emit({ type: 'video_frame', data, frameId: 0, ptsMs: 0, keyframe })
    }
    rtc.onConnected    = () => { console.log('[WebRTC] P2P 连接成功') }
    rtc.onDisconnected = () => { console.log('[WebRTC] P2P 断开，回落到 WebSocket') }
    rtc.onICECandidate = (json) => { this.sendJson({ type: 'webrtc_ice', candidate: json }) }

    const offerSdp = await rtc.createOffer()
    this.sendJson({ type: 'webrtc_offer', sdp: offerSdp })
  }

  // MARK: - 消息处理

  private handleText(text: string): void {
    let msg: Record<string, unknown>
    try { msg = JSON.parse(text) } catch { return }
    this.routeMessage(msg)
  }

  private handleBinary(buf: ArrayBuffer): void {
    const view = new DataView(buf)
    if (buf.byteLength < 1) return
    const prefix = view.getUint8(0)

    // 0xE0 = 服务端发来的加密 JSON
    if (prefix === ENCRYPTED_MSG) {
      const ct = new Uint8Array(buf, 1)
      this.sendQueue = this.sendQueue.then(async () => {
        try {
          const msg = await this.e2e.decryptJson(ct)
          this.routeMessage(msg)
        } catch (e) {
          console.warn('[Conn] decrypt failed:', e)
        }
      })
      return
    }

    // 视频帧（0x01）
    if (prefix === VIDEO_FRAME && buf.byteLength >= 10) {
      this._frameCount++
      this._bytesCount += buf.byteLength
      const frameId  = view.getUint32(1, false)
      const ptsMs    = view.getUint32(5, false)
      const keyframe = (view.getUint8(9) & 0x01) !== 0
      this.emit({ type: 'video_frame', data: buf.slice(10), frameId, ptsMs, keyframe })
    }
  }

  private routeMessage(msg: Record<string, unknown>): void {
    switch (msg.type) {

      // ── hello：发起 E2E 握手，然后做 WebRTC ──────────────────
      case 'hello': {
        const macPubkey = msg.pubkey as string | undefined
        if (macPubkey) {
          this.sendQueue = this.sendQueue.then(async () => {
            await this.e2e.generateKeyPair()
            await this.e2e.deriveSharedKey(macPubkey)
            const myPub = await this.e2e.getPublicKeyBase64()
            // crypto_hello 本身必须明文发出（加密密钥刚推导完成）
            this.ws?.send(JSON.stringify({ type: 'crypto_hello', pubkey: myPub }))
            console.log('[E2E] 握手完成，后续消息已加密')
          })
        }
        break
      }

      case 'crypto_ok':
        // Mac 端确认握手成功（可选）
        break

      // 认证成功后发起 WebRTC 协商
      case 'auth_ok':
      case 'connected':
        this.emit({ type: 'state', state: 'authenticating' })
        this.initiateWebRTC()
        break

      case 'stream_started': {
        this.streamWidth  = msg.width  as number
        this.streamHeight = msg.height as number
        const codec = (msg.codec as VideoCodec | undefined) ?? 'h264'
        this.emit({ type: 'state', state: 'streaming' })
        this.emit({ type: 'stream_started', info: { width: this.streamWidth, height: this.streamHeight }, codec })
        this.startStatsLoop()
        break
      }

      case 'codec_changed': {
        const codec = msg.codec as VideoCodec
        this.emit({ type: 'codec_changed', codec })
        break
      }

      // WebRTC 信令
      case 'webrtc_answer':
        this.webrtc?.handleAnswer(msg.sdp as string)
        break

      case 'webrtc_ice':
        this.webrtc?.addICECandidate(msg.candidate as string)
        break

      case 'error':
        this.emit({ type: 'error', message: (msg.message ?? msg.code) as string })
        this.emit({ type: 'state', state: 'error' })
        break

      case 'pong': {
        if (this._pingTs > 0) {
          this._rttMs  = Date.now() - this._pingTs
          this._pingTs = 0
        }
        break
      }

      case 'clipboard':
        this.emit({ type: 'clipboard', text: msg.text as string })
        break

      case 'host_disconnected':
        this.emit({ type: 'state', state: 'disconnected' })
        break
    }
  }

  // Stats loop：每 2s 上报一次，同时驱动 ABR
  private startStatsLoop(): void {
    if (this.statsTimer) clearInterval(this.statsTimer)
    const INTERVAL = 2000

    this.statsTimer = setInterval(() => {
      const fps         = Math.round(this._frameCount / (INTERVAL / 1000))
      const bitrateKbps = Math.round(this._bytesCount * 8 / INTERVAL)
      const transport   = this.webrtc?.videoState === 'open' ? 'UDP' : 'TCP' as 'UDP' | 'TCP'

      this._pingTs = Date.now()
      this.sendJson({ type: 'ping' })
      this.sendJson({ type: 'client_stats', fps, rtt_ms: this._rttMs })
      this.emit({ type: 'stats', stats: { fps, rttMs: this._rttMs, bitrateKbps, transport } })

      this._frameCount = 0
      this._bytesCount = 0
    }, INTERVAL)
  }

  private emit(e: ConnEvent): void {
    this.onEvent?.(e)
  }
}
