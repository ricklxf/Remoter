// Captures local microphone audio via getUserMedia + Web Audio API and emits
// 48 kHz, mono, 16-bit signed little-endian PCM in 20 ms chunks (960 samples = 1,920 bytes).
// Matches Remoter-MacServer's MicPlayer wire format ([0x04] + raw PCM).

const TARGET_SAMPLE_RATE = 48000
const CHUNK_SAMPLES = 960 // 20 ms @ 48 kHz

export class MicCapturer {
  private stream: MediaStream | null = null
  private ctx: AudioContext | null = null
  private source: MediaStreamAudioSourceNode | null = null
  private processor: ScriptProcessorNode | null = null
  private zeroGain: GainNode | null = null
  private running = false

  private accum = new Int16Array(CHUNK_SAMPLES)
  private accumLen = 0
  private resamplePos = 0

  get isRunning(): boolean {
    return this.running
  }

  async start(onPcm: (pcm: Uint8Array) => void): Promise<boolean> {
    if (this.running) return true
    if (typeof navigator === 'undefined' || !navigator.mediaDevices?.getUserMedia) {
      return false
    }

    try {
      const stream = await navigator.mediaDevices.getUserMedia({
        audio: {
          channelCount: 1,
          echoCancellation: true,
          noiseSuppression: true,
          autoGainControl: true,
        },
        video: false,
      })

      let ctx: AudioContext
      try {
        ctx = new AudioContext({ sampleRate: TARGET_SAMPLE_RATE })
      } catch {
        ctx = new AudioContext()
      }
      if (ctx.state === 'suspended') {
        await ctx.resume()
      }

      const source = ctx.createMediaStreamSource(stream)
      const processor = ctx.createScriptProcessor(1024, 1, 1)
      // Connect through a muted gain node so ScriptProcessorNode fires without local echo
      const zeroGain = ctx.createGain()
      zeroGain.gain.value = 0

      this.stream = stream
      this.ctx = ctx
      this.source = source
      this.processor = processor
      this.zeroGain = zeroGain
      this.accumLen = 0
      this.resamplePos = 0
      this.running = true

      const inputRate = ctx.sampleRate

      processor.onaudioprocess = (ev) => {
        if (!this.running) return
        const input = ev.inputBuffer.getChannelData(0)
        if (!input || input.length === 0) return

        if (inputRate === TARGET_SAMPLE_RATE) {
          for (let i = 0; i < input.length; i++) {
            this.pushFloatSample(input[i], onPcm)
          }
        } else {
          // Linear resample from ctx.sampleRate → 48 kHz
          const step = inputRate / TARGET_SAMPLE_RATE
          let pos = this.resamplePos
          while (pos < input.length) {
            const idx = Math.floor(pos)
            const frac = pos - idx
            const s0 = input[idx]
            const s1 = idx + 1 < input.length ? input[idx + 1] : s0
            this.pushFloatSample(s0 + (s1 - s0) * frac, onPcm)
            pos += step
          }
          this.resamplePos = pos - input.length
        }
      }

      source.connect(processor)
      processor.connect(zeroGain)
      zeroGain.connect(ctx.destination)
      return true
    } catch (err) {
      console.warn('[MicCapturer] failed to start:', err)
      this.stop()
      return false
    }
  }

  private pushFloatSample(sample: number, onPcm: (pcm: Uint8Array) => void): void {
    const clamped = Math.max(-1, Math.min(1, sample))
    const i16 = clamped < 0 ? Math.round(clamped * 32768) : Math.round(clamped * 32767)
    this.accum[this.accumLen++] = i16

    if (this.accumLen >= CHUNK_SAMPLES) {
      const out = new Uint8Array(CHUNK_SAMPLES * 2)
      const view = new DataView(out.buffer)
      for (let i = 0; i < CHUNK_SAMPLES; i++) {
        view.setInt16(i * 2, this.accum[i], true) // little-endian
      }
      this.accumLen = 0
      onPcm(out)
    }
  }

  stop(): void {
    this.running = false
    this.accumLen = 0
    this.resamplePos = 0

    if (this.processor) {
      this.processor.onaudioprocess = null
      try { this.processor.disconnect() } catch { /* ignore */ }
      this.processor = null
    }
    if (this.source) {
      try { this.source.disconnect() } catch { /* ignore */ }
      this.source = null
    }
    if (this.zeroGain) {
      try { this.zeroGain.disconnect() } catch { /* ignore */ }
      this.zeroGain = null
    }
    if (this.stream) {
      for (const track of this.stream.getTracks()) {
        try { track.stop() } catch { /* ignore */ }
      }
      this.stream = null
    }
    if (this.ctx) {
      const ctx = this.ctx
      this.ctx = null
      ctx.close().catch(() => { /* ignore */ })
    }
  }
}
