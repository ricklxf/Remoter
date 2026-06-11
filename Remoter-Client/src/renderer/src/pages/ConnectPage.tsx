import React, { useState } from 'react'
import { ConnectParams, ConnectMode } from '../types'

interface Props {
  onConnect: (params: ConnectParams) => void
  isConnecting: boolean
  errorMsg: string
}

function inferInitial(): { mode: ConnectMode; directUrl: string; relayUrl: string } {
  const isWeb = window.remoterAPI?.platform === 'web' || !window.remoterAPI
  if (!isWeb) {
    return { mode: 'direct', directUrl: 'ws://192.168.1.144:7788', relayUrl: 'ws://your-relay-server:7789' }
  }
  const { hostname, port, protocol } = window.location
  const scheme = protocol === 'https:' ? 'wss' : 'ws'
  if (port === '7799') return { mode: 'direct', directUrl: `${scheme}://${hostname}:7788`,  relayUrl: 'ws://your-relay-server:7789' }
  if (port === '7789') return { mode: 'relay',  directUrl: 'ws://192.168.1.144:7788',       relayUrl: `${scheme}://${hostname}:7789` }
  if (port === '7788') return { mode: 'direct', directUrl: `${scheme}://${hostname}:7788`,  relayUrl: 'ws://your-relay-server:7789' }
  if (port === '')     return { mode: 'direct', directUrl: `${scheme}://${hostname}`,        relayUrl: 'ws://your-relay-server:7789' }
  return               { mode: 'direct', directUrl: 'ws://192.168.1.144:7788',              relayUrl: 'ws://your-relay-server:7789' }
}

export function ConnectPage({ onConnect, isConnecting, errorMsg }: Props) {
  const init = inferInitial()
  const [mode, setMode]           = useState<ConnectMode>(init.mode)
  const [directUrl, setDirectUrl] = useState(init.directUrl)
  const [relayUrl, setRelayUrl]   = useState(init.relayUrl)
  const [sessionId, setSessionId] = useState('')
  const [pin, setPin]             = useState('')

  function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    onConnect({ mode, directUrl, relayUrl, sessionId: sessionId.toUpperCase(), pin })
  }

  return (
    <div style={styles.wrap}>
      <div style={styles.card}>
        <div style={styles.logo}>
          <span style={styles.logoIcon}>⬡</span>
          <h1 style={styles.logoText}>Remoter</h1>
        </div>
        <p style={styles.sub}>远程控制 · 超清 2K · 60fps</p>

        {/* Mode toggle */}
        <div style={styles.tabs}>
          {(['direct', 'relay'] as ConnectMode[]).map(m => (
            <button
              key={m}
              style={{ ...styles.tab, ...(mode === m ? styles.tabActive : {}) }}
              onClick={() => setMode(m)}
            >
              {m === 'direct' ? '🔌 直连 (局域网)' : '🌐 中继 (公网)'}
            </button>
          ))}
        </div>

        <form onSubmit={handleSubmit} style={styles.form}>
          {mode === 'direct' ? (
            <label style={styles.label}>
              <span>被控端地址</span>
              <input
                value={directUrl}
                onChange={e => setDirectUrl(e.target.value)}
                placeholder="ws://192.168.1.100:7788"
                required
              />
            </label>
          ) : (
            <>
              <label style={styles.label}>
                <span>中继服务器地址</span>
                <input
                  value={relayUrl}
                  onChange={e => setRelayUrl(e.target.value)}
                  placeholder="ws://your-relay:7789"
                  required
                />
              </label>
              <label style={styles.label}>
                <span>会话 ID</span>
                <input
                  value={sessionId}
                  onChange={e => setSessionId(e.target.value.toUpperCase())}
                  placeholder="A1B2C3"
                  maxLength={6}
                  style={{ ...{ letterSpacing: '0.2em', textTransform: 'uppercase' } }}
                  required
                />
              </label>
            </>
          )}

          {/* PIN 登录已暂时禁用，测试用 */}

          {errorMsg && <div style={styles.error}>{errorMsg}</div>}

          <button type="submit" style={styles.btn} disabled={isConnecting}>
            {isConnecting ? '连接中…' : '连接'}
          </button>
        </form>

        <div style={styles.hint}>
          Mac 端运行：<code style={styles.code}>swift run RemoterAgent --pin 123456</code>
        </div>
      </div>
    </div>
  )
}

const styles: Record<string, React.CSSProperties> = {
  wrap: {
    display: 'flex', alignItems: 'center', justifyContent: 'center',
    height: '100%', background: 'var(--bg)'
  },
  card: {
    background: 'var(--bg2)', borderRadius: 16, padding: '40px 36px',
    width: 420, boxShadow: 'var(--shadow)'
  },
  logo: { display: 'flex', alignItems: 'center', gap: 12, marginBottom: 6 },
  logoIcon: { fontSize: 32, color: 'var(--primary)' },
  logoText: { fontSize: 28, fontWeight: 700, letterSpacing: '-0.5px' },
  sub: { color: 'var(--text2)', fontSize: 13, marginBottom: 28 },
  tabs: { display: 'flex', gap: 8, marginBottom: 24 },
  tab: {
    flex: 1, padding: '8px 0', borderRadius: 6, fontSize: 13,
    background: 'var(--bg3)', color: 'var(--text2)'
  },
  tabActive: { background: 'var(--primary)', color: '#fff' },
  form: { display: 'flex', flexDirection: 'column', gap: 16 },
  label: { display: 'flex', flexDirection: 'column', gap: 6, fontSize: 13, color: 'var(--text2)' },
  error: {
    background: '#fef2f2', color: '#dc2626', borderRadius: 6,
    padding: '8px 12px', fontSize: 13, border: '1px solid #fecaca'
  },
  btn: {
    marginTop: 4, padding: '12px 0', borderRadius: 8,
    background: 'var(--primary)', color: '#fff',
    fontSize: 15, fontWeight: 600
  },
  hint: {
    marginTop: 24, fontSize: 12, color: 'var(--text2)',
    lineHeight: 1.6, borderTop: '1px solid var(--border)', paddingTop: 16
  },
  code: {
    background: 'var(--bg)', padding: '2px 6px', borderRadius: 4,
    fontFamily: 'monospace', fontSize: 11, color: 'var(--text)'
  }
}
