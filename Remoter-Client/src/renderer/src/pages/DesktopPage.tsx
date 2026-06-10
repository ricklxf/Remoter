import React, { useEffect, useState, useCallback, useRef } from 'react'
import { Connection } from '../network/Connection'
import { StreamInfo, FileTransfer } from '../types'
import { ConnStats } from '../network/Connection'
import { RemoteCanvas } from '../components/RemoteCanvas'
import { Toolbar } from '../components/Toolbar'
import { StatsHUD } from '../components/StatsHUD'
import { FileTransferPanel } from '../components/FileTransferPanel'
import { VideoCodec } from '../video/Decoder'

interface Props {
  conn: Connection
  streamInfo: StreamInfo
  initialCodec?: VideoCodec | 'jpeg'
  stats: ConnStats
  transfers: FileTransfer[]
  onDisconnect: () => void
}

export function DesktopPage({ conn, streamInfo, initialCodec = 'jpeg', stats, transfers, onDisconnect }: Props) {
  const [fps, setFps]         = useState(60)
  const [bitrate, setBitrate] = useState(15_000_000)
  const [showStats, setShowStats]     = useState(false)
  const [showTransfers, setShowTransfers] = useState(false)
  const [toolbarVisible, setToolbarVisible] = useState(true)
  const hideTimer = useRef<ReturnType<typeof setTimeout> | null>(null)

  // Auto-show transfers panel when a new transfer starts
  const prevTransfersLen = useRef(0)
  useEffect(() => {
    if (transfers.length > prevTransfersLen.current) {
      setShowTransfers(true)
    }
    prevTransfersLen.current = transfers.length
  }, [transfers.length])

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
      <RemoteCanvas
        conn={conn}
        streamInfo={streamInfo}
        initialCodec={initialCodec}
        showCursor={true}
      />

      {showStats && <StatsHUD stats={stats} visible={showStats} />}

      {showTransfers && (
        <FileTransferPanel
          transfers={transfers}
          onClose={() => setShowTransfers(false)}
        />
      )}

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
          transferCount={transfers.filter(t => !t.done).length}
          onToggleTransfers={() => setShowTransfers(v => !v)}
          showTransfers={showTransfers}
        />
      </div>
    </div>
  )
}

const styles: Record<string, React.CSSProperties> = {
  wrap: { position: 'relative', width: '100%', height: '100%', background: '#000', overflow: 'hidden' },
  toolbarWrap: { transition: 'opacity 0.3s', pointerEvents: 'auto' }
}
