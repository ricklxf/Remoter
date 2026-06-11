import React, { useState } from 'react'
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
  const barColor = level >= 3 ? TEAL_DARK : level === 2 ? '#d97706' : '#dc2626'
  const heights = [5, 8, 11, 14]
  return (
    <svg width="14" height="14" viewBox="0 0 14 14" style={{ flexShrink: 0 }}>
      {heights.map((h, i) => (
        <rect key={i} x={i * 3.5} y={14 - h} width={2.5} height={h} rx={0.5}
          fill={i < level ? barColor : 'rgba(0,0,0,0.18)'} />
      ))}
    </svg>
  )
}

// ─── Stats popup (position: fixed, escapes tab bar overflow) ─────────

const STATE_LABEL: Record<ConnectionState, string> = {
  idle: '未连接', connecting: '连接中…', authenticating: '验证中…',
  streaming: '串流中', disconnected: '已断开', error: '连接失败',
}
const STATE_DOT: Record<ConnectionState, string> = {
  idle: '#aaa', connecting: '#d97706', authenticating: '#d97706',
  streaming: '#22c55e', disconnected: '#aaa', error: '#dc2626',
}

function StatsPopup({ tab, pos }: { tab: TabInfo; pos: { left: number; top: number } }) {
  const { state, stats, label } = tab
  const streaming = state === 'streaming'
  const rttColor = stats.rttMs <= 0 ? '#aaa' : stats.rttMs < 50 ? '#15803d' : stats.rttMs < 120 ? '#d97706' : '#dc2626'
  const fpsColor = stats.fps  <= 0 ? '#aaa' : stats.fps  > 50  ? '#15803d' : stats.fps  > 25  ? '#d97706' : '#dc2626'
  const mbps = (stats.bitrateKbps / 1000).toFixed(1)

  return (
    <div style={{
      position: 'fixed',
      top: pos.top + 6,
      left: pos.left,
      transform: 'translateX(-50%)',
      zIndex: 9999,
      pointerEvents: 'none',
      background: 'var(--ov-popup-bg)',
      backdropFilter: 'blur(12px)',
      WebkitBackdropFilter: 'blur(12px)',
      border: '1px solid var(--ov-popup-bdr)',
      borderRadius: 10,
      boxShadow: 'var(--ov-shadow)',
      minWidth: 180,
      overflow: 'hidden',
      fontSize: 12,
      color: 'var(--ov-text)',
      userSelect: 'none',
    }}>
      <div style={{
        padding: '9px 14px',
        borderBottom: streaming ? '1px solid var(--ov-sep)' : undefined,
        display: 'flex', alignItems: 'center', gap: 8,
      }}>
        <span style={{ width: 7, height: 7, borderRadius: '50%', background: STATE_DOT[state], flexShrink: 0, display: 'inline-block' }} />
        <span style={{ fontWeight: 600, flex: 1, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
          {label}
        </span>
        <span style={{ color: 'var(--ov-text2)', fontSize: 11, flexShrink: 0 }}>{STATE_LABEL[state]}</span>
      </div>
      {streaming && (
        <div style={{ padding: '8px 14px', display: 'flex', flexDirection: 'column', gap: 5 }}>
          <StatRow label="延迟" value={`${stats.rttMs} ms`}  color={rttColor} />
          <StatRow label="帧率" value={`${stats.fps} fps`}   color={fpsColor} />
          <StatRow label="码率" value={`${mbps} Mbps`}       color="#4a5568" />
          <StatRow label="传输" value={stats.transport}
            color={stats.transport === 'UDP' ? '#15803d' : '#d97706'} />
        </div>
      )}
    </div>
  )
}

function StatRow({ label, value, color }: { label: string; value: string; color: string }) {
  return (
    <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', gap: 16 }}>
      <span style={{ color: 'var(--ov-text2)' }}>{label}</span>
      <span style={{ color, fontWeight: 500, fontVariantNumeric: 'tabular-nums' }}>{value}</span>
    </div>
  )
}

// ─── Tab item ────────────────────────────────────────────────────────

function TabItem({ tab, active, canClose, onSelect, onClose, onDisconnect, onToggleMute, onHover, onHoverEnd }: {
  tab: TabInfo
  active: boolean
  canClose: boolean
  onSelect: () => void
  onClose: () => void
  onDisconnect: () => void
  onToggleMute: () => void
  onHover: (e: React.MouseEvent<HTMLDivElement>) => void
  onHoverEnd: () => void
}) {
  const streaming = tab.state === 'streaming'
  const rtt = tab.stats.rttMs
  const handleX = canClose ? onClose : onDisconnect
  const xTitle  = canClose ? '关闭标签页' : '断开连接'
  const textColor = active ? '#1a1a2e' : 'rgba(255,255,255,0.88)'

  return (
    <div
      style={{ ...s.tab, ...(active ? s.tabActive : s.tabInactive) }}
      onClick={onSelect}
      onMouseEnter={onHover}
      onMouseLeave={onHoverEnd}
      // @ts-ignore
      WebkitAppRegion="no-drag"
    >
      <span style={{ ...s.favicon, background: streaming ? '#4caf50' : '#aaa' }} />
      <span style={{ ...s.tabLabel, color: textColor }}>{tab.label}</span>

      {streaming && (
        <>
          {rtt > 0 && <SignalBars rttMs={rtt} />}
          {rtt > 0 && <span style={{ ...s.rttText, color: active ? TEAL_DARK : 'rgba(255,255,255,0.9)' }}>{rtt}ms</span>}
          <svg width="10" height="12" viewBox="0 0 10 12" style={{ flexShrink: 0, opacity: 0.7 }}>
            <rect x="1" y="5" width="8" height="7" rx="1.5" fill={active ? '#555' : 'rgba(255,255,255,0.9)'} />
            <path d="M2.5 5V3.5a2.5 2.5 0 015 0V5" fill="none" stroke={active ? '#555' : 'rgba(255,255,255,0.9)'} strokeWidth="1.5" />
          </svg>
          <span style={{ ...s.hdBadge, background: active ? TEAL_DARK : 'rgba(255,255,255,0.25)', color: '#fff' }}>HD</span>
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
  const [hoveredId, setHoveredId] = useState<string | null>(null)
  const [popupPos, setPopupPos]   = useState<{ left: number; top: number } | null>(null)
  const hoveredTab = hoveredId ? (tabs.find(t => t.id === hoveredId) ?? null) : null

  return (
    <>
      <div style={s.bar}>
        {isMac ? <div style={s.trafficSpacer} /> : <div style={s.winSpacer} />}

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
            onHover={e => {
              const rect = e.currentTarget.getBoundingClientRect()
              setHoveredId(tab.id)
              setPopupPos({ left: rect.left + rect.width / 2, top: rect.bottom })
            }}
            onHoverEnd={() => setHoveredId(null)}
          />
        ))}

        <button style={s.addBtn} onClick={onAdd} title="新建连接"
          // @ts-ignore
          WebkitAppRegion="no-drag"
        >+</button>

        <div style={s.dragFill} />
      </div>

      {hoveredTab && popupPos && <StatsPopup tab={hoveredTab} pos={popupPos} />}
    </>
  )
}

// ─── Styles ─────────────────────────────────────────────────────────

const TEAL_DARK = '#0d9488'
const BAR_BG = 'linear-gradient(180deg, #2dd4bf 0%, #0fb8ab 100%)'

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
  trafficSpacer: { width: 72, flexShrink: 0, height: '100%' },
  winSpacer:     { width: 8,  flexShrink: 0 },
  tab: {
    display: 'flex',
    alignItems: 'center',
    gap: 5,
    padding: '0 5px 0 9px',
    height: 30,
    width: 240,
    flexShrink: 0,
    cursor: 'pointer',
    fontSize: 12,
    borderRadius: '6px 6px 0 0',
    marginRight: 1,
    position: 'relative',
    overflow: 'hidden',
    // @ts-ignore
    WebkitAppRegion: 'no-drag',
  },
  tabActive:   { background: '#f0faf9', boxShadow: '0 1px 0 #f0faf9' },
  tabInactive: { background: 'rgba(255,255,255,0.14)' },
  favicon:  { width: 8, height: 8, borderRadius: '50%', flexShrink: 0 },
  tabLabel: { flex: 1, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', fontWeight: 500 },
  rttText:  { fontSize: 10, fontVariantNumeric: 'tabular-nums', flexShrink: 0 },
  hdBadge:  { fontSize: 9, fontWeight: 700, borderRadius: 3, padding: '1px 4px', letterSpacing: '0.03em', flexShrink: 0 },
  iconBtn: {
    background: 'transparent', padding: '1px 2px', fontSize: 12, lineHeight: '1',
    borderRadius: 3, flexShrink: 0, cursor: 'pointer',
    // @ts-ignore
    WebkitAppRegion: 'no-drag',
  },
  closeBtn: {
    background: 'transparent', padding: '1px 3px', fontSize: 13, lineHeight: '1',
    borderRadius: 3, flexShrink: 0, opacity: 0.7,
    // @ts-ignore
    WebkitAppRegion: 'no-drag',
  },
  addBtn: {
    background: 'transparent', color: 'rgba(255,255,255,0.85)',
    padding: '0 14px', height: 30, fontSize: 18, borderRadius: '6px 6px 0 0',
    // @ts-ignore
    WebkitAppRegion: 'no-drag',
  },
  dragFill: { flex: 1, height: '100%' },
}
