import React, { useState, useEffect, useRef } from 'react'
import { ConnectPage } from './pages/ConnectPage'
import { DesktopPage } from './pages/DesktopPage'
import { Connection } from './network/Connection'
import { ConnectParams, ConnectionState, StreamInfo } from './types'
import { VideoCodec } from './video/Decoder'

export default function App() {
  const connRef  = useRef<Connection>(new Connection())
  const [state, setState]           = useState<ConnectionState>('idle')
  const [streamInfo, setStreamInfo] = useState<StreamInfo | null>(null)
  const [codec, setCodec]           = useState<VideoCodec | 'jpeg'>('jpeg')
  const [errorMsg, setErrorMsg]     = useState('')

  useEffect(() => {
    const conn = connRef.current
    conn.onEvent = (e) => {
      switch (e.type) {
        case 'state':
          setState(e.state)
          if (e.state !== 'error') setErrorMsg('')
          break
        case 'stream_started':
          setStreamInfo(e.info)
          setCodec(e.codec ?? 'h264')
          setState('streaming')
          break
        case 'error':
          setErrorMsg(e.message)
          break
        case 'clipboard':
          navigator.clipboard.writeText(e.text).catch(() => {})
          break
      }
    }
    return () => { conn.onEvent = null }
  }, [])

  function handleConnect(params: ConnectParams) {
    setErrorMsg('')
    connRef.current.connect(params)
  }

  function handleDisconnect() {
    connRef.current.disconnect()
    setStreamInfo(null)
    setState('idle')
  }

  // 远程桌面页全屏，不需要拖拽条
  if (state === 'streaming' && streamInfo) {
    return (
      <DesktopPage
        conn={connRef.current}
        streamInfo={streamInfo}
        initialCodec={codec}
        onDisconnect={handleDisconnect}
      />
    )
  }

  return (
    <>
      {/* macOS hiddenInset 模式下的不可见拖拽区域，让窗口可以被拖动 */}
      <div style={{
        position: 'fixed', top: 0, left: 0, right: 0,
        height: 28,
        // @ts-ignore
        WebkitAppRegion: 'drag',
        zIndex: 9999,
        pointerEvents: 'none'   // 不拦截点击，让下方内容正常交互
      }} />
      <ConnectPage
        onConnect={handleConnect}
        isConnecting={state === 'connecting' || state === 'authenticating'}
        errorMsg={errorMsg}
      />
    </>
  )
}
