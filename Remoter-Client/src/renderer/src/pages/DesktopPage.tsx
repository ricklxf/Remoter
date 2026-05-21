import React, { useEffect, useState, useCallback } from 'react'
import { Connection } from '../network/Connection'
import { StreamInfo } from '../types'
import { RemoteCanvas } from '../components/RemoteCanvas'
import { Toolbar } from '../components/Toolbar'

interface Props {
  conn: Connection
  streamInfo: StreamInfo
  onDisconnect: () => void
}

export function DesktopPage({ conn, streamInfo, onDisconnect }: Props) {
  const [fps, setFps]         = useState(60)
  const [bitrate, setBitrate] = useState(15_000_000)
  const [toolbarVisible, setToolbarVisible] = useState(true)
  const [hideTimer, setHideTimer]           = useState<ReturnType<typeof setTimeout> | null>(null)

  // Auto-hide toolbar after 3s of no mouse movement at top
  const showToolbar = useCallback(() => {
    setToolbarVisible(true)
    if (hideTimer) clearTimeout(hideTimer)
    const t = setTimeout(() => setToolbarVisible(false), 3000)
    setHideTimer(t)
  }, [hideTimer])

  useEffect(() => {
    showToolbar()
    return () => { if (hideTimer) clearTimeout(hideTimer) }
  }, [])

  function handleQualityChange(f: number, b: number) {
    setFps(f)
    setBitrate(b)
  }

  function handleToggleFullscreen() {
    window.remoterAPI?.toggleFullscreen()
  }

  return (
    <div
      style={styles.wrap}
      onMouseMove={showToolbar}
    >
      <RemoteCanvas
        conn={conn}
        streamInfo={streamInfo}
        showCursor={true}
      />

      <div style={{ ...styles.toolbarWrap, opacity: toolbarVisible ? 1 : 0 }}>
        <Toolbar
          conn={conn}
          onDisconnect={onDisconnect}
          onToggleFullscreen={handleToggleFullscreen}
          fps={fps}
          bitrate={bitrate}
          onQualityChange={handleQualityChange}
        />
      </div>

      <div style={styles.statusDot} title="已连接" />
    </div>
  )
}

const styles: Record<string, React.CSSProperties> = {
  wrap: {
    position: 'relative', width: '100%', height: '100%',
    background: '#000', overflow: 'hidden'
  },
  toolbarWrap: {
    transition: 'opacity 0.3s',
    pointerEvents: 'auto'
  },
  statusDot: {
    position: 'absolute', bottom: 12, right: 12,
    width: 8, height: 8, borderRadius: '50%',
    background: '#4caf50', boxShadow: '0 0 6px #4caf50'
  }
}

// Extend window for preload API
declare global {
  interface Window {
    remoterAPI?: {
      toggleFullscreen: () => void
      saveFileDialog: (name: string) => Promise<string | null>
    }
  }
}
