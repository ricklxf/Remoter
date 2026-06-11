import React from 'react'
import { ConnectionState } from '../types'
import { ConnStats } from '../network/Connection'

export interface TabInfo {
  id: string
  label: string
  state: ConnectionState
  stats: ConnStats
  muted: boolean
}

interface Props {
  tabs: TabInfo[]
  activeId: string
  onSelect: (id: string) => void
  onClose: (id: string) => void
  onDisconnect: (id: string) => void
  onToggleMute: (id: string) => void
  onAdd: () => void
}

const isMac = window.remoterAPI?.platform === 'darwin'

// ─── Signal bars ────────────────────────────────────────────────────

function SignalBars({ rttMs }: { rttMs: number }) {
  const level = rttMs <= 0 ? 0 : rttMs < 50 ? 4 : rttMs < 120 ? 3 : rttMs < 250 ? 2 : 1
  const barColor = level >= 3 ? '#1a7f1a' : level === 2 ? '#e06e00' : '#cc2222'
  const heights = [5, 8, 11, 14]
  return (
    <svg width="14" height="14" viewBox="0 0 14 14" style={{ flexShrink: 0 }}>
      {heights.map((h, i) => (
        <rect
          key={i}
          x={i * 3.5}
          y={14 - h}
          width={2.5}
          height={h}
          rx={0.5}
          fill={i < level ? barColor : 'rgba(0,0,0,0.18)'}
        />
      ))}
    </svg>
  )
}

// ─── Tab item ────────────────────────────────────────────────────────

function TabItem({ tab, active, canClose, onSelect, onClose, onDisconnect, onToggleMute }: {
  tab: TabInfo
  active: boolean
  canClose: boolean
  onSelect: () => void
  onClose: () => void
  onDisconnect: () => void
  onToggleMute: () => void
}) {
  const streaming = tab.state === 'streaming'
  const rtt = tab.stats.rttMs
  const handleX = canClose ? onClose : onDisconnect
  const xTitle  = canClose ? '关闭标签页' : '断开连接'

  const tabStyle: React.CSSProperties = active
    ? { ...s.tab, ...s.tabActive }
    : { ...s.tab, ...s.tabInactive }

  const textColor = active ? '#1a1a2e' : 'rgba(255,255,255,0.88)'

  return (
    <div style={tabStyle} onClick={onSelect}
      // @ts-ignore
      WebkitAppRegion="no-drag"
    >
      {/* Favicon-style icon */}
      <span style={{ ...s.favicon, background: streaming ? '#4caf50' : '#aaa' }} />

      {/* Label */}
      <span style={{ ...s.tabLabel, color: textColor }}>{tab.label}</span>

      {/* Streaming indicators */}
      {streaming && (
        <>
          {rtt > 0 && <SignalBars rttMs={rtt} />}
          {rtt > 0 && <span style={{ ...s.rttText, color: active ? '#1a6e1a' : 'rgba(255,255,255,0.8)' }}>{rtt}ms</span>}

          {/* Encrypted indicator */}
          <svg width="10" height="12" viewBox="0 0 10 12" style={{ flexShrink: 0, opacity: 0.7 }}>
            <rect x="1" y="5" width="8" height="7" rx="1.5" fill={active ? '#555' : 'rgba(255,255,255,0.9)'} />
            <path d="M2.5 5V3.5a2.5 2.5 0 015 0V5" fill="none" stroke={active ? '#555' : 'rgba(255,255,255,0.9)'} strokeWidth="1.5" />
          </svg>

          {/* HD badge */}
          <span style={{ ...s.hdBadge, background: active ? '#1a1a2e' : 'rgba(255,255,255,0.25)', color: active ? '#fff' : '#fff' }}>
            HD
          </span>

          {/* Mute button */}
          <button
            style={{ ...s.iconBtn, color: textColor }}
            onClick={e => { e.stopPropagation(); onToggleMute() }}
            title={tab.muted ? '取消静音' : '静音远端'}
            // @ts-ignore
            WebkitAppRegion="no-drag"
          >
            {tab.muted ? '🔇' : '🔊'}
          </button>
        </>
      )}

      {/* Close button */}
      <button
        style={{ ...s.closeBtn, color: active ? '#555' : 'rgba(255,255,255,0.7)' }}
        onClick={e => { e.stopPropagation(); handleX() }}
        title={xTitle}
        // @ts-ignore
        WebkitAppRegion="no-drag"
      >×</button>
    </div>
  )
}

