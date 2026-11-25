import React, { useState, useEffect, useCallback, useRef } from 'react'
import { Connection } from '../network/Connection'
import { DirEntry, FileTransfer } from '../types'
import { UploadEntry, extractDroppedEntries, extractPickedEntries } from '../utils/fileEntries'

interface Props {
  conn: Connection
  transfers: FileTransfer[]
  onClose: () => void
}

// ─── Utils ────────────────────────────────────────────────────────

function fmtBytes(b: number): string {
  if (b <= 0)            return ''
  if (b < 1024)          return `${b} B`
  if (b < 1024 * 1024)   return `${(b / 1024).toFixed(1)} KB`
  return `${(b / 1024 / 1024).toFixed(2)} MB`
}

function fmtSpeed(bps: number): string {
  if (bps < 1024)        return `${Math.round(bps)} B/s`
  if (bps < 1024 * 1024) return `${(bps / 1024).toFixed(0)} KB/s`
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

// ─── NavBar ────────────────────────────────────────────────────────

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
  bar:   { display: 'flex', alignItems: 'center', gap: 2, padding: '5px 8px', borderBottom: '1px solid #e0e4ea', background: '#f0f4f8' },
  btn:   { background: 'transparent', color: '#4a5568', padding: '2px 7px', fontSize: 14, borderRadius: 4, border: '1px solid transparent', cursor: 'pointer' },
  input: { flex: 1, fontSize: 12, padding: '3px 8px', background: '#fff', border: '1px solid #c8d0da', borderRadius: 4, color: '#1a1a2e' },
}

// ─── FileList ────────────────────────────────────────────────────────

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
              <span style={{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', color: '#1a1a2e' }}>{entry.name}</span>
            </span>
            <span style={{ flex: 1, textAlign: 'right', color: '#6c757d' }}>{fmtBytes(entry.size)}</span>
            <span style={{ flex: 1.5, color: '#6c757d' }}>{fileType(entry)}</span>
            <span style={{ flex: 2, color: '#6c757d' }}>{fmtDate(entry.modified)}</span>
          </div>
        ))}
      </div>
    </div>
  )
}
const fl: Record<string, React.CSSProperties> = {
  wrap:   { flex: 1, display: 'flex', flexDirection: 'column', overflow: 'hidden' },
  header: { display: 'flex', padding: '4px 10px', fontSize: 11, color: '#8899aa', borderBottom: '1px solid #e8ecf0', background: '#f8f9fa', flexShrink: 0, fontWeight: 600 },
  body:   { flex: 1, overflowY: 'auto', background: '#fff' },
  row:    { display: 'flex', padding: '5px 10px', fontSize: 12, cursor: 'default', borderBottom: '1px solid #f0f2f5' },
  rowSel: { background: 'rgba(87,144,213,0.12)' },
  empty:  { padding: 20, color: '#aaa', fontSize: 12, textAlign: 'center' },
}

// ─── StatusBar ────────────────────────────────────────────────────

function StatusBar({ selected, total, showHidden, onToggleHidden }: {
  selected: number; total: number; showHidden: boolean; onToggleHidden: () => void
}) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '4px 10px', fontSize: 11, color: '#6c757d', borderTop: '1px solid #e0e4ea', background: '#f8f9fa', flexShrink: 0 }}>
      <span>{selected > 0 ? `${selected} 个对象被选定` : `${total} 个对象`}</span>
      <label style={{ display: 'flex', alignItems: 'center', gap: 4, cursor: 'pointer' }}>
        <input type="checkbox" checked={showHidden} onChange={onToggleHidden} style={{ margin: 0 }} />
        显示隐藏文件
      </label>
    </div>
  )
}

// ─── TransferItem ────────────────────────────────────────────────

