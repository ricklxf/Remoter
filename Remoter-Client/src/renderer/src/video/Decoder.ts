// WebCodecs VideoDecoder wrapper — supports H.264 and H.265 (HEVC)
// H.265 需要 Chromium 107+ / Electron 22+ 且硬件解码器支持

export type FrameCallback = (frame: VideoFrame) => void
export type VideoCodec = 'h264' | 'h265' | 'jpeg'

const CODEC_STRING: Record<Exclude<VideoCodec, 'jpeg'>, string> = {
  h264: 'avc1.42E034',       // H.264 Baseline Profile Level 5.2 (broad compatibility)
  h265: 'hvc1.1.6.L150.B0'  // H.265 Main Profile Level 5.0
}

export class VideoDecoder_ {
  private decoder: VideoDecoder | null = null
  private onFrame: FrameCallback
  private pendingKeyframe = true
  private currentCodec: VideoCodec = 'h264'

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
        console.warn('[Decoder] error:', e.message)
        this.pendingKeyframe = true
      }
    })

    this.decoder.configure({
      codec: codecStr,
      codedWidth: width,
      codedHeight: height,
      optimizeForLatency: true
    })

    this.pendingKeyframe = true
    console.log(`[Decoder] configured ${codec} (${codecStr}) ${width}×${height}`)
  }

  decode(data: ArrayBuffer, keyframe: boolean, timestampUs: number): void {
    if (!this.decoder || this.decoder.state === 'closed') return

    if (this.pendingKeyframe && !keyframe) return
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
