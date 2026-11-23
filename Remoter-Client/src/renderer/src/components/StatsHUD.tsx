import React, { useEffect, useState } from 'react'
import type { ConnStats } from '../network/Connection'

export type { ConnStats }

interface Props {
  stats: ConnStats
  visible: boolean
  width?: number
  height?: number
  isRelay?: boolean
}

function formatDuration(totalSec: number): string {
  const sec = Math.max(0, Math.floor(totalSec))
  const h = Math.floor(sec / 3600)
  const m = Math.floor((sec % 3600) / 60)
  const s = sec % 60
  return `${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}`
}

function formatBitrate(kbps: number): string {
  if (!Number.isFinite(kbps) || kbps <= 0) return '0.0 Kbps'
  if (kbps < 1000) return `${kbps.toFixed(1)} Kbps`
  return `${(kbps / 1000).toFixed(1)} Mbps`
}

function formatResolutionTier(width?: number, height?: number): string {
  const w = width ?? 0
  const h = height ?? 0
  if (w <= 0 || h <= 0) return '--'
  const longEdge = Math.max(w, h)
  const shortEdge = Math.min(w, h)
  if (longEdge >= 3840 || shortEdge >= 2160) return '4K'
  if (longEdge >= 2560 || shortEdge >= 1440) return '2K'
  if (shortEdge >= 1080) return '1080P'
  if (shortEdge >= 720) return '720P'
  return `${shortEdge}P`
}

/**
 * UU Remote 1:1 bottom-right performance HUD overlay (matching UURemote's
 * NetDetailView, Remoter-MacClient's StatsHudOverlayView, and
 * Remoter-WinClient's StatsHudOverlay):
 * 8 uniform white monospace lines, regular weight, rgba(0,0,0,0.35) rounded
 * background, borderless, 100% click-through.
 */
export function StatsHUD({ stats, visible, width, height, isRelay }: Props) {
  const [elapsedSec, setElapsedSec] = useState(0)

  useEffect(() => {
    const startMs = Date.now()
    setElapsedSec(0)
    const timer = window.setInterval(() => {
      setElapsedSec(Math.floor((Date.now() - startMs) / 1000))
    }, 1000)
    return () => window.clearInterval(timer)
  }, [])

  if (!visible) return null

  const durationLine = formatDuration(elapsedSec)
  const proto = (stats.transport || 'TCP').trim().toUpperCase()
  const mode = isRelay ? 'relay' : 'direct'
  const transportLine = `${proto} ${mode}`

  const fpsLine = stats.hasStats ? `${Math.round(stats.fps)} fps` : '-- fps'
  const bitrateLine = formatBitrate(stats.hasStats ? stats.bitrateKbps : 0)

  const hasRtt = stats.hasStats && stats.hasRtt !== false && stats.rttMs >= 0
  const rttLine = hasRtt ? `${Math.round(stats.rttMs)} ms` : '-- ms'

  const frmMs = (stats.encodeMs > 0 ? stats.encodeMs : 0) + (stats.decodeMs > 0 ? stats.decodeMs : 0)
  const frmLine = stats.hasStats && frmMs > 0 ? `${Math.round(frmMs)} ms frm.` : '0 ms frm.'

  const lossPct = stats.packetLossPct ?? 0
  const lossLine = `${lossPct.toFixed(1)}% loss`

  const resLine = formatResolutionTier(width, height)

  return (
    <div style={s.hud} aria-hidden="true">
      <div>{durationLine}</div>
      <div>{transportLine}</div>
      <div>{fpsLine}</div>
      <div>{bitrateLine}</div>
      <div>{rttLine}</div>
      <div>{frmLine}</div>
      <div>{lossLine}</div>
      <div>{resLine}</div>
    </div>
  )
}

const s: Record<string, React.CSSProperties> = {
  hud: {
    position: 'absolute',
    right: 10,
    bottom: 10,
    display: 'flex',
    flexDirection: 'column',
    minWidth: 108,
    background: 'rgba(0, 0, 0, 0.35)',
    border: 'none',
    borderRadius: 6,
    padding: '6px 10px',
    fontFamily: "'SF Mono', Menlo, Consolas, 'Courier New', monospace",
    fontSize: 12,
    fontWeight: 400,
    lineHeight: 1.45,
    fontVariantNumeric: 'tabular-nums',
    textAlign: 'left',
    color: 'rgba(255, 255, 255, 0.88)',
    whiteSpace: 'nowrap',
    pointerEvents: 'none',
    userSelect: 'none',
    WebkitUserSelect: 'none',
    zIndex: 99,
  },
}