function TransferItem({ t, onRetry }: { t: FileTransfer; onRetry?: (t: FileTransfer) => void }) {
  const pct = t.size > 0 ? Math.min(100, (t.transferred / t.size * 100)) : 0
  const dir = t.direction === 'upload' ? '↑' : '↓'
  const color = t.error ? '#ef4444' : (t.direction === 'upload' ? '#3b82f6' : '#10b981')
  return (
    <div style={{ padding: '7px 12px', borderBottom: '1px solid #f0f2f5', fontSize: 12 }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 6, marginBottom: 4 }}>
        <span style={{ color, fontWeight: 700, fontSize: 13 }}>{dir}</span>
        <span style={{ flex: 1, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', color: '#1a1a2e' }} title={t.relPath ?? t.name}>
          {t.name}
        </span>
        {t.resumed && (
          <span style={{
            fontSize: 10, padding: '1px 5px', borderRadius: 4,
            background: '#e0f2fe', color: '#0369a1', fontWeight: 600, flexShrink: 0,
          }}>
            断点续传
          </span>
        )}
        {t.error ? (
          <>
            <span style={{ color: '#ef4444', flexShrink: 0, fontSize: 11 }}>失败</span>
            {onRetry && (
              <button
                onClick={() => onRetry(t)}
                style={{
                  fontSize: 11, padding: '1px 7px', borderRadius: 4,
                  background: '#fef2f2', color: '#dc2626', border: '1px solid #fecaca',
                  cursor: 'pointer', flexShrink: 0,
                }}
              >
                续传
              </button>
            )}
          </>
        ) : (
          <span style={{ color: '#6c757d', flexShrink: 0 }}>
            {t.done ? '完成' : `${Math.round(pct)}%`}
            {!t.done && t.speedBps > 0 && ` · ${fmtSpeed(t.speedBps)}`}
          </span>
        )}
      </div>
      <div style={{ height: 3, background: '#e8ecf0', borderRadius: 2, overflow: 'hidden' }}>
        <div style={{ height: '100%', width: `${pct}%`, background: t.error ? '#ef4444' : (t.done ? '#10b981' : color), borderRadius: 2, transition: 'width 0.2s' }} />
      </div>
    </div>
  )
}

// ─── Main ────────────────────────────────────────────────────────

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

  const failedUploadsRef = useRef(new Map<string, { entry: UploadEntry; destDir?: string }>())
  const remoteUploadFileRef = useRef<HTMLInputElement>(null)
  const remoteUploadDirRef  = useRef<HTMLInputElement>(null)

  function addLog(msg: string) {
    const t = new Date().toLocaleTimeString('zh-CN', { hour: '2-digit', minute: '2-digit', second: '2-digit' })
    setLog(prev => [`[${t}] ${msg}`, ...prev.slice(0, 99)])
  }

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

  const isWeb = window.remoterAPI?.platform === 'web' || !window.remoterAPI

  useEffect(() => {
    if (!isWeb) {
      window.remoterAPI!.homeDir().then(h => loadLocal(h, false))
    }
  }, []) // eslint-disable-line

  const loadRemote = useCallback((path: string, push = true) => {
    if (push && remotePath) setRemoteHistory(h => [...h, remotePath])
    if (push) setRemoteFwd([])
    setRemoteInput(path)
    setRemoteLoading(true)
    conn.sendListDir(path)
  }, [remotePath, conn])

  useEffect(() => { loadRemote('~', false) }, []) // eslint-disable-line

  useEffect(() => {
    conn.onDirListing = (path, entries) => {
      setRemotePath(path)
      setRemoteInput(path)
      setRemoteEntries(entries)
      setRemoteSel(new Set())
      setRemoteLoading(false)
    }
    return () => { conn.onDirListing = null }
  }, [conn])

  async function sendEntries(entries: UploadEntry[], destDir?: string) {
    if (!entries.length) return
    setBusy(true)
    setActiveTab('list')
    const targetDir = destDir || remotePath || undefined
    for (const entry of entries) {
      const label = entry.relPath || entry.file.name
      try {
        addLog(`↑ 开始发送: ${label} (${fmtBytes(entry.file.size)})${targetDir ? ` → ${targetDir}` : ''}`)
        const res = await conn.sendFile(entry.file, {
          relPath: entry.relPath,
          destDir: targetDir,
          resume: true,
        })
        failedUploadsRef.current.delete(label)
        addLog(`↑ 发送完成${res.resumed ? ' (断点续传)' : ''}: ${label}`)
      } catch (e) {
        failedUploadsRef.current.set(label, { entry, destDir: targetDir })
        addLog(`↑ 失败: ${label} - ${e}`)
      }
    }
    if (remotePath) loadRemote(remotePath, false)
    setBusy(false)
  }

  async function collectLocalFolderEntries(dirPath: string, relPrefix: string, out: UploadEntry[]) {
    const res = await window.remoterAPI!.listDir(dirPath)
    for (const child of res.entries) {
      const childPath = `${dirPath}/${child.name}`
      const childRel = relPrefix ? `${relPrefix}/${child.name}` : child.name
      if (child.isDir) {
        await collectLocalFolderEntries(childPath, childRel, out)
      } else {
        const data = await window.remoterAPI!.readFile(childPath)
        out.push({ file: new File([data as BlobPart], child.name), relPath: childRel })
      }
    }
  }

  async function sendToRemote() {
    if (localSel.size === 0) return
    setBusy(true)
    try {
      const entries: UploadEntry[] = []
      for (const name of localSel) {
        const item = localEntries.find(e => e.name === name)
        if (!item) continue
        if (item.isDir) {
          addLog(`📁 扫描本地文件夹: ${name}`)
          await collectLocalFolderEntries(`${localPath}/${name}`, name, entries)
        } else {
          const data = await window.remoterAPI!.readFile(`${localPath}/${name}`)
          entries.push({ file: new File([data as BlobPart], name) })
        }
      }
      await sendEntries(entries, remotePath || undefined)
    } catch (e) {
      addLog(`↑ 读取本地文件失败: ${e}`)
      setBusy(false)
    }
  }

  async function requestFromRemote() {
    if (remoteSel.size === 0) return
    setActiveTab('list')
    for (const name of remoteSel) {
      const entry = remoteEntries.find(e => e.name === name)
      if (!entry) continue
      const fullPath = remotePath ? `${remotePath}/${name}` : name
      if (entry.isDir) {
        addLog(`📁 扫描远端文件夹: ${name}`)
        const tree = await conn.requestDirTree(fullPath)
        if (tree.files.length === 0) {
          addLog(`📁 远端文件夹为空或无权访问: ${name}`)
          continue
        }
        addLog(`↓ 递归下载 ${name} (${tree.files.length} 个文件)`)
        for (const f of tree.files) {
          conn.sendRequestFile(f.path)
        }
      } else {
        conn.sendRequestFile(fullPath)
        addLog(`↓ 请求接收: ${name}`)
      }
    }
  }

  async function handleRetryTransfer(t: FileTransfer) {
    if (busy) return
    const saved = failedUploadsRef.current.get(t.relPath || t.name)
    if (!saved) return
    await sendEntries([saved.entry], saved.destDir)
  }

  const visibleLocal  = showHiddenL ? localEntries  : localEntries.filter(e => !e.name.startsWith('.'))
  const visibleRemote = showHiddenR ? remoteEntries : remoteEntries.filter(e => !e.name.startsWith('.'))
  const activeTransfers = transfers.filter(t => !t.done && !t.error)

  return (
    <div style={w.backdrop} onMouseDown={e => { if (e.target === e.currentTarget) onClose() }}>
      <div style={w.window}>

        {/* Hidden pickers for "上传到此目录" on remote pane */}
        <input
          ref={remoteUploadFileRef}
          type="file"
          multiple
          style={{ display: 'none' }}
          onChange={e => {
            const entries = extractPickedEntries(e.target.files)
            if (entries.length) void sendEntries(entries, remotePath || undefined)
            e.target.value = ''
          }}
        />
        <input
          ref={remoteUploadDirRef}
          type="file"
          multiple
          {...({ webkitdirectory: '', directory: '' } as React.InputHTMLAttributes<HTMLInputElement>)}
          style={{ display: 'none' }}
          onChange={e => {
            const entries = extractPickedEntries(e.target.files)
            if (entries.length) void sendEntries(entries, remotePath || undefined)
            e.target.value = ''
          }}
        />

        {/* Header */}
        <div style={w.header}>
          <div style={w.headerSide}>
            <span style={{ fontSize: 16 }}>🖥</span>
            <span style={w.headerTitle}>本地计算机</span>
          </div>
          <div style={{ width: 1, background: 'rgba(255,255,255,0.25)', margin: '0 8px', height: 18, alignSelf: 'center' }} />
          <div style={w.headerSide}>
            <span style={{ fontSize: 16 }}>🖥</span>
            <span style={w.headerTitle}>远程计算机</span>
          </div>
          <button style={w.closeBtn} onClick={onClose} title="关闭">×</button>
        </div>

        {/* Panels */}
        <div style={w.panels}>

          {/* Local */}
          <div style={w.panel}>
            {isWeb ? (
              <WebLocalPanel
                onSend={entries => void sendEntries(entries, remotePath || undefined)}
                busy={busy}
                targetDir={remotePath || 'Downloads'}
              />
            ) : (
              <>
                <NavBar
                  path={localInput}
                  canBack={localHistory.length > 0}
                  canForward={localFwd.length > 0}
                  onBack={() => { const p = localHistory[localHistory.length-1]; setLocalHistory(h=>h.slice(0,-1)); setLocalFwd(f=>[localPath,...f]); loadLocal(p,false) }}
                  onForward={() => { const p = localFwd[0]; setLocalFwd(f=>f.slice(1)); setLocalHistory(h=>[...h,localPath]); loadLocal(p,false) }}
                  onUp={() => loadLocal(parentPath(localPath))}
                  onRefresh={() => loadLocal(localPath, false)}
                  onChange={setLocalInput}
                  onSubmit={() => loadLocal(localInput)}
                />
                <div style={w.actionBar}>
                  <button
                    style={{ ...w.sendBtn, opacity: localSel.size === 0 || busy ? 0.45 : 1 }}
                    disabled={localSel.size === 0 || busy}
                    onClick={sendToRemote}
                    title="支持多选文件与文件夹递归上传到右侧远端目录"
                  >上传到远端目录 →</button>
                </div>
                <FileList entries={visibleLocal} selected={localSel} onSelect={setLocalSel}
                  onOpen={e => e.isDir ? loadLocal(localPath + '/' + e.name) : undefined} />
                <StatusBar selected={localSel.size} total={visibleLocal.length}
                  showHidden={showHiddenL} onToggleHidden={() => setShowHiddenL(v => !v)} />
              </>
            )}
          </div>

          <div style={w.divider} />

          {/* Remote */}
          <div style={w.panel}>
            <NavBar
              path={remoteInput}
              canBack={remoteHistory.length > 0}
              canForward={remoteFwd.length > 0}
              onBack={() => { const p = remoteHistory[remoteHistory.length-1]; setRemoteHistory(h=>h.slice(0,-1)); setRemoteFwd(f=>[remotePath,...f]); loadRemote(p,false) }}
              onForward={() => { const p = remoteFwd[0]; setRemoteFwd(f=>f.slice(1)); setRemoteHistory(h=>[...h,remotePath]); loadRemote(p,false) }}
              onUp={() => loadRemote(parentPath(remotePath))}
              onRefresh={() => loadRemote(remotePath, false)}
              onChange={setRemoteInput}
              onSubmit={() => loadRemote(remoteInput)}
            />
            <div style={w.actionBar}>
              <button
                style={{ ...w.recvBtn, opacity: remoteSel.size === 0 ? 0.45 : 1 }}
                disabled={remoteSel.size === 0}
                onClick={() => void requestFromRemote()}
                title="支持下载选中的单个文件或递归下载整个文件夹"
              >← 下载</button>
              <button
                style={{ ...w.sendBtn, opacity: busy ? 0.45 : 1, padding: '4px 10px' }}
                disabled={busy}
                onClick={() => remoteUploadFileRef.current?.click()}
                title={`上传文件到 ${remotePath || '当前目录'}`}
              >↑ 上传到此目录</button>
              <button
                style={{ ...w.recvBtn, opacity: busy ? 0.45 : 1, padding: '4px 10px' }}
                disabled={busy}
                onClick={() => remoteUploadDirRef.current?.click()}
                title={`递归上传整个文件夹到 ${remotePath || '当前目录'}`}
              >📁 传文件夹</button>
            </div>
            {remoteLoading
              ? <div style={w.loading}>加载中…</div>
              : <FileList entries={visibleRemote} selected={remoteSel} onSelect={setRemoteSel}
                  onOpen={e => e.isDir ? loadRemote(remotePath + '/' + e.name) : undefined} />
            }
            <StatusBar selected={remoteSel.size} total={visibleRemote.length}
              showHidden={showHiddenR} onToggleHidden={() => setShowHiddenR(v => !v)} />
          </div>
        </div>

        {/* Bottom */}
        <div style={w.bottom}>
          <div style={w.tabBar}>
            <button style={{ ...w.tabBtn, ...(activeTab==='list' ? w.tabBtnActive : {}) }}
              onClick={() => setActiveTab('list')}>
              传输列表{activeTransfers.length > 0 ? ` (${activeTransfers.length})` : ''}
            </button>
            <button style={{ ...w.tabBtn, ...(activeTab==='log' ? w.tabBtnActive : {}) }}
              onClick={() => setActiveTab('log')}>传输日志</button>
          </div>
          <div style={w.tabContent}>
            {activeTab === 'list'
              ? transfers.length === 0
                ? <div style={{ padding: '12px 16px', color: '#aaa', fontSize: 12 }}>暂无传输任务</div>
                : transfers.map(t => (
                    <TransferItem
                      key={t.id}
                      t={t}
                      onRetry={t.error && failedUploadsRef.current.has(t.relPath || t.name) ? handleRetryTransfer : undefined}
                    />
                  ))
              : log.length === 0
                ? <div style={{ padding: '12px 16px', color: '#aaa', fontSize: 12 }}>暂无日志</div>
                : log.map((l, i) => <div key={i} style={{ padding: '2px 14px', fontSize: 11, color: '#555', fontFamily: 'monospace' }}>{l}</div>)
            }
          </div>
        </div>

      </div>
    </div>
  )
}

