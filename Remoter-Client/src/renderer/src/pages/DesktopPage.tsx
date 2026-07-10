import React, { useEffect, useState, useCallback, useRef } from 'react'
import { Connection } from '../network/Connection'
import { StreamInfo, FileTransfer } from '../types'
import { RemoteCanvas } from '../components/RemoteCanvas'
import { Toolbar } from '../components/Toolbar'
import { FileTransferWindow } from '../components/FileTransferWindow'
import { VideoCodec } from '../video/Decoder'
import { AudioPlayer } from '../audio/AudioPlayer'

interface Props {
  conn: Connection
  streamInfo: StreamInfo
  initialCodec?: VideoCodec | 'jpeg'
  transfers: FileTransfer[]
  isReconnecting?: boolean
  isActive?: boolean
  onDisconnect: () => void
}

export function DesktopPage({ conn, streamInfo, initialCodec = 'jpeg', transfers, isReconnecting = false, isActive = true, onDisconnect }: Props) {
  const isWeb = window.remoterAPI?.platform === 'web' || !window.remoterAPI
  const [fps, setFps]         = useState(30)
  const [fpsAuto, setFpsAuto] = useState(true)
  const [bitrate, setBitrate] = useState(2_000_000)
  const [bitrateAuto, setBitrateAuto] = useState(true)
  // Matches the server's own default (resolutionMaxDimension = 1920) — no
  // need to send this on mount like the fps/bitrate auto default, since
  // both sides already agree without a message.
  const [resolution, setResolution] = useState<'1080' | '2k'>('1080')
  // Manual pick only (both sides default to h264); jpeg fallback is chosen
  // by the connection layer itself, not from this menu.
  const [codec, setCodec] = useState<'h264' | 'h265'>('h264')
  // Remote system-audio forwarding — off by default (bandwidth + privacy:
  // don't silently pick up whatever's playing on the remote machine).
  const [audioOn, setAudioOn] = useState(false)
  const audioPlayerRef = useRef<AudioPlayer | null>(null)
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

  // Default is "自动" for both — tell the server to actually enable auto
  // stepping (not just apply the floor tier once and leave it fixed).
  // Without this, the server only knows to adapt after the user opens the
  // menu and picks it manually. fps and bitrate are independent, so both
  // get enabled separately.
  useEffect(() => {
    conn.sendFps(fps, true)
    conn.sendBitrate(bitrate, true)
  }, []) // eslint-disable-line react-hooks/exhaustive-deps

  // Server pushes the values it's actually running whenever auto mode
  // steps either one up/down, so the toolbar reflects reality instead of
  // staying stuck on whatever was picked (or the initial default) forever.
  // Also routes incoming audio packets into the player when enabled.
  useEffect(() => {
    const prev = conn.onEvent
    conn.onEvent = (e) => {
      prev?.(e)
      if (e.type === 'quality_active') {
        setFps(e.fps)
        setBitrate(e.bitrate)
      }
      if (e.type === 'audio_frame') {
        audioPlayerRef.current?.push(e.data)
      }
    }
    return () => { conn.onEvent = prev }
  }, [conn])

  // Tear the audio player down with the page (tab close / disconnect).
  useEffect(() => () => { audioPlayerRef.current?.stop(); audioPlayerRef.current = null }, [])

  function handleToggleAudio() {
    const next = !audioOn
    setAudioOn(next)
    conn.sendSetAudio(next)
    if (next) {
      const player = new AudioPlayer()
      player.start()   // inside the click handler, so autoplay policy permits it
      audioPlayerRef.current = player
    } else {
      audioPlayerRef.current?.stop()
      audioPlayerRef.current = null
    }
  }

  function handleFpsChange(f: number, auto: boolean) {
    setFps(f)
    setFpsAuto(auto)
  }

  function handleBitrateChange(b: number, auto: boolean) {
    setBitrate(b)
    setBitrateAuto(auto)
  }

  const toggleToolbar = useCallback(() => setToolbarVisible(v => !v), [])

  return (
    <div style={styles.wrap}>
      <RemoteCanvas
        conn={conn}
        streamInfo={streamInfo}
        initialCodec={initialCodec}
        isActive={isActive}
      />

      {showTransfers && (
        <FileTransferWindow
          conn={conn}
          transfers={transfers}
          onClose={() => setShowTransfers(false)}
        />
      )}

      {isReconnecting && (
        <div style={styles.reconnectBanner}>
          <span style={{ marginRight: 8 }}>⟳</span>正在重连…
        </div>
      )}

      {/* Web-only: disconnect button */}
      {isWeb && (
        <button style={styles.webDisconnect} onClick={onDisconnect} title="断开连接">
          ✕ 断开
        </button>
      )}

      {/* Floating trigger — only visible when toolbar is hidden */}
      {!toolbarVisible && <button
        style={styles.floatTrigger}
        onClick={toggleToolbar}
        title="显示工具栏"
      >
        <span style={{ fontSize: 11, lineHeight: 1 }}>▼</span>
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
            fpsAuto={fpsAuto}
            onFpsChange={handleFpsChange}
            bitrate={bitrate}
            bitrateAuto={bitrateAuto}
            onBitrateChange={handleBitrateChange}
            resolution={resolution}
            onResolutionChange={setResolution}
            codec={codec}
            onCodecChange={setCodec}
            audioOn={audioOn}
            onToggleAudio={handleToggleAudio}
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
  wrap: { position: 'relative', width: '100%', height: '100%', background: 'var(--canvas-surround)', overflow: 'hidden' },
  reconnectBanner: {
    position: 'absolute',
    top: 12,
    left: '50%',
    transform: 'translateX(-50%)',
    zIndex: 200,
    padding: '6px 18px',
    borderRadius: 20,
    background: 'rgba(0,0,0,0.72)',
    color: '#fff',
    fontSize: 13,
    backdropFilter: 'blur(4px)',
    display: 'flex',
    alignItems: 'center',
    pointerEvents: 'none',
  },
  toolbarWrap: { pointerEvents: 'auto' },
  floatTrigger: {
    position: 'absolute',
    top: 0,
    left: '50%',
    transform: 'translateX(-50%)',
    zIndex: 120,
    display: 'flex',
    alignItems: 'center',
    gap: 3,
    padding: '2px 10px 4px',
    background: 'var(--ov-bg)',
    backdropFilter: 'blur(12px)',
    WebkitBackdropFilter: 'blur(12px)',
    border: '1px solid var(--ov-border)',
    borderTop: 'none',
    borderRadius: '0 0 6px 6px',
    color: 'var(--ov-text)',
    cursor: 'pointer',
    fontSize: 11,
    userSelect: 'none',
    pointerEvents: 'auto',
    whiteSpace: 'nowrap',
    boxShadow: '0 3px 8px rgba(0,0,0,0.10)',
  },
  webDisconnect: {
    position: 'absolute' as const,
    top: 8,
    right: 8,
    zIndex: 150,
    padding: '4px 10px',
    background: 'rgba(0,0,0,0.55)',
    backdropFilter: 'blur(8px)',
    WebkitBackdropFilter: 'blur(8px)',
    border: '1px solid rgba(255,255,255,0.18)',
    borderRadius: 6,
    color: '#fff',
    cursor: 'pointer',
    fontSize: 12,
    userSelect: 'none' as const,
    pointerEvents: 'auto' as const,
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
