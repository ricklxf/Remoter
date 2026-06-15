export class VideoRenderer {
  private canvas: HTMLCanvasElement | null = null

  attach(canvas: HTMLCanvasElement): void {
    this.canvas = canvas
  }

  renderFrame(frame: VideoFrame): void {
    const canvas = this.canvas
    if (!canvas) { frame.close(); return }
    const ctx = canvas.getContext('2d')
    if (ctx) {
      ctx.drawImage(frame, 0, 0, canvas.width, canvas.height)
    } else {
      console.warn('[Renderer] no 2d context')
    }
    frame.close()
  }

  resize(width: number, height: number): void {
    if (!this.canvas) return
    this.canvas.width  = width
    this.canvas.height = height
  }

  detach(): void {
    this.canvas = null
  }
}
