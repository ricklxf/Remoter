import React, { useState, useEffect, useRef } from 'react'
import { Connection } from '../network/Connection'
import { Theme, getTheme, applyTheme } from '../utils/theme'

interface Props {
  conn: Connection
  onHide: () => void
  onToggleFullscreen: () => void
  fps: number
  bitrate: number
  onQualityChange: (fps: number, bitrate: number) => void
  transferCount: number
  onToggleTransfers: () => void
  showTransfers: boolean
  onMouseEnter?: () => void
  onMouseLeave?: () => void
}

const QUALITY_PRESETS = [
  { label: '2K · 60fps',   fps: 60, bitrate: 15_000_000 },
  { label: '1080 · 60fps', fps: 60, bitrate:  8_000_000 },
  { label: '1080 · 30fps', fps: 30, bitrate:  4_000_000 },
  { label: '流畅优先',      fps: 30, bitrate:  2_000_000 },
]

const THEME_NEXT: Record<Theme, Theme> = { system: 'light', light: 'dark', dark: 'system' }
const THEME_ICON: Record<Theme, string> = { system: '💻', light: '☀️', dark: '🌙' }
const THEME_LABEL: Record<Theme, string> = { system: '跟随系统', light: '浅色', dark: '深色' }

export function Toolbar({
  conn, onHide, onToggleFullscreen,
  fps, bitrate, onQualityChange,
  transferCount, onToggleTransfers, showTransfers,
  onMouseEnter, onMouseLeave,
}: Props) {
  const [theme, setTheme] = useState<Theme>(getTheme)

  function cycleTheme() {
    const next = THEME_NEXT[theme]
    applyTheme(next)
    setTheme(next)
  }

  return (
    <div style={s.bar} onMouseEnter={onMouseEnter} onMouseLeave={onMouseLeave}>
      <QualitySelect
        value={`${fps}:${bitrate}`}
        onChange={v => {
          const [f, b] = v.split(':').map(Number)
          onQualityChange(f, b)
          conn.sendQuality(f, b)
        }}
      />

      <div style={s.sep} />

      <ToolBtn icon="📁" title={showTransfers ? '关闭文件管理器' : '文件管理器'}
        onClick={onToggleTransfers} active={showTransfers}
        badge={transferCount > 0 ? transferCount : undefined} />
      <ToolBtn icon={THEME_ICON[theme]} title={`主题: ${THEME_LABEL[theme]}`}
        onClick={cycleTheme} />
      <ToolBtn icon="⛶" title="全屏" onClick={onToggleFullscreen} />

      <div style={s.sep} />

      <ToolBtn icon="⊙" title="隐藏工具栏" onClick={onHide} />
    </div>
  )
}

// ─── Custom quality dropdown ─────────────────────────────────────────

function QualitySelect({ value, onChange }: { value: string; onChange: (v: string) => void }) {
  const [open, setOpen] = useState(false)
  const ref = useRef<HTMLDivElement>(null)
  const current = QUALITY_PRESETS.find(p => `${p.fps}:${p.bitrate}` === value) ?? QUALITY_PRESETS[0]

  useEffect(() => {
    if (!open) return
    const handler = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false)
    }
    document.addEventListener('mousedown', handler)
    return () => document.removeEventListener('mousedown', handler)
  }, [open])

  return (
    <div ref={ref} style={{ position: 'relative' }}>
      <button style={s.selectBtn} onClick={() => setOpen(v => !v)}>
        <span>{current.label}</span>
        <span style={{ fontSize: 9, opacity: 0.45, lineHeight: 1 }}>{open ? '▲' : '▼'}</span>
      </button>
      {open && (
        <div style={s.dropdown}>
          {QUALITY_PRESETS.map(p => {
            const v = `${p.fps}:${p.bitrate}`
            const active = v === value
            return (
              <button
                key={p.label}
                style={{ ...s.dropItem, ...(active ? s.dropItemActive : {}) }}
                onClick={() => { onChange(v); setOpen(false) }}
              >
                <span>{p.label}</span>
                {active && <span style={{ color: '#0d9488', fontSize: 11 }}>✓</span>}
              </button>
            )
          })}
        </div>
      )}
    </div>
  )
}

// ─── Icon button ─────────────────────────────────────────────────────

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

// ─── Styles ──────────────────────────────────────────────────────────

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
  selectBtn: {
    display: 'flex', alignItems: 'center', gap: 6,
    background: '#f0f4f8',
    color: '#1a1a2e',
    border: '1px solid #c8d0da',
    borderRadius: 8,
    padding: '5px 10px',
    fontSize: 13,
    cursor: 'pointer',
    fontFamily: 'inherit',
    whiteSpace: 'nowrap',
    height: 30,
  },
  dropdown: {
    position: 'absolute',
    top: 'calc(100% + 8px)',
    left: '50%',
    transform: 'translateX(-50%)',
    background: 'rgba(255,255,255,0.97)',
    backdropFilter: 'blur(12px)',
    WebkitBackdropFilter: 'blur(12px)',
    border: '1px solid rgba(0,0,0,0.1)',
    borderRadius: 10,
    boxShadow: '0 8px 24px rgba(0,0,0,0.14)',
    overflow: 'hidden',
    zIndex: 200,
    minWidth: 130,
  },
  dropItem: {
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'space-between',
    width: '100%',
    padding: '9px 16px',
    fontSize: 13,
    color: '#1a1a2e',
    background: 'transparent',
    cursor: 'pointer',
    whiteSpace: 'nowrap',
    gap: 12,
    fontFamily: 'inherit',
  },
  dropItemActive: {
    color: '#0d9488',
    fontWeight: 600,
    background: 'rgba(13,148,136,0.07)',
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
