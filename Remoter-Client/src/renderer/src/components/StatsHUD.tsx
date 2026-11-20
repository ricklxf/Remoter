import React from 'react'
import type { ConnStats } from '../network/Connection'
import type { VideoCodec } from '../video/Decoder'

export type { ConnStats }

interface Props {
  stats: ConnStats
  visible: boolean
}

const COLOR_DEFAULT = 'rgba(255, 255, 255, 0.82)'
const COLOR_BRIGHT  = 'rgba(255, 255, 255, 0.85)'
const COLOR_DECODE  = 'rgba(255, 255, 255, 0.72)'
const COLOR_MUTED   = 'rgba(255, 255, 255, 0.55)'
const COLOR_SEP     = 'rgba(255, 255, 255, 0.45)'
const COLOR_GOOD    = '#34D399'
const COLOR_WARN    = '#F59E0B'
const COLOR_DANGER  = '#EF4444'

function codecBadgeText(codec: VideoCodec): string {
  if (codec === 'h265') return 'H.265'
  if (codec === 'jpeg') return 'JPEG'
  return 'H.264'
}

/**
 * UU-style translucent black bottom-right performance HUD overlay (matching
 * UURemote's NetDetailView and Remoter-MacClient's StatsHudOverlayView).
 * Multi-line vertical layout, 40% black background, 100% click-through via
 * pointer-events: none, no backdrop-filter.
 */
export function StatsHUD({ stats, visible }: Props) {
  if (!visible) return null

  if (!stats.hasStats) {
    return (
      <div style={s.hud} aria-hidden="true">
        <div style={{ color: COLOR_MUTED }}>-- fps</div>
        <div style={{ color: COLOR_MUTED }}>0.0 Mbps</div>
        <div style={{ color: COLOR_MUTED }}>-- ms</div>
      </div>
    )
  }

  // Line 1: <transport> · <codec> <HW/SW>
  const transport = stats.transport?.trim()
  const codecText = codecBadgeText(stats.codec)
  const decodeTag = stats.isHardwareDecoded ? 'HW' : 'SW'
  const decodeTagColor = stats.isHardwareDecoded ? COLOR_GOOD : COLOR_WARN

  // Line 2: <fps> fps
  const fpsRounded = Math.round(stats.fps)
  let fpsColor: string
  if (stats.fps <= 0) {
    fpsColor = COLOR_MUTED
  } else if (stats.fps < 15) {
    fpsColor = COLOR_DANGER
  } else if (stats.fps < 25) {
    fpsColor = COLOR_WARN
  } else {
    fpsColor = COLOR_BRIGHT
  }

  // Line 3: <mbps> Mbps
  const mbps = (stats.bitrateKbps / 1000).toFixed(1)

  // Line 4: <rtt> ms (UU thresholds: <50 green, 50-99 white, 100-150 amber, >150 red)
  const hasRtt = stats.hasRtt !== false && stats.rttMs >= 0
  let rttText = '-- ms'
  let rttColor = COLOR_MUTED
  if (hasRtt) {
    const rttRounded = Math.round(stats.rttMs)
    rttText = `${rttRounded} ms`
    if (rttRounded < 50) {
      rttColor = COLOR_GOOD
    } else if (rttRounded < 100) {
      rttColor = COLOR_BRIGHT
    } else if (rttRounded <= 150) {
      rttColor = COLOR_WARN
    } else {
      rttColor = COLOR_DANGER
    }
  }

  // Line 5 (optional): dec <decodeMs> ms (1 decimal place)
  const showDecode = stats.decodeMs > 0

  return (
    <div style={s.hud} aria-hidden="true">
      <div>
        {transport && (
          <>
            <span>{transport}</span>
            <span style={{ color: COLOR_SEP }}>{' · '}</span>
          </>
        )}
        <span>{codecText}</span>{' '}
        <span style={{ color: decodeTagColor }}>{decodeTag}</span>
      </div>
      <div style={{ color: fpsColor }}>{fpsRounded} fps</div>
      <div>{mbps} Mbps</div>
      <div style={{ color: rttColor }}>{rttText}</div>
      {showDecode && (
        <div style={{ color: COLOR_DECODE }}>dec {stats.decodeMs.toFixed(1)} ms</div>
      )}
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
    gap: 1,
    minWidth: 96,
    background: 'rgba(0, 0, 0, 0.40)',
    border: 'none',
    borderRadius: 4,
    padding: '5px 8px',
    fontFamily: "ui-monospace, 'SF Mono', Menlo, Consolas, monospace",
    fontSize: 11.5,
    fontWeight: 600,
    lineHeight: 1.45,
    fontVariantNumeric: 'tabular-nums',
    textAlign: 'left',
    color: COLOR_DEFAULT,
    whiteSpace: 'nowrap',
    pointerEvents: 'none',
    userSelect: 'none',
    WebkitUserSelect: 'none',
    zIndex: 99,
  },
}
