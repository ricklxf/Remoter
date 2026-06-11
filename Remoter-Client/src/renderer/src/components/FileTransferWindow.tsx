import React, { useState, useEffect, useCallback } from 'react'
import { Connection } from '../network/Connection'
import { DirEntry, FileTransfer } from '../types'

interface Props {
  conn: Connection
  transfers: FileTransfer[]
  onClose: () => void
}

// ─── Utils ────────────────────────────────────────────────────────

function fmtBytes(b: number): string {
  if (b <= 0)             return ''
  if (b < 1024)           return `${b} B`
  if (b < 1024 * 1024)    return `${(b / 1024).toFixed(1)} KB`
  return `${(b / 1024 / 1024).toFixed(2)} MB`
}

function fmtSpeed(bps: number): string {
  if (bps < 1024)         return `${Math.round(bps)} B/s`
  if (bps < 1024 * 1024)  return `${(bps / 1024).toFixed(0)} KB/s`
  return `${(bps / 1024 / 1024).toFixed(1)} MB/s`
}

function fmtDate(ms: number): string {
  if (!ms) return ''
  return new Intl.DateTimeFormat('zh-CN', { month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit' }).format(new Date(ms))
}

function fileIcon(e: DirEntry): string {
  if (e.isDir) return '📁'
  const ext = e.name.split('.').pop()?.toLowerCase() ?? ''
  if (['jpg','jpeg','png','gif','webp','heic','svg'].includes(ext)) return '🖼️'
  if (['mp4','mov','avi','mkv','m4v'].includes(ext))               return '🎬'
  if (['mp3','wav','flac','aac','m4a'].includes(ext))              return '🎵'
  if (['pdf'].includes(ext))                                        return '📄'
  if (['zip','tar','gz','rar','7z'].includes(ext))                  return '🗜️'
  return '📄'
}

function fileType(e: DirEntry): string {
  if (e.isDir) return '文件夹'
  const ext = e.name.split('.').pop()?.toUpperCase()
  return ext ? `${ext} 文件` : '文件'
}

function parentPath(p: string): string {
  const parts = p.split('/')
  if (parts.length <= 2) return '/'
  return parts.slice(0, -1).join('/') || '/'
}

// ─── Sub-components ───────────────────────────────────────────────

function NavBar({ path, canBack, canForward, onBack, onForward, onUp, onRefresh, onChange, onSubmit }: {
  path: string; canBack: boolean; canForward: boolean
  onBack: () => void; onForward: () => void; onUp: () => void; onRefresh: () => void
  onChange: (v: string) => void; onSubmit: () => void
}) {
  return (
    <div style={nb.bar}>
      <button style={nb.btn} disabled={!canBack}    onClick={onBack}    title="后退">‹</button>
      <button style={nb.btn} disabled={!canForward} onClick={onForward} title="前进">›</button>
      <button style={nb.btn} onClick={onUp}      title="上级目录">↑</button>
      <input
        style={nb.input}
        value={path}
        onChange={e => onChange(e.target.value)}
        onKeyDown={e => e.key === 'Enter' && onSubmit()}
      />
      <button style={nb.btn} onClick={onRefresh} title="刷新">↺</button>
    </div>
  )
}
const nb: Record<string, React.CSSProperties> = {
  bar:   { display: 'flex', alignItems: 'center', gap: 2, padding: '4px 8px', borderBottom: '1px solid rgba(255,255,255,0.06)' },
  btn:   { background: 'transparent', color: 'var(--text2)', padding: '2px 6px', fontSize: 14, borderRadius: 4, minWidth: 24 },
  input: { flex: 1, fontSize: 12, padding: '3px 8px', background: 'var(--bg)', border: '1px solid #333', borderRadius: 4, color: 'var(--text)' },
}

function FileList({ entries, selected, onSelect, onOpen }: {
  entries: DirEntry[]
  selected: Set<string>
  onSelect: (s: Set<string>) => void
  onOpen: (e: DirEntry) => void
}) {
  function handleClick(e: DirEntry, ev: React.MouseEvent) {
    if (ev.metaKey || ev.ctrlKey) {
      const next = new Set(selected)
      next.has(e.name) ? next.delete(e.name) : next.add(e.name)
      onSelect(next)
    } else {
      onSelect(new Set([e.name]))
    }
  }

  return (
    <div style={fl.wrap}>
      <div style={fl.header}>
        <span style={{ flex: 3 }}>名称</span>
        <span style={{ flex: 1, textAlign: 'right' }}>大小</span>
        <span style={{ flex: 1.5 }}>类型</span>
        <span style={{ flex: 2 }}>修改时间</span>
      </div>
      <div style={fl.body}>
        {entries.length === 0 && <div style={fl.empty}>空目录</div>}
        {entries.map(entry => (
          <div
            key={entry.name}
            style={{ ...fl.row, ...(selected.has(entry.name) ? fl.rowSel : {}) }}
            onClick={ev => handleClick(entry, ev)}
            onDoubleClick={() => onOpen(entry)}
          >
            <span style={{ flex: 3, display: 'flex', alignItems: 'center', gap: 5, overflow: 'hidden' }}>
              <span style={{ flexShrink: 0 }}>{fileIcon(entry)}</span>
              <span style={{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{entry.name}</span>
            </span>
            <span style={{ flex: 1, textAlign: 'right', color: 'var(--text2)' }}>{fmtBytes(entry.size)}</span>
            <span style={{ flex: 1.5, color: 'var(--text2)' }}>{fileType(entry)}</span>
            <span style={{ flex: 2, color: 'var(--text2)' }}>{fmtDate(entry.modified)}</span>
          </div>
        ))}
      </div>
    </div>
  )
}
const fl: Record<string, React.CSSProperties> = {
  wrap:   { flex: 1, display: 'flex', flexDirection: 'column', overflow: 'hidden' },
  header: { display: 'flex', padding: '4px 10px', fontSize: 11, color: 'var(--text2)', borderBottom: '1px solid rgba(255,255,255,0.06)', flexShrink: 0 },
  body:   { flex: 1, overflowY: 'auto' },
  row:    { display: 'flex', padding: '4px 10px', fontSize: 12, cursor: 'default', borderBottom: '1px solid rgba(255,255,255,0.03)' },
  rowSel: { background: 'rgba(233,69,96,0.15)' },
  empty:  { padding: 20, color: '#555', fontSize: 12, textAlign: 'center' },
}

function StatusBar({ selected, total, showHidden, onToggleHidden }: {
  selected: number; total: number; showHidden: boolean; onToggleHidden: () => void
}) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '4px 10px', fontSize: 11, color: 'var(--text2)', borderTop: '1px solid rgba(255,255,255,0.06)', flexShrink: 0 }}>
      <span>{selected > 0 ? `${selected} 个对象被选定` : `${total} 个对象`}</span>
      <label style={{ display: 'flex', alignItems: 'center', gap: 4, cursor: 'pointer' }}>
        <input type="checkbox" checked={showHidden} onChange={onToggleHidden} style={{ margin: 0 }} />
        显示隐藏文件
      </label>
    </div>
  )
}

