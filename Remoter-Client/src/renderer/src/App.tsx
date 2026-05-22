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
  const [codec, setCodec]           = useState<VideoCodec>('h264')
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
    <ConnectPage
      onConnect={handleConnect}
      isConnecting={state === 'connecting' || state === 'authenticating'}
      errorMsg={errorMsg}
    />
  )
}
