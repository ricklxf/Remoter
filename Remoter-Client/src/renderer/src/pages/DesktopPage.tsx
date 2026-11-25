import React, { useEffect, useState, useCallback, useRef } from 'react'
import { Connection, ConnStats } from '../network/Connection'
import { StreamInfo, FileTransfer, ResolutionTier, ScaleMode, SharpnessLevel, ChromaMode, QualityPreset, ClipboardFileItem } from '../types'
import { extractDroppedEntries } from '../utils/fileEntries'
import { RemoteCanvas } from '../components/RemoteCanvas'
import { StatsHUD } from '../components/StatsHUD'
import { Toolbar } from '../components/Toolbar'
import { FileTransferWindow } from '../components/FileTransferWindow'
import { VideoCodec } from '../video/Decoder'
import { AudioPlayer } from '../audio/AudioPlayer'
import { MicCapturer } from '../audio/MicCapturer'

interface Props {
  conn: Connection
  streamInfo: StreamInfo
  stats: ConnStats
  initialCodec?: VideoCodec | 'jpeg'
  transfers: FileTransfer[]
  isReconnecting?: boolean
  isActive?: boolean
  onDisconnect: () => void
}

export function DesktopPage({ conn, streamInfo, stats, initialCodec = 'jpeg', transfers, isReconnecting = false, isActive = true, onDisconnect }: Props) {
  const isWeb = window.remoterAPI?.platform === 'web' || !window.remoterAPI
  const [qualityPreset, setQualityPreset] = useState<QualityPreset>(() => {
    const saved = localStorage.getItem('remoter_quality_preset')
    if (saved === 'auto' || saved === 'smooth' || saved === 'hd' || saved === 'original') return saved
    return 'auto'
  })
  const [fps, setFps]         = useState(30)
  const [fpsAuto, setFpsAuto] = useState(true)
  const [bitrate, setBitrate] = useState(2_000_000)
  const [bitrateAuto, setBitrateAuto] = useState(true)
  const [resolution, setResolution] = useState<ResolutionTier>('native')
  const [scaleMode, setScaleMode] = useState<ScaleMode>(() => {
    return (localStorage.getItem('remoter_scale_mode') as ScaleMode) || 'fit'
  })
  // Manual pick only (both sides default to h264); jpeg fallback is chosen
  // by the connection layer itself, not from this menu.
  const [codec, setCodec] = useState<'h264' | 'h265'>('h264')
  const [sharpness, setSharpness] = useState<SharpnessLevel>(() => {
    const saved = localStorage.getItem('remoter_sharpness')
    if (saved === 'off' || saved === 'low' || saved === 'medium' || saved === 'high') return saved
    return 'off'
  })
  const [chromaMode, setChromaMode] = useState<ChromaMode>('420')
  const [hdrOn, setHdrOn] = useState(false)
  const [toneMap, setToneMap] = useState(false)
  const [lowLatency, setLowLatency] = useState<boolean>(() => {
    return localStorage.getItem('remoter_low_latency') === 'true'
  })
  const [forceCanvas, setForceCanvas] = useState(false)
  const [zoom, setZoom] = useState(1)
  // Remote system-audio forwarding — off by default (bandwidth + privacy:
  // don't silently pick up whatever's playing on the remote machine).
  const [audioOn, setAudioOn] = useState(false)
  const audioPlayerRef = useRef<AudioPlayer | null>(null)
  // Local microphone passthrough (opt-in, default OFF)
  const [micOn, setMicOn] = useState(false)
  const micCapturerRef = useRef<MicCapturer | null>(null)
  const [micToast, setMicToast] = useState<string | null>(null)
  const micToastTimerRef = useRef<ReturnType<typeof setTimeout>>()
  // Clipboard files copied on the remote host (one-click download toast)
  const [remoteClipboardFiles, setRemoteClipboardFiles] = useState<ClipboardFileItem[] | null>(null)
  const clipFilesTimerRef = useRef<ReturnType<typeof setTimeout>>()
  // Machine-wide lock on the target's own physical keyboard/mouse — off by
  // default, and only ever flipped by the input_lock_changed broadcast (see
  // conn.onEvent below), never optimistically here, since the agent is the
  // single source of truth (it can also change on its own via the local
  // escape hatch, or from another connected client's toggle).
  const [inputLocked, setInputLocked] = useState(false)
  // Which remote display is being captured. streamInfo carries the list and
  // the server's current pick on every (re)start, so this stays in sync
  // through pipeline rebuilds without extra messages.
  const [activeDisplay, setActiveDisplay] = useState(streamInfo.display ?? 0)
  useEffect(() => { setActiveDisplay(streamInfo.display ?? 0) }, [streamInfo.display])
  const [showTransfers, setShowTransfers] = useState(false)
  const [toolbarVisible, setToolbarVisible] = useState(false)
  // Lifted out of RemoteCanvas so the toolbar's icon button can drive it.
  const [imeCalibrating, setImeCalibrating] = useState(false)
  const [privacyOn, setPrivacyOn] = useState(false)
  const [virtualDisplayOn, setVirtualDisplayOn] = useState(false)
  const [dragOver, setDragOver] = useState(false)
  const dragDepthRef = useRef(0)
  const [showStatsHud, setShowStatsHud] = useState<boolean>(() => {
    return localStorage.getItem('remoter_show_stats_hud') !== 'false'
  })
  const hideTimerRef = useRef<ReturnType<typeof setTimeout>>()

  // Cancel hide timer on unmount
  useEffect(() => () => clearTimeout(hideTimerRef.current), [])

  // Reverse clipboard sync (target → local) must only apply for the tab
  // actually in front — with multiple tabs open to different machines, a
  // background tab's target could otherwise silently overwrite the local
  // clipboard with content meant for a machine the user isn't even looking
  // at right now. See Connection.setReverseClipboardActive.
  useEffect(() => {
    conn.setReverseClipboardActive(isActive)
  }, [conn, isActive])

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
    if (qualityPreset === 'smooth') {
      setFps(30); setFpsAuto(false); setBitrate(4_000_000); setBitrateAuto(false)
      conn.sendFps(30, false)
      conn.sendBitrate(4_000_000, false)
    } else if (qualityPreset === 'hd') {
      setFps(60); setFpsAuto(false); setBitrate(8_000_000); setBitrateAuto(false)
      conn.sendFps(60, false)
      conn.sendBitrate(8_000_000, false)
    } else if (qualityPreset === 'original') {
      setFps(120); setFpsAuto(false); setBitrate(25_000_000); setBitrateAuto(false)
      conn.sendFps(120, false)
      conn.sendBitrate(25_000_000, false)
    } else {
      conn.sendFps(fps, true)
      conn.sendBitrate(bitrate, true)
    }
    if (lowLatency) {
      conn.sendLowLatency(true)
    }
  }, []) // eslint-disable-line react-hooks/exhaustive-deps

  function handleQualityPresetChange(preset: QualityPreset) {
    setQualityPreset(preset)
    localStorage.setItem('remoter_quality_preset', preset)
    if (preset === 'auto') {
      setFpsAuto(true)
      setBitrateAuto(true)
      handleSharpnessChange('low')
      conn.sendFps(fps, true)
      conn.sendBitrate(bitrate, true)
    } else if (preset === 'smooth') {
      setFps(30); setFpsAuto(false)
      setBitrate(4_000_000); setBitrateAuto(false)
      handleSharpnessChange('off')
      conn.sendFps(30, false)
      conn.sendBitrate(4_000_000, false)
    } else if (preset === 'hd') {
      setFps(60); setFpsAuto(false)
      setBitrate(8_000_000); setBitrateAuto(false)
      handleSharpnessChange('low')
      conn.sendFps(60, false)
      conn.sendBitrate(8_000_000, false)
    } else if (preset === 'original') {
      setFps(120); setFpsAuto(false)
      setBitrate(25_000_000); setBitrateAuto(false)
      handleSharpnessChange('medium')
      conn.sendFps(120, false)
      conn.sendBitrate(25_000_000, false)
    }
  }

  function handleScaleModeChange(mode: ScaleMode) {
    setScaleMode(mode)
    localStorage.setItem('remoter_scale_mode', mode)
  }

  function handleSharpnessChange(level: SharpnessLevel) {
    setSharpness(level)
    localStorage.setItem('remoter_sharpness', level)
  }

  function handleToggleChroma() {
    const next: ChromaMode = chromaMode === '444' ? '420' : '444'
    setChromaMode(next)
    conn.sendChroma(next)
  }

  function handleToggleHdr() {
    const next = !hdrOn
    setHdrOn(next)
    setToneMap(next)
    conn.sendHdr(next)
  }

  function handleToggleLowLatency() {
    const next = !lowLatency
    setLowLatency(next)
    localStorage.setItem('remoter_low_latency', String(next))
    conn.sendLowLatency(next)
  }

  function handleResolutionChange(tier: ResolutionTier) {
    setResolution(tier)
    localStorage.setItem('remoter_resolution', tier)
    if (tier === 'match') {
      const dpr = window.devicePixelRatio || 1
      const w = Math.round(window.screen.width || window.innerWidth) & ~1
      const h = Math.round(window.screen.height || window.innerHeight) & ~1
      conn.sendResolution(tier, w, h, dpr)
    } else {
      conn.sendResolution(tier)
    }
  }

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
      if (e.type === 'chroma_active') {
        setChromaMode(e.mode)
      }
      if (e.type === 'hdr_active') {
        setHdrOn(e.enabled)
        setToneMap(e.enabled)
      }
      if (e.type === 'force_canvas') {
        setForceCanvas(e.enabled)
      }
      if (e.type === 'virtual_display_active') {
        setVirtualDisplayOn(e.enabled)
      }
      if (e.type === 'audio_frame') {
        audioPlayerRef.current?.push(e.data)
      }
      if (e.type === 'mic_status') {
        if (!e.available) {
          micCapturerRef.current?.stop()
          micCapturerRef.current = null
          setMicOn(false)
          showMicToast(
            e.reason === 'no_virtual_audio_device'
              ? '被控端未安装虚拟音频设备（BlackHole / VB-Cable），无法回传麦克风'
              : '被控端暂不支持麦克风回传'
          )
        } else if (!e.enabled) {
          micCapturerRef.current?.stop()
          micCapturerRef.current = null
          setMicOn(false)
        } else if (e.device) {
          showMicToast(`🎤 麦克风已回传至 ${e.device}`)
        }
      }
      if (e.type === 'clipboard_files_from_target') {
        if (e.files.length > 0) {
          setRemoteClipboardFiles(e.files)
          clearTimeout(clipFilesTimerRef.current)
          clipFilesTimerRef.current = setTimeout(() => setRemoteClipboardFiles(null), 8000)
        }
      }
      if (e.type === 'input_lock_changed') {
        setInputLocked(e.locked)
      }
    }
    return () => { conn.onEvent = prev }
  }, [conn])

  // Tear audio player & mic capturer down with the page (tab close / disconnect).
  useEffect(() => () => {
    audioPlayerRef.current?.stop()
    audioPlayerRef.current = null
    micCapturerRef.current?.stop()
    micCapturerRef.current = null
    clearTimeout(micToastTimerRef.current)
    clearTimeout(clipFilesTimerRef.current)
  }, [])

  function showMicToast(msg: string) {
    setMicToast(msg)
    clearTimeout(micToastTimerRef.current)
    micToastTimerRef.current = setTimeout(() => setMicToast(null), 3500)
  }

  // Just requests the change — inputLocked itself only ever updates from the
  // input_lock_changed broadcast above, so it can't drift from what the
  // agent actually did (e.g. if the toggle races with the local escape
  // hatch on the other end).
  function handleToggleInputLock() {
    conn.sendInputLock(!inputLocked)
  }

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

  async function handleToggleMic() {
    const next = !micOn
    if (next) {
      const capturer = new MicCapturer()
      micCapturerRef.current = capturer
      const started = await capturer.start((pcm) => {
        conn.sendMicPcm(pcm)
      })
      if (!started) {
        micCapturerRef.current = null
        setMicOn(false)
        conn.sendSetMicEnabled(false)
        showMicToast('无法打开本地麦克风，请检查浏览器或系统麦克风权限')
        return
      }
      setMicOn(true)
      conn.sendSetMicEnabled(true)
    } else {
      setMicOn(false)
      micCapturerRef.current?.stop()
      micCapturerRef.current = null
      conn.sendSetMicEnabled(false)
    }
  }

  function handleTogglePrivacy() {
    const next = !privacyOn
    setPrivacyOn(next)
    conn.sendSetPrivacyScreen(next)
  }

  function handleToggleVirtualDisplay() {
    const next = !virtualDisplayOn
    setVirtualDisplayOn(next)
    conn.sendVirtualDisplay(next ? 'create' : 'destroy')
  }

  function handleFpsChange(f: number, auto: boolean) {
    setFps(f)
    setFpsAuto(auto)
  }

  function handleBitrateChange(b: number, auto: boolean) {
    setBitrate(b)
    setBitrateAuto(auto)
  }

  function handleToggleStatsHud() {
    setShowStatsHud(prev => {
      const next = !prev
      localStorage.setItem('remoter_show_stats_hud', String(next))
      return next
    })
  }

  const toggleToolbar = useCallback(() => setToolbarVisible(v => !v), [])

  function hasDraggedFiles(dt: DataTransfer | null): boolean {
    return Boolean(dt && Array.from(dt.types).includes('Files'))
  }

  function handleDragEnter(e: React.DragEvent) {
    if (!hasDraggedFiles(e.dataTransfer)) return
    e.preventDefault()
    e.stopPropagation()
    dragDepthRef.current += 1
    setDragOver(true)
  }

  function handleDragOver(e: React.DragEvent) {
    if (!hasDraggedFiles(e.dataTransfer)) return
    e.preventDefault()
    e.stopPropagation()
    e.dataTransfer.dropEffect = 'copy'
    if (!dragOver) setDragOver(true)
  }

  function handleDragLeave(e: React.DragEvent) {
    if (!hasDraggedFiles(e.dataTransfer)) return
    e.preventDefault()
    e.stopPropagation()
    dragDepthRef.current = Math.max(0, dragDepthRef.current - 1)
    if (dragDepthRef.current === 0) setDragOver(false)
  }

  function handleDrop(e: React.DragEvent) {
    dragDepthRef.current = 0
    setDragOver(false)
    if (!hasDraggedFiles(e.dataTransfer)) return
    e.preventDefault()
    e.stopPropagation()
    const dt = e.dataTransfer
    ;(async () => {
      const entries = await extractDroppedEntries(dt)
      if (entries.length === 0) return
      setShowTransfers(true)
      for (const entry of entries) {
        try {
          await conn.sendFile(entry.file, { relPath: entry.relPath, resume: true })
        } catch (err) {
          console.warn('[DesktopPage] drop upload failed:', entry.relPath ?? entry.file.name, err)
        }
      }
    })()
  }

  function fmtClipSize(bytes: number): string {
    if (bytes <= 0) return '0 B'
    if (bytes < 1024) return `${bytes} B`
    if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`
    return `${(bytes / 1024 / 1024).toFixed(1)} MB`
  }

  async function handleDownloadClipboardFiles() {
    const files = remoteClipboardFiles
    if (!files || files.length === 0) return
    clearTimeout(clipFilesTimerRef.current)
    setRemoteClipboardFiles(null)
    setShowTransfers(true)
    for (const item of files) {
      if (item.isDir) {
        const tree = await conn.requestDirTree(item.path)
        for (const f of tree.files) {
          conn.sendRequestFile(f.path)
        }
      } else {
        conn.sendRequestFile(item.path)
      }
    }
  }

  return (
    <div
      style={styles.wrap}
      onDragEnter={handleDragEnter}
      onDragOver={handleDragOver}
      onDragLeave={handleDragLeave}
      onDrop={handleDrop}
    >
      <RemoteCanvas
        conn={conn}
        streamInfo={streamInfo}
        initialCodec={initialCodec}
        isActive={isActive}
        imeCalibrating={imeCalibrating}
        scaleMode={scaleMode}
        sharpness={sharpness}
        toneMap={toneMap}
        zoom={zoom}
        onZoomChange={setZoom}
        forceCanvas={forceCanvas}
        chroma444={chromaMode === '444'}
        hdr={hdrOn}
      />

      <StatsHUD
        stats={stats}
        visible={showStatsHud}
        width={streamInfo.width}
        height={streamInfo.height}
        isRelay={conn.isRelay}
      />

      {dragOver && (
        <div style={styles.dropOverlay}>
          <div style={styles.dropHint}>
            <span style={{ fontSize: 28, lineHeight: 1 }}>📁</span>
            <span>松开即上传文件到远端</span>
          </div>
        </div>
      )}

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

      {micToast && (
        <div style={{ ...styles.reconnectBanner, top: isReconnecting ? 52 : 12 }}>
          {micToast}
        </div>
      )}

      {remoteClipboardFiles && remoteClipboardFiles.length > 0 && (
        <div
          style={{
            ...styles.reconnectBanner,
            top: (isReconnecting ? 52 : 12) + (micToast ? 40 : 0),
            pointerEvents: 'auto',
            gap: 10,
            padding: '7px 14px',
          }}
        >
          <span>
            📋 远端复制了 {remoteClipboardFiles.length} 个文件 ({fmtClipSize(remoteClipboardFiles.reduce((s, f) => s + (f.size || 0), 0))})
          </span>
          <button
            onClick={handleDownloadClipboardFiles}
            style={{
              background: '#0d9488',
              color: '#fff',
              border: 'none',
              borderRadius: 6,
              padding: '3px 10px',
              fontSize: 12,
              fontWeight: 600,
              cursor: 'pointer',
            }}
          >
            下载
          </button>
          <button
            onClick={() => {
              clearTimeout(clipFilesTimerRef.current)
              setRemoteClipboardFiles(null)
            }}
            style={{
              background: 'transparent',
              color: 'rgba(255,255,255,0.75)',
              border: 'none',
              fontSize: 14,
              cursor: 'pointer',
              padding: '0 2px',
              lineHeight: 1,
            }}
            title="关闭"
          >
            ×
          </button>
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
            qualityPreset={qualityPreset}
            onQualityPresetChange={handleQualityPresetChange}
            fps={fps}
            fpsAuto={fpsAuto}
            onFpsChange={handleFpsChange}
            bitrate={bitrate}
            bitrateAuto={bitrateAuto}
            onBitrateChange={handleBitrateChange}
            resolution={resolution}
            onResolutionChange={handleResolutionChange}
            scaleMode={scaleMode}
            onScaleModeChange={handleScaleModeChange}
            codec={codec}
            onCodecChange={setCodec}
            sharpness={sharpness}
            onSharpnessChange={handleSharpnessChange}
            chromaMode={chromaMode}
            onToggleChroma={handleToggleChroma}
            hdrOn={hdrOn}
            onToggleHdr={handleToggleHdr}
            toneMap={toneMap}
            onToggleToneMap={() => setToneMap(v => !v)}
            lowLatency={lowLatency}
            onToggleLowLatency={handleToggleLowLatency}
            zoom={zoom}
            onZoomChange={setZoom}
            audioOn={audioOn}
            onToggleAudio={handleToggleAudio}
            micOn={micOn}
            onToggleMic={handleToggleMic}
            privacyOn={privacyOn}
            onTogglePrivacy={handleTogglePrivacy}
            virtualDisplayOn={virtualDisplayOn}
            onToggleVirtualDisplay={handleToggleVirtualDisplay}
            inputLocked={inputLocked}
            onToggleInputLock={handleToggleInputLock}
            displays={streamInfo.displays ?? []}
            activeDisplay={activeDisplay}
            onDisplayChange={setActiveDisplay}
            transferCount={transfers.filter(t => !t.done).length}
            onToggleTransfers={() => setShowTransfers(v => !v)}
            showTransfers={showTransfers}
            imeCalibrating={imeCalibrating}
            onToggleImeCalibration={() => setImeCalibrating(v => !v)}
            showStatsHud={showStatsHud}
            onToggleStatsHud={handleToggleStatsHud}
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
  dropOverlay: {
    position: 'absolute',
    inset: 0,
    zIndex: 300,
    background: 'rgba(13, 148, 136, 0.18)',
    border: '3px dashed rgba(20, 184, 166, 0.85)',
    backdropFilter: 'blur(2px)',
    WebkitBackdropFilter: 'blur(2px)',
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
    pointerEvents: 'none',
  },
  dropHint: {
    display: 'flex',
    flexDirection: 'column',
    alignItems: 'center',
    gap: 10,
    padding: '18px 32px',
    borderRadius: 14,
    background: 'rgba(15, 23, 42, 0.82)',
    color: '#fff',
    fontSize: 16,
    fontWeight: 600,
    boxShadow: '0 8px 32px rgba(0, 0, 0, 0.35)',
  },
}
