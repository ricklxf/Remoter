import React, { useRef, useState } from 'react'
import { Connection } from '../network/Connection'

interface Props {
  conn: Connection
  onDisconnect: () => void
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
  conn, onDisconnect, onToggleFullscreen,
  fps, bitrate, onQualityChange,
  showStats, onToggleStats,
  transferCount, onToggleTransfers, showTransfers,
}: Props) {
  const fileRef = useRef<HTMLInputElement>(null)
  const [clipState, setClipState] = useState<'idle' | 'ok' | 'empty' | 'fail'>('idle')

  async function handleFileChange(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0]
    if (!file) return
    e.target.value = ''
    await conn.sendFile(file)
  }

  async function handleClipboard() {
    try {
      const text = await navigator.clipboard.readText()
      if (!text) {
        flash('empty')
        return
      }
      conn.sendClipboard(text)
      flash('ok')
    } catch {
      flash('fail')
    }
  }

  function flash(s: 'ok' | 'empty' | 'fail') {
    setClipState(s)
    setTimeout(() => setClipState('idle'), 2000)
  }

  const clipIcon  = clipState === 'ok' ? '✓' : clipState === 'empty' ? '⊘' : clipState === 'fail' ? '✗' : '📋'
  const clipTitle = clipState === 'ok' ? '已同步到远端' : clipState === 'empty' ? '剪贴板为空' : clipState === 'fail' ? '读取剪贴板失败' : '将本机剪贴板发送给远端'

  return (
    <div style={styles.bar}>
      <select
        style={styles.select}
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

      <div style={styles.sep} />

      <ToolBtn
        icon={clipIcon}
        title={clipTitle}
        onClick={handleClipboard}
        active={clipState === 'ok'}
      />
      <ToolBtn icon="📂" title="发送文件给远端" onClick={() => fileRef.current?.click()} />
      <input ref={fileRef} type="file" style={{ display: 'none' }} onChange={handleFileChange} />

      <div style={styles.sep} />

      <ToolBtn
        icon="⇅"
        title={showTransfers ? '隐藏传输列表' : '文件传输列表'}
        onClick={onToggleTransfers}
        active={showTransfers}
        badge={transferCount > 0 ? transferCount : undefined}
      />
      <ToolBtn
        icon="📊"
        title={showStats ? '隐藏网络状态' : '显示网络状态'}
        onClick={onToggleStats}
        active={showStats}
      />
      <ToolBtn icon="⛶"  title="全屏"     onClick={onToggleFullscreen} />
      <ToolBtn icon="⏏"  title="断开连接" onClick={onDisconnect} danger />
    </div>
  )
}

function ToolBtn({ icon, title, onClick, danger, active, badge }: {
  icon: string; title: string; onClick: () => void
  danger?: boolean; active?: boolean; badge?: number
}) {
  return (
    <button
      style={{
        ...styles.btn,
        ...(danger  ? styles.btnDanger : {}),
        ...(active  ? styles.btnActive : {})
      }}
      title={title}
      onClick={onClick}
    >
      {icon}
      {badge != null && badge > 0 && (
        <span style={styles.badge}>{badge}</span>
      )}
    </button>
  )
}

const styles: Record<string, React.CSSProperties> = {
  bar: {
    display: 'flex', alignItems: 'center', gap: 4,
    background: 'rgba(15,15,26,0.92)', backdropFilter: 'blur(8px)',
    padding: '6px 12px', borderRadius: 10,
    position: 'absolute', top: 12, left: '50%', transform: 'translateX(-50%)',
    boxShadow: '0 2px 16px rgba(0,0,0,0.6)', zIndex: 100,
    border: '1px solid rgba(255,255,255,0.08)'
  },
  select: {
    background: 'var(--bg3)', color: 'var(--text)', border: '1px solid #333',
    borderRadius: 6, padding: '4px 8px', fontSize: 13, cursor: 'pointer'
  },
  sep: { width: 1, height: 20, background: '#333', margin: '0 4px' },
  btn: {
    position: 'relative',
    background: 'transparent', color: 'var(--text)',
    padding: '6px 8px', borderRadius: 6, fontSize: 16
  },
  btnDanger: { color: 'var(--primary)' },
  btnActive:  { background: 'rgba(255,255,255,0.1)' },
  badge: {
    position: 'absolute',
    top: 2, right: 2,
    background: 'var(--primary)',
    color: '#fff',
    fontSize: 9,
    fontWeight: 700,
    borderRadius: 8,
    padding: '0 3px',
    minWidth: 14,
    textAlign: 'center',
    lineHeight: '14px',
  }
}
