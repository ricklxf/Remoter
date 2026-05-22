// Windows 端 WebRTC 客户端（作为 Offerer）
// 视频走 DataChannel（UDP），控制消息保留在 WebSocket

const STUN_SERVERS: RTCIceServer[] = [
  { urls: 'stun:stun.l.google.com:19302' },
  { urls: 'stun:stun1.l.google.com:19302' }
]

// 帧头：1B flags + 4B frameId + 2B chunkIdx + 2B totalChunks = 9B
const CHUNK_HEADER = 9

export interface WebRTCConfig {
  iceServers?: RTCIceServer[]   // 可追加 TURN 服务器
}

export class WebRTCClient {
  private pc: RTCPeerConnection | null = null
  private videoChannel: RTCDataChannel | null = null
  private controlChannel: RTCDataChannel | null = null

  // 收到视频帧时的回调（与 WebSocket 路径共用同一 Decoder）
  onVideoFrame:   ((data: ArrayBuffer, keyframe: boolean) => void) | null = null
  onConnected:    (() => void) | null = null
  onDisconnected: (() => void) | null = null
  // 需要把 ICE candidate 发回给 Mac（通过 WebSocket）
  onICECandidate: ((json: string) => void) | null = null

  // 分片重组缓冲区
  private frameBuffer = new Map<number, {
    chunks: ArrayBuffer[]
    total: number
    received: number
    isKeyframe: boolean
  }>()

  // MARK: - Offer / Answer

  async createOffer(config: WebRTCConfig = {}): Promise<string> {
    const iceServers = [...STUN_SERVERS, ...(config.iceServers ?? [])]
    const pc = new RTCPeerConnection({ iceServers })
    this.pc = pc

    // 视频 DataChannel：无序、不重传（UDP 语义，单帧丢失不阻塞后续帧）
    this.videoChannel = pc.createDataChannel('video', {
      ordered: false,
      maxRetransmits: 0
    })
    this.videoChannel.binaryType = 'arraybuffer'
    this.videoChannel.onmessage = (ev) => this.handleVideoChunk(ev.data as ArrayBuffer)
    this.videoChannel.onopen    = () => console.log('[WebRTC] Video channel open')
    this.videoChannel.onclose   = () => console.log('[WebRTC] Video channel closed')

    // 控制 DataChannel：有序、可靠（备用，当前控制消息仍走 WebSocket）
    this.controlChannel = pc.createDataChannel('control', { ordered: true })

    pc.onicecandidate = (ev) => {
      if (!ev.candidate) return
      const { candidate, sdpMid, sdpMLineIndex } = ev.candidate
      this.onICECandidate?.(JSON.stringify({ candidate, sdpMid, sdpMLineIndex }))
    }

    pc.onconnectionstatechange = () => {
      const s = pc.connectionState
      console.log('[WebRTC] connection state:', s)
      if (s === 'connected')                        this.onConnected?.()
      if (s === 'failed' || s === 'disconnected')   this.onDisconnected?.()
    }

    const offer = await pc.createOffer()
    await pc.setLocalDescription(offer)
    return offer.sdp!
  }

  async handleAnswer(sdp: string): Promise<void> {
    if (!this.pc) return
    await this.pc.setRemoteDescription(new RTCSessionDescription({ type: 'answer', sdp }))
  }

  async addICECandidate(json: string): Promise<void> {
    if (!this.pc) return
    try {
      const init = JSON.parse(json) as RTCIceCandidateInit
      await this.pc.addIceCandidate(new RTCIceCandidate(init))
    } catch (e) {
      console.warn('[WebRTC] addICECandidate error:', e)
    }
  }

  get videoState(): RTCDataChannelState | 'none' {
    return this.videoChannel?.readyState ?? 'none'
  }

  close(): void {
    this.pc?.close()
    this.pc = null
    this.videoChannel = null
    this.controlChannel = null
    this.frameBuffer.clear()
  }

  // MARK: - 分片重组

  private handleVideoChunk(data: ArrayBuffer): void {
    if (data.byteLength < CHUNK_HEADER) return
    const view       = new DataView(data)
    const flags      = view.getUint8(0)
    const frameId    = view.getUint32(1, false)
    const chunkIdx   = view.getUint16(5, false)
    const totalChunks = view.getUint16(7, false)
    const isKeyframe = (flags & 0x01) !== 0
    const payload    = data.slice(CHUNK_HEADER)

    // 单片帧，直接交给解码器
    if (totalChunks === 1) {
      this.onVideoFrame?.(payload, isKeyframe)
      return
    }

    // 多片帧：重组
    if (!this.frameBuffer.has(frameId)) {
      this.frameBuffer.set(frameId, {
        chunks: new Array(totalChunks),
        total: totalChunks,
        received: 0,
        isKeyframe
      })
    }
    const buf = this.frameBuffer.get(frameId)!
    buf.chunks[chunkIdx] = payload
    buf.received++

    if (buf.received === buf.total) {
      const combined = mergeBuffers(buf.chunks)
      this.frameBuffer.delete(frameId)
      // 清理过旧的不完整帧（网络乱序可能导致）
      if (this.frameBuffer.size > 15) {
        const oldest = this.frameBuffer.keys().next().value
        if (oldest !== undefined) this.frameBuffer.delete(oldest)
      }
      this.onVideoFrame?.(combined, buf.isKeyframe)
    }
  }
}

function mergeBuffers(bufs: ArrayBuffer[]): ArrayBuffer {
  const total = bufs.reduce((s, b) => s + b.byteLength, 0)
  const out   = new Uint8Array(total)
  let offset  = 0
  for (const b of bufs) { out.set(new Uint8Array(b), offset); offset += b.byteLength }
  return out.buffer
}
