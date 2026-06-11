import React from 'react'
import { Connection } from '../network/Connection'

interface Props {
  conn: Connection
  onHide: () => void
  onToggleFullscreen: () => void
  fps: number
  bitrate: number
  onQualityChange: (fps: number, bitrate: number) => void
  showStats: boolean
  onToggleStats: () => void
  transferCount: number
  onToggleTransfers: () => void
  showTransfers: boolean
}

const QUALITY_PRESETS = [
  { label: '2K 60fps',   fps: 60, bitrate: 15_000_000 },
  { label: '1080 60fps', fps: 60, bitrate:  8_000_000 },
  { label: '1080 30fps', fps: 30, bitrate:  4_000_000 },
  { label: '流畅优先',    fps: 30, bitrate:  2_000_000 },
]

export function Toolbar({
  conn, onHide, onToggleFullscreen,
  fps, bitrate, onQualityChange,
  showStats, onToggleStats,
  transferCount, onToggleTransfers, showTransfers,
}: Props) {
  return (
    <div style={s.bar}>
      <select
        style={s.select}
        value={`${fps}:${bitrate}`}
        onChange={e => {
          const [f, b] = e.target.value.split(':').map(Number)
          onQualityChange(f, b)
          conn.sendQuality(f, b)
        }}
      >
        {QUALITY_PRESETS.map(p => (
          <option key={p.label} value={`${p.fps}:${p.bitrate}`}>{p.label}</option>
        ))}
      </select>

      <div style={s.sep} />

      <ToolBtn icon="📁" title={showTransfers ? '关闭文件管理器' : '文件管理器'}
        onClick={onToggleTransfers} active={showTransfers}
        badge={transferCount > 0 ? transferCount : undefined} />
      <ToolBtn icon="📊" title={showStats ? '隐藏网络状态' : '显示网络状态'}
        onClick={onToggleStats} active={showStats} />
      <ToolBtn icon="⛶"  title="全屏" onClick={onToggleFullscreen} />

      <div style={s.sep} />

      <ToolBtn icon="⊙" title="隐藏工具栏" onClick={onHide} />
    </div>
  )
}

function ToolBtn({ icon, title, onClick, active, badge }: {
  icon: string; title: string; onClick: () => void
  active?: boolean; badge?: number
}) {
  return (
    <button
      style={{ ...s.btn, ...(active ? s.btnActive : {}) }}
      title={title}
      onClick={onClick}
    >
      {icon}
      {badge != null && badge > 0 && (
        <span style={s.badge}>{badge}</span>
      )}
    </button>
  )
}

const s: Record<string, React.CSSProperties> = {
  bar: {
    display: 'flex', alignItems: 'center', gap: 2,
    background: 'rgba(255,255,255,0.92)',
    backdropFilter: 'blur(12px)',
    WebkitBackdropFilter: 'blur(12px)',
    padding: '5px 10px',
    borderRadius: 20,
    position: 'absolute', top: 12, left: '50%', transform: 'translateX(-50%)',
    boxShadow: '0 4px 20px rgba(0,0,0,0.15), 0 1px 4px rgba(0,0,0,0.08)',
    zIndex: 100,
    border: '1px solid rgba(0,0,0,0.09)',
    pointerEvents: 'auto',
  },
  select: {
    background: '#f0f4f8',
    color: '#1a1a2e',
    border: '1px solid #c8d0da',
    borderRadius: 8,
    padding: '4px 8px',
    fontSize: 12,
    cursor: 'pointer',
    fontFamily: 'inherit',
  },
  sep: { width: 1, height: 18, background: '#dde2e8', margin: '0 4px', flexShrink: 0 },
  btn: {
    position: 'relative',
    background: 'transparent',
    color: '#1a1a2e',
    padding: '5px 8px',
    borderRadius: 8,
    fontSize: 16,
    cursor: 'pointer',
    transition: 'background 0.1s',
  },
  btnActive: { background: 'rgba(13,148,136,0.13)', color: '#0d9488' },
  badge: {
    position: 'absolute',
    top: 2, right: 2,
    background: '#e94560',
    color: '#fff',
    fontSize: 9,
    fontWeight: 700,
    borderRadius: 8,
    padding: '0 3px',
    minWidth: 14,
    textAlign: 'center',
    lineHeight: '14px',
  },
}
