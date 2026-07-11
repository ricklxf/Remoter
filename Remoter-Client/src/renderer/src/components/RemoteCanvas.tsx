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
  isActive?: boolean
}

export function RemoteCanvas({ conn, streamInfo, initialCodec = 'h264', isActive = true }: Props) {
  const canvasRef   = useRef<HTMLCanvasElement>(null)
  const imeRef      = useRef<HTMLTextAreaElement>(null)
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
      decoder.onOverloaded = () => {
        console.warn('[Decoder] decode queue overloaded, requesting keyframe')
        conn.sendRequestKeyframe()
      }
      decoderRef.current = decoder
      conn.decodeMsProvider = () => decoder.lastDecodeMs
      decoder.init(streamInfo.width, streamInfo.height, initialCodec as VideoCodec).catch(console.error)
      console.log('[RemoteCanvas] H.264 mode, decoder initializing')
      // This decoder is brand new and won't decode anything until it gets a
      // keyframe (Decoder.ts buffers/drops delta frames until then) — ask the
      // encoder for one now instead of waiting for its next scheduled one
      // (up to 2s away), which is what made switching tabs show a black
      // screen for a few seconds.
      conn.sendRequestKeyframe()
    }

    inputRef.current.attach(canvas, streamInfo.width, streamInfo.height, imeRef.current ?? undefined)

    return () => {
      decoderRef.current?.close()
      decoderRef.current = null
      conn.decodeMsProvider = null
      rendererRef.current.detach()
      inputRef.current.detach()
      ctx2dRef.current = null
    }
  }, [streamInfo, initialCodec])

  // Tab switched away: this canvas stays mounted (decoder keeps decoding in
  // the background, see App.tsx), but its keyboard capture must not — else
  // it keeps eating keystrokes meant for whichever tab you switched to.
  useEffect(() => {
    if (!isActive) inputRef.current.deactivate()
  }, [isActive])

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

      // Remote cursor *shape* rendered on the local pointer: the capture
      // stream has the cursor hidden, position is already local — this just
      // swaps the local arrow for whatever shape the remote system shows
      // (text beam, resize arrows, …). Set directly on the DOM node instead
      // of React state so a busy cursor flipping shapes doesn't re-render
      // the component tree.
      if (e.type === 'cursor_shape' && canvasRef.current) {
        canvasRef.current.style.cursor =
          `url(data:image/png;base64,${e.pngBase64}) ${e.hotX} ${e.hotY}, default`
      }
    }
    return () => { conn.onEvent = prev }
  }, [conn, streamInfo, initialCodec])

  return (
    <div ref={wrapRef} style={{ width: '100%', height: '100%', display: 'flex', alignItems: 'center', justifyContent: 'center', position: 'relative' }}>
      <canvas
        ref={canvasRef}
        tabIndex={0}
        style={{
          display: 'block',
          width:  cssSize ? cssSize.w : '100%',
          height: cssSize ? cssSize.h : '100%',
          cursor: 'default',
          outline: 'none',
        }}
      />
      {/* Invisible IME staging area: holds keyboard focus while capturing so
          the local input method can compose CJK text (composition only works
          on editable elements — the canvas can't host it). Final committed
          text is sent to the remote via compositionend; see InputHandler. */}
      <textarea
        ref={imeRef}
        tabIndex={-1}
        autoCapitalize="off"
        autoCorrect="off"
        spellCheck={false}
        style={{
          position: 'absolute', left: 0, bottom: 0,
          width: 1, height: 1, padding: 0, border: 'none',
          opacity: 0, pointerEvents: 'none', resize: 'none',
          overflow: 'hidden', zIndex: -1,
        }}
      />
    </div>
  )
}
