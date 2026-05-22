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

  const udp   = stats.transport === 'UDP'
  const mbps  = (stats.bitrateKbps / 1000).toFixed(1)
  const rttColor = stats.rttMs < 50 ? '#4caf50' : stats.rttMs < 120 ? '#ff9800' : '#f44336'
  const fpsColor = stats.fps  > 50  ? '#4caf50' : stats.fps  > 25   ? '#ff9800' : '#f44336'

  return (
    <div style={styles.hud}>
      <span style={{ color: udp ? '#4caf50' : '#ff9800', fontWeight: 600 }}>
        {stats.transport}
      </span>
      <Dot />
      <span style={{ color: fpsColor }}>{stats.fps}<small> fps</small></span>
      <Dot />
      <span style={{ color: rttColor }}>{stats.rttMs}<small> ms</small></span>
      <Dot />
      <span style={{ color: '#aaa' }}>{mbps}<small> Mbps</small></span>
    </div>
  )
}

function Dot() {
  return <span style={{ color: '#555', margin: '0 5px' }}>·</span>
}

const styles: Record<string, React.CSSProperties> = {
  hud: {
    position: 'absolute',
    bottom: 14,
    left: 14,
    background: 'rgba(0,0,0,0.65)',
    backdropFilter: 'blur(6px)',
    borderRadius: 6,
    padding: '4px 10px',
    fontSize: 13,
    fontVariantNumeric: 'tabular-nums',
    color: '#ddd',
    pointerEvents: 'none',
    userSelect: 'none',
    border: '1px solid rgba(255,255,255,0.07)',
    zIndex: 99,
  }
}
