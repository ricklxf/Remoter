// WebCodecs VideoDecoder wrapper — supports H.264 and H.265 (HEVC),
// including 4:4:4 chroma and 10-bit HDR profiles.
// H.265 需要 Chromium 107+ / Electron 22+ 且硬件解码器支持

export type FrameCallback = (frame: VideoFrame) => void
export type VideoCodec = 'h264' | 'h265' | 'jpeg'

export interface DecoderOptions {
  chroma444?: boolean
  hdr?: boolean
}

const CODEC_STRINGS = {
  h264_420: 'avc3.640034',       // H.264 High profile (4:2:0), Annex-B in-band SPS/PPS, Level 5.2
  h264_444: 'avc3.f40034',       // H.264 High 4:4:4 Predictive profile, Level 5.2
  h265_420: 'hvc1.1.6.L150.B0',  // H.265 Main Profile (4:2:0 8-bit) Level 5.0
  h265_hdr: 'hvc1.2.4.L150.B0',  // H.265 Main10 Profile (4:2:0 10-bit HDR) Level 5.0
  h265_444: 'hvc1.4.10.L150.B0', // H.265 Format Range Extensions (4:4:4) Level 5.0
} as const

function resolveCodecString(codec: Exclude<VideoCodec, 'jpeg'>, options?: DecoderOptions): string {
  if (codec === 'h264') {
    return options?.chroma444 ? CODEC_STRINGS.h264_444 : CODEC_STRINGS.h264_420
  }
  if (options?.chroma444) return CODEC_STRINGS.h265_444
  if (options?.hdr) return CODEC_STRINGS.h265_hdr
  return CODEC_STRINGS.h265_420
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
const DECODE_QUEUE_OVERLOAD = 10

export class VideoDecoder_ {
  private decoder: VideoDecoder | null = null
  private onFrame: FrameCallback
  private pendingKeyframe = true
  private currentCodec: VideoCodec = 'h264'
  private currentOptions: DecoderOptions = {}

  /** Fired (once per recovery cycle) when the decode queue backs up and a fresh keyframe is needed to recover. */
  onOverloaded: (() => void) | null = null

  // True per-frame decode latency (submit → output callback), keyed by the
  // chunk timestamp which VideoFrame echoes back — for the latency panel.
  private decodeSubmitTimes = new Map<number, number>()
  lastDecodeMs = 0

  // Periodic visibility into decodeQueueSize even when it never crosses the
  // hard overload threshold — distinguishes "chronically a bit behind" from
  // "fine, then one sharp spike", which the overload event alone can't tell apart.
  private lastQueueLogAt = 0

  constructor(onFrame: FrameCallback) {
    this.onFrame = onFrame
  }

  async init(
    width: number,
    height: number,
    codec: VideoCodec = 'h264',
    options: DecoderOptions = {}
  ): Promise<void> {
    if (codec === 'jpeg') return  // JPEG 由 RemoteCanvas 直接处理
    if (this.decoder) this.close()

    let targetCodec: Exclude<VideoCodec, 'jpeg'> = codec
    let targetOptions: DecoderOptions = { ...options }

    // Check browser support and gracefully fall back if an advanced profile is unavailable
    if (targetCodec === 'h265') {
      if (targetOptions.chroma444 && !(await VideoDecoder_.is444Supported('h265'))) {
        console.warn('[Decoder] H.265 4:4:4 not supported, falling back to 4:2:0')
        targetOptions.chroma444 = false
      }
      if (targetOptions.hdr && !(await VideoDecoder_.isHdrSupported())) {
        console.warn('[Decoder] H.265 Main10 HDR not supported, falling back to SDR')
        targetOptions.hdr = false
      }
      if (!targetOptions.chroma444 && !targetOptions.hdr && !(await VideoDecoder_.isH265Supported())) {
        console.warn('[Decoder] H.265 not supported, falling back to H.264')
        targetCodec = 'h264'
        targetOptions = { chroma444: false, hdr: false }
      }
    } else if (targetCodec === 'h264' && targetOptions.chroma444) {
      if (!(await VideoDecoder_.is444Supported('h264'))) {
        console.warn('[Decoder] H.264 4:4:4 not supported, falling back to 4:2:0')
        targetOptions.chroma444 = false
      }
    }

    this.currentCodec = targetCodec
    this.currentOptions = targetOptions
    const codecStr = resolveCodecString(targetCodec, targetOptions)

    this.decoder = new VideoDecoder({
      output: (frame) => {
        const t = this.decodeSubmitTimes.get(frame.timestamp)
        if (t !== undefined) {
          this.lastDecodeMs = performance.now() - t
          this.decodeSubmitTimes.delete(frame.timestamp)
        }
        this.onFrame(frame)
      },
      error: (e) => {
        console.error('[Decoder] decode error:', e.message)
        this.pendingKeyframe = true
        this.decodeSubmitTimes.clear()
      }
    })

    this.decoder.configure({
      codec: codecStr,
      codedWidth: width,
      codedHeight: height,
      optimizeForLatency: true,
      hardwareAcceleration: 'prefer-hardware',
    })

    this.pendingKeyframe = true
    console.log(
      `[Decoder] configured ${targetCodec} (${codecStr}) ${width}×${height}` +
      `${targetOptions.chroma444 ? ' 4:4:4' : ''}${targetOptions.hdr ? ' HDR10' : ''}`
    )
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
      this.decodeSubmitTimes.set(timestampUs, performance.now())
      // Dropped/errored frames never reach the output callback — cap growth.
      if (this.decodeSubmitTimes.size > 200) {
        const oldest = this.decodeSubmitTimes.keys().next().value
        if (oldest !== undefined) this.decodeSubmitTimes.delete(oldest)
      }
      this.decoder.decode(chunk)
    } catch (e) {
      console.warn('[Decoder] decode error:', e)
      this.pendingKeyframe = true
    }
  }

  /** 收到服务端 codec_changed / chroma / hdr 通知后，重新初始化解码器 */
  async switchCodec(
    width: number,
    height: number,
    codec: VideoCodec,
    options?: DecoderOptions
  ): Promise<void> {
    await this.init(width, height, codec, options ?? this.currentOptions)
  }

  get codec(): VideoCodec { return this.currentCodec }
  get chroma444(): boolean { return Boolean(this.currentOptions.chroma444) }
  get hdr(): boolean { return Boolean(this.currentOptions.hdr) }

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

  private static async checkCodecConfig(codecStr: string, isHevc: boolean): Promise<boolean> {
    if (!VideoDecoder_.isSupported()) return false
    try {
      const result = await VideoDecoder.isConfigSupported({
        codec: codecStr,
        codedWidth: 1920,
        codedHeight: 1080,
        optimizeForLatency: true,
        // Must mirror the flags configure() actually uses: Chromium has no
        // software HEVC decoder, so on win32 (where we force prefer-software)
        // HEVC is genuinely unavailable and this check correctly reports so.
        ...(isHevc && window.remoterAPI?.platform === 'win32'
          ? { hardwareAcceleration: 'prefer-software' as HardwareAcceleration }
          : {}),
      })
      return result.supported === true
    } catch {
      return false
    }
  }

  static async isH265Supported(): Promise<boolean> {
    return VideoDecoder_.checkCodecConfig(CODEC_STRINGS.h265_420, true)
  }

  static async is444Supported(codec: Exclude<VideoCodec, 'jpeg'> = 'h265'): Promise<boolean> {
    const codecStr = codec === 'h264' ? CODEC_STRINGS.h264_444 : CODEC_STRINGS.h265_444
    return VideoDecoder_.checkCodecConfig(codecStr, codec === 'h265')
  }

  static async isHdrSupported(): Promise<boolean> {
    return VideoDecoder_.checkCodecConfig(CODEC_STRINGS.h265_hdr, true)
  }
}

// 向后兼容别名
export { VideoDecoder_ as H264Decoder }
