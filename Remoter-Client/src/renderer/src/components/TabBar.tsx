import React from 'react'
import { ConnectionState } from '../types'
import { ConnStats } from '../network/Connection'

export interface TabInfo {
  id: string
  label: string
  state: ConnectionState
  stats: ConnStats
}

interface Props {
  tabs: TabInfo[]
  activeId: string
  onSelect: (id: string) => void
  onClose: (id: string) => void
  onDisconnect: (id: string) => void
  onAdd: () => void
}

export function TabBar({ tabs, activeId, onSelect, onClose, onDisconnect, onAdd }: Props) {
  return (
    <div style={styles.bar}>
      <div style={styles.trafficSpacer} />

      {tabs.map(tab => (
        <TabItem
          key={tab.id}
          tab={tab}
          active={tab.id === activeId}
          canClose={tabs.length > 1}
          onSelect={() => onSelect(tab.id)}
          onClose={() => onClose(tab.id)}
          onDisconnect={() => onDisconnect(tab.id)}
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

function TabItem({ tab, active, canClose, onSelect, onClose, onDisconnect }: {
  tab: TabInfo
  active: boolean
  canClose: boolean
  onSelect: () => void
  onClose: () => void
  onDisconnect: () => void
}) {
  const streaming = tab.state === 'streaming'
  const mbps = (tab.stats.bitrateKbps / 1000).toFixed(1)

  // × disconnects when streaming; closes tab when idle
  const handleX = streaming ? onDisconnect : (canClose ? onClose : undefined)
  const xTitle  = streaming ? '断开连接' : '关闭标签页'

  return (
    <div
      style={{ ...styles.tab, ...(active ? styles.tabActive : {}) }}
      onClick={onSelect}
      // @ts-ignore
      WebkitAppRegion="no-drag"
    >
      <StatusDot state={tab.state} />
      <span style={styles.tabLabel}>{tab.label}</span>
      {streaming && (
        <span style={styles.speed}>{mbps}M</span>
      )}
      {handleX && (
        <button
          style={styles.closeBtn}
          onClick={e => { e.stopPropagation(); handleX() }}
          title={xTitle}
          // @ts-ignore
          WebkitAppRegion="no-drag"
        >×</button>
      )}
    </div>
  )
}

function StatusDot({ state }: { state: ConnectionState }) {
  const color =
    state === 'streaming'                                        ? '#4caf50' :
    state === 'connecting' || state === 'authenticating'         ? '#ff9800' :
    state === 'error'                                            ? '#f44336' : '#444'
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
    gap: 6,
    padding: '0 6px 0 10px',
    height: '100%',
    minWidth: 120,
    maxWidth: 240,
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
  speed: {
    fontSize: 10,
    color: '#4caf50',
    fontVariantNumeric: 'tabular-nums',
    flexShrink: 0,
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