// ─── Tab bar ────────────────────────────────────────────────────────

export function TabBar({ tabs, activeId, onSelect, onClose, onDisconnect, onToggleMute, onAdd }: Props) {
  return (
    <div style={s.bar}>
      {isMac
        ? <div style={s.trafficSpacer} />
        : <div style={s.winSpacer} />
      }

      {tabs.map(tab => (
        <TabItem
          key={tab.id}
          tab={tab}
          active={tab.id === activeId}
          canClose={tabs.length > 1}
          onSelect={() => onSelect(tab.id)}
          onClose={() => onClose(tab.id)}
          onDisconnect={() => onDisconnect(tab.id)}
          onToggleMute={() => onToggleMute(tab.id)}
        />
      ))}

      <button
        style={s.addBtn}
        onClick={onAdd}
        title="新建连接"
        // @ts-ignore
        WebkitAppRegion="no-drag"
      >+</button>

      <div style={s.dragFill} />
    </div>
  )
}

// ─── Styles ─────────────────────────────────────────────────────────

const BAR_BG = 'linear-gradient(180deg, #6da4e2 0%, #5790d5 100%)'

const s: Record<string, React.CSSProperties> = {
  bar: {
    display: 'flex',
    alignItems: 'flex-end',
    height: 36,
    background: BAR_BG,
    flexShrink: 0,
    overflow: 'hidden',
    userSelect: 'none',
    paddingTop: 4,
    // @ts-ignore
    WebkitAppRegion: 'drag',
  },
  trafficSpacer: {
    width: 72,
    flexShrink: 0,
    height: '100%',
  },
  winSpacer: {
    width: 8,
    flexShrink: 0,
  },
  tab: {
    display: 'flex',
    alignItems: 'center',
    gap: 5,
    padding: '0 5px 0 9px',
    height: 30,
    minWidth: 120,
    maxWidth: 260,
    cursor: 'pointer',
    fontSize: 12,
    borderRadius: '6px 6px 0 0',
    marginRight: 1,
    position: 'relative',
    // @ts-ignore
    WebkitAppRegion: 'no-drag',
  },
  tabActive: {
    background: '#f0f4fa',
    boxShadow: '0 1px 0 #f0f4fa',
  },
  tabInactive: {
    background: 'rgba(255,255,255,0.14)',
  },
  favicon: {
    width: 8,
    height: 8,
    borderRadius: '50%',
    flexShrink: 0,
  },
  tabLabel: {
    flex: 1,
    overflow: 'hidden',
    textOverflow: 'ellipsis',
    whiteSpace: 'nowrap',
    fontWeight: 500,
  },
  rttText: {
    fontSize: 10,
    fontVariantNumeric: 'tabular-nums',
    flexShrink: 0,
  },
  hdBadge: {
    fontSize: 9,
    fontWeight: 700,
    borderRadius: 3,
    padding: '1px 4px',
    letterSpacing: '0.03em',
    flexShrink: 0,
  },
  iconBtn: {
    background: 'transparent',
    padding: '1px 2px',
    fontSize: 12,
    lineHeight: '1',
    borderRadius: 3,
    flexShrink: 0,
    cursor: 'pointer',
    // @ts-ignore
    WebkitAppRegion: 'no-drag',
  },
  closeBtn: {
    background: 'transparent',
    padding: '1px 3px',
    fontSize: 13,
    lineHeight: '1',
    borderRadius: 3,
    flexShrink: 0,
    opacity: 0.7,
    // @ts-ignore
    WebkitAppRegion: 'no-drag',
  },
  addBtn: {
    background: 'transparent',
    color: 'rgba(255,255,255,0.85)',
    padding: '0 14px',
    height: 30,
    fontSize: 18,
    borderRadius: '6px 6px 0 0',
    // @ts-ignore
    WebkitAppRegion: 'no-drag',
  },
  dragFill: {
    flex: 1,
    height: '100%',
  },
}
