import React, { useEffect, useRef, useCallback } from 'react'
import { Connection } from '../network/Connection'
import { H264Decoder } from '../video/Decoder'
import { VideoRenderer } from '../video/Renderer'
import { InputHandler } from '../input/InputHandler'
import { StreamInfo } from '../types'

interface Props {
  conn: Connection
  streamInfo: StreamInfo
  showCursor: boolean
}

export function RemoteCanvas({ conn, streamInfo, showCursor }: Props) {
  const canvasRef   = useRef<HTMLCanvasElement>(null)
  const decoderRef  = useRef<H264Decoder | null>(null)
  const rendererRef = useRef<VideoRenderer>(new VideoRenderer())
  const inputRef    = useRef<InputHandler>(new InputHandler(conn))

  // Init decoder + renderer when stream info arrives
  useEffect(() => {
    const canvas = canvasRef.current
    if (!canvas) return

    const renderer = rendererRef.current
    renderer.resize(streamInfo.width, streamInfo.height)
    renderer.attach(canvas)

    if (!H264Decoder.isSupported()) {
      console.error('WebCodecs not supported in this Electron version')
      return
    }

    const decoder = new H264Decoder((frame) => renderer.renderFrame(frame))
    decoder.init(streamInfo.width, streamInfo.height)
    decoderRef.current = decoder

    inputRef.current.attach(canvas, streamInfo.width, streamInfo.height)

    return () => {
      decoder.close()
      renderer.detach()
      inputRef.current.detach()
    }
  }, [streamInfo])

  // Wire up video frames from connection
  useEffect(() => {
    const prev = conn.onEvent
    conn.onEvent = (e) => {
      prev?.(e)
      if (e.type === 'video_frame' && decoderRef.current) {
        decoderRef.current.decode(e.data, e.keyframe, e.ptsMs * 1000)
      }
    }
    return () => { conn.onEvent = prev }
  }, [conn])

  // Sync cursor style
  const cursor = showCursor ? 'none' : 'default'

  return (
    <canvas
      ref={canvasRef}
      tabIndex={0}
      style={{
        display: 'block',
        width: '100%',
        height: '100%',
        objectFit: 'contain',
        cursor,
        outline: 'none',
        background: '#000'
      }}
    />
  )
}
