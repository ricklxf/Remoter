// Renders VideoFrame to canvas using ImageBitmapRenderingContext
// (hardware-accelerated, lower latency than 2D canvas drawImage)

export class VideoRenderer {
  private ctx: ImageBitmapRenderingContext | null = null
  private canvas: HTMLCanvasElement | null = null

  attach(canvas: HTMLCanvasElement): void {
    this.canvas = canvas
    this.ctx = canvas.getContext('bitmaprenderer') ?? null
    if (!this.ctx) {
      console.warn('[Renderer] bitmaprenderer not available, falling back to 2d')
    }
  }

  renderFrame(frame: VideoFrame): void {
    if (!this.canvas) { frame.close(); return }

    if (this.ctx) {
      createImageBitmap(frame).then((bmp) => {
        this.ctx!.transferFromImageBitmap(bmp)
        frame.close()
      })
    } else {
      // 2D canvas fallback
      const ctx2d = this.canvas.getContext('2d')
      if (ctx2d) {
        ctx2d.drawImage(frame, 0, 0, this.canvas.width, this.canvas.height)
      }
      frame.close()
    }
  }

  resize(width: number, height: number): void {
    if (!this.canvas) return
    this.canvas.width  = width
    this.canvas.height = height
  }

  detach(): void {
    this.ctx = null
    this.canvas = null
  }
}
