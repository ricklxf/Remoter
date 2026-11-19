import React from 'react'
import type { ConnStats } from '../network/Connection'
import type { VideoCodec } from '../video/Decoder'

export type { ConnStats }

interface Props {
  stats: ConnStats
  visible: boolean
}

const COLOR_NORMAL = 'rgba(255, 255, 255, 0.90)'
const COLOR_MUTED  = 'rgba(255, 255, 255, 0.55)'
const COLOR_SEP    = 'rgba(255, 255, 255, 0.40)'
const COLOR_GOOD   = '#34D399'
const COLOR_WARN   = '#F59E0B'
const COLOR_DANGER = '#EF4444'

function codecBadgeText(codec: VideoCodec): string {
  if (codec === 'h265') return 'H.265'
  if (codec === 'jpeg') return 'JPEG'
  return 'H.264'
}

/**
 * UU-style translucent black bottom-right performance HUD overlay (matching
 * Remoter-MacClient's StatsHudOverlayView / UURemote's NetDetailView).
 * 100% click-through via pointer-events: none; no backdrop-filter so bright
 * remote desktops never bleed through.
 */
export function StatsHUD({ stats, visible }: Props) {
  if (!visible) return null

  if (!stats.hasStats) {
    return (
      <div style={s.hud} aria-hidden="true">
        <span style={{ color: COLOR_MUTED }}>-- fps</span>
        <Sep />
        <span style={{ color: COLOR_MUTED }}>0.0 Mbps</span>
        <Sep />
        <span style={{ color: COLOR_MUTED }}>-- ms</span>
      </div>
    )
  }

  // 1. FPS
  const fpsRounded = Math.round(stats.fps)
  let fpsColor: string
  if (stats.fps <= 0) {
    fpsColor = COLOR_MUTED
  } else if (stats.fps < 15) {
    fpsColor = COLOR_DANGER
  } else if (stats.fps < 25) {
    fpsColor = COLOR_WARN
  } else {
    fpsColor = COLOR_NORMAL
  }

  // 2. Bitrate
  const mbps = (stats.bitrateKbps / 1000).toFixed(1)

  // 3. RTT (UU thresholds: <50 teal/green, 50-99 white, 100-150 amber, >150 red)
  const hasRtt = stats.hasRtt !== false && stats.rttMs >= 0
  let rttText = '-- ms'
  let rttColor = COLOR_MUTED
  if (hasRtt) {
    const rttRounded = Math.round(stats.rttMs)
    rttText = `${rttRounded} ms`
    if (rttRounded < 50) {
      rttColor = COLOR_GOOD
    } else if (rttRounded < 100) {
      rttColor = COLOR_NORMAL
    } else if (rttRounded <= 150) {
      rttColor = COLOR_WARN
    } else {
      rttColor = COLOR_DANGER
    }
  }

  // 4. Codec
  const codecText = codecBadgeText(stats.codec)

  // 5. HW / SW decode tag
  const decodeTag = stats.isHardwareDecoded ? 'HW' : 'SW'
  const decodeTagColor = stats.isHardwareDecoded ? COLOR_GOOD : COLOR_WARN

  // 6. Optional decode time
  const decodeMs = Math.round(stats.decodeMs)

  return (
    <div style={s.hud} aria-hidden="true">
      <span style={{ color: fpsColor }}>{fpsRounded} fps</span>
      <Sep />
      <span style={{ color: COLOR_NORMAL }}>{mbps} Mbps</span>
      <Sep />
      <span style={{ color: rttColor }}>{rttText}</span>
      <Sep />
      <span style={{ color: COLOR_NORMAL }}>{codecText}</span>
      <Sep />
      <span style={{ color: decodeTagColor }}>{decodeTag}</span>
      {decodeMs > 0 && (
        <>
          <Sep />
          <span style={{ color: COLOR_NORMAL }}>dec {decodeMs}ms</span>
        </>
      )}
    </div>
  )
}

function Sep() {
  return <span style={{ color: COLOR_SEP }}>{' · '}</span>
}

const s: Record<string, React.CSSProperties> = {
  hud: {
    position: 'absolute',
    right: 12,
    bottom: 12,
    background: 'rgba(0, 0, 0, 0.62)',
    borderRadius: 6,
    border: '1px solid rgba(255, 255, 255, 0.12)',
    padding: '5px 10px',
    fontSize: 11.5,
    fontWeight: 500,
    lineHeight: 1.2,
    fontVariantNumeric: 'tabular-nums',
    fontFamily: 'ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", monospace',
    color: COLOR_NORMAL,
    whiteSpace: 'nowrap',
    pointerEvents: 'none',
    userSelect: 'none',
    WebkitUserSelect: 'none',
    zIndex: 99,
  },
}
