// WebRTC 客户端（作为 Offerer）
// 视频走 RTP 媒体轨道（libwebrtc 原生：抖动缓冲/NACK/PLI/GCC 带宽估计），
// 输入事件走 control DataChannel，控制信令仍走 WebSocket。
// 旧的"视频分片走 DataChannel + 手工重组"路径已删除——新客户端不再创建
// video 通道，旧版被控端检测不到该通道会自动回落 WS 传输，混版本可用。

const STUN_SERVERS: RTCIceServer[] = [
  { urls: 'stun:stun.l.google.com:19302' },
  { urls: 'stun:stun1.l.google.com:19302' }
]

export interface WebRTCConfig {
  iceServers?: RTCIceServer[]   // 可追加 TURN 服务器
}

export interface InboundVideoStats {
  fps: number
  bitrateKbps: number
  decodeMs: number
}

export class WebRTCClient {
  private pc: RTCPeerConnection | null = null
  private controlChannel: RTCDataChannel | null = null
  private videoTrack: MediaStreamTrack | null = null

  // RTP 视频轨道到达（浏览器自行解码渲染，喂给 <video> 元素即可）
  onTrack:        ((stream: MediaStream) => void) | null = null
  onConnected:    (() => void) | null = null
  onDisconnected: (() => void) | null = null
  // 需要把 ICE candidate 发回给被控端（通过 WebSocket）
  onICECandidate: ((json: string) => void) | null = null

  // 上一次 getStats 采样，用于算增量
  private lastStats = { framesDecoded: 0, bytesReceived: 0, totalDecodeTime: 0, at: 0 }

  // MARK: - Offer / Answer

  async createOffer(config: WebRTCConfig = {}): Promise<string> {
    const iceServers = [...STUN_SERVERS, ...(config.iceServers ?? [])]
    const pc = new RTCPeerConnection({ iceServers })
    this.pc = pc

    // 声明只收不发的视频 m-line，被控端 answer 时把它的屏幕轨道挂上来
    pc.addTransceiver('video', { direction: 'recvonly' })

    pc.ontrack = (ev) => {
      if (ev.track.kind !== 'video') return
      this.videoTrack = ev.track
      // Measured via a TEMP DIAGNOSTIC (scroll→rendered-frame): most frames
      // render in well under 100ms, but occasional ones spike to 1000ms+ —
      // classic jitter-buffer behavior (Chrome grows the WebRTC playout
      // buffer to absorb network jitter, which trades latency for
      // resilience). playoutDelayHint asks the browser to target near-zero
      // buffering instead — appropriate here since this is a same-LAN link
      // that doesn't need much jitter tolerance, and low input-to-display
      // latency matters far more for a remote-control session than for a
      // typical video call. Chrome-specific API; unsupported browsers just
      // ignore the assignment.
      const receiver = ev.receiver as RTCRtpReceiver & { playoutDelayHint?: number }
      if (receiver && 'playoutDelayHint' in receiver) receiver.playoutDelayHint = 0
      const stream = ev.streams[0] ?? new MediaStream([ev.track])
      this.onTrack?.(stream)
    }

    // 控制 DataChannel：有序、可靠。输入事件（键鼠）在此通道打开后走这里
    // 而不是 WebSocket —— WS 是 TCP，链路拥塞时输入会排在重传后面（队头
    // 阻塞），SCTP 通道则和视频一样走 UDP 路径。安全性等价：DataChannel 由
    // DTLS 端到端加密（即使经 TURN 中继也是端到端），与 WS 上的 AES-GCM
    // 层保护目标一致。
    this.controlChannel = pc.createDataChannel('control', { ordered: true })
    this.controlChannel.onopen  = () => console.log('[WebRTC] Control channel open')
    this.controlChannel.onclose = () => console.log('[WebRTC] Control channel closed')

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

  get mediaActive(): boolean {
    // No !videoTrack.muted check — that flag is the browser's own "seen an
    // RTP gap" signal and doesn't reliably clear again afterward (observed
    // stuck true following a severe bandwidth dip). Gating stats on it just
    // freezes the fps readout at 0 forever (getInboundVideoStats's fallback,
    // _frameCount, only increments on the legacy WS binary-frame path and
    // never counts RTP frames), even once real frames are flowing again.
    // getInboundVideoStats() already measures actual framesDecoded deltas,
    // so it self-reports 0 correctly during a real stall with no help needed.
    return this.videoTrack?.readyState === 'live'
      && this.pc?.connectionState === 'connected'
  }

  // TEMP DIAGNOSTIC — fps stat stuck at 0 was already traced once to
  // mediaActive's now-removed muted check; this exposes the two conditions
  // still gating it (pc.connectionState, track.readyState) plus
  // iceConnectionState for comparison, so a stuck fps readout can be
  // diagnosed straight from a console.log instead of guessing again.
  debugState(): string {
    return `pcState=${this.pc?.connectionState ?? 'no-pc'} ice=${this.pc?.iceConnectionState ?? 'no-pc'} ` +
      `trackState=${this.videoTrack?.readyState ?? 'no-track'} trackMuted=${this.videoTrack?.muted ?? 'no-track'} ` +
      `mediaActive=${this.mediaActive}`
  }

  get controlOpen(): boolean {
    return this.controlChannel?.readyState === 'open'
  }

  /** Send a control-plane JSON message (input events) over the DataChannel. */
  sendControl(json: string): void {
    if (this.controlChannel?.readyState === 'open') this.controlChannel.send(json)
  }

  /** 从 inbound-rtp 统计里取 fps/码率/解码耗时（增量计算），媒体未活跃返回 null */
  async getInboundVideoStats(): Promise<InboundVideoStats | null> {
    const pc = this.pc
    if (!pc || pc.connectionState !== 'connected') return null
    let s: { framesDecoded?: number; bytesReceived?: number; totalDecodeTime?: number; framesPerSecond?: number } | null = null
    try {
      const report = await pc.getStats()
      for (const entry of report.values()) {
        if (entry.type === 'inbound-rtp' && entry.kind === 'video') { s = entry; break }
      }
    } catch { return null }
    if (!s) return null

    const now = performance.now()
    const prev = this.lastStats
    const frames = (s.framesDecoded ?? 0) - prev.framesDecoded
    const bytes  = (s.bytesReceived ?? 0) - prev.bytesReceived
    const decode = (s.totalDecodeTime ?? 0) - prev.totalDecodeTime
    const dtSec  = prev.at > 0 ? (now - prev.at) / 1000 : 0
    this.lastStats = {
      framesDecoded: s.framesDecoded ?? 0,
      bytesReceived: s.bytesReceived ?? 0,
      totalDecodeTime: s.totalDecodeTime ?? 0,
      at: now,
    }
    if (dtSec <= 0) return null
    return {
      fps: s.framesPerSecond ?? Math.round(frames / dtSec),
      bitrateKbps: Math.round(bytes * 8 / 1000 / dtSec),
      decodeMs: frames > 0 ? Math.round(decode * 1000 / frames) : 0,
    }
  }

  close(): void {
    this.pc?.close()
    this.pc = null
    this.controlChannel = null
    this.videoTrack = null
  }
}
