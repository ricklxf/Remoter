import { ConnectParams, ConnectionState, StreamInfo, FileTransfer, DirEntry } from '../types'
import { saveAccount, saveMachineInfo } from '../utils/savedAccounts'
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
  | { type: 'dir_listing'; path: string; entries: DirEntry[] }

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
  private serverOs = ''

  private sendQueue: Promise<void> = Promise.resolve()
  private _inputLogN = 0

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
  private lastClipImgLen = -1

  onEvent:      ((e: ConnEvent) => void)                               | null = null
  onDirListing: ((path: string, entries: DirEntry[]) => void)          | null = null

  // MARK: - 连接 / 断开

  connect(params: ConnectParams): void {
    // 关闭旧连接（清空事件回调，防止 onclose 触发 disconnected 事件）
    if (this.ws) {
      this.ws.onopen    = null
      this.ws.onmessage = null
      this.ws.onclose   = null
      this.ws.onerror   = null
      this.ws.close()
      this.ws = null
    }
    this.stopStats()
    this.stopClipboardSync()
    this.webrtc?.close()
    this.webrtc = null

    this.params = params
    this.e2e.reset()
    this.serverOs = ''
    this.sendQueue = Promise.resolve()
    this._inputLogN = 0
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
      console.log('[Conn] WS open →', url)
      this.emit({ type: 'state', state: 'authenticating' })
      if (params.mode === 'direct') {
        const method = params.authMethod ?? 'pin'
        // PIN is sent immediately (plaintext, low sensitivity)
        // credentials/token are deferred until after E2E (see crypto_ok handler)
        if (method === 'pin') {
          this.sendJson({ type: 'auth', pin: params.pin })
        }
      }
    }
    ws.onmessage = (ev) => {
      if (typeof ev.data === 'string') {
        this.handleText(ev.data)
      } else {
        this.handleBinary(ev.data as ArrayBuffer)
      }
    }
    ws.onclose = (ev) => {
      console.warn(`[WS] closed: code=${ev.code}, reason="${ev.reason}", wasClean=${ev.wasClean}`)
      this.webrtc?.close()
      this.webrtc = null
      this.stopStats()
      this.emit({ type: 'state', state: 'disconnected' })
    }
    ws.onerror = (ev) => {
      console.error('[WS] error event:', ev)
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
    if (this._inputLogN++ < 3) console.log('[Conn] sendMouseMove', x.toFixed(3), y.toFixed(3), 'e2e=', this.e2e.isReady)
    this.sendJson({ type: 'mouse_move', x, y })
  }
  sendMouseButton(button: string, down: boolean, x: number, y: number): void {
    this.sendJson({ type: 'mouse_button', button, down, x, y })
  }

  sendMouseDoubleClick(button: string, x: number, y: number): void {
    this.sendJson({ type: 'mouse_double_click', button, x, y })
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

  sendMute(muted: boolean): void {
    this.sendJson({ type: 'set_muted', muted })
  }

  sendCtrlAltDel(): void {
    this.sendJson({ type: 'ctrl_alt_del' })
  }

  sendSetClipboardSync(enabled: boolean): void {
    this.sendJson({ type: 'set_clipboard_sync', enabled })
  }

  sendSetInputEnabled(enabled: boolean): void {
    this.sendJson({ type: 'set_input_enabled', enabled })
  }

  sendLockScreen(): void {
    this.sendJson({ type: 'lock_screen' })
  }

  sendLogout(): void {
    this.sendJson({ type: 'logout' })
  }

  sendRestart(): void {
    this.sendJson({ type: 'restart' })
  }

  sendListDir(path: string): void {
    this.sendJson({ type: 'list_dir', path })
  }

  sendRequestFile(path: string): void {
    this.sendJson({ type: 'request_file', path })
  }

  sendJson(obj: object): void {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) {
      console.warn('[Conn] sendJson: ws not open, state=', this.ws?.readyState)
      return
    }
    if (this.e2e.isReady) {
      this.sendQueue = this.sendQueue.then(async () => {
        try {
          const ct = await this.e2e.encryptJson(obj)
          const frame = new Uint8Array(1 + ct.length)
          frame[0] = ENCRYPTED_MSG
          frame.set(ct, 1)
          if (this.ws?.readyState === WebSocket.OPEN) this.ws.send(frame.buffer)
        } catch (e) {
          console.warn('[Conn] encrypt/send failed:', e)
        }
      })
    } else {
      try {
        this.ws.send(JSON.stringify(obj))
      } catch (e) {
        console.warn('[Conn] send failed:', e)
      }
    }
  }

  sendBinary(data: ArrayBuffer): void {
    if (this.ws?.readyState === WebSocket.OPEN) this.ws.send(data)
  }

  private sendAuthPlaintext(): void {
    if (!this.params || this.params.mode !== 'direct') return
    const method = this.params.authMethod ?? 'pin'
    if (method === 'credentials') {
      this.ws?.send(JSON.stringify({ type: 'auth_credentials',
        username: this.params.username ?? '',
        password: this.params.password ?? '' }))
    } else if (method === 'token') {
      this.ws?.send(JSON.stringify({ type: 'auth_token', token: this.params.token ?? '' }))
    }
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
        this.serverOs = (msg.os as string | undefined) ?? ''
        if (this.params?.mode === 'direct' && this.params.directUrl) {
          const computerName = (msg.computerName as string | undefined) ?? ''
          const modelId = (msg.modelId as string | undefined) ?? ''
          if (computerName || modelId) {
            saveMachineInfo(this.params.directUrl, { computerName, modelId })
          }
        }
        console.log('[Conn] hello, os=', this.serverOs, 'e2e-avail=', !!(typeof crypto !== 'undefined' && crypto.subtle))
        // crypto.subtle requires a secure context (HTTPS / localhost).
        // On plain HTTP, skip E2E and stay in plaintext mode.
        if (macPubkey && typeof crypto !== 'undefined' && crypto.subtle) {
          this.sendQueue = this.sendQueue.then(async () => {
            try {
              await this.e2e.generateKeyPair()
              await this.e2e.deriveSharedKey(macPubkey)
              const myPub = await this.e2e.getPublicKeyBase64()
              this.ws?.send(JSON.stringify({ type: 'crypto_hello', pubkey: myPub }))
            } catch (e) {
              console.warn('[Conn] E2E failed, falling back to plaintext auth:', e)
              // E2E 失败时直接明文发送，避免凭据认证卡死
              this.sendAuthPlaintext()
            }
          })
        } else {
          // 无 crypto.subtle（非安全上下文），直接明文发送
          this.sendAuthPlaintext()
        }
        break
      }

      case 'crypto_ok': {
        // Send sensitive auth after E2E is ready
        if (this.params?.mode === 'direct') {
          const method = this.params.authMethod ?? 'pin'
          if (method === 'credentials') {
            this.sendJson({ type: 'auth_credentials',
              username: this.params.username ?? '',
              password: this.params.password ?? '' })
          } else if (method === 'token') {
            this.sendJson({ type: 'auth_token', token: this.params.token ?? '' })
          }
        }
        break
      }

      case 'auth_ok':
      case 'connected': {
        // Save token when server returns one (credential auth)
        const token    = msg.token    as string | undefined
        const username = msg.username as string | undefined
        if (token && (username ?? this.params?.username)) {
          const addr = this.params?.directUrl ?? ''
          saveAccount(addr, username ?? this.params?.username ?? '', token)
        }
        console.log('[Conn] auth_ok, serverOs=', this.serverOs, 'skipWebRTC=', this.serverOs === 'Windows')
        this.emit({ type: 'state', state: 'authenticating' })
        // Windows agent 不支持 WebRTC，跳过以避免 ICE candidate 占满 sendQueue
        if (this.serverOs !== 'Windows') {
          this.initiateWebRTC()
        }
        break
      }

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
        const text  = msg.text  as string | undefined
        const image = msg.image as string | undefined
        if (text) {
          this.lastClipText = text
          this.clipWrite(text)
        }
        if (image) {
          this.lastClipImgLen = image.length
          this.clipWriteImage(image)
        }
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

      case 'dir_listing': {
        const dlPath    = msg.path    as string
        const dlEntries = msg.entries as DirEntry[]
        this.emit({ type: 'dir_listing', path: dlPath, entries: dlEntries })
        this.onDirListing?.(dlPath, dlEntries)
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

  private clipRead(): Promise<string> {
    if (window.remoterAPI) return window.remoterAPI.readClipboard()
    return navigator.clipboard.readText()
  }

  private clipWrite(text: string): void {
    if (window.remoterAPI) window.remoterAPI.writeClipboard(text)
    else navigator.clipboard.writeText(text).catch(() => {})
  }

  private async clipReadImage(): Promise<string | null> {
    if (window.remoterAPI?.readClipboardImage) {
      return window.remoterAPI.readClipboardImage()
    }
    try {
      const items = await navigator.clipboard.read()
      for (const item of items) {
        if (item.types.includes('image/png')) {
          const blob = await item.getType('image/png')
          return new Promise<string>((resolve) => {
            const reader = new FileReader()
            reader.onload = () => resolve((reader.result as string).split(',')[1])
            reader.readAsDataURL(blob)
          })
        }
      }
    } catch { /* ignore */ }
    return null
  }

  private clipWriteImage(b64: string): void {
    if (window.remoterAPI?.writeClipboardImage) {
      window.remoterAPI.writeClipboardImage(b64)
      return
    }
    try {
      const bytes = Uint8Array.from(atob(b64), c => c.charCodeAt(0))
      const blob  = new Blob([bytes], { type: 'image/png' })
      navigator.clipboard.write([new ClipboardItem({ 'image/png': blob })]).catch(() => {})
    } catch { /* ignore */ }
  }

  private startClipboardSync(): void {
    if (this.clipTimer) return
    this.clipRead().then(t => { this.lastClipText = t }).catch(() => {})
    this.clipReadImage().then(img => { if (img) this.lastClipImgLen = img.length }).catch(() => {})

    this.clipTimer = setInterval(async () => {
      try {
        const text = await this.clipRead()
        if (text && text !== this.lastClipText) {
          this.lastClipText = text
          this.sendJson({ type: 'clipboard_set', text })
        }
      } catch { /* ignore */ }
      try {
        const img = await this.clipReadImage()
        if (img && img.length !== this.lastClipImgLen) {
          this.lastClipImgLen = img.length
          this.sendJson({ type: 'clipboard_set_image', data: img })
        }
      } catch { /* ignore */ }
    }, 1000)
  }

  private stopClipboardSync(): void {
    if (this.clipTimer) { clearInterval(this.clipTimer); this.clipTimer = null }
  }

  private emit(e: ConnEvent): void {
    this.onEvent?.(e)
  }
}
