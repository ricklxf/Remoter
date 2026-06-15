import React, { useState, useEffect } from 'react'
import { ConnectParams, ConnectMode, AuthMethod } from '../types'
import { getSavedAccounts, removeSavedAccount, SavedAccount,
         getMachineName, saveMachineName,
         getMachineInfo, MachineInfo } from '../utils/savedAccounts'

interface Props {
  onConnect: (params: ConnectParams) => void
  isConnecting: boolean
  errorMsg: string
}

function inferInitial(): { mode: ConnectMode; directUrl: string; relayUrl: string } {
  const savedDirect = localStorage.getItem('remoter-direct-url')
  const savedRelay  = localStorage.getItem('remoter-relay-url')

  const isWeb = window.remoterAPI?.platform === 'web' || !window.remoterAPI
  let defaults: { mode: ConnectMode; directUrl: string; relayUrl: string }
  if (!isWeb) {
    defaults = { mode: 'direct', directUrl: 'ws://192.168.1.144:7788', relayUrl: 'ws://your-relay-server:7789' }
  } else {
    const { hostname, port, protocol } = window.location
    const scheme = protocol === 'https:' ? 'wss' : 'ws'
    if (port === '7789')      defaults = { mode: 'relay',  directUrl: 'ws://192.168.1.144:7788',      relayUrl: `${scheme}://${hostname}:7789` }
    else if (port === '7788') defaults = { mode: 'direct', directUrl: `${scheme}://${hostname}:7788`, relayUrl: 'ws://your-relay-server:7789' }
    else if (port === '')     defaults = { mode: 'direct', directUrl: `${scheme}://${hostname}`,      relayUrl: 'ws://your-relay-server:7789' }
    else                      defaults = { mode: 'direct', directUrl: 'ws://192.168.1.144:7788',      relayUrl: 'ws://your-relay-server:7789' }
  }

  return {
    mode:      defaults.mode,
    directUrl: savedDirect ?? defaults.directUrl,
    relayUrl:  savedRelay  ?? defaults.relayUrl,
  }
}

const isDesktop = !!window.remoterAPI && window.remoterAPI.platform !== 'web'

