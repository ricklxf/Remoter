// Plays the remote system-audio stream: ADTS-framed AAC packets (binary
// frame type 0x03) → WebCodecs AudioDecoder → WebAudio.
//
// Playback scheduling: each decoded chunk (1024 samples ≈ 21ms) becomes an
// AudioBufferSourceNode started on a running timeline. `nextTime` chains the
// chunks seamlessly; if we fall behind (network gap), the timeline snaps
// forward to "now + jitter margin" and playback resumes with a small skip
// instead of drifting ever further behind real time.
export class AudioPlayer {
  private ctx: AudioContext | null = null
  private decoder: AudioDecoder | null = null
  private nextTime = 0
  private tsUs = 0

  static isSupported(): boolean {
    return typeof AudioDecoder !== 'undefined'
  }

  start(): void {
    if (this.ctx) return
    // Created from a user-gesture handler (the toolbar toggle), so the
    // autoplay policy allows it to start immediately.
    this.ctx = new AudioContext()
    this.decoder = new AudioDecoder({
      output: (data) => this.schedule(data),
      error: (e) => console.error('[Audio] decode error:', e.message),
    })
    // No `description` → the decoder parses the self-describing ADTS headers.
    this.decoder.configure({ codec: 'mp4a.40.2', sampleRate: 48000, numberOfChannels: 2 })
  }

  push(adts: ArrayBuffer): void {
    if (!this.decoder || this.decoder.state !== 'configured') return
    try {
      this.decoder.decode(new EncodedAudioChunk({
        type: 'key',            // every AAC frame is independently decodable
        timestamp: this.tsUs,
        data: adts,
      }))
      this.tsUs += 21333        // 1024 samples @ 48kHz
    } catch (e) {
      console.warn('[Audio] decode submit failed:', e)
    }
  }

  private schedule(data: AudioData): void {
    const ctx = this.ctx
    if (!ctx) { data.close(); return }
    const buf = ctx.createBuffer(data.numberOfChannels, data.numberOfFrames, data.sampleRate)
    for (let ch = 0; ch < data.numberOfChannels; ch++) {
      const arr = new Float32Array(data.numberOfFrames)
      data.copyTo(arr, { planeIndex: ch, format: 'f32-planar' })
      buf.copyToChannel(arr, ch)
    }
    data.close()

    const src = ctx.createBufferSource()
    src.buffer = buf
    src.connect(ctx.destination)
    const startAt = Math.max(ctx.currentTime + 0.06, this.nextTime)
    src.start(startAt)
    this.nextTime = startAt + buf.duration
  }

  stop(): void {
    try { this.decoder?.close() } catch { /* already closed */ }
    this.decoder = null
    this.ctx?.close()
    this.ctx = null
    this.nextTime = 0
    this.tsUs = 0
  }
}
