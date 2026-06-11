import React, { useEffect, useState, useCallback, useRef } from 'react'
import { Connection } from '../network/Connection'
import { StreamInfo, FileTransfer } from '../types'
import { ConnStats } from '../network/Connection'
import { RemoteCanvas } from '../components/RemoteCanvas'
import { Toolbar } from '../components/Toolbar'
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
  const [showTransfers, setShowTransfers] = useState(false)
  const [toolbarVisible, setToolbarVisible] = useState(false)
  const hideTimerRef = useRef<ReturnType<typeof setTimeout>>()

  // Cancel hide timer on unmount
  useEffect(() => () => clearTimeout(hideTimerRef.current), [])

  const startHideTimer = useCallback(() => {
    hideTimerRef.current = setTimeout(() => setToolbarVisible(false), 3000)
  }, [])

  const cancelHideTimer = useCallback(() => {
    clearTimeout(hideTimerRef.current)
  }, [])

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

      {showTransfers && (
        <FileTransferWindow
          conn={conn}
          transfers={transfers}
          onClose={() => setShowTransfers(false)}
        />
      )}

      {/* Floating trigger — only visible when toolbar is hidden */}
      {!toolbarVisible && <button
        style={styles.floatTrigger}
        onClick={toggleToolbar}
        title="显示工具栏"
      >
        <span style={{ fontSize: 18, lineHeight: 1 }}>↓</span>
        {transfers.filter(t => !t.done).length > 0 && (
          <span style={styles.floatBadge}>{transfers.filter(t => !t.done).length}</span>
        )}
      </button>}

      {toolbarVisible && (
        <div style={styles.toolbarWrap}>
          <Toolbar
            conn={conn}
            onHide={toggleToolbar}
            onToggleFullscreen={() => window.remoterAPI?.toggleFullscreen()}
            fps={fps}
            bitrate={bitrate}
            onQualityChange={handleQualityChange}
            transferCount={transfers.filter(t => !t.done).length}
            onToggleTransfers={() => setShowTransfers(v => !v)}
            showTransfers={showTransfers}
            onMouseEnter={cancelHideTimer}
            onMouseLeave={startHideTimer}
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
    top: 0,
    left: '50%',
    transform: 'translateX(-50%)',
    zIndex: 120,
    display: 'flex',
    alignItems: 'center',
    gap: 4,
    padding: '5px 16px 7px',
    background: 'var(--ov-bg)',
    backdropFilter: 'blur(12px)',
    WebkitBackdropFilter: 'blur(12px)',
    border: '1px solid var(--ov-border)',
    borderTop: 'none',
    borderRadius: '0 0 8px 8px',
    color: 'var(--ov-text)',
    cursor: 'pointer',
    fontSize: 13,
    userSelect: 'none',
    pointerEvents: 'auto',
    whiteSpace: 'nowrap',
    boxShadow: '0 4px 12px rgba(0,0,0,0.12)',
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
