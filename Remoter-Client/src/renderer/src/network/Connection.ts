import { ConnectParams, ConnectionState, StreamInfo } from '../types'

export type ConnEvent =
  | { type: 'state'; state: ConnectionState }
  | { type: 'stream_started'; info: StreamInfo }
  | { type: 'video_frame'; data: ArrayBuffer; frameId: number; ptsMs: number; keyframe: boolean }
  | { type: 'clipboard'; text: string }
  | { type: 'error'; message: string }

const VIDEO_FRAME = 0x01

export class Connection {
  private ws: WebSocket | null = null
  private params: ConnectParams | null = null
  onEvent: ((e: ConnEvent) => void) | null = null

  connect(params: ConnectParams): void {
    this.params = params
    this.emit({ type: 'state', state: 'connecting' })

    let url: string
    if (params.mode === 'direct') {
      url = params.directUrl!
    } else {
      // relay: ws://relay-host/path?role=client&session=XXX&pin=YYY
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
      // relay auth is done via query params during connect
    }

    ws.onmessage = (ev) => {
      if (typeof ev.data === 'string') {
        this.handleText(ev.data)
      } else {
        this.handleBinary(ev.data as ArrayBuffer)
      }
    }

    ws.onclose = () => {
      this.emit({ type: 'state', state: 'disconnected' })
    }

    ws.onerror = () => {
      this.emit({ type: 'error', message: 'Connection failed' })
      this.emit({ type: 'state', state: 'error' })
    }
  }

  disconnect(): void {
    this.ws?.close()
    this.ws = null
  }

  sendJson(obj: object): void {
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify(obj))
    }
  }

  sendBinary(data: ArrayBuffer): void {
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(data)
    }
  }

  // Input helpers
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

  // File transfer: send file in chunks via binary frames
  async sendFile(file: File): Promise<void> {
    const id = crypto.randomUUID()
    this.sendJson({ type: 'file_start', id, name: file.name, size: file.size })

    const CHUNK = 64 * 1024
    let offset = 0
    while (offset < file.size) {
      const slice = file.slice(offset, offset + CHUNK)
      const buf = await slice.arrayBuffer()

      // [0x02][16B id padded][4B offset BE][data]
      const idBytes = new TextEncoder().encode(id.padEnd(16, '\0').slice(0, 16))
      const header = new Uint8Array(1 + 16 + 4)
      header[0] = 0x02
      header.set(idBytes, 1)
      new DataView(header.buffer).setUint32(17, offset, false)
      const packet = new Uint8Array(header.length + buf.byteLength)
      packet.set(header)
      packet.set(new Uint8Array(buf), header.length)

      this.sendBinary(packet.buffer)
      offset += CHUNK
      // throttle to ~100MB/s to avoid overwhelming the channel
      await new Promise(r => setTimeout(r, 0))
    }
    this.sendJson({ type: 'file_end', id })
  }

  // MARK: - Private

  private handleText(text: string): void {
    let msg: Record<string, unknown>
    try { msg = JSON.parse(text) } catch { return }

    switch (msg.type) {
      case 'auth_ok':
      case 'connected':
        this.emit({ type: 'state', state: 'authenticating' })
        break
      case 'stream_started':
        this.emit({ type: 'state', state: 'streaming' })
        this.emit({
          type: 'stream_started',
          info: { width: msg.width as number, height: msg.height as number }
        })
        break
      case 'error':
        this.emit({ type: 'error', message: msg.message as string ?? msg.code as string })
        break
      case 'clipboard':
        this.emit({ type: 'clipboard', text: msg.text as string })
        break
      case 'host_disconnected':
        this.emit({ type: 'state', state: 'disconnected' })
        break
    }
  }

  private handleBinary(buf: ArrayBuffer): void {
    if (buf.byteLength < 10) return
    const view = new DataView(buf)
    const frameType = view.getUint8(0)

    if (frameType === VIDEO_FRAME) {
      const frameId = view.getUint32(1, false)
      const ptsMs   = view.getUint32(5, false)
      const flags   = view.getUint8(9)
      const keyframe = (flags & 0x01) !== 0
      const payload = buf.slice(10)
      this.emit({ type: 'video_frame', data: payload, frameId, ptsMs, keyframe })
    }
  }

  private emit(e: ConnEvent): void {
    this.onEvent?.(e)
  }
}
