import { ConnectParams, ConnectionState, StreamInfo, FileTransfer } from '../types'
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
  | { type: 'error'; message: string }
  | { type: 'stats'; stats: ConnStats }
  | { type: 'file_progress'; transfer: FileTransfer }

const VIDEO_FRAME   = 0x01
const FILE_CHUNK    = 0x02
const ENCRYPTED_MSG = 0xE0

interface DownloadState {
  name: string
  size: number
  chunks: Map<number, ArrayBuffer>
  received: number
  startTime: number
  lastSpeedTime: number
  lastSpeedBytes: number
  speedBps: number
}

export class Connection {
  private ws: WebSocket | null = null
  private webrtc: WebRTCClient | null = null
  private params: ConnectParams | null = null
  private statsTimer: ReturnType<typeof setInterval> | null = null
  private readonly e2e = new E2ECrypto()

  private sendQueue: Promise<void> = Promise.resolve()

  private streamWidth  = 0
  private streamHeight = 0

  private _frameCount  = 0
  private _bytesCount  = 0
  private _rttMs       = 0
  private _pingTs      = 0

  private downloads = new Map<string, DownloadState>()

  // Clipboard auto-sync
  private clipTimer: ReturnType<typeof setInterval> | null = null
  private lastClipText = ''

  onEvent: ((e: ConnEvent) => void) | null = null

  // MARK: - 连接 / 断开

