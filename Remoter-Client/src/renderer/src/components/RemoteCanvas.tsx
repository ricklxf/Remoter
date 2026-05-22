import React, { useEffect, useRef, useCallback } from 'react'
import { Connection } from '../network/Connection'
import { VideoDecoder_, VideoCodec } from '../video/Decoder'
import { VideoRenderer } from '../video/Renderer'
import { InputHandler } from '../input/InputHandler'
import { StreamInfo } from '../types'

interface Props {
  conn: Connection
  streamInfo: StreamInfo
  initialCodec?: VideoCodec
  showCursor: boolean
}

export function RemoteCanvas({ conn, streamInfo, initialCodec = 'h264', showCursor }: Props) {
  const canvasRef   = useRef<HTMLCanvasElement>(null)
  const decoderRef  = useRef<VideoDecoder_ | null>(null)
  const rendererRef = useRef<VideoRenderer>(new VideoRenderer())
  const inputRef    = useRef<InputHandler>(new InputHandler(conn))

  // Init decoder + renderer when stream info arrives
  useEffect(() => {
    const canvas = canvasRef.current
    if (!canvas) return

    const renderer = rendererRef.current
    renderer.resize(streamInfo.width, streamInfo.height)
    renderer.attach(canvas)

    if (!VideoDecoder_.isSupported()) {
      console.error('WebCodecs not supported in this Electron version')
      return
    }

    const decoder = new VideoDecoder_((frame) => renderer.renderFrame(frame))
    decoderRef.current = decoder
    // init 是 async（H.265 需要 isConfigSupported 检查），不阻塞渲染流程
    decoder.init(streamInfo.width, streamInfo.height, initialCodec).catch(console.error)

    inputRef.current.attach(canvas, streamInfo.width, streamInfo.height)

    return () => {
      decoder.close()
      renderer.detach()
      inputRef.current.detach()
    }
  }, [streamInfo, initialCodec])

  // Wire up video frames + codec_changed events from connection
  useEffect(() => {
    const prev = conn.onEvent
    conn.onEvent = (e) => {
      prev?.(e)
      if (e.type === 'video_frame' && decoderRef.current) {
        decoderRef.current.decode(e.data, e.keyframe, e.ptsMs * 1000)
      }
      if (e.type === 'codec_changed' && decoderRef.current) {
        console.log(`[RemoteCanvas] switching decoder to ${e.codec}`)
        decoderRef.current.switchCodec(streamInfo.width, streamInfo.height, e.codec).catch(console.error)
      }
    }
    return () => { conn.onEvent = prev }
  }, [conn, streamInfo])

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