// ─── WebLocalPanel ───────────────────────────────────────────────

function WebLocalPanel({ onSend, busy, targetDir }: { onSend: (entries: UploadEntry[]) => void; busy: boolean; targetDir: string }) {
  const fileInputRef = useRef<HTMLInputElement>(null)
  const dirInputRef  = useRef<HTMLInputElement>(null)

  function handleChange(e: React.ChangeEvent<HTMLInputElement>) {
    const entries = extractPickedEntries(e.target.files)
    if (entries.length) onSend(entries)
    e.target.value = ''
  }

  function handleDrop(e: React.DragEvent) {
    e.preventDefault()
    if (busy) return
    const dt = e.dataTransfer
    void extractDroppedEntries(dt).then((entries) => {
      if (entries.length) onSend(entries)
    })
  }

  return (
    <div
      style={wp.container}
      onDragOver={e => { e.preventDefault(); e.dataTransfer.dropEffect = 'copy' }}
      onDrop={handleDrop}
    >
      <input ref={fileInputRef} type="file" multiple onChange={handleChange} style={{ display: 'none' }} />
      <input
        ref={dirInputRef}
        type="file"
        multiple
        {...({ webkitdirectory: '', directory: '' } as React.InputHTMLAttributes<HTMLInputElement>)}
        onChange={handleChange}
        style={{ display: 'none' }}
      />
      <div style={wp.dropZone}>
        <div style={wp.icon}>📂</div>
        <p style={wp.title}>拖放文件或文件夹到此处</p>
        <p style={wp.desc}>支持递归上传文件夹与断点续传，目标：{targetDir}</p>
        <div style={{ display: 'flex', gap: 8, marginTop: 10 }}>
          <button
            style={{ ...w.sendBtn, opacity: busy ? 0.45 : 1 }}
            disabled={busy}
            onClick={() => fileInputRef.current?.click()}
          >选择文件 →</button>
          <button
            style={{ ...w.recvBtn, opacity: busy ? 0.45 : 1 }}
            disabled={busy}
            onClick={() => dirInputRef.current?.click()}
          >📁 选择文件夹 →</button>
        </div>
      </div>
    </div>
  )
}
const wp: Record<string, React.CSSProperties> = {
  container: { flex: 1, display: 'flex', flexDirection: 'column', overflow: 'hidden' },
  dropZone:  { flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', gap: 6, padding: 24, textAlign: 'center' },
  icon:      { fontSize: 40, marginBottom: 4 },
  title:     { fontSize: 14, fontWeight: 600, color: '#1a1a2e', margin: 0 },
  desc:      { fontSize: 12, color: '#6c757d', margin: 0 },
}

// ─── Styles ──────────────────────────────────────────────────────

const w: Record<string, React.CSSProperties> = {
  backdrop: {
    position: 'absolute', inset: 0, zIndex: 150,
    background: 'rgba(0,0,0,0.35)',
    display: 'flex', alignItems: 'center', justifyContent: 'center',
  },
  window: {
    width: 920, height: 580,
    display: 'flex', flexDirection: 'column',
    background: '#fff',
    borderRadius: 12,
    overflow: 'hidden',
    boxShadow: '0 20px 60px rgba(0,0,0,0.35)',
  },
  header: {
    display: 'flex', alignItems: 'center',
    padding: '0 12px',
    height: 40,
    background: 'linear-gradient(180deg, #2dd4bf 0%, #0fb8ab 100%)',
    flexShrink: 0,
  },
  headerSide: { display: 'flex', alignItems: 'center', gap: 6, flex: 1 },
  headerTitle: { fontSize: 13, fontWeight: 600, color: '#fff' },
  closeBtn: {
    background: 'rgba(255,255,255,0.2)',
    color: '#fff',
    fontSize: 18,
    width: 28, height: 28,
    borderRadius: 6,
    display: 'flex', alignItems: 'center', justifyContent: 'center',
    cursor: 'pointer',
    marginLeft: 'auto',
    padding: 0,
    lineHeight: '1',
  },
  panels: { flex: 1, display: 'flex', overflow: 'hidden' },
  panel:  { flex: 1, display: 'flex', flexDirection: 'column', overflow: 'hidden' },
  divider: { width: 1, background: '#e0e4ea', flexShrink: 0 },
  actionBar: {
    display: 'flex', alignItems: 'center', padding: '5px 8px',
    borderBottom: '1px solid #e8ecf0', background: '#f8f9fa', gap: 6,
  },
  sendBtn: {
    padding: '4px 16px', borderRadius: 6, fontSize: 12, fontWeight: 600,
    background: '#0d9488', color: '#fff', cursor: 'pointer',
  },
  recvBtn: {
    padding: '4px 16px', borderRadius: 6, fontSize: 12, fontWeight: 600,
    background: '#e6faf8', color: '#0d9488', border: '1px solid #99e0d8', cursor: 'pointer',
  },
  loading: {
    flex: 1, display: 'flex', alignItems: 'center', justifyContent: 'center',
    color: '#aaa', fontSize: 13,
  },
  bottom: {
    height: 150, flexShrink: 0, display: 'flex', flexDirection: 'column',
    borderTop: '1px solid #e0e4ea',
  },
  tabBar: {
    display: 'flex', borderBottom: '1px solid #e8ecf0', flexShrink: 0, background: '#f8f9fa',
  },
  tabBtn: {
    padding: '6px 16px', fontSize: 12, background: 'transparent', color: '#6c757d',
    borderRight: '1px solid #e8ecf0', cursor: 'pointer',
  },
  tabBtnActive: {
    color: '#1a1a2e', fontWeight: 600,
    borderBottom: '2px solid #0d9488', background: '#fff',
  },
  tabContent: { flex: 1, overflowY: 'auto', background: '#fff' },
}
