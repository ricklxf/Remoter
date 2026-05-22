import React, { useEffect, useState, useCallback, useRef } from 'react'
import { Connection } from '../network/Connection'
import { StreamInfo } from '../types'
import { ConnStats } from '../network/Connection'
import { RemoteCanvas } from '../components/RemoteCanvas'
import { Toolbar } from '../components/Toolbar'
import { StatsHUD } from '../components/StatsHUD'

interface Props {
  conn: Connection
  streamInfo: StreamInfo
  onDisconnect: () => void
}

const DEFAULT_STATS: ConnStats = { fps: 0, rttMs: 0, bitrateKbps: 0, transport: 'TCP' }

export function DesktopPage({ conn, streamInfo, onDisconnect }: Props) {
  const [fps, setFps]         = useState(60)
  const [bitrate, setBitrate] = useState(15_000_000)
  const [stats, setStats]     = useState<ConnStats>(DEFAULT_STATS)
  const [showStats, setShowStats] = useState(true)
  const [toolbarVisible, setToolbarVisible] = useState(true)
  const hideTimer = useRef<ReturnType<typeof setTimeout> | null>(null)

  // 订阅 stats 事件
  useEffect(() => {
    const prev = conn.onEvent
    conn.onEvent = (e) => {
      prev?.(e)
      if (e.type === 'stats') setStats(e.stats)
    }
    return () => { conn.onEvent = prev }
  }, [conn])

  // 自动隐藏工具栏
  const showToolbar = useCallback(() => {
    setToolbarVisible(true)
    if (hideTimer.current) clearTimeout(hideTimer.current)
    hideTimer.current = setTimeout(() => setToolbarVisible(false), 3000)
  }, [])

  useEffect(() => {
    showToolbar()
    return () => { if (hideTimer.current) clearTimeout(hideTimer.current) }
  }, [])

  function handleQualityChange(f: number, b: number) {
    setFps(f)
    setBitrate(b)
  }

  return (
    <div style={styles.wrap} onMouseMove={showToolbar}>
      <RemoteCanvas conn={conn} streamInfo={streamInfo} showCursor={true} />

      <StatsHUD stats={stats} visible={showStats} />

      <div style={{ ...styles.toolbarWrap, opacity: toolbarVisible ? 1 : 0 }}>
        <Toolbar
          conn={conn}
          onDisconnect={onDisconnect}
          onToggleFullscreen={() => window.remoterAPI?.toggleFullscreen()}
          fps={fps}
          bitrate={bitrate}
          onQualityChange={handleQualityChange}
          showStats={showStats}
          onToggleStats={() => setShowStats(v => !v)}
        />
      </div>
    </div>
  )
}

const styles: Record<string, React.CSSProperties> = {
  wrap: { position: 'relative', width: '100%', height: '100%', background: '#000', overflow: 'hidden' },
  toolbarWrap: { transition: 'opacity 0.3s', pointerEvents: 'auto' }
}

declare global {
  interface Window {
    remoterAPI?: {
      toggleFullscreen: () => void
      saveFileDialog: (name: string) => Promise<string | null>
    }
  }
}
