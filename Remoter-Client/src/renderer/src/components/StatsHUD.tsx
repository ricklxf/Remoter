import React from 'react'

export interface ConnStats {
  fps: number
  rttMs: number
  bitrateKbps: number
  transport: 'UDP' | 'TCP'
}

interface Props {
  stats: ConnStats
  visible: boolean
}

export function StatsHUD({ stats, visible }: Props) {
  if (!visible) return null

  const udp      = stats.transport === 'UDP'
  const mbps     = (stats.bitrateKbps / 1000).toFixed(1)
  const rttColor = stats.rttMs < 50  ? '#15803d' : stats.rttMs < 120 ? '#d97706' : '#dc2626'
  const fpsColor = stats.fps  > 50   ? '#15803d' : stats.fps  > 25   ? '#d97706' : '#dc2626'

  return (
    <div style={s.hud}>
      <span style={{ color: udp ? '#15803d' : '#d97706', fontWeight: 600 }}>
        {stats.transport}
      </span>
      <Dot />
      <span style={{ color: fpsColor }}>{stats.fps}<small style={{ color: '#6c757d' }}> fps</small></span>
      <Dot />
      <span style={{ color: rttColor }}>{stats.rttMs}<small style={{ color: '#6c757d' }}> ms</small></span>
      <Dot />
      <span style={{ color: '#4a5568' }}>{mbps}<small style={{ color: '#6c757d' }}> Mbps</small></span>
    </div>
  )
}

function Dot() {
  return <span style={{ color: '#c8d0da', margin: '0 5px' }}>·</span>
}

const s: Record<string, React.CSSProperties> = {
  hud: {
    position: 'absolute',
    bottom: 14,
    left: 14,
    background: 'rgba(255,255,255,0.88)',
    backdropFilter: 'blur(12px)',
    WebkitBackdropFilter: 'blur(12px)',
    borderRadius: 10,
    padding: '5px 12px',
    fontSize: 13,
    fontVariantNumeric: 'tabular-nums',
    color: '#1a1a2e',
    pointerEvents: 'none',
    userSelect: 'none',
    border: '1px solid rgba(0,0,0,0.08)',
    boxShadow: '0 2px 12px rgba(0,0,0,0.12)',
    zIndex: 99,
  }
}
