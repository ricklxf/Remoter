import { ConnectParams, ConnectionState, StreamInfo } from '../types'
import { WebRTCClient } from '../webrtc/WebRTCClient'

export type ConnEvent =
  | { type: 'state'; state: ConnectionState }
  | { type: 'stream_started'; info: StreamInfo }
  | { type: 'video_frame'; data: ArrayBuffer; frameId: number; ptsMs: number; keyframe: boolean }
  | { type: 'clipboard'; text: string }
  | { type: 'error'; message: string }

const VIDEO_FRAME = 0x01

export class Connection {
  private ws: WebSocket | null = null
  private webrtc: WebRTCClient | null = null
  private params: ConnectParams | null = null

  onEvent: ((e: ConnEvent) => void) | null = null

  // MARK: - 连接 / 断开

  connect(params: ConnectParams): void {
    this.params = params
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
      if (typeof ev.data === 'string') this.handleText(ev.data)
      else this.handleBinary(ev.data as ArrayBuffer)
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

  sendJson(obj: object): void {
    if (this.ws?.readyState === WebSocket.OPEN) this.ws.send(JSON.stringify(obj))
  }
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
      const buf   = await file.slice(offset, offset + CHUNK).arrayBuffer()
      const idB   = new TextEncoder().encode(id.padEnd(16, '\0').slice(0, 16))
      const hdr   = new Uint8Array(1 + 16 + 4)
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

  // MARK: - WebRTC 信令（通过 WebSocket 中转 SDP / ICE）

  private async initiateWebRTC(): Promise<void> {
    const rtc = new WebRTCClient()
    this.webrtc = rtc

    // 收到视频帧 → 和 WebSocket 视频帧走同一个事件
    rtc.onVideoFrame = (data, keyframe) => {
      this.emit({ type: 'video_frame', data, frameId: 0, ptsMs: 0, keyframe })
    }

    rtc.onConnected = () => {
      console.log('[WebRTC] P2P 连接成功，视频切换到 DataChannel (UDP)')
    }

    rtc.onDisconnected = () => {
      console.log('[WebRTC] P2P 断开，视频回落到 WebSocket (TCP)')
    }

    // ICE candidate 通过 WebSocket 转发给 Mac
    rtc.onICECandidate = (json) => {
      this.sendJson({ type: 'webrtc_ice', candidate: json })
    }

    const offerSdp = await rtc.createOffer()
    this.sendJson({ type: 'webrtc_offer', sdp: offerSdp })
  }

  // MARK: - 消息处理

  private handleText(text: string): void {
    let msg: Record<string, unknown>
    try { msg = JSON.parse(text) } catch { return }

    switch (msg.type) {
      // 认证成功后发起 WebRTC 协商
      case 'auth_ok':
      case 'connected':
        this.emit({ type: 'state', state: 'authenticating' })
        this.initiateWebRTC()
        break

      case 'stream_started':
        this.emit({ type: 'state', state: 'streaming' })
        this.emit({
          type: 'stream_started',
          info: { width: msg.width as number, height: msg.height as number }
        })
        break

      // WebRTC 信令：Mac → Windows
      case 'webrtc_answer':
        this.webrtc?.handleAnswer(msg.sdp as string)
        break

      case 'webrtc_ice':
        this.webrtc?.addICECandidate(msg.candidate as string)
        break

      case 'error':
        this.emit({ type: 'error', message: (msg.message ?? msg.code) as string })
        break

      case 'clipboard':
        this.emit({ type: 'clipboard', text: msg.text as string })
        break

      case 'host_disconnected':
        this.emit({ type: 'state', state: 'disconnected' })
        break
    }
  }

  // WebSocket 视频帧（WebRTC 未就绪时的 fallback）
  private handleBinary(buf: ArrayBuffer): void {
    if (buf.byteLength < 10) return
    const view      = new DataView(buf)
    const frameType = view.getUint8(0)
    if (frameType !== VIDEO_FRAME) return

    const frameId  = view.getUint32(1, false)
    const ptsMs    = view.getUint32(5, false)
    const keyframe = (view.getUint8(9) & 0x01) !== 0
    const payload  = buf.slice(10)
    this.emit({ type: 'video_frame', data: payload, frameId, ptsMs, keyframe })
  }

  private emit(e: ConnEvent): void {
    this.onEvent?.(e)
  }
}