function TransferItem({ t }: { t: FileTransfer }) {
  const pct = t.size > 0 ? Math.min(100, (t.transferred / t.size * 100)) : 0
  const dir = t.direction === 'upload' ? '↑' : '↓'
  const color = t.direction === 'upload' ? '#64b5f6' : '#81c784'
  return (
    <div style={{ padding: '6px 12px', borderBottom: '1px solid rgba(255,255,255,0.04)', fontSize: 12 }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 6, marginBottom: 3 }}>
        <span style={{ color, fontWeight: 700 }}>{dir}</span>
        <span style={{ flex: 1, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{t.name}</span>
        <span style={{ color: '#888', flexShrink: 0 }}>
          {t.done ? '完成' : `${Math.round(pct)}%`}
          {!t.done && t.speedBps > 0 && ` · ${fmtSpeed(t.speedBps)}`}
        </span>
      </div>
      <div style={{ height: 3, background: 'rgba(255,255,255,0.1)', borderRadius: 2, overflow: 'hidden' }}>
        <div style={{ height: '100%', width: `${pct}%`, background: t.done ? '#4caf50' : color, borderRadius: 2, transition: 'width 0.2s' }} />
      </div>
    </div>
  )
}

// ─── Main component ────────────────────────────────────────────────

export function FileTransferWindow({ conn, transfers, onClose }: Props) {
  const [localPath, setLocalPath]       = useState('')
  const [localInput, setLocalInput]     = useState('')
  const [localEntries, setLocalEntries] = useState<DirEntry[]>([])
  const [localHistory, setLocalHistory] = useState<string[]>([])
  const [localFwd, setLocalFwd]         = useState<string[]>([])
  const [localSel, setLocalSel]         = useState<Set<string>>(new Set())
  const [showHiddenL, setShowHiddenL]   = useState(false)

  const [remotePath, setRemotePath]       = useState('')
  const [remoteInput, setRemoteInput]     = useState('~')
  const [remoteEntries, setRemoteEntries] = useState<DirEntry[]>([])
  const [remoteHistory, setRemoteHistory] = useState<string[]>([])
  const [remoteFwd, setRemoteFwd]         = useState<string[]>([])
  const [remoteSel, setRemoteSel]         = useState<Set<string>>(new Set())
  const [showHiddenR, setShowHiddenR]     = useState(false)
  const [remoteLoading, setRemoteLoading] = useState(false)

  const [activeTab, setActiveTab] = useState<'list' | 'log'>('list')
  const [log, setLog]             = useState<string[]>([])
  const [busy, setBusy]           = useState(false)

  function addLog(msg: string) {
    const t = new Date().toLocaleTimeString('zh-CN', { hour: '2-digit', minute: '2-digit', second: '2-digit' })
    setLog(prev => [`[${t}] ${msg}`, ...prev.slice(0, 99)])
  }

  // ── Local navigation ──────────────────────────────────────────

  const loadLocal = useCallback(async (path: string, push = true) => {
    try {
      const res = await window.remoterAPI!.listDir(path)
      if (push && localPath) setLocalHistory(h => [...h, localPath])
      if (push) setLocalFwd([])
      setLocalPath(res.path)
      setLocalInput(res.path)
      setLocalEntries(res.entries)
      setLocalSel(new Set())
    } catch (e) { addLog(`本地读取失败: ${e}`) }
  }, [localPath])

  useEffect(() => {
    window.remoterAPI!.homeDir().then(h => loadLocal(h, false))
  }, []) // eslint-disable-line

  // ── Remote navigation ─────────────────────────────────────────

  const loadRemote = useCallback((path: string, push = true) => {
    if (push && remotePath) setRemoteHistory(h => [...h, remotePath])
    if (push) setRemoteFwd([])
    setRemoteInput(path)
    setRemoteLoading(true)
    conn.sendListDir(path)
  }, [remotePath, conn])

  useEffect(() => { loadRemote('~', false) }, []) // eslint-disable-line

  useEffect(() => {
    const prev = conn.onEvent
    conn.onEvent = (e) => {
      prev?.(e)
      if (e.type === 'dir_listing') {
        setRemotePath(e.path)
        setRemoteInput(e.path)
        setRemoteEntries(e.entries)
        setRemoteSel(new Set())
        setRemoteLoading(false)
      }
    }
    return () => { conn.onEvent = prev }
  }, [conn])

  // ── Transfer ───────────────────────────────────────────────────

  async function sendToRemote() {
    const files = [...localSel].filter(n => localEntries.find(e => e.name === n && !e.isDir))
    if (!files.length) return
    setBusy(true)
    setActiveTab('log')
    for (const name of files) {
      try {
        const data = await window.remoterAPI!.readFile(localPath + '/' + name)
        const file = new File([data], name)
        addLog(`↑ 开始发送: ${name} (${fmtBytes(data.byteLength)})`)
        await conn.sendFile(file)
        addLog(`↑ 发送完成: ${name}`)
        if (remotePath) loadRemote(remotePath, false)
      } catch (e) { addLog(`↑ 失败: ${name} - ${e}`) }
    }
    setBusy(false)
  }

  function requestFromRemote() {
    const files = [...remoteSel].filter(n => remoteEntries.find(e => e.name === n && !e.isDir))
    if (!files.length) return
    setActiveTab('log')
    for (const name of files) {
      conn.sendRequestFile(remotePath + '/' + name)
      addLog(`↓ 请求接收: ${name}`)
    }
  }

  const visibleLocal  = showHiddenL ? localEntries  : localEntries.filter(e => !e.name.startsWith('.'))
  const visibleRemote = showHiddenR ? remoteEntries : remoteEntries.filter(e => !e.name.startsWith('.'))
  const activeTransfers = transfers.filter(t => !t.done)

  return (
    <div style={s.overlay} onMouseDown={e => e.stopPropagation()}>
      <div style={s.window}>

        {/* ── Header ── */}
        <div style={s.header}>
          <div style={s.headerSide}>
            <span style={s.headerIcon}>🖥</span>
            <div>
              <div style={s.headerTitle}>本地计算机</div>
            </div>
          </div>
          <div style={s.headerSide}>
            <span style={s.headerIcon}>🖥</span>
            <div>
              <div style={s.headerTitle}>远程计算机</div>
            </div>
          </div>
          <button style={s.headerClose} onClick={onClose} title="关闭">×</button>
        </div>

        {/* ── Panels ── */}
        <div style={s.panels}>

          {/* Local */}
          <div style={s.panel}>
            <NavBar
              path={localInput}
              canBack={localHistory.length > 0}
              canForward={localFwd.length > 0}
              onBack={() => {
                const p = localHistory[localHistory.length - 1]
                setLocalHistory(h => h.slice(0, -1))
                setLocalFwd(f => [localPath, ...f])
                loadLocal(p, false)
              }}
              onForward={() => {
                const p = localFwd[0]
                setLocalFwd(f => f.slice(1))
                setLocalHistory(h => [...h, localPath])
                loadLocal(p, false)
              }}
              onUp={() => loadLocal(parentPath(localPath))}
              onRefresh={() => loadLocal(localPath, false)}
              onChange={setLocalInput}
              onSubmit={() => loadLocal(localInput)}
            />
            <div style={s.panelBar}>
              <button
                style={{ ...s.transferBtn, opacity: localSel.size === 0 || busy ? 0.4 : 1 }}
                disabled={localSel.size === 0 || busy}
                onClick={sendToRemote}
              >发送 →</button>
            </div>
            <FileList entries={visibleLocal} selected={localSel} onSelect={setLocalSel}
              onOpen={e => e.isDir ? loadLocal(localPath + '/' + e.name) : undefined} />
            <StatusBar selected={localSel.size} total={visibleLocal.length}
              showHidden={showHiddenL} onToggleHidden={() => setShowHiddenL(v => !v)} />
          </div>

          <div style={s.divider} />

          {/* Remote */}
          <div style={s.panel}>
            <NavBar
              path={remoteInput}
              canBack={remoteHistory.length > 0}
              canForward={remoteFwd.length > 0}
              onBack={() => {
                const p = remoteHistory[remoteHistory.length - 1]
                setRemoteHistory(h => h.slice(0, -1))
                setRemoteFwd(f => [remotePath, ...f])
                loadRemote(p, false)
              }}
              onForward={() => {
                const p = remoteFwd[0]
                setRemoteFwd(f => f.slice(1))
                setRemoteHistory(h => [...h, remotePath])
                loadRemote(p, false)
              }}
              onUp={() => loadRemote(parentPath(remotePath))}
              onRefresh={() => loadRemote(remotePath, false)}
              onChange={setRemoteInput}
              onSubmit={() => loadRemote(remoteInput)}
            />
            <div style={s.panelBar}>
              <button
                style={{ ...s.transferBtn, background: 'var(--bg3)', opacity: remoteSel.size === 0 ? 0.4 : 1 }}
                disabled={remoteSel.size === 0}
                onClick={requestFromRemote}
              >← 接收</button>
            </div>
            {remoteLoading ? (
              <div style={s.loading}>加载中…</div>
            ) : (
              <FileList entries={visibleRemote} selected={remoteSel} onSelect={setRemoteSel}
                onOpen={e => e.isDir ? loadRemote(remotePath + '/' + e.name) : undefined} />
            )}
            <StatusBar selected={remoteSel.size} total={visibleRemote.length}
              showHidden={showHiddenR} onToggleHidden={() => setShowHiddenR(v => !v)} />
          </div>
        </div>

        {/* ── Bottom ── */}
        <div style={s.bottom}>
          <div style={s.bottomTabBar}>
            <button style={{ ...s.bottomTab, ...(activeTab === 'list' ? s.bottomTabActive : {}) }}
              onClick={() => setActiveTab('list')}>
              传输列表{activeTransfers.length > 0 ? ` · ${activeTransfers.length}` : ''}
            </button>
            <button style={{ ...s.bottomTab, ...(activeTab === 'log' ? s.bottomTabActive : {}) }}
              onClick={() => setActiveTab('log')}>传输日志</button>
          </div>
          <div style={s.bottomContent}>
            {activeTab === 'list' ? (
              transfers.length === 0
                ? <div style={{ padding: 12, color: '#555', fontSize: 12 }}>暂无传输任务</div>
                : transfers.map(t => <TransferItem key={t.id} t={t} />)
            ) : (
              log.length === 0
                ? <div style={{ padding: 12, color: '#555', fontSize: 12 }}>暂无日志</div>
                : log.map((l, i) => <div key={i} style={{ padding: '2px 12px', fontSize: 11, color: '#999', fontFamily: 'monospace' }}>{l}</div>)
            )}
          </div>
        </div>

      </div>
    </div>
  )
}

// ─── Styles ────────────────────────────────────────────────────────

const s: Record<string, React.CSSProperties> = {
  overlay: {
    position: 'absolute', inset: 0, zIndex: 150,
    background: 'rgba(0,0,0,0.6)',
    display: 'flex', alignItems: 'stretch',
  },
  window: {
    flex: 1,
    display: 'flex', flexDirection: 'column',
    background: 'var(--bg2)',
    overflow: 'hidden',
  },
  header: {
    display: 'flex', alignItems: 'center',
    padding: '8px 12px',
    borderBottom: '1px solid rgba(255,255,255,0.08)',
    background: 'var(--bg3)',
    flexShrink: 0,
    position: 'relative',
  },
  headerSide: {
    flex: 1, display: 'flex', alignItems: 'center', gap: 8,
  },
  headerIcon: { fontSize: 22 },
  headerTitle: { fontSize: 13, fontWeight: 600 },
  headerClose: {
    position: 'absolute', right: 12, top: '50%', transform: 'translateY(-50%)',
    background: 'transparent', color: '#888', fontSize: 20, padding: '0 6px', borderRadius: 4,
  },
  panels: {
    flex: 1, display: 'flex', overflow: 'hidden',
  },
  panel: {
    flex: 1, display: 'flex', flexDirection: 'column', overflow: 'hidden',
  },
  divider: {
    width: 1, background: 'rgba(255,255,255,0.06)', flexShrink: 0,
  },
  panelBar: {
    display: 'flex', alignItems: 'center', padding: '4px 8px',
    borderBottom: '1px solid rgba(255,255,255,0.06)', gap: 6,
  },
  transferBtn: {
    padding: '4px 14px', borderRadius: 6, fontSize: 12, fontWeight: 600,
    background: 'var(--primary)', color: '#fff', cursor: 'pointer',
  },
  loading: {
    flex: 1, display: 'flex', alignItems: 'center', justifyContent: 'center',
    color: '#555', fontSize: 13,
  },
  bottom: {
    height: 160, flexShrink: 0, display: 'flex', flexDirection: 'column',
    borderTop: '1px solid rgba(255,255,255,0.08)',
  },
  bottomTabBar: {
    display: 'flex', borderBottom: '1px solid rgba(255,255,255,0.06)', flexShrink: 0,
  },
  bottomTab: {
    padding: '5px 16px', fontSize: 12, background: 'transparent', color: 'var(--text2)',
    borderRight: '1px solid rgba(255,255,255,0.06)',
  },
  bottomTabActive: {
    color: 'var(--text)', borderBottom: '2px solid var(--primary)',
  },
  bottomContent: {
    flex: 1, overflowY: 'auto',
  },
}