export function ConnectPage({ onConnect, isConnecting, errorMsg }: Props) {
  const init = inferInitial()
  const [mode, setMode]           = useState<ConnectMode>(init.mode)
  const [directUrl, setDirectUrl] = useState(init.directUrl)
  const [relayUrl, setRelayUrl]   = useState(init.relayUrl)
  const [sessionId, setSessionId] = useState('')
  const [pin, setPin]             = useState('')
  const [authMode, setAuthMode]       = useState<AuthMethod>('pin')
  const [username, setUsername]       = useState('')
  const [password, setPassword]       = useState('')
  const [savedList, setSavedList]     = useState<SavedAccount[]>([])
  const [selectedSaved, setSelectedSaved] = useState<SavedAccount | null>(null)
  const [machineName, setMachineName] = useState('')
  const [machineInfo, setMachineInfo] = useState<MachineInfo | null>(null)
  const [rememberDevice, setRememberDevice] = useState(false)

  // Load saved accounts, PIN, and machine name whenever address changes
  useEffect(() => {
    if (mode !== 'direct') { setSavedList([]); setSelectedSaved(null); setMachineName(''); setMachineInfo(null); return }
    const accounts = getSavedAccounts(directUrl)
    setSavedList(accounts)
    if (accounts.length > 0) {
      setSelectedSaved(accounts[0])
      setAuthMode('token')
    } else {
      setSelectedSaved(null)
    }
    setMachineName(getMachineName(directUrl))
    setMachineInfo(getMachineInfo(directUrl))
  }, [mode, directUrl])

  function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    localStorage.setItem('remoter-direct-url', directUrl)
    localStorage.setItem('remoter-relay-url', relayUrl)
    if (mode === 'direct') saveMachineName(directUrl, machineName)
    const label = (mode === 'direct' && machineName.trim()) ? machineName.trim() : undefined
    const base = { mode, directUrl, relayUrl, sessionId: sessionId.toUpperCase(), pin, label }
    if (authMode === 'token' && selectedSaved) {
      onConnect({ ...base, authMethod: 'token', token: selectedSaved.token, rememberDevice: true })
    } else if (authMode === 'credentials') {
      onConnect({ ...base, authMethod: 'credentials', username, password, rememberDevice })
    } else {
      onConnect({ ...base, authMethod: 'pin', rememberDevice })
    }
  }

  function forgetAccount() {
    if (!selectedSaved) return
    removeSavedAccount(directUrl, selectedSaved.username)
    const remaining = getSavedAccounts(directUrl)
    setSavedList(remaining)
    if (remaining.length > 0) {
      setSelectedSaved(remaining[0])
    } else {
      setSelectedSaved(null)
      setAuthMode('pin')
    }
  }

  const serverAddr = mode === 'direct' ? directUrl : null

  const isMac = window.remoterAPI?.platform === 'darwin'
  // 桌面模式：顶部对齐（避免内容超出时上溢）+ 可滚动
  // Mac hiddenInset 红绿灯占 ~28px，额外加顶部间距
  const wrapStyle = isDesktop
    ? { ...s.wrap, background: 'var(--bg2)', alignItems: 'flex-start' as const, overflowY: 'auto' as const }
    : s.wrap
  const cardStyle = isDesktop
    ? { ...s.card, borderRadius: 0, boxShadow: 'none',
        paddingTop: isMac ? '56px' : '40px' }
    : s.card

  return (
    <div style={wrapStyle}>
      <div style={cardStyle}>
        {/* Mac：顶部 56px padding 区域作为拖拽把手 */}
        {isMac && isDesktop && (
          <div style={{ position: 'absolute', top: 0, left: 0, right: 0, height: 56,
            // @ts-ignore
            WebkitAppRegion: 'drag' }} />
        )}
        <div style={s.logo}>
          <span style={s.logoIcon}>⬡</span>
          <h1 style={s.logoText}>Remoter</h1>
        </div>
        <p style={s.sub}>远程控制 · 超清 2K · 60fps</p>

        {/* Connection mode */}
        <div style={s.tabs}>
          {(['direct', 'relay'] as ConnectMode[]).map(m => (
            <button key={m}
              style={{ ...s.tab, ...(mode === m ? s.tabActive : {}) }}
              onClick={() => setMode(m)}>
              {m === 'direct' ? '🔌 直连 (局域网)' : '🌐 中继 (公网)'}
            </button>
          ))}
        </div>

        <form onSubmit={handleSubmit} style={s.form}>
          {/* Address */}
          {mode === 'direct' ? (
            <label style={s.label}>
              <span>被控端地址</span>
              <input value={directUrl} onChange={e => setDirectUrl(e.target.value)}
                placeholder="ws://192.168.1.100:7788" required />
            </label>
          ) : (
            <>
              <label style={s.label}>
                <span>中继服务器地址</span>
                <input value={relayUrl} onChange={e => setRelayUrl(e.target.value)}
                  placeholder="ws://your-relay:7789" required />
              </label>
              <label style={s.label}>
                <span>会话 ID</span>
                <input value={sessionId} onChange={e => setSessionId(e.target.value.toUpperCase())}
                  placeholder="A1B2C3" maxLength={6}
                  style={{ letterSpacing: '0.2em', textTransform: 'uppercase' }} required />
              </label>
            </>
          )}

          {/* Auth section (direct only) */}
          {mode === 'direct' && (
            <>
              {/* Connection card: machine name + saved accounts (only when accounts exist) */}
              {savedList.length > 0 && selectedSaved !== null && (
              <div style={{ ...s.savedBanner, borderColor: 'var(--primary)' }}>
                <input
                  style={s.machineInput}
                  value={machineName}
                  onChange={e => setMachineName(e.target.value)}
                  onBlur={() => { if (directUrl) saveMachineName(directUrl, machineName) }}
                  placeholder="给这台机器起个名字（可选）"
                />
                {machineInfo && (machineInfo.computerName || machineInfo.modelId) && (
                  <div style={s.machineInfoRow}>
                    <span style={s.machineInfoName}>{machineInfo.computerName}</span>
                    {machineInfo.modelId && <span style={s.machineInfoBadge}>{machineInfo.modelId}</span>}
                  </div>
                )}
                <div style={s.bannerDivider} />
                <div style={s.accountRow}>
                  <span style={s.savedIcon}>👤</span>
                  <select
                    style={s.savedSelect}
                    value={selectedSaved?.username ?? '__new__'}
                    onChange={e => {
                      if (e.target.value === '__new__') {
                        setSelectedSaved(null)
                        setAuthMode('pin')
                      } else {
                        const acct = savedList.find(a => a.username === e.target.value)
                        if (acct) { setSelectedSaved(acct); setAuthMode('token') }
                      }
                    }}
                  >
                    {savedList.map(a => (
                      <option key={a.username} value={a.username}>
                        {a.username === '__pin__' ? 'PIN 码（记住）' : a.username}
                      </option>
                    ))}
                    <option value="__new__">+ 使用其他账户…</option>
                  </select>
                  <button type="button" style={s.forgetBtn} onClick={forgetAccount}>忘记</button>
                </div>
              </div>
              )}

              {/* Auth mode tabs */}
              <div style={s.authTabs}>
                {([['pin', 'PIN 码'], ['credentials', '账户密码']] as [AuthMethod, string][]).map(([m, label]) => (
                  <button key={m} type="button"
                    style={{ ...s.authTab, ...(authMode === m ? s.authTabActive : {}) }}
                    onClick={() => { setAuthMode(m); setSelectedSaved(null) }}>
                    {label}
                  </button>
                ))}
              </div>

              {authMode === 'pin' && (
                <label style={s.label}>
                  <span>PIN 码</span>
                  <input value={pin} onChange={e => setPin(e.target.value)}
                    placeholder="输入 6 位 PIN" type="text" inputMode="numeric" />
                </label>
              )}

              {authMode === 'credentials' && (
                <>
                  <label style={s.label}>
                    <span>用户名</span>
                    <input value={username} onChange={e => setUsername(e.target.value)}
                      placeholder="Windows / macOS 账户名" autoComplete="username" required />
                  </label>
                  <label style={s.label}>
                    <span>密码</span>
                    <input value={password} onChange={e => setPassword(e.target.value)}
                      type="password" placeholder="账户密码" autoComplete="current-password" required />
                  </label>
                  <div style={s.hint2}>密码通过端对端加密传输，不会被中间节点获取</div>
                </>
              )}
            </>
          )}

          {mode === 'direct' && authMode !== 'token' && (
            <label style={s.rememberRow}>
              <input
                type="checkbox"
                checked={rememberDevice}
                onChange={e => setRememberDevice(e.target.checked)}
                style={s.rememberCheck}
              />
              <span>记住登录状态</span>
            </label>
          )}

          {errorMsg && (
            <div style={s.error}>
              {errorMsg}
              {errorMsg.includes('Token') && serverAddr && selectedSaved && (
                <button type="button" style={s.reloginBtn}
                  onClick={() => { forgetAccount(); setAuthMode('credentials') }}>
                  重新登录
                </button>
              )}
            </div>
          )}

          <button type="submit" style={s.btn} disabled={isConnecting}>
            {isConnecting ? '连接中…' : (authMode === 'token' && selectedSaved ? `连接 (${selectedSaved.username})` : '连接')}
          </button>
        </form>

        <div style={s.hintBox}>
          Mac 端运行：<code style={s.code}>swift run RemoterAgent --pin 123456</code>
        </div>
        <div style={s.version}>v{__APP_VERSION__}</div>
      </div>
    </div>
  )
}

