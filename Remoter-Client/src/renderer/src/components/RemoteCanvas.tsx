import React, { useEffect, useRef, useState } from 'react'
import { Connection } from '../network/Connection'
import { VideoDecoder_, VideoCodec } from '../video/Decoder'
import { VideoRenderer } from '../video/Renderer'
import { InputHandler } from '../input/InputHandler'
import { StreamInfo } from '../types'

interface Props {
  conn: Connection
  streamInfo: StreamInfo
  initialCodec?: VideoCodec | 'jpeg'
}

export function RemoteCanvas({ conn, streamInfo, initialCodec = 'h264' }: Props) {
  const canvasRef   = useRef<HTMLCanvasElement>(null)
  const decoderRef  = useRef<VideoDecoder_ | null>(null)
  const rendererRef = useRef<VideoRenderer>(new VideoRenderer())
  const inputRef    = useRef<InputHandler>(new InputHandler(conn))
  const ctx2dRef    = useRef<CanvasRenderingContext2D | null>(null)
  const wrapRef     = useRef<HTMLDivElement>(null)
  const [cssSize, setCssSize] = useState<{ w: number; h: number } | null>(null)

  // Recompute canvas CSS size when container or stream dimensions change
  useEffect(() => {
    const el = wrapRef.current
    if (!el) return
    const update = () => {
      const cw = el.clientWidth, ch = el.clientHeight
      if (!cw || !ch) return
      const ar = streamInfo.width / streamInfo.height
      let w: number, h: number
      if (cw / ch > ar) { w = ch * ar; h = ch }
      else              { w = cw; h = cw / ar }
      // Never upscale past native resolution (1 CSS px × DPR = 1 stream px) —
      // beyond that the source has no more detail to show, only blur.
      const dpr  = window.devicePixelRatio || 1
      const maxW = streamInfo.width  / dpr
      const maxH = streamInfo.height / dpr
      if (w > maxW) { w = maxW; h = maxH }
      setCssSize({ w, h })
    }
    update()
    const ro = new ResizeObserver(update)
    ro.observe(el)
    // Fullscreen transition can settle layout a frame after the resize fires,
    // leaving cssSize computed from a stale (pre-transition) rect — force a
    // recompute once the transition completes.
    const onFullscreenChange = () => requestAnimationFrame(update)
    document.addEventListener('fullscreenchange', onFullscreenChange)
    return () => {
      ro.disconnect()
      document.removeEventListener('fullscreenchange', onFullscreenChange)
    }
  }, [streamInfo.width, streamInfo.height])

  useEffect(() => {
    const canvas = canvasRef.current
    if (!canvas) return

    canvas.width  = streamInfo.width
    canvas.height = streamInfo.height

    if (initialCodec === 'jpeg') {
      ctx2dRef.current = canvas.getContext('2d')
      console.log('[RemoteCanvas] JPEG mode')
    } else {
      const renderer = rendererRef.current
      renderer.resize(streamInfo.width, streamInfo.height)
      renderer.attach(canvas)

      if (!VideoDecoder_.isSupported()) {
        console.error('[RemoteCanvas] WebCodecs not supported')
        return
      }

      const decoder = new VideoDecoder_((frame) => renderer.renderFrame(frame))
      decoderRef.current = decoder
      decoder.init(streamInfo.width, streamInfo.height, initialCodec as VideoCodec).catch(console.error)
      console.log('[RemoteCanvas] H.264 mode, decoder initializing')
      // This decoder is brand new and won't decode anything until it gets a
      // keyframe (Decoder.ts buffers/drops delta frames until then) — ask the
      // encoder for one now instead of waiting for its next scheduled one
      // (up to 2s away), which is what made switching tabs show a black
      // screen for a few seconds.
      conn.sendRequestKeyframe()
    }

    inputRef.current.attach(canvas, streamInfo.width, streamInfo.height)

    return () => {
      decoderRef.current?.close()
      decoderRef.current = null
      rendererRef.current.detach()
      inputRef.current.detach()
      ctx2dRef.current = null
    }
  }, [streamInfo, initialCodec])

  // Wire up video frames + codec_changed events
  useEffect(() => {
    const prev = conn.onEvent
    conn.onEvent = (e) => {
      prev?.(e)

      if (e.type === 'video_frame') {
        if (initialCodec === 'jpeg') {
          // JPEG 模式：直接 createImageBitmap 渲染
          const blob = new Blob([e.data], { type: 'image/jpeg' })
          createImageBitmap(blob).then((bmp) => {
            const ctx = ctx2dRef.current
            const canvas = canvasRef.current
            if (ctx && canvas) {
              ctx.drawImage(bmp, 0, 0, canvas.width, canvas.height)
              bmp.close()
            }
          }).catch(() => {/* ignore decode errors */})
        } else if (decoderRef.current) {
          decoderRef.current.decode(e.data, e.keyframe, e.ptsMs * 1000)
        }
      }

      if (e.type === 'codec_changed' && decoderRef.current) {
        console.log(`[RemoteCanvas] switching decoder to ${e.codec}`)
        decoderRef.current.switchCodec(streamInfo.width, streamInfo.height, e.codec).catch(console.error)
      }
    }
    return () => { conn.onEvent = prev }
  }, [conn, streamInfo, initialCodec])

  return (
    <div ref={wrapRef} style={{ width: '100%', height: '100%', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
      <canvas
        ref={canvasRef}
        tabIndex={0}
        style={{
          display: 'block',
          width:  cssSize ? cssSize.w : '100%',
          height: cssSize ? cssSize.h : '100%',
          cursor: 'default',
          // outline (not border) — drawn outside the box, doesn't eat into
          // the canvas's own layout size or distort the rendered video.
          outline: '1px solid var(--canvas-edge)',
        }}
      />
    </div>
  )
}
