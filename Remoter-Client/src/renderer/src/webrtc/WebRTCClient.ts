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
  preferredCodec?: 'h264' | 'h265'
}

import type { VideoCodec } from '../video/Decoder'

export interface InboundVideoStats {
  fps: number
  bitrateKbps: number
  decodeMs: number
  codec?: VideoCodec
  isHardwareDecoded?: boolean
}

const PLAYOUT_DELAY_EXT_URI = 'http://www.webrtc.org/experiments/rtp-hdrext/playout-delay'

type LowLatencyRtpReceiver = RTCRtpReceiver & {
  playoutDelayHint?: number
  jitterBufferTarget?: number | null
}

type HeaderExtTransceiver = RTCRtpTransceiver & {
  getHeaderExtensionsToNegotiate?: () => Array<{ uri: string; direction: RTCRtpTransceiverDirection }>
  setHeaderExtensionsToNegotiate?: (exts: Array<{ uri: string; direction: RTCRtpTransceiverDirection }>) => void
}

export class WebRTCClient {
  private pc: RTCPeerConnection | null = null
  private controlChannel: RTCDataChannel | null = null
  private videoTrack: MediaStreamTrack | null = null
  private videoReceiver: LowLatencyRtpReceiver | null = null
  private firstFrameJitterReset = false

  // RTP 视频轨道到达（浏览器自行解码渲染，喂给 <video> 元素即可）
  onTrack:        ((stream: MediaStream) => void) | null = null
  onConnected:    (() => void) | null = null
  onDisconnected: (() => void) | null = null
  // 需要把 ICE candidate 发回给被控端（通过 WebSocket）
  onICECandidate: ((json: string) => void) | null = null

  // 上一次 getStats 采样，用于算增量
  private lastStats = { framesDecoded: 0, bytesReceived: 0, totalDecodeTime: 0, at: 0 }

  static isH265Supported(): boolean {
    try {
      const codecs = RTCRtpReceiver.getCapabilities?.('video')?.codecs
      if (!codecs || codecs.length === 0) return false
      return codecs.some((c) => {
        const mime = c.mimeType.toLowerCase()
        return mime === 'video/h265' || mime === 'video/hevc'
      })
    } catch {
      return false
    }
  }

  // MARK: - Offer / Answer

