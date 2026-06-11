import React, { useState, useRef, useCallback, useEffect } from 'react'
import { ConnectPage } from './pages/ConnectPage'
import { DesktopPage } from './pages/DesktopPage'
import { Connection, ConnStats, ConnEvent } from './network/Connection'
import { ConnectParams, ConnectionState, StreamInfo, FileTransfer } from './types'
import { VideoCodec } from './video/Decoder'
import { TabBar } from './components/TabBar'

// ─── Tab display state ──────────────────────────────────────────────

const DEFAULT_STATS: ConnStats = { fps: 0, rttMs: 0, bitrateKbps: 0, transport: 'TCP' }

interface TabDisplay {
  id: string
  label: string
  state: ConnectionState
  streamInfo: StreamInfo | null
  codec: VideoCodec | 'jpeg'
  errorMsg: string
  stats: ConnStats
  transfers: FileTransfer[]
  muted: boolean
}

function makeTab(id: string): TabDisplay {
  return { id, label: '新连接', state: 'idle', streamInfo: null, codec: 'jpeg', errorMsg: '', stats: DEFAULT_STATS, transfers: [], muted: false }
}

function upsertTransfer(list: FileTransfer[], t: FileTransfer): FileTransfer[] {
  const idx = list.findIndex(x => x.id === t.id)
  if (idx >= 0) return list.map((x, i) => i === idx ? t : x)
  return [...list, t]
}

// ─── App ────────────────────────────────────────────────────────────

export default function App() {
  const connMapRef = useRef(new Map<string, Connection>())
  const setTabsRef = useRef<React.Dispatch<React.SetStateAction<TabDisplay[]>>>()

  const [tabs, setTabs]         = useState<TabDisplay[]>(() => [makeTab('tab-init')])
  const [activeId, setActiveId] = useState('tab-init')
  setTabsRef.current = setTabs

  // Wire a Connection's onEvent to update a specific tab's display state
  const wireTab = useCallback((id: string, conn: Connection) => {
    conn.onEvent = (e: ConnEvent) => {
      setTabsRef.current!(prev => prev.map(t => {
        if (t.id !== id) return t
        switch (e.type) {
          case 'state':
            return { ...t, state: e.state, ...(e.state !== 'error' && { errorMsg: '' }) }
          case 'stream_started':
            window.remoterAPI?.maximize()
            return { ...t, state: 'streaming', streamInfo: e.info, codec: e.codec ?? 'jpeg' }
          case 'error':
            return { ...t, errorMsg: e.message }
          case 'stats':
            return { ...t, stats: e.stats }
          case 'file_progress':
            return { ...t, transfers: upsertTransfer(t.transfers, e.transfer) }
          default:
            return t
        }
      }))
    }
  }, [])

  // Create the initial connection on mount
  useEffect(() => {
    const id = 'tab-init'
    const conn = new Connection()
    connMapRef.current.set(id, conn)
    wireTab(id, conn)
    return () => { conn.disconnect(); connMapRef.current.delete(id) }
  }, []) // eslint-disable-line react-hooks/exhaustive-deps

  // Add a new tab
  const addTab = useCallback(() => {
    const id = crypto.randomUUID()
    const conn = new Connection()
    connMapRef.current.set(id, conn)
    wireTab(id, conn)
    setTabs(prev => [...prev, makeTab(id)])
    setActiveId(id)
  }, [wireTab])

  // Close a tab (never close the last one)
  const closeTab = useCallback((id: string) => {
    const conn = connMapRef.current.get(id)
    conn?.disconnect()
    connMapRef.current.delete(id)

    setTabs(prev => {
      if (prev.length <= 1) return prev
      return prev.filter(t => t.id !== id)
    })
    setActiveId(prev => {
      if (prev !== id) return prev
      const idx = tabs.findIndex(t => t.id === id)
      const remaining = tabs.filter(t => t.id !== id)
      if (remaining.length === 0) return prev
      return (remaining[idx - 1] ?? remaining[0]).id
    })
  }, [tabs])

  // Connect active tab
  function handleConnect(tabId: string, params: ConnectParams) {
    const conn = connMapRef.current.get(tabId)
    if (!conn) return
    const label = params.mode === 'direct'
      ? (params.directUrl ?? '').replace('ws://', '').split(':')[0] || '新连接'
      : params.sessionId || '新连接'
    setTabs(prev => prev.map(t => t.id === tabId ? { ...t, label, errorMsg: '' } : t))
    conn.connect(params)
  }

  // Toggle remote mute
  function handleToggleMute(tabId: string) {
    const conn = connMapRef.current.get(tabId)
    if (!conn) return
    setTabs(prev => prev.map(t => {
      if (t.id !== tabId) return t
      const next = !t.muted
      conn.sendMute(next)
      return { ...t, muted: next }
    }))
  }

  // Disconnect active tab
  function handleDisconnect(tabId: string) {
    const conn = connMapRef.current.get(tabId)
    conn?.disconnect()
    setTabs(prev => prev.map(t => t.id === tabId
      ? { ...t, state: 'idle' as const, streamInfo: null, stats: DEFAULT_STATS } : t))
  }

  const activeTab  = tabs.find(t => t.id === activeId) ?? tabs[0]
  const activeConn = connMapRef.current.get(activeTab?.id ?? '')

  return (
    <div style={{ display: 'flex', flexDirection: 'column', height: '100%', overflow: 'hidden' }}>
      <TabBar
        tabs={tabs.map(t => ({ id: t.id, label: t.label, state: t.state, stats: t.stats, muted: t.muted }))}
        activeId={activeId}
        onSelect={setActiveId}
        onClose={closeTab}
        onDisconnect={handleDisconnect}
        onToggleMute={handleToggleMute}
        onAdd={addTab}
      />
      <div style={{ flex: 1, overflow: 'hidden', position: 'relative' }}>
        {activeTab && (
          activeTab.state === 'streaming' && activeTab.streamInfo && activeConn ? (
            <DesktopPage
              key={activeTab.id}
              conn={activeConn}
              streamInfo={activeTab.streamInfo}
              initialCodec={activeTab.codec}
              stats={activeTab.stats}
              transfers={activeTab.transfers}
              onDisconnect={() => handleDisconnect(activeTab.id)}
            />
          ) : (
            <ConnectPage
              key={activeTab.id}
              onConnect={(params) => handleConnect(activeTab.id, params)}
              isConnecting={activeTab.state === 'connecting' || activeTab.state === 'authenticating'}
              errorMsg={activeTab.errorMsg}
            />
          )
        )}
      </div>
    </div>
  )
}
