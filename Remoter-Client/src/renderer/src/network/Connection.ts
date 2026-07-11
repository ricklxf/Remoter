import { ConnectParams, ConnectionState, StreamInfo, FileTransfer, DirEntry } from '../types'
import { saveAccount, saveMachineInfo } from '../utils/savedAccounts'
import { WebRTCClient } from '../webrtc/WebRTCClient'
import { E2ECrypto } from '../crypto/E2ECrypto'
import { VideoCodec } from '../video/Decoder'

export interface ConnStats {
  fps: number
  rttMs: number
  bitrateKbps: number
  transport: 'UDP' | 'TCP'
  encodeMs: number   // server-side per-frame encode latency (rides on pong)
  decodeMs: number   // client-side per-frame decode latency
}

export type ConnEvent =
  | { type: 'state'; state: ConnectionState }
  | { type: 'stream_started'; info: StreamInfo; codec: VideoCodec }
  | { type: 'video_frame'; data: ArrayBuffer; frameId: number; ptsMs: number; keyframe: boolean }
  | { type: 'codec_changed'; codec: VideoCodec }
  | { type: 'quality_active'; fps: number; bitrate: number }
  | { type: 'audio_frame'; data: ArrayBuffer }
  | { type: 'cursor_shape'; pngBase64: string; hotX: number; hotY: number }
  | { type: 'media_stream'; stream: MediaStream }
  | { type: 'error'; message: string }
  | { type: 'stats'; stats: ConnStats }
  | { type: 'file_progress'; transfer: FileTransfer }
  | { type: 'dir_listing'; path: string; entries: DirEntry[] }