  async createOffer(config: WebRTCConfig = {}): Promise<string> {
    const iceServers = [...STUN_SERVERS, ...(config.iceServers ?? [])]
    const pc = new RTCPeerConnection({ iceServers })
    this.pc = pc

    // 声明只收不发的视频 m-line，被控端 answer 时把它的屏幕轨道挂上来
    const transceiver = pc.addTransceiver('video', { direction: 'recvonly' })
    this.applyCodecPreferences(transceiver, config.preferredCodec)
    this.ensurePlayoutDelayNegotiated(transceiver)

    pc.ontrack = (ev) => {
      if (ev.track.kind !== 'video') return
      this.videoTrack = ev.track
      this.videoReceiver = ev.receiver as LowLatencyRtpReceiver
      this.firstFrameJitterReset = false
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
      // The hint alone wasn't enough: client_rx still showed the jitter
      // buffer holding 200-400ms with network jitter down at 6-15ms.
      // jitterBufferTarget is the standard knob for the same thing.
      this.applyZeroJitterBuffer(ev.receiver)
      // Chromium can reset jitterBufferTarget on track unmute / SSRC switch —
      // re-apply both hints whenever the track unmutes as well.
      ev.track.addEventListener('unmute', () => {
        this.applyZeroJitterBuffer(ev.receiver)
      })
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
    if (offer.sdp) {
      const patchedSdp = this.ensurePlayoutDelayHeaderExtension(offer.sdp)
      if (patchedSdp !== offer.sdp) {
        try {
          await pc.setLocalDescription({ type: offer.type, sdp: patchedSdp })
          return pc.localDescription?.sdp ?? patchedSdp
        } catch (e) {
          console.warn('[WebRTC] playout-delay SDP patch rejected, using default offer:', e)
        }
      }
    }
    await pc.setLocalDescription(offer)
    return pc.localDescription?.sdp ?? offer.sdp!
  }

  private applyZeroJitterBuffer(receiver?: RTCRtpReceiver | null): void {
    const r = (receiver ?? this.videoReceiver) as LowLatencyRtpReceiver | null
    if (!r) return
    if ('playoutDelayHint' in r) r.playoutDelayHint = 0
    if ('jitterBufferTarget' in r) r.jitterBufferTarget = 0
  }

  /** Re-assert 0ms jitter buffer targets if Chromium reset them after ICE/SSRC recovery. */
  private reassertZeroJitterBufferIfDrifted(): void {
    const r = this.videoReceiver
    if (!r) return
    let drifted = false
    if ('playoutDelayHint' in r && r.playoutDelayHint !== 0) {
      r.playoutDelayHint = 0
      drifted = true
    }
    if ('jitterBufferTarget' in r && r.jitterBufferTarget !== 0) {
      r.jitterBufferTarget = 0
      drifted = true
    }
    if (drifted) {
      console.log('[WebRTC] re-asserted playoutDelayHint=0 and jitterBufferTarget=0 after drift')
    }
  }

  private ensurePlayoutDelayNegotiated(transceiver: RTCRtpTransceiver): void {
    try {
      const extTransceiver = transceiver as HeaderExtTransceiver
      if (
        typeof extTransceiver.getHeaderExtensionsToNegotiate !== 'function' ||
        typeof extTransceiver.setHeaderExtensionsToNegotiate !== 'function'
      ) {
        return
      }
      const exts = extTransceiver.getHeaderExtensionsToNegotiate()
      let changed = false
      const updated = exts.map((ext) => {
        if (
          ext.uri === PLAYOUT_DELAY_EXT_URI &&
          ext.direction !== 'recvonly' &&
          ext.direction !== 'sendrecv'
        ) {
          changed = true
          return { ...ext, direction: 'recvonly' as RTCRtpTransceiverDirection }
        }
        return ext
      })
      if (changed) {
        extTransceiver.setHeaderExtensionsToNegotiate(updated)
      }
    } catch (e) {
      console.warn('[WebRTC] ensurePlayoutDelayNegotiated failed:', e)
    }
  }

  /** Ensure the video m-line advertises the playout-delay RTP header extension
   *  so the sender can signal min=0/max=0 playout delay per frame. */
  private ensurePlayoutDelayHeaderExtension(sdp: string): string {
    const eol = sdp.includes('\r\n') ? '\r\n' : '\n'
    const lines = sdp.split(eol)
    const videoStart = lines.findIndex((l) => l.startsWith('m=video '))
    if (videoStart < 0) return sdp

    let videoEnd = lines.length
    for (let i = videoStart + 1; i < lines.length; i++) {
      if (lines[i].startsWith('m=')) {
        videoEnd = i
        break
      }
    }

    const usedIds = new Set<number>()
    let lastExtmapIdx = -1
    for (let i = videoStart + 1; i < videoEnd; i++) {
      const line = lines[i]
      if (line.includes(PLAYOUT_DELAY_EXT_URI)) {
        // Already present in video m-line; ensure it is not marked inactive/sendonly.
        const fixed = line.replace(/^(a=extmap:\d+)\/(?:inactive|sendonly)(\s+)/, '$1$2')
        if (fixed !== line) {
          lines[i] = fixed
          return lines.join(eol)
        }
        return sdp
      }
      const m = line.match(/^a=extmap:(\d+)(?:\/\S+)?\s+/)
      if (m) {
        usedIds.add(Number(m[1]))
        lastExtmapIdx = i
      }
    }

    let nextId = 1
    while (usedIds.has(nextId) && nextId < 15) nextId++
    if (nextId >= 15) return sdp

    const insertIdx = lastExtmapIdx >= 0 ? lastExtmapIdx + 1 : videoStart + 1
    lines.splice(insertIdx, 0, `a=extmap:${nextId} ${PLAYOUT_DELAY_EXT_URI}`)
    return lines.join(eol)
  }

  private applyCodecPreferences(
    transceiver: RTCRtpTransceiver,
    preferredCodec?: 'h264' | 'h265'
  ): void {
    try {
      const codecs = RTCRtpReceiver.getCapabilities?.('video')?.codecs
      if (!codecs || codecs.length === 0) return
      if (typeof transceiver.setCodecPreferences !== 'function') return

      const preferH265 = preferredCodec === 'h265'
      const rank = (codec: RTCRtpCodec): number => {
        const mime = codec.mimeType.toLowerCase()
        const fmtp = (codec.sdpFmtpLine ?? '').toLowerCase()

        if (mime === 'video/h265' || mime === 'video/hevc') {
          return preferH265 ? 0 : 3
        }
        if (mime === 'video/h264') {
          if (fmtp.includes('profile-level-id=640')) {
            return preferH265 ? 1 : 0
          }
          if (fmtp.includes('profile-level-id=4d')) {
            return preferH265 ? 2 : 1
          }
          return preferH265 ? 3 : 2
        }
        if (mime === 'video/vp9') return 4
        if (mime === 'video/av1') return 5
        if (mime === 'video/vp8') return 7
        if (mime === 'video/rtx') return 8
        if (mime === 'video/flexfec-03' || mime.startsWith('video/flexfec')) return 9
        if (mime === 'video/red') return 10
        if (mime === 'video/ulpfec') return 11
        return 6
      }

      const sorted = [...codecs].sort((a, b) => rank(a) - rank(b))
      transceiver.setCodecPreferences(sorted)
      const fecCodecs = sorted
        .filter((c) => {
          const r = rank(c)
          return r >= 9 && r <= 11
        })
        .map((c) => c.mimeType)
      console.log(
        '[WebRTC] codec preferences applied:',
        sorted
          .filter((c) => rank(c) < 8)
          .slice(0, 5)
          .map((c) => `${c.mimeType}${c.sdpFmtpLine ? `(${c.sdpFmtpLine})` : ''}`)
          .join(', '),
        `| fec=${fecCodecs.length > 0 ? fecCodecs.join(',') : 'none'}`
      )
    } catch (e) {
      console.warn('[WebRTC] setCodecPreferences failed:', e)
    }
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

  /** RTP 轨道是否存在且存活——统计用。不看 connectionState：它在网络抖动时
   * 会短暂掉到 disconnected，而此时帧往往仍在解码；按 mediaActive 门控统计
   * 会落到只数 WS 二进制帧的 _frameCount 上，RTP 会话里那个数永远是 0。 */
  get hasLiveVideoTrack(): boolean {
    return this.videoTrack?.readyState === 'live'
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
    if (!pc) return null
    let s: {
      framesDecoded?: number
      bytesReceived?: number
      totalDecodeTime?: number
      framesPerSecond?: number
      codecId?: string
      decoderImplementation?: string
      powerEfficientDecoder?: boolean
    } | null = null
    let codecMime: string | undefined
    try {
      const report = await pc.getStats()
      for (const entry of report.values()) {
        if (entry.type === 'inbound-rtp' && entry.kind === 'video') {
          s = entry
          if (typeof entry.codecId === 'string') {
            const codecEntry = report.get(entry.codecId) as { mimeType?: string } | undefined
            codecMime = codecEntry?.mimeType
          }
          break
        }
      }
    } catch { return null }
    if (!s) return null

    if (!this.firstFrameJitterReset && (s.framesDecoded ?? 0) > 0) {
      this.firstFrameJitterReset = true
      this.applyZeroJitterBuffer()
    } else {
      this.reassertZeroJitterBufferIfDrifted()
    }

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

    let codec: VideoCodec | undefined
    if (codecMime) {
      const mime = codecMime.toLowerCase()
      if (mime.includes('h265') || mime.includes('hevc')) codec = 'h265'
      else if (mime.includes('h264') || mime.includes('avc')) codec = 'h264'
    }

    let isHardwareDecoded: boolean | undefined
    if (typeof s.powerEfficientDecoder === 'boolean') {
      isHardwareDecoded = s.powerEfficientDecoder
    } else if (typeof s.decoderImplementation === 'string' && s.decoderImplementation.length > 0) {
      const impl = s.decoderImplementation.toLowerCase()
      const isSoft = impl.includes('openh264') || impl.includes('ffmpeg') || impl.includes('libvpx') || impl.includes('dav1d') || impl.includes('software')
      isHardwareDecoded = !isSoft
    }

    return {
      fps: s.framesPerSecond ?? Math.round(frames / dtSec),
      bitrateKbps: Math.round(bytes * 8 / 1000 / dtSec),
      decodeMs: frames > 0 ? Math.round(decode * 1000 / frames) : 0,
      codec,
      isHardwareDecoded,
    }
  }

  // TEMP DIAGNOSTIC — receive-side deltas since the previous call, forwarded
  // to the agent's log (see Session.swift's .clientStats). Sender stats are
  // healthy while scrolling still stutters, so this is where to look next.
  private lastRx: Record<string, number> = {}
  async rxDiag(renderedFrames: number): Promise<string> {
    const pc = this.pc
    if (!pc) return ''
    try {
      const report = await pc.getStats()
      for (const e of report.values()) {
        if (e.type !== 'inbound-rtp' || e.kind !== 'video') continue
        const keys = ['framesReceived', 'framesDecoded', 'framesDropped', 'packetsLost', 'nackCount', 'pliCount',
          'freezeCount', 'totalFreezesDuration', 'jitterBufferDelay', 'jitterBufferEmittedCount', 'totalDecodeTime', 'bytesReceived']
        const d: Record<string, number> = {}
        for (const k of keys) { const v = Number(e[k] ?? 0); d[k] = v - (this.lastRx[k] ?? 0); this.lastRx[k] = v }
        const jb  = d.jitterBufferEmittedCount > 0 ? Math.round(d.jitterBufferDelay * 1000 / d.jitterBufferEmittedCount) : -1
        const dec = d.framesDecoded > 0 ? Math.round(d.totalDecodeTime * 1000 / d.framesDecoded) : -1
        return `recv=${d.framesReceived} dec=${d.framesDecoded} drop=${d.framesDropped} rendered=${renderedFrames} ` +
          `lost=${d.packetsLost} nack=${d.nackCount} pli=${d.pliCount} freeze=${d.freezeCount}/${Math.round(d.totalFreezesDuration * 1000)}ms ` +
          `jbMs=${jb} decMs=${dec} kbps=${Math.round(d.bytesReceived * 8 / 1000 / 2)} jitterMs=${Math.round(Number(e.jitter ?? 0) * 1000)} ` +
          `${e.frameWidth}x${e.frameHeight} impl=${e.decoderImplementation ?? '?'} pcState=${pc.connectionState}`
      }
    } catch { /* ignore */ }
    return ''
  }

  close(): void {
    this.pc?.close()
    this.pc = null
    this.controlChannel = null
    this.videoTrack = null
    this.videoReceiver = null
    this.firstFrameJitterReset = false
  }
}
