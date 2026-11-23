import React, { useEffect, useRef, useState } from 'react'
import { Connection } from '../network/Connection'
import { VideoDecoder_, VideoCodec } from '../video/Decoder'
import { VideoRenderer } from '../video/Renderer'
import { InputHandler } from '../input/InputHandler'
import { StreamInfo, ScaleMode, SharpnessLevel } from '../types'
import { useImeOffset, setImeOffset, resolutionKey, MIN_IME_BOTTOM } from '../utils/imeOffset'

interface Props {
  conn: Connection
  streamInfo: StreamInfo
  initialCodec?: VideoCodec | 'jpeg'
  isActive?: boolean
  /** Toggled from the toolbar (see Toolbar's "🎯 校准输入法位置" button) — lifted
   * up rather than kept as local state so the toolbar can show/drive it. */
  imeCalibrating?: boolean
  scaleMode?: ScaleMode
  sharpness?: SharpnessLevel
  toneMap?: boolean
  zoom?: number
  onZoomChange?: (z: number) => void
  forceCanvas?: boolean
  chroma444?: boolean
  hdr?: boolean
}

export function RemoteCanvas({
  conn,
  streamInfo,
  initialCodec = 'h264',
  isActive = true,
  imeCalibrating = false,
  scaleMode = 'fit',
  sharpness = 'off',
  toneMap = false,
  zoom = 1,
  onZoomChange: _onZoomChange,
  forceCanvas = false,
  chroma444 = false,
  hdr = false,
}: Props) {
  const canvasRef   = useRef<HTMLCanvasElement>(null)
  const videoRef    = useRef<HTMLVideoElement>(null)
  const frameRef    = useRef<HTMLDivElement>(null)
  const imeRef      = useRef<HTMLTextAreaElement>(null)
  const decoderRef  = useRef<VideoDecoder_ | null>(null)
  const rendererRef = useRef<VideoRenderer>(new VideoRenderer())
  const inputRef    = useRef<InputHandler>(new InputHandler(conn))
  const ctx2dRef    = useRef<CanvasRenderingContext2D | null>(null)
  const wrapRef     = useRef<HTMLDivElement>(null)
  const [cssSize, setCssSize] = useState<{ w: number; h: number } | null>(null)
  // RTP media track flowing → show <video>; otherwise the WebCodecs canvas
  // (WS fallback). Driven by the track's mute/unmute events, which is how
  // the browser signals "RTP packets stopped/resumed arriving".
  const [mediaActive, setMediaActive] = useState(false)
  useEffect(() => {
    const t = setTimeout(() => {
      if (outCountRef.current > 0 || mediaActive) return
      const d = decoderRef.current
      setDiag(`收到 ${rxCountRef.current} 帧，已显示 ${outCountRef.current} 帧 | VideoDecoder=${typeof VideoDecoder !== 'undefined'} | 解码器=${d ? d.debugState : '未创建'} | codec=${initialCodec}` +
        `${d?.lastError ? ' | 解码错误: ' + d.lastError : ''}${initErrRef.current ? ' | 初始化错误: ' + initErrRef.current : ''}`)
    }, 4000)
    return () => clearTimeout(t)
  }, [mediaActive, initialCodec])
  const clampedZoom = Math.min(3, Math.max(1, zoom))
  const [pan, setPan] = useState<{ x: number; y: number }>({ x: 0, y: 0 })
  const rvfcIdRef = useRef<number | null>(null)
  // On-screen diagnosis when frames arrive but nothing is ever drawn (no console access on the viewing machine).
  const rxCountRef = useRef(0)
  const outCountRef = useRef(0)
  const initErrRef = useRef('')
  const jpegCanvasRef = useRef<HTMLCanvasElement>(null)
  const [jpegFallback, setJpegFallback] = useState(false)
  const jpegFallbackRef = useRef(false)
  const [diag, setDiag] = useState<string | null>(null)
  const useVideoShader = mediaActive && !forceCanvas && (sharpness !== 'off' || toneMap)
  const useVideoShaderRef = useRef(useVideoShader)
  useVideoShaderRef.current = useVideoShader
  const chroma444Ref = useRef(chroma444)
  chroma444Ref.current = chroma444
  const hdrRef = useRef(hdr)
  hdrRef.current = hdr
  const showCanvas = !mediaActive || forceCanvas || useVideoShader
  const showVideoEl = mediaActive && !forceCanvas
  // Native-anchor unified IME display:
  // Instead of hiding the <textarea> and guessing an offset (+4 / +50) for a
  // second cosmetic echo div — which inevitably either overlaps or leaves a
  // huge gap depending on OS/IME/upward-vs-downward candidate direction —
  // keep the <textarea> itself at a fixed single-line pill geometry (34px tall)
  // and simply toggle its opacity during composition. The browser & OS IME then
  // snap the candidate bar flush against this exact box automatically on every
  // OS, browser, and IME (WeChat, Sogou, Microsoft Pinyin, Apple Pinyin, etc.).
  const [compositionText, setCompositionText] = useState('')
  const imeResKey = resolutionKey(streamInfo.width, streamInfo.height)
  const imeOffset = useImeOffset(imeResKey)
  const effectiveImeY = Math.max(MIN_IME_BOTTOM, imeOffset.y)
  const isComposingUi = !!compositionText

  // Drag-to-calibrate: the OS candidate window's real size/position varies
  // with the remote machine's resolution/DPI scaling, so no single hardcoded
  // anchor looks right everywhere (see imeOffset.ts). Dragging the echo box
  // directly (no separate "calibration mode") moves both it and the anchor
  // the OS positions its candidate window against, live, and persists on
  // release — scoped to the resolution currently streaming.
  function onEchoMouseDown(e: React.MouseEvent): void {
    e.preventDefault()
    e.stopPropagation()
    const start = { x: e.clientX, y: e.clientY, origX: imeOffset.x, origY: effectiveImeY }
    const onMove = (ev: MouseEvent): void => {
      ev.preventDefault()
      ev.stopPropagation()
      // bottom grows upward on screen, clientY grows downward — invert.
      const nextY = Math.max(MIN_IME_BOTTOM, start.origY - (ev.clientY - start.y))
      setImeOffset(imeResKey, { x: start.origX + (ev.clientX - start.x), y: nextY })
    }
    const onUp = (ev: MouseEvent): void => {
      ev.preventDefault()
      ev.stopPropagation()
      window.removeEventListener('mousemove', onMove, true)
      window.removeEventListener('mouseup', onUp, true)
    }
    // Capture phase, ahead of InputHandler's bubble-phase listeners on the
    // frame div — otherwise dragging here would also move the remote cursor.
    window.addEventListener('mousemove', onMove, true)
    window.addEventListener('mouseup', onUp, true)
  }

  // Reset pan when returning to 1.0x zoom, and clamp pan bounds when zoomed
  useEffect(() => {
    if (clampedZoom <= 1) {
      setPan({ x: 0, y: 0 })
      return
    }
    const el = wrapRef.current
    if (!el || !cssSize) return
    const maxX = Math.max(0, (cssSize.w * clampedZoom - el.clientWidth) / 2)
    const maxY = Math.max(0, (cssSize.h * clampedZoom - el.clientHeight) / 2)
    setPan(prev => ({
      x: Math.max(-maxX, Math.min(maxX, prev.x)),
      y: Math.max(-maxY, Math.min(maxY, prev.y)),
    }))
  }, [clampedZoom, cssSize])

  // Panning when zoomed in: middle-mouse drag or Alt + left-mouse drag
  function onWrapMouseDownCapture(e: React.MouseEvent): void {
    if (clampedZoom <= 1) return
    const isPanGesture = e.button === 1 || (e.button === 0 && e.altKey)
    if (!isPanGesture) return
    e.preventDefault()
    e.stopPropagation()
    const startX = e.clientX
    const startY = e.clientY
    const origX = pan.x
    const origY = pan.y
    const el = wrapRef.current
    const maxX = el && cssSize ? Math.max(0, (cssSize.w * clampedZoom - el.clientWidth) / 2) : 0
    const maxY = el && cssSize ? Math.max(0, (cssSize.h * clampedZoom - el.clientHeight) / 2) : 0
    const onMove = (ev: MouseEvent) => {
      ev.preventDefault()
      ev.stopPropagation()
      const nx = Math.max(-maxX, Math.min(maxX, origX + (ev.clientX - startX)))
      const ny = Math.max(-maxY, Math.min(maxY, origY + (ev.clientY - startY)))
      setPan({ x: nx, y: ny })
    }
    const onUp = (ev: MouseEvent) => {
      ev.preventDefault()
      ev.stopPropagation()
      window.removeEventListener('mousemove', onMove, true)
      window.removeEventListener('mouseup', onUp, true)
    }
    window.addEventListener('mousemove', onMove, true)
    window.addEventListener('mouseup', onUp, true)
  }

  // Recompute canvas CSS size when container or stream dimensions change
  useEffect(() => {
    const el = wrapRef.current
    if (!el) return
    const update = () => {
      const cw = el.clientWidth, ch = el.clientHeight
      if (!cw || !ch) return

      if (scaleMode === 'stretch') {
        setCssSize({ w: cw, h: ch })
        return
      }

      if (scaleMode === 'original') {
        const dpr = window.devicePixelRatio || 1
        setCssSize({ w: streamInfo.width / dpr, h: streamInfo.height / dpr })
        return
      }

      // Default 'fit' mode: scale preserving aspect ratio to fill container without arbitrary clamping
      const ar = streamInfo.width / streamInfo.height
      let w: number, h: number
      if (cw / ch > ar) { w = ch * ar; h = ch }
      else              { w = cw; h = cw / ar }
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
  }, [streamInfo.width, streamInfo.height, scaleMode])

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
      renderer.setSharpness(sharpness)
      renderer.setToneMap(toneMap)

      if (!VideoDecoder_.isSupported()) {
        // WebCodecs requires a secure context (HTTPS / localhost).
        // On plain-HTTP LAN connections, VideoDecoder is undefined.
        // Fall back to JPEG: tell the server to switch codec and set up 2D canvas.
        console.warn('[RemoteCanvas] WebCodecs unavailable (non-secure context?), falling back to JPEG')
        jpegFallbackRef.current = true
        setJpegFallback(true)
        conn.sendSetCodec('jpeg')
        return
      }

      const decoder = new VideoDecoder_((frame) => { outCountRef.current++; renderer.renderFrame(frame) })
      decoder.onOverloaded = () => {
        console.warn('[Decoder] decode queue overloaded, requesting keyframe')
        conn.sendRequestKeyframe()
      }
      decoderRef.current = decoder
      conn.decodeMsProvider = () => decoder.lastDecodeMs
      decoder.init(streamInfo.width, streamInfo.height, initialCodec as VideoCodec, {
        chroma444: chroma444Ref.current,
        hdr: hdrRef.current,
      }).catch((err) => {
        initErrRef.current = String(err); console.error(err)
        // Decoder can't be configured here → ask the server for JPEG frames instead.
        console.warn('[RemoteCanvas] H.264 decoder unavailable, falling back to JPEG')
        decoderRef.current = null
        jpegFallbackRef.current = true
        setJpegFallback(true)
        conn.sendSetCodec('jpeg')
      })
      console.log('[RemoteCanvas] H.264 mode, decoder initializing')
      // This decoder is brand new and won't decode anything until it gets a
      // keyframe (Decoder.ts buffers/drops delta frames until then) — ask the
      // encoder for one now instead of waiting for its next scheduled one
      // (up to 2s away), which is what made switching tabs show a black
      // screen for a few seconds.
      conn.sendRequestKeyframe()
    }

    // Input attaches to the frame container (which exactly bounds whichever
    // of canvas/video is showing), so coordinate mapping is identical on
    // both the RTP and fallback paths.
    if (frameRef.current) {
      inputRef.current.attach(frameRef.current, streamInfo.width, streamInfo.height, imeRef.current ?? undefined)
    }

    return () => {
      if (rvfcIdRef.current !== null && videoRef.current && 'cancelVideoFrameCallback' in videoRef.current) {
        videoRef.current.cancelVideoFrameCallback(rvfcIdRef.current)
        rvfcIdRef.current = null
      }
      decoderRef.current?.close()
      decoderRef.current = null
      conn.decodeMsProvider = null
      rendererRef.current.detach()
      inputRef.current.detach()
      ctx2dRef.current = null
    }
  }, [streamInfo, initialCodec])

  // Sync GPU CAS sharpness and ACES SDR tone-mapping settings to WebGL2 renderer
  useEffect(() => {
    rendererRef.current.setSharpness(sharpness)
    rendererRef.current.setToneMap(toneMap)
    if (useVideoShader && videoRef.current && videoRef.current.readyState >= 2) {
      rendererRef.current.renderVideo(videoRef.current)
    }
  }, [sharpness, toneMap, useVideoShader])

  // Reconfigure WebCodecs decoder when 4:4:4 or 10-bit HDR mode changes
  useEffect(() => {
    const decoder = decoderRef.current
    if (!decoder || initialCodec === 'jpeg') return
    if (decoder.chroma444 === chroma444 && decoder.hdr === hdr) return
    decoder.switchCodec(streamInfo.width, streamInfo.height, decoder.codec, { chroma444, hdr }).catch(console.error)
    conn.sendRequestKeyframe()
  }, [chroma444, hdr, streamInfo.width, streamInfo.height, initialCodec, conn])

  // Tab switched away: this canvas stays mounted (decoder keeps decoding in
  // the background, see App.tsx), but its keyboard capture must not — else
  // it keeps eating keystrokes meant for whichever tab you switched to.
  useEffect(() => {
    if (!isActive) inputRef.current.deactivate()
  }, [isActive])

  // RTP video track: hand it to the <video> element — the browser owns
  // jitter buffering, decode and render from here.
  //
  // Visibility is sticky once the track arrives: it does NOT follow
  // track.muted. ScreenCaptureKit only emits a frame when the screen content
  // actually changes, so libwebrtc's source — and therefore the track's
  // `muted` flag — flips on/off constantly on an idle/static screen (e.g.
  // just reading a page without scrolling). The server also stops sending WS
  // fallback frames once RTP is up, so the canvas underneath is a single
  // frozen frame from whenever RTP first took over. Following `muted` would
  // swap back to that stale frame every time the screen briefly goes idle —
  // exactly the "jumps between an old and a new frame" symptom. <video>
  // itself already does the right thing on a stall (keeps showing its last
  // frame), so only fall back to canvas on a real failure (track ended).
  function attachMediaStream(stream: MediaStream): void {
    const video = videoRef.current
    if (!video) return
    video.srcObject = stream
    video.play().catch(() => {/* autoplay of muted video is allowed; ignore races */})
    const track = stream.getVideoTracks()[0]
    setMediaActive(true)
    if (track) {
      track.onended = () => setMediaActive(false)
    }
    if (rvfcIdRef.current !== null && 'cancelVideoFrameCallback' in video) {
      video.cancelVideoFrameCallback(rvfcIdRef.current)
      rvfcIdRef.current = null
    }
    // TEMP DIAGNOSTIC — see Connection.sendMouseScroll/markFrameRendered.
    // <video> owns decode/render internally for the RTP path (no per-frame
    // JS callback otherwise), so requestVideoFrameCallback is the only way
    // to know when a frame actually got composited on screen, as opposed to
    // when the server captured/sent it (already measured, and fast).
    // When GPU CAS sharpening or ACES tone-mapping is active on the RTP path,
    // also pump each decoded <video> frame through the WebGL2 VideoRenderer.
    const tick = (): void => {
      conn.markFrameRendered()
      if (useVideoShaderRef.current && video.readyState >= 2) {
        rendererRef.current.renderVideo(video)
      }
      rvfcIdRef.current = video.requestVideoFrameCallback(tick)
    }
    rvfcIdRef.current = video.requestVideoFrameCallback(tick)
  }

  // Wire up video frames + codec_changed events
  useEffect(() => {
    // ontrack can fire (esp. on loopback/LAN with near-instant ICE) before
    // this effect subscribes below — Connection caches that first stream
    // since its emit() has no replay, so pick it up here instead of waiting
    // for an event that already happened.
    const already = conn.currentMediaStream
    if (already) attachMediaStream(already)

    const prev = conn.onEvent
    conn.onEvent = (e) => {
      prev?.(e)

      if (e.type === 'video_frame') {
        rxCountRef.current++
        if (initialCodec === 'jpeg' || jpegFallbackRef.current) {
          // JPEG 模式（含解码器不可用时的降级）：画到独立的 2D canvas（主 canvas 可能已被 WebGL 占用）
          const blob = new Blob([e.data], { type: 'image/jpeg' })
          createImageBitmap(blob).then((bmp) => {
            const jc = jpegCanvasRef.current
            const ctx = jc?.getContext('2d')
            if (jc && ctx) {
              if (jc.width !== bmp.width || jc.height !== bmp.height) { jc.width = bmp.width; jc.height = bmp.height }
              ctx.drawImage(bmp, 0, 0)
              outCountRef.current++
            }
            bmp.close()
          }).catch(() => {/* ignore decode errors */})
        } else if (decoderRef.current) {
          decoderRef.current.decode(e.data, e.keyframe, e.ptsMs * 1000)
        }
      }

      if (e.type === 'codec_changed' && decoderRef.current) {
        console.log(`[RemoteCanvas] switching decoder to ${e.codec}`)
        decoderRef.current.switchCodec(streamInfo.width, streamInfo.height, e.codec, {
          chroma444: chroma444Ref.current,
          hdr: hdrRef.current,
        }).catch(console.error)
      }

      // Keep local controller's native cursor — do not swap to remote cursor_shape PNG.

      if (e.type === 'media_stream') attachMediaStream(e.stream)
    }
    return () => { conn.onEvent = prev }
  }, [conn, streamInfo, initialCodec])

  return (
    <div
      ref={wrapRef}
      onMouseDownCapture={onWrapMouseDownCapture}
      style={{
        width: '100%', height: '100%',
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        position: 'relative', overflow: 'hidden',
      }}
    >
      {/* The frame div is the single interactive surface (input handler +
          cursor shape live here) and exactly bounds the picture, so the
          RTP <video> and the fallback canvas map coordinates identically. */}
      <div
        ref={frameRef}
        tabIndex={0}
        style={{
          position: 'relative',
          width:  cssSize ? cssSize.w * clampedZoom : '100%',
          height: cssSize ? cssSize.h * clampedZoom : '100%',
          flexShrink: 0,
          transform: clampedZoom > 1 ? `translate(${pan.x}px, ${pan.y}px)` : undefined,
          cursor: 'default',
          outline: 'none',
        }}
      >
        <canvas
          ref={canvasRef}
          style={{
            position: 'absolute', inset: 0, width: '100%', height: '100%',
            display: showCanvas ? 'block' : 'none',
            zIndex: useVideoShader ? 1 : undefined,
            pointerEvents: 'none',
          }}
        />
        {diag && outCountRef.current === 0 && (
          <div style={{ position: 'absolute', left: 8, right: 8, bottom: 8, zIndex: 5, padding: 8, background: 'rgba(0,0,0,.8)', color: '#ffb4b4', font: '12px monospace', pointerEvents: 'none' }}>
            无画面诊断：{diag}
          </div>
        )}
        <canvas
          ref={jpegCanvasRef}
          style={{
            position: 'absolute', inset: 0, width: '100%', height: '100%',
            display: (jpegFallback || initialCodec === 'jpeg') ? 'block' : 'none',
            zIndex: 2, pointerEvents: 'none',
          }}
        />
        <video
          ref={videoRef}
          muted
          playsInline
          style={{
            position: 'absolute', inset: 0, width: '100%', height: '100%',
            display: showVideoEl ? 'block' : 'none',
            opacity: useVideoShader ? 0 : 1,
            pointerEvents: 'none',
            objectFit: 'fill',   // the frame div already has the correct aspect ratio
          }}
        />
        {/* Unified IME staging & composition box:
            Fixed single-line pill geometry (width 240, height 34) that never
            resizes when composition starts/ends. When idle it is opacity: 0
            (invisible while holding focus); while composing it becomes
            opacity: 1 in place, so the OS/browser anchors the candidate window
            flush against this exact box regardless of OS, browser, or IME. */}
        <textarea
          ref={imeRef}
          tabIndex={-1}
          wrap="off"
          autoCapitalize="off"
          autoCorrect="off"
          spellCheck={false}
          onCompositionStart={() => setCompositionText('')}
          onCompositionUpdate={(e) => setCompositionText(e.data)}
          onCompositionEnd={() => setCompositionText('')}
          style={{
            position: 'absolute', left: `calc(50% + ${imeOffset.x}px)`, bottom: effectiveImeY,
            width: 240, height: 34, boxSizing: 'border-box',
            padding: '4px 10px', border: '2px solid #000', borderRadius: 4,
            boxShadow: '0 2px 8px rgba(0, 0, 0, 0.25)',
            background: '#fff', color: '#111',
            fontSize: 15, lineHeight: '22px', fontFamily: 'inherit',
            whiteSpace: 'pre', overflow: 'hidden', resize: 'none', outline: 'none',
            opacity: isComposingUi ? 1 : 0,
            pointerEvents: 'none',
            zIndex: isComposingUi ? 10 : -1,
          }}
        />
        {/* Calibration-only draggable handle at the exact same rect as the
            <textarea> above, shown only when user explicitly toggles IME
            position calibration. */}
        {imeCalibrating && (
          <div
            onMouseDownCapture={onEchoMouseDown}
            style={{
              position: 'absolute', left: `calc(50% + ${imeOffset.x}px)`, bottom: effectiveImeY,
              width: 240, height: 34, boxSizing: 'border-box',
              display: 'flex', alignItems: 'center', justifyContent: 'center',
              padding: '4px 10px', border: '2px solid #000', borderRadius: 4,
              boxShadow: '0 2px 8px rgba(0, 0, 0, 0.25)',
              background: '#fff', color: '#111', fontSize: 14,
              whiteSpace: 'pre', pointerEvents: 'auto', cursor: 'move', zIndex: 11,
            }}
          >
            拖动调整输入法位置
          </div>
        )}
      </div>
    </div>
  )
}
