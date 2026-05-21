// H.264 decoder via WebCodecs API (available in Chromium/Electron 94+)

export type FrameCallback = (frame: VideoFrame) => void

export class H264Decoder {
  private decoder: VideoDecoder | null = null
  private onFrame: FrameCallback
  private pendingKeyframe = true

  constructor(onFrame: FrameCallback) {
    this.onFrame = onFrame
  }

  init(width: number, height: number): void {
    if (this.decoder) this.close()

    this.decoder = new VideoDecoder({
      output: (frame) => {
        this.onFrame(frame)
      },
      error: (e) => {
        console.warn('[Decoder] error:', e.message)
        // Re-initialize on error; next keyframe will recover
        this.pendingKeyframe = true
      }
    })

    this.decoder.configure({
      codec: 'avc1.640028',   // H.264 High Profile Level 4.0
      codedWidth: width,
      codedHeight: height,
      optimizeForLatency: true
    })

    this.pendingKeyframe = true
  }

  decode(data: ArrayBuffer, keyframe: boolean, timestampUs: number): void {
    if (!this.decoder || this.decoder.state === 'closed') return

    // Drop delta frames until we get a keyframe
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

  flush(): Promise<void> {
    return this.decoder?.flush() ?? Promise.resolve()
  }

  close(): void {
    if (this.decoder && this.decoder.state !== 'closed') {
      this.decoder.close()
    }
    this.decoder = null
  }

  static isSupported(): boolean {
    return typeof VideoDecoder !== 'undefined'
  }
}
