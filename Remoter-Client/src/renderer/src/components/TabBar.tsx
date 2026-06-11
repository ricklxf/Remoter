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

export function TabBar({ tabs, activeId, onSelect, onClose, onDisconnect, onToggleMute, onAdd }: Props) {
  return (
    <div style={styles.bar}>
      {isMac && <div style={styles.trafficSpacer} />}

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
        style={styles.addBtn}
        onClick={onAdd}
        title="新建连接"
        // @ts-ignore
        WebkitAppRegion="no-drag"
      >+</button>

      <div style={styles.dragFill} />
    </div>
  )
}

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

  return (
    <div
      style={{ ...styles.tab, ...(active ? styles.tabActive : {}) }}
      onClick={onSelect}
      // @ts-ignore
      WebkitAppRegion="no-drag"
    >
      <StatusDot state={tab.state} />
      <span style={styles.tabLabel}>{tab.label}</span>

      {streaming && rtt > 0 && (
        <span style={styles.rtt}>{rtt}ms</span>
      )}

      {streaming && (
        <button
          style={styles.iconBtn}
          onClick={e => { e.stopPropagation(); onToggleMute() }}
          title={tab.muted ? '取消静音' : '静音远端'}
          // @ts-ignore
          WebkitAppRegion="no-drag"
        >
          {tab.muted ? '🔇' : '🔊'}
        </button>
      )}

      <button
        style={styles.closeBtn}
        onClick={e => { e.stopPropagation(); handleX() }}
        title={xTitle}
        // @ts-ignore
        WebkitAppRegion="no-drag"
      >×</button>
    </div>
  )
}

function StatusDot({ state }: { state: ConnectionState }) {
  const color =
    state === 'streaming'                                     ? '#4caf50' :
    state === 'connecting' || state === 'authenticating'      ? '#ff9800' :
    state === 'error'                                         ? '#f44336' : '#444'
  return (
    <span style={{
      width: 6, height: 6, borderRadius: '50%',
      background: color, flexShrink: 0,
      boxShadow: state === 'streaming' ? `0 0 4px ${color}` : 'none'
    }} />
  )
}

const styles: Record<string, React.CSSProperties> = {
  bar: {
    display: 'flex',
    alignItems: 'center',
    height: 36,
    background: 'var(--bg2)',
    borderBottom: '1px solid rgba(255,255,255,0.06)',
    flexShrink: 0,
    overflow: 'hidden',
    userSelect: 'none',
    // @ts-ignore
    WebkitAppRegion: 'drag',
  },
  trafficSpacer: {
    width: 72,
    flexShrink: 0,
  },
  tab: {
    display: 'flex',
    alignItems: 'center',
    gap: 5,
    padding: '0 5px 0 10px',
    height: '100%',
    minWidth: 120,
    maxWidth: 260,
    cursor: 'pointer',
    fontSize: 12,
    color: 'var(--text2)',
    borderRight: '1px solid rgba(255,255,255,0.06)',
    // @ts-ignore
    WebkitAppRegion: 'no-drag',
  },
  tabActive: {
    background: 'var(--bg)',
    color: 'var(--text)',
    borderBottom: '2px solid var(--primary)',
  },
  tabLabel: {
    flex: 1,
    overflow: 'hidden',
    textOverflow: 'ellipsis',
    whiteSpace: 'nowrap',
  },
  rtt: {
    fontSize: 10,
    color: '#4caf50',
    fontVariantNumeric: 'tabular-nums',
    flexShrink: 0,
  },
  iconBtn: {
    background: 'transparent',
    padding: '1px 2px',
    fontSize: 12,
    lineHeight: '1',
    borderRadius: 3,
    flexShrink: 0,
    opacity: 0.8,
    cursor: 'pointer',
    // @ts-ignore
    WebkitAppRegion: 'no-drag',
  },
  closeBtn: {
    background: 'transparent',
    color: 'var(--text2)',
    padding: '1px 3px',
    fontSize: 13,
    lineHeight: '1',
    borderRadius: 3,
    flexShrink: 0,
    opacity: 0.6,
    // @ts-ignore
    WebkitAppRegion: 'no-drag',
  },
  addBtn: {
    background: 'transparent',
    color: 'var(--text2)',
    padding: '0 14px',
    height: '100%',
    fontSize: 18,
    borderRight: '1px solid rgba(255,255,255,0.06)',
    // @ts-ignore
    WebkitAppRegion: 'no-drag',
  },
  dragFill: {
    flex: 1,
    height: '100%',
  },
}