const VIDEO_FRAME   = 0x01
const FILE_CHUNK    = 0x02
const AUDIO_FRAME   = 0x03
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
  // TURN relay info from the agent's hello message (empty until/unless the
  // agent resolved its public IP) — passed into WebRTCClient.createOffer so
  // P2P can fall back to relay when direct/STUN connectivity fails.
  private turnServers: RTCIceServer[] = []

  private sendQueue: Promise<void> = Promise.resolve()
  private queueGen = 0        // incremented on disconnect to abort stale queue items
  private _lastRecvTs = 0    // timestamp of last received WebSocket message
  private _inputLogN = 0

  private intentionalClose = false
  private wasStreaming = false
  private reconnectCount = 0
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null
  private static readonly MAX_RECONNECTS = 5

  private streamWidth  = 0
  private streamHeight = 0

  private _frameCount  = 0
  private _bytesCount  = 0
  private _rttMs       = 0
  private _encodeMs    = 0
  // RemoteCanvas owns the decoder; it plugs a getter in here so the stats
  // loop can report decode latency without Connection knowing the decoder.
  decodeMsProvider: (() => number) | null = null
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
    this.intentionalClose = false
    this.wasStreaming = false
    this.reconnectCount = 0
    this._openWS(params)
  }

  private _openWS(params: ConnectParams): void {
    if (this.reconnectTimer) { clearTimeout(this.reconnectTimer); this.reconnectTimer = null }

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
    this.queueGen++                       // invalidate any stale queue items from prior connection
    this.sendQueue = Promise.resolve()
    this._lastRecvTs = Date.now()
    this._inputLogN = 0
    if (this.reconnectCount === 0) {
      this.emit({ type: 'state', state: 'connecting' })
    }

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
      this._lastRecvTs = Date.now()
      if (typeof ev.data === 'string') {
        this.handleText(ev.data)
      } else {
        this.handleBinary(ev.data as ArrayBuffer)
      }
    }
    ws.onclose = (ev) => {
      console.warn(`[WS] closed: code=${ev.code}, reason="${ev.reason}", wasClean=${ev.wasClean}`)
      this.queueGen++                     // abort any pending queue items — they must not alter state
      this.webrtc?.close()
      this.webrtc = null
      this.stopStats()
      this.stopClipboardSync()

      const canReconnect = !this.intentionalClose
        && this.wasStreaming
        && this.params !== null
        && this.reconnectCount < Connection.MAX_RECONNECTS
      if (canReconnect) {
        this.reconnectCount++
        const delay = Math.min(500 * Math.pow(2, this.reconnectCount - 1), 5000)
        console.log(`[WS] reconnecting in ${delay}ms (attempt ${this.reconnectCount}/${Connection.MAX_RECONNECTS})`)
        this.emit({ type: 'state', state: 'reconnecting' })
        this.reconnectTimer = setTimeout(() => {
          if (!this.intentionalClose && this.params) this._openWS(this.params)
        }, delay)
      } else {
        this.emit({ type: 'state', state: 'disconnected' })
      }
    }
    ws.onerror = (ev) => {
      console.error('[WS] error event:', ev)
      this.emit({ type: 'error', message: 'Connection failed' })
      this.emit({ type: 'state', state: 'error' })
    }
  }

  disconnect(): void {
    this.intentionalClose = true
    this.wasStreaming = false
    this.reconnectCount = 0
    if (this.reconnectTimer) { clearTimeout(this.reconnectTimer); this.reconnectTimer = null }
    if (this.webrtcRestartTimer) { clearTimeout(this.webrtcRestartTimer); this.webrtcRestartTimer = null }
    this.webrtcRestartAttempts = 0
    this.stopStats()
    this.stopClipboardSync()
    this.webrtc?.close()
    this.webrtc = null
    this.ws?.close()
    this.ws = null
    this.downloads.clear()
  }

  // MARK: - 输入事件

  sendMouseMove(x: number, y: number, dragging?: string): void {
    if (this._inputLogN++ < 3) console.log('[Conn] sendMouseMove', x.toFixed(3), y.toFixed(3), 'e2e=', this.e2e.isReady)
    this.sendJson(dragging ? { type: 'mouse_move', x, y, dragging } : { type: 'mouse_move', x, y })
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
  sendFps(fps: number, auto = false): void {
    this.sendJson({ type: 'fps', fps, auto })
  }
  sendBitrate(bitrate: number, auto = false): void {
    this.sendJson({ type: 'bitrate', bitrate, auto })
  }
  sendResolution(tier: '1080' | '2k'): void {
    this.sendJson({ type: 'resolution', tier })
  }
  sendSetAudio(enabled: boolean): void {
    this.sendJson({ type: 'set_audio', enabled })
  }
  /** IME-composed text (e.g. Chinese) — injected remotely as a unicode string, not raw keys. */
  sendTextInput(text: string): void {
    this.sendJson({ type: 'text_input', text })
  }
  sendSetDisplay(id: number): void {
    this.sendJson({ type: 'display', id })
  }

  // Forces the encoder to emit a keyframe right away instead of waiting for
  // its next scheduled one (up to 2s) — call whenever a fresh decoder
  // attaches (e.g. switching back to a tab) so it isn't stuck on a black
  // screen until the interval comes around on its own.
  sendRequestKeyframe(): void {
    this.sendJson({ type: 'request_keyframe' })
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

  sendSetCodec(codec: string): void {
    this.sendJson({ type: 'set_codec', codec })
  }

  sendJson(obj: object): void {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) {
      console.warn('[Conn] sendJson: ws not open, state=', this.ws?.readyState)
      return
    }
    if ((obj as { type?: string }).type === 'mouse_move') {
      // mouse_move is high-frequency and only the latest position matters —
      // queueing every single one behind the previous one's async encrypt+
      // send lets the backlog grow unbounded while the mouse is moving, and
      // anything sent after (e.g. a keypress) inherits that whole backlog
      // instead of going out promptly. Cap it at one in-flight slot: newer
      // positions just overwrite the pending one instead of queueing again.
      this.pendingMouseMove = obj
      if (this.mouseMoveInFlight) return
      this.mouseMoveInFlight = true
      this.enqueueSend(() => {
        const latest = this.pendingMouseMove!
        this.pendingMouseMove = null
        this.mouseMoveInFlight = false
        return latest
      })
      return
    }
    if ((obj as { type?: string }).type === 'mouse_scroll') {
      // Same backlog risk as mouse_move (a trackpad scroll gesture can fire
      // far more often than 120Hz) — but unlike position, intermediate
      // deltas matter and must accumulate rather than be discarded.
      const o = obj as { dx: number; dy: number }
      if (this.pendingScroll) {
        this.pendingScroll.dx += o.dx
        this.pendingScroll.dy += o.dy
      } else {
        this.pendingScroll = { dx: o.dx, dy: o.dy }
      }
      if (this.scrollInFlight) return
      this.scrollInFlight = true
      this.enqueueSend(() => {
        const latest = this.pendingScroll!
        this.pendingScroll = null
        this.scrollInFlight = false
        return { type: 'mouse_scroll', dx: latest.dx, dy: latest.dy }
      })
      return
    }
    this.enqueueSend(() => obj)
  }

  private pendingMouseMove: object | null = null
  private mouseMoveInFlight = false
  private pendingScroll: { dx: number; dy: number } | null = null
  private scrollInFlight = false

  // Input events prefer the WebRTC control DataChannel once it's open: the
  // WS path is TCP, so during congestion a keypress queues behind whatever
  // retransmits are in flight (head-of-line blocking) — the SCTP channel
  // rides the same UDP path as video instead. Security is equivalent: the
  // DataChannel is DTLS-encrypted end-to-end (even through a TURN relay),
  // which covers the same threat the WS AES-GCM layer exists for. Decided
  // per message at send time so a mid-session ICE failure falls back to WS
  // transparently, same as the video path.
  private static readonly INPUT_TYPES = new Set([
    'mouse_move', 'mouse_button', 'mouse_double_click', 'mouse_scroll', 'key', 'text_input',
  ])

  private trySendViaControlChannel(obj: object): boolean {
    const type = (obj as { type?: string }).type
    if (!type || !Connection.INPUT_TYPES.has(type)) return false
    if (!this.webrtc?.controlOpen) return false
    this.webrtc.sendControl(JSON.stringify(obj))
    return true
  }

  private enqueueSend(getObj: () => object): void {
    if (this.e2e.isReady) {
      const gen = this.queueGen
      this.sendQueue = this.sendQueue.then(async () => {
        if (this.queueGen !== gen) return
        try {
          const obj = getObj()
          if (this.trySendViaControlChannel(obj)) return
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
        const obj = getObj()
        if (this.trySendViaControlChannel(obj)) return
        this.ws!.send(JSON.stringify(obj))
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

  private webrtcRestartTimer: ReturnType<typeof setTimeout> | null = null
  private webrtcRestartAttempts = 0

  private async initiateWebRTC(): Promise<void> {
    const rtc = new WebRTCClient()
    this.webrtc = rtc

    rtc.onTrack = (stream) => {
      console.log('[WebRTC] video track arrived')
      this.emit({ type: 'media_stream', stream })
    }
    rtc.onConnected    = () => {
      console.log('[WebRTC] P2P 连接成功')
      this.webrtcRestartAttempts = 0
    }
    // ICE failure while the WS signaling link is still alive (network roam,
    // NAT rebind, AP switch): video already falls back to WS per-frame, so
    // nothing is lost — renegotiate a fresh peer connection in the
    // background to get the UDP path back, with backoff so a genuinely
    // unreachable path doesn't loop forever (WS keeps carrying everything).
    rtc.onDisconnected = () => {
      console.log('[WebRTC] P2P 断开')
      if (this.intentionalClose || this.webrtc !== rtc) return
      if (this.ws?.readyState !== WebSocket.OPEN) return  // WS reconnect flow re-creates WebRTC itself
      if (this.webrtcRestartAttempts >= 3) {
        console.warn('[WebRTC] renegotiation given up after 3 attempts — staying on WS transport')
        return
      }
      this.webrtcRestartAttempts++
      const delay = 2000 * this.webrtcRestartAttempts
      console.log(`[WebRTC] renegotiating in ${delay}ms (attempt ${this.webrtcRestartAttempts}/3)`)
      if (this.webrtcRestartTimer) clearTimeout(this.webrtcRestartTimer)
      this.webrtcRestartTimer = setTimeout(() => {
        this.webrtcRestartTimer = null
        if (this.intentionalClose || this.ws?.readyState !== WebSocket.OPEN) return
        this.webrtc?.close()
        this.initiateWebRTC().catch(e => console.warn('[WebRTC] renegotiation failed:', e))
      }, delay)
    }
    rtc.onICECandidate = (json) => { this.sendJson({ type: 'webrtc_ice', candidate: json }) }

    const offerSdp = await rtc.createOffer({ iceServers: this.turnServers })
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
      const gen = this.queueGen
      this.sendQueue = this.sendQueue.then(async () => {
        if (this.queueGen !== gen) return
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

    if (prefix === AUDIO_FRAME && buf.byteLength > 1) {
      this.emit({ type: 'audio_frame', data: buf.slice(1) })
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
        const turn = msg.turn as { urls: string[]; username: string; credential: string } | undefined
        this.turnServers = turn ? [{ urls: turn.urls, username: turn.username, credential: turn.credential }] : []
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
        if (token && (username ?? this.params?.username) && this.params?.rememberDevice) {
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
        this.wasStreaming = true
        this.reconnectCount = 0
        this.streamWidth  = msg.width  as number
        this.streamHeight = msg.height as number
        const codec = (msg.codec as VideoCodec | undefined) ?? 'h264'
        this.emit({ type: 'state', state: 'streaming' })
        this.emit({ type: 'stream_started', info: {
          width: this.streamWidth,
          height: this.streamHeight,
          displays: msg.displays as StreamInfo['displays'],
          display: msg.display as number | undefined,
        }, codec })
        this.startStatsLoop()
        this.startClipboardSync()
        break
      }

      case 'codec_changed': {
        const codec = msg.codec as VideoCodec
        this.emit({ type: 'codec_changed', codec })
        break
      }

      case 'quality_active': {
        const fps = msg.fps as number
        const bitrate = msg.bitrate as number
        this.emit({ type: 'quality_active', fps, bitrate })
        break
      }

      case 'cursor_shape': {
        this.emit({
          type: 'cursor_shape',
          pngBase64: msg.png as string,
          hotX: (msg.hot_x as number) ?? 0,
          hotY: (msg.hot_y as number) ?? 0,
        })
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
        this._encodeMs = (msg.encode_ms as number) ?? 0
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
    const STALE_TIMEOUT = 6000   // no data for 6s → assume connection is dead (WireGuard renegotiation ~2s)

    this.statsTimer = setInterval(async () => {
      // Detect stale connection: server crashed / TCP hung without a clean close
      if (this._lastRecvTs > 0 && Date.now() - this._lastRecvTs > STALE_TIMEOUT) {
        console.warn('[Conn] no data received for 15s — closing stale connection')
        this.ws?.close(4001, 'stale connection')
        return
      }

      // RTP path: numbers come from the browser's own inbound-rtp stats
      // (frames actually decoded, decode time, received bytes). Fallback
      // path: locally-counted WS/WebCodecs figures, same as before.
      const rtp = this.webrtc?.mediaActive ? await this.webrtc.getInboundVideoStats() : null
      const fps         = rtp ? rtp.fps         : Math.round(this._frameCount / (INTERVAL / 1000))
      const bitrateKbps = rtp ? rtp.bitrateKbps : Math.round(this._bytesCount * 8 / INTERVAL)
      const decodeMs    = rtp ? rtp.decodeMs    : Math.round(this.decodeMsProvider?.() ?? 0)
      const transport   = this.webrtc?.mediaActive ? 'UDP' : 'TCP' as 'UDP' | 'TCP'

      this._pingTs = Date.now()
      this.sendJson({ type: 'ping' })
      this.sendJson({ type: 'client_stats', fps, rtt_ms: this._rttMs })
      this.emit({ type: 'stats', stats: {
        fps, rttMs: this._rttMs, bitrateKbps, transport,
        encodeMs: this._encodeMs,
        decodeMs,
      } })

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
