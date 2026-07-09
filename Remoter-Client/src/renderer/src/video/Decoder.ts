// WebCodecs VideoDecoder wrapper — supports H.264 and H.265 (HEVC)
// H.265 需要 Chromium 107+ / Electron 22+ 且硬件解码器支持

export type FrameCallback = (frame: VideoFrame) => void
export type VideoCodec = 'h264' | 'h265' | 'jpeg'

const CODEC_STRING: Record<Exclude<VideoCodec, 'jpeg'>, string> = {
  h264: 'avc3.42E034',       // H.264 Baseline Annex-B in-band SPS/PPS, Level 5.2
  h265: 'hvc1.1.6.L150.B0'  // H.265 Main Profile Level 5.0
}

// If decode can't keep up with arrival rate (e.g. no hardware decoder
// available, falling back to software H.264 decode on an underpowered/
// locked-down machine), WebCodecs just queues chunks — decodeQueueSize grows
// without bound and what's on screen falls further and further behind real
// time. Network stats (fps/RTT) look perfectly healthy the whole time since
// they measure arrival, not decode, which makes this easy to misdiagnose as
// a network problem. Past this many queued chunks, treat it like a decode
// error: drop frames until the next keyframe instead of letting the backlog
// (and visible lag) grow indefinitely.
const DECODE_QUEUE_OVERLOAD = 4

export class VideoDecoder_ {
  private decoder: VideoDecoder | null = null
  private onFrame: FrameCallback
  private pendingKeyframe = true
  private currentCodec: VideoCodec = 'h264'

  /** Fired (once per recovery cycle) when the decode queue backs up and a fresh keyframe is needed to recover. */
  onOverloaded: (() => void) | null = null

  // Periodic visibility into decodeQueueSize even when it never crosses the
  // hard overload threshold — distinguishes "chronically a bit behind" from
  // "fine, then one sharp spike", which the overload event alone can't tell apart.
  private lastQueueLogAt = 0

  constructor(onFrame: FrameCallback) {
    this.onFrame = onFrame
  }

  async init(width: number, height: number, codec: VideoCodec = 'h264'): Promise<void> {
    if (codec === 'jpeg') return  // JPEG 由 RemoteCanvas 直接处理
    if (this.decoder) this.close()
    this.currentCodec = codec

    const codecStr = CODEC_STRING[codec as Exclude<VideoCodec, 'jpeg'>]

    // H.265 需要先检查浏览器是否支持
    if (codec === 'h265') {
      const support = await VideoDecoder_.isH265Supported()
      if (!support) {
        console.warn('[Decoder] H.265 not supported, falling back to H.264')
        this.currentCodec = 'h264'
        return this.init(width, height, 'h264')
      }
    }

    this.decoder = new VideoDecoder({
      output: (frame) => {
        this.onFrame(frame)
      },
      error: (e) => {
        console.error('[Decoder] decode error:', e.message)
        this.pendingKeyframe = true
      }
    })

    this.decoder.configure({
      codec: codecStr,
      codedWidth: width,
      codedHeight: height,
      optimizeForLatency: true,
    })

    this.pendingKeyframe = true
    console.log(`[Decoder] configured ${codec} (${codecStr}) ${width}×${height}`)
  }

  decode(data: ArrayBuffer, keyframe: boolean, timestampUs: number): void {
    if (!this.decoder || this.decoder.state === 'closed') return

    if (this.pendingKeyframe && !keyframe) return

    const now = performance.now()
    if (now - this.lastQueueLogAt > 1000) {
      this.lastQueueLogAt = now
      console.log(`[Decoder] decodeQueueSize=${this.decoder.decodeQueueSize}`)
    }

    if (!keyframe && this.decoder.decodeQueueSize > DECODE_QUEUE_OVERLOAD) {
      this.pendingKeyframe = true
      this.onOverloaded?.()
      return
    }

    if (keyframe) this.pendingKeyframe = false

    try {
      const chunk = new EncodedVideoChunk({
        type: keyframe ? 'key' : 'delta',
        timestamp: timestampUs,
        data
      })
      this.decoder.decode(chunk)
    } catch (e) {
      console.warn('[Decoder] decode error:', e)
      this.pendingKeyframe = true
    }
  }

  /** 收到服务端 codec_changed 通知后，重新初始化解码器 */
  async switchCodec(width: number, height: number, codec: VideoCodec): Promise<void> {
    await this.init(width, height, codec)
  }

  get codec(): VideoCodec { return this.currentCodec }

  flush(): Promise<void> {
    return this.decoder?.flush() ?? Promise.resolve()
  }

  close(): void {
    if (this.decoder && this.decoder.state !== 'closed') {
      this.decoder.close()
    }
    this.decoder = null
  }

  // MARK: - Static helpers

  static isSupported(): boolean {
    return typeof VideoDecoder !== 'undefined'
  }

  static async isH265Supported(): Promise<boolean> {
    if (!VideoDecoder_.isSupported()) return false
    try {
      const result = await VideoDecoder.isConfigSupported({
        codec: CODEC_STRING['h265'],
        codedWidth: 1920,
        codedHeight: 1080
      })
      return result.supported === true
    } catch {
      return false
    }
  }
}

// 向后兼容别名
export { VideoDecoder_ as H264Decoder }