  connect(params: ConnectParams): void {
    this.params = params
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
      this.stopStats()
      this.emit({ type: 'state', state: 'disconnected' })
    }
    ws.onerror = () => {
      this.emit({ type: 'error', message: 'Connection failed' })
      this.emit({ type: 'state', state: 'error' })
    }
  }

  disconnect(): void {
    this.stopStats()
    this.stopClipboardSync()
    this.webrtc?.close()
    this.webrtc = null
    this.ws?.close()
    this.ws = null
    this.downloads.clear()
  }

  // MARK: - 输入事件

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

  sendBinary(data: ArrayBuffer): void {
    if (this.ws?.readyState === WebSocket.OPEN) this.ws.send(data)
  }

  async sendFile(file: File): Promise<void> {
    const id = crypto.randomUUID()
    let lastSpeedTime = Date.now()
    let lastSpeedBytes = 0
    let speedBps = 0

    const emitProgress = (transferred: number, done: boolean) => {
      this.emit({ type: 'file_progress', transfer: {
        id, name: file.name, size: file.size, transferred,
        direction: 'upload', speedBps, done
      }})
    }

    emitProgress(0, false)
    this.sendJson({ type: 'file_start', id, name: file.name, size: file.size })

    const CHUNK = 64 * 1024
    let offset = 0
    while (offset < file.size) {
      const buf  = await file.slice(offset, offset + CHUNK).arrayBuffer()
      const idB  = new TextEncoder().encode(id.padEnd(16, '\0').slice(0, 16))
      const hdr  = new Uint8Array(1 + 16 + 4)
      hdr[0] = FILE_CHUNK
      hdr.set(idB, 1)
      new DataView(hdr.buffer).setUint32(17, offset, false)
      const pkt = new Uint8Array(hdr.length + buf.byteLength)
      pkt.set(hdr)
      pkt.set(new Uint8Array(buf), hdr.length)
      this.sendBinary(pkt.buffer)
      offset += CHUNK

      const now = Date.now()
      const dt = now - lastSpeedTime
      if (dt >= 300) {
        speedBps = ((offset - lastSpeedBytes) / dt) * 1000
        lastSpeedTime = now
        lastSpeedBytes = offset
      }
      emitProgress(Math.min(offset, file.size), false)
      await new Promise(r => setTimeout(r, 0))
    }

    this.sendJson({ type: 'file_end', id })
    emitProgress(file.size, true)
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
    rtc.onDisconnected = () => { console.log('[WebRTC] P2P 断开') }
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

    if (prefix === VIDEO_FRAME && buf.byteLength >= 10) {
      this._frameCount++
      this._bytesCount += buf.byteLength
      const frameId  = view.getUint32(1, false)
      const ptsMs    = view.getUint32(5, false)
      const keyframe = (view.getUint8(9) & 0x01) !== 0
      this.emit({ type: 'video_frame', data: buf.slice(10), frameId, ptsMs, keyframe })
      return
    }

    // 服务端发来的文件块（Mac → 客户端方向）
    if (prefix === FILE_CHUNK && buf.byteLength >= 21) {
      const idData = new Uint8Array(buf, 1, 16)
      const fid = new TextDecoder().decode(idData).replace(/\0/g, '')
      const offset = view.getUint32(17, false) // big-endian
      const chunk = buf.slice(21)
      this.handleDownloadChunk(fid, offset, chunk)
    }
  }

  private handleDownloadChunk(id: string, offset: number, chunk: ArrayBuffer): void {
    const t = this.downloads.get(id)
    if (!t) return
    t.chunks.set(offset, chunk)
    t.received += chunk.byteLength

    const now = Date.now()
    const dt = now - t.lastSpeedTime
    if (dt >= 300) {
      t.speedBps = ((t.received - t.lastSpeedBytes) / dt) * 1000
      t.lastSpeedTime = now
      t.lastSpeedBytes = t.received
    }

    this.emit({ type: 'file_progress', transfer: {
      id, name: t.name, size: t.size, transferred: t.received,
      direction: 'download', speedBps: t.speedBps, done: false
    }})
  }

  private async finishDownload(id: string): Promise<void> {
    const t = this.downloads.get(id)
    if (!t) return
    this.downloads.delete(id)

    const buffer = new Uint8Array(t.size)
    t.chunks.forEach((chunk, offset) => {
      buffer.set(new Uint8Array(chunk), offset)
    })

    this.emit({ type: 'file_progress', transfer: {
      id, name: t.name, size: t.size, transferred: t.size,
      direction: 'download', speedBps: 0, done: true
    }})

    const savePath = await window.remoterAPI?.saveFileDialog(t.name)
    if (savePath) {
      await window.remoterAPI?.saveFile(savePath, buffer)
    }
  }

  private routeMessage(msg: Record<string, unknown>): void {
    switch (msg.type) {

      case 'hello': {
        const macPubkey = msg.pubkey as string | undefined
        if (macPubkey) {
          this.sendQueue = this.sendQueue.then(async () => {
            await this.e2e.generateKeyPair()
            await this.e2e.deriveSharedKey(macPubkey)
            const myPub = await this.e2e.getPublicKeyBase64()
            this.ws?.send(JSON.stringify({ type: 'crypto_hello', pubkey: myPub }))
          })
        }
        break
      }

      case 'crypto_ok':
        break

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
        this.startClipboardSync()
        break
      }

      case 'codec_changed': {
        const codec = msg.codec as VideoCodec
        this.emit({ type: 'codec_changed', codec })
        break
      }

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

      case 'clipboard': {
        const text = msg.text as string
        this.lastClipText = text  // prevent echo on next poll
        navigator.clipboard.writeText(text).catch(() => {})
        break
      }

      // 服务端发起的文件传输（Mac → 客户端）
      case 'file_start': {
        const id   = msg.id   as string
        const name = msg.name as string
        const size = msg.size as number
        this.downloads.set(id, {
          name, size, chunks: new Map(), received: 0,
          startTime: Date.now(), lastSpeedTime: Date.now(), lastSpeedBytes: 0, speedBps: 0
        })
        this.emit({ type: 'file_progress', transfer: {
          id, name, size, transferred: 0, direction: 'download', speedBps: 0, done: false
        }})
        break
      }

      case 'file_end': {
        const id = msg.id as string
        void this.finishDownload(id)
        break
      }

      case 'host_disconnected':
        this.emit({ type: 'state', state: 'disconnected' })
        break
    }
  }

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

  private stopStats(): void {
    if (this.statsTimer) { clearInterval(this.statsTimer); this.statsTimer = null }
  }

  private startClipboardSync(): void {
    if (this.clipTimer) return
    // Seed with current clipboard so we don't send stale content on connect
    navigator.clipboard.readText().then(t => { this.lastClipText = t }).catch(() => {})
    this.clipTimer = setInterval(async () => {
      try {
        const text = await navigator.clipboard.readText()
        if (text && text !== this.lastClipText) {
          this.lastClipText = text
          this.sendJson({ type: 'clipboard_set', text })
        }
      } catch { /* clipboard permission denied */ }
    }, 1000)
  }

  private stopClipboardSync(): void {
    if (this.clipTimer) { clearInterval(this.clipTimer); this.clipTimer = null }
  }

  private emit(e: ConnEvent): void {
    this.onEvent?.(e)
  }
}
