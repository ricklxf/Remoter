import React, { useEffect, useRef } from 'react'
import { Connection } from '../network/Connection'
import { VideoDecoder_, VideoCodec } from '../video/Decoder'
import { VideoRenderer } from '../video/Renderer'
import { InputHandler } from '../input/InputHandler'
import { StreamInfo } from '../types'

interface Props {
  conn: Connection
  streamInfo: StreamInfo
  initialCodec?: VideoCodec | 'jpeg'
  showCursor: boolean
}

export function RemoteCanvas({ conn, streamInfo, initialCodec = 'h264', showCursor }: Props) {
  const canvasRef   = useRef<HTMLCanvasElement>(null)
  const decoderRef  = useRef<VideoDecoder_ | null>(null)
  const rendererRef = useRef<VideoRenderer>(new VideoRenderer())
  const inputRef    = useRef<InputHandler>(new InputHandler(conn))
  // For JPEG mode: 2D context
  const ctx2dRef    = useRef<CanvasRenderingContext2D | null>(null)

  useEffect(() => {
    const canvas = canvasRef.current
    if (!canvas) return

    canvas.width  = streamInfo.width
    canvas.height = streamInfo.height

    if (initialCodec === 'jpeg') {
      // JPEG 模式：直接用 2D context 渲染，不需要 VideoDecoder
      ctx2dRef.current = canvas.getContext('2d')
      console.log('[RemoteCanvas] JPEG mode, using 2D canvas')
    } else {
      // H.264 / H.265 模式：使用 WebCodecs VideoDecoder
      const renderer = rendererRef.current
      renderer.resize(streamInfo.width, streamInfo.height)
      renderer.attach(canvas)

      if (!VideoDecoder_.isSupported()) {
        console.error('WebCodecs not supported in this Electron version')
        return
      }

      const decoder = new VideoDecoder_((frame) => renderer.renderFrame(frame))
      decoderRef.current = decoder
      decoder.init(streamInfo.width, streamInfo.height, initialCodec as VideoCodec).catch(console.error)
    }

    inputRef.current.attach(canvas, streamInfo.width, streamInfo.height)

    return () => {
      decoderRef.current?.close()
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
    <canvas
      ref={canvasRef}
      tabIndex={0}
      style={{
        display: 'block',
        width: '100%',
        height: '100%',
        objectFit: 'fill',
        cursor: 'default',
        outline: 'none',
        background: '#000'
      }}
    />
  )
}
