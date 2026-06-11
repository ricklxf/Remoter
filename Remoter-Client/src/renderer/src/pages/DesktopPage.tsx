import React, { useEffect, useState, useCallback, useRef } from 'react'
import { Connection } from '../network/Connection'
import { StreamInfo, FileTransfer } from '../types'
import { ConnStats } from '../network/Connection'
import { RemoteCanvas } from '../components/RemoteCanvas'
import { Toolbar } from '../components/Toolbar'
import { StatsHUD } from '../components/StatsHUD'
import { FileTransferWindow } from '../components/FileTransferWindow'
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
  const [showStats, setShowStats]         = useState(false)
  const [showTransfers, setShowTransfers] = useState(false)
  const [toolbarVisible, setToolbarVisible] = useState(false)

  // Auto-show transfers panel when a new transfer starts
  const prevTransfersLen = useRef(0)
  useEffect(() => {
    if (transfers.length > prevTransfersLen.current) {
      setShowTransfers(true)
    }
    prevTransfersLen.current = transfers.length
  }, [transfers.length])

  function handleQualityChange(f: number, b: number) {
    setFps(f)
    setBitrate(b)
  }

  const toggleToolbar = useCallback(() => setToolbarVisible(v => !v), [])

  return (
    <div style={styles.wrap}>
      <RemoteCanvas
        conn={conn}
        streamInfo={streamInfo}
        initialCodec={initialCodec}
        showCursor={true}
      />

      {showStats && <StatsHUD stats={stats} visible={showStats} />}

      {showTransfers && (
        <FileTransferWindow
          conn={conn}
          transfers={transfers}
          onClose={() => setShowTransfers(false)}
        />
      )}

      {/* Always-visible floating trigger button */}
      <button
        style={{
          ...styles.floatTrigger,
          ...(toolbarVisible ? styles.floatTriggerActive : {}),
        }}
        onClick={toggleToolbar}
        title={toolbarVisible ? '隐藏工具栏' : '显示工具栏'}
      >
        <span style={{ fontSize: 14 }}>≡</span>
        {transfers.filter(t => !t.done).length > 0 && (
          <span style={styles.floatBadge}>{transfers.filter(t => !t.done).length}</span>
        )}
      </button>

      {toolbarVisible && (
        <div style={styles.toolbarWrap}>
          <Toolbar
            conn={conn}
            onHide={toggleToolbar}
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
      )}
    </div>
  )
}

const styles: Record<string, React.CSSProperties> = {
  wrap: { position: 'relative', width: '100%', height: '100%', background: '#000', overflow: 'hidden' },
  toolbarWrap: { pointerEvents: 'auto' },
  floatTrigger: {
    position: 'absolute',
    top: 10,
    right: 10,
    zIndex: 120,
    display: 'flex',
    alignItems: 'center',
    gap: 4,
    padding: '5px 10px',
    background: 'rgba(20,20,25,0.7)',
    backdropFilter: 'blur(8px)',
    WebkitBackdropFilter: 'blur(8px)',
    border: '1px solid rgba(255,255,255,0.12)',
    borderRadius: 8,
    color: 'rgba(255,255,255,0.85)',
    cursor: 'pointer',
    fontSize: 13,
    userSelect: 'none',
    pointerEvents: 'auto',
  },
  floatTriggerActive: {
    background: 'rgba(233,69,96,0.25)',
    border: '1px solid rgba(233,69,96,0.4)',
    color: '#fff',
  },
  floatBadge: {
    fontSize: 10,
    fontWeight: 700,
    background: '#e94560',
    color: '#fff',
    borderRadius: 10,
    padding: '1px 5px',
    lineHeight: '14px',
  },
}