const s: Record<string, React.CSSProperties> = {
  wrap:    { display: 'flex', alignItems: 'center', justifyContent: 'center', height: '100%', background: 'var(--bg)' },
  card:    { background: 'var(--bg2)', borderRadius: 16, padding: '40px 36px', width: 420, boxShadow: 'var(--shadow)', position: 'relative' as const },
  logo:    { display: 'flex', alignItems: 'center', gap: 12, marginBottom: 6 },
  logoIcon:{ fontSize: 32, color: 'var(--primary)' },
  logoText:{ fontSize: 28, fontWeight: 700, letterSpacing: '-0.5px' },
  sub:     { color: 'var(--text2)', fontSize: 13, marginBottom: 20 },
  tabs:    { display: 'flex', gap: 8, marginBottom: 16 },
  tab:     { flex: 1, padding: '8px 0', borderRadius: 6, fontSize: 13, background: 'var(--bg3)', color: 'var(--text2)' },
  tabActive:{ background: 'var(--primary)', color: '#fff' },
  form:    { display: 'flex', flexDirection: 'column', gap: 16 },
  label:   { display: 'flex', flexDirection: 'column', gap: 6, fontSize: 13, color: 'var(--text2)' },
  // connection card (machine name + saved accounts)
  savedBanner: {
    display: 'flex', flexDirection: 'column',
    background: 'var(--bg3)', borderRadius: 10, padding: '5px 12px',
    border: '1px solid var(--border)',
  },
  machineInput: {
    background: 'transparent', border: 'none', outline: 'none',
    fontSize: 13, fontWeight: 600, color: 'var(--text)',
    width: '100%', padding: '2px 0',
  },
  machineInfoRow: {
    display: 'flex', alignItems: 'center', gap: 6,
    marginTop: 2, fontSize: 11, color: 'var(--text2)',
  },
  machineInfoName: {
    flex: 1, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' as const,
  },
  machineInfoBadge: {
    background: 'var(--bg)', border: '1px solid var(--border)',
    borderRadius: 4, padding: '1px 6px',
    fontSize: 11, color: 'var(--text2)',
    whiteSpace: 'nowrap' as const, flexShrink: 0,
  },
  bannerDivider: { height: 1, background: 'var(--border)', margin: '4px 0' },
  accountRow:   { display: 'flex', alignItems: 'center', gap: 8 },
  savedIcon:    { fontSize: 18, flexShrink: 0 },
  savedSelect: {
    flex: 1, background: 'var(--bg3)', color: 'var(--text)',
    border: 'none', outline: 'none', fontSize: 13, fontWeight: 600,
    cursor: 'pointer', minWidth: 0,
  },
  forgetBtn: {
    fontSize: 12, color: 'var(--text2)', background: 'transparent', flexShrink: 0,
    border: '1px solid var(--border)', borderRadius: 6, padding: '4px 10px', cursor: 'pointer',
  },

  // auth mode tabs
  authTabs:   { display: 'flex', gap: 6 },
  authTab:    { flex: 1, padding: '6px 0', borderRadius: 6, fontSize: 12, background: 'var(--bg3)', color: 'var(--text2)' },
  authTabActive: { background: 'var(--bg)', color: 'var(--text)', border: '1px solid var(--primary)' },

  hint2: { fontSize: 11, color: 'var(--text2)', opacity: 0.7, lineHeight: 1.4, marginTop: -6 },
  rememberRow: {
    display: 'flex', alignItems: 'center', gap: 8,
    fontSize: 13, color: 'var(--text2)', cursor: 'pointer', userSelect: 'none' as const,
  },
  rememberCheck: { width: 15, height: 15, cursor: 'pointer', flexShrink: 0 },

  error: {
    background: '#fef2f2', color: '#dc2626', borderRadius: 6,
    padding: '8px 12px', fontSize: 13, border: '1px solid #fecaca',
    display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 8,
  },
  reloginBtn: {
    fontSize: 12, color: '#dc2626', background: 'transparent',
    border: '1px solid #fecaca', borderRadius: 5, padding: '3px 10px', cursor: 'pointer', flexShrink: 0,
  },
  btn: {
    marginTop: 4, padding: '12px 0', borderRadius: 8,
    background: 'var(--primary)', color: '#fff', fontSize: 15, fontWeight: 600,
  },
  hintBox: {
    marginTop: 12, fontSize: 12, color: 'var(--text2)',
    lineHeight: 1.6, borderTop: '1px solid var(--border)', paddingTop: 16,
  },
  code: {
    background: 'var(--bg)', padding: '2px 6px', borderRadius: 4,
    fontFamily: 'monospace', fontSize: 11, color: 'var(--text)',
  },
  version: { marginTop: 8, fontSize: 11, color: 'var(--text2)', textAlign: 'center' as const, opacity: 0.6 },
}
