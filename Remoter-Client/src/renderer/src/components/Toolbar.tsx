import React, { useState, useEffect, useRef } from 'react'
import { Connection } from '../network/Connection'
import { Theme, useTheme, applyTheme } from '../utils/theme'
import { KeyMap, ModKey, loadKeymap, setKeymapGlobal } from '../utils/keymap'

interface Props {
  conn: Connection
  onHide: () => void
  onToggleFullscreen: () => void
  fps: number
  fpsAuto: boolean
  onFpsChange: (fps: number, auto: boolean) => void
  bitrate: number
  bitrateAuto: boolean
  onBitrateChange: (bitrate: number, auto: boolean) => void
  resolution: '1080' | '2k'
  onResolutionChange: (tier: '1080' | '2k') => void
  transferCount: number
  onToggleTransfers: () => void
  showTransfers: boolean
  onMouseEnter?: () => void
  onMouseLeave?: () => void
}

// fps and bitrate are independent — each has its own auto-adjusting mode
// (server steps it based on its own feedback signal: fps on decode-overload,
// bitrate on network backpressure) plus its own manual tiers.
const FPS_TIERS = [30, 60]
const BITRATE_TIERS = [2_000_000, 4_000_000, 8_000_000, 15_000_000]

function formatBitrate(bps: number): string {
  const mbps = bps / 1_000_000
  return `${Number.isInteger(mbps) ? mbps : mbps.toFixed(1)}Mbps`
}

const RESOLUTION_OPTIONS: Array<{ label: string; tier: '1080' | '2k' }> = [
  { label: '1080p', tier: '1080' },
  { label: '2K',    tier: '2k'   },
]

const THEME_NEXT: Record<Theme, Theme> = { system: 'light', light: 'dark', dark: 'system' }
const THEME_ICON: Record<Theme, string> = { system: '💻', light: '☀️', dark: '🌙' }
const THEME_LABEL: Record<Theme, string> = { system: '跟随系统', light: '浅色', dark: '深色' }

export function Toolbar({
  conn, onHide, onToggleFullscreen,
  fps, fpsAuto, onFpsChange,
  bitrate, bitrateAuto, onBitrateChange,
  resolution, onResolutionChange,
  transferCount, onToggleTransfers, showTransfers,
  onMouseEnter, onMouseLeave,
}: Props) {
  const theme = useTheme()

  function cycleTheme() {
    applyTheme(THEME_NEXT[theme])
  }

  return (
    <div style={s.bar} onMouseEnter={onMouseEnter} onMouseLeave={onMouseLeave}>
      <AutoSelect
        value={fps}
        auto={fpsAuto}
        options={FPS_TIERS}
        formatValue={v => `${v}fps`}
        onChange={(f, auto) => {
          onFpsChange(f, auto)
          conn.sendFps(f, auto)
        }}
      />

      <AutoSelect
        value={bitrate}
        auto={bitrateAuto}
        options={BITRATE_TIERS}
        formatValue={formatBitrate}
        onChange={(b, auto) => {
          onBitrateChange(b, auto)
          conn.sendBitrate(b, auto)
        }}
      />

      <ResolutionSelect
        value={resolution}
        onChange={tier => {
          onResolutionChange(tier)
          conn.sendResolution(tier)
        }}
      />

      <ControlMenu conn={conn} />
      <ShortcutMenu conn={conn} />
      <KeymapMenu />

      <div style={s.sep} />

      <ToolBtn icon="📁" title={showTransfers ? '关闭文件管理器' : '文件管理器'}
        onClick={onToggleTransfers} active={showTransfers}
        badge={transferCount > 0 ? transferCount : undefined} />
      <ToolBtn icon={THEME_ICON[theme]} title={`主题: ${THEME_LABEL[theme]}`}
        onClick={cycleTheme} />
      <ToolBtn icon="⛶" title="全屏" onClick={onToggleFullscreen} />

      <div style={s.sep} />

      <ToolBtn icon="⊙" title="隐藏工具栏" onClick={onHide} />
    </div>
  )
}

// ─── Control menu ─────────────────────────────────────────────────────

function ControlMenu({ conn }: { conn: Connection }) {
  const [open, setOpen] = useState(false)
  const [clipSync, setClipSync]     = useState(true)
  const [inputEnabled, setInput]    = useState(true)
  const ref = useRef<HTMLDivElement>(null)

  useEffect(() => {
    if (!open) return
    const handler = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false)
    }
    document.addEventListener('mousedown', handler)
    return () => document.removeEventListener('mousedown', handler)
  }, [open])

  function toggleClip() {
    const next = !clipSync
    setClipSync(next)
    conn.sendSetClipboardSync(next)
  }

  function toggleInput() {
    const next = !inputEnabled
    setInput(next)
    conn.sendSetInputEnabled(next)
  }

  return (
    <div ref={ref} style={{ position: 'relative' }}>
      <button style={{ ...s.selectBtn, gap: 5 }} onClick={() => setOpen(v => !v)}>
        <span>控制</span>
        <span style={{ fontSize: 9, opacity: 0.45, lineHeight: 1 }}>{open ? '▲' : '▼'}</span>
      </button>

      {open && (
        <div style={{ ...s.dropdown, minWidth: 200 }}>
          {/* Clipboard sync toggle */}
          <div style={s.ctrlItem}>
            <span style={s.ctrlItemIcon}>📋</span>
            <span style={{ flex: 1 }}>同步剪贴板</span>
            <Toggle checked={clipSync} onToggle={toggleClip} />
          </div>

          {/* Input enabled toggle */}
          <div style={s.ctrlItem}>
            <span style={s.ctrlItemIcon}>🖱</span>
            <span style={{ flex: 1 }}>禁用被控端键鼠</span>
            <Toggle checked={!inputEnabled} onToggle={toggleInput} />
          </div>

          <div style={s.menuSep} />

          {/* Lock screen */}
          <button style={s.ctrlItem} onClick={() => { conn.sendLockScreen(); setOpen(false) }}>
            <span style={s.ctrlItemIcon}>🔒</span>
            <span>锁定计算机</span>
          </button>

          {/* Logout */}
          <button style={{ ...s.ctrlItem, color: '#d97706' }} onClick={() => { conn.sendLogout(); setOpen(false) }}>
            <span style={s.ctrlItemIcon}>👤</span>
            <span>注销计算机</span>
          </button>

          {/* Restart */}
          <button style={{ ...s.ctrlItem, color: '#dc2626' }} onClick={() => { conn.sendRestart(); setOpen(false) }}>
            <span style={s.ctrlItemIcon}>🔄</span>
            <span>重启计算机</span>
          </button>
        </div>
      )}
    </div>
  )
}

// ─── Shortcut keys menu ───────────────────────────────────────────────
// Keys the local browser reserves for itself (fullscreen, DevTools) or that the
// local OS intercepts before they reach the page (Ctrl+Alt+Delete) never make it
// through the normal keyboard capture path — send them explicitly instead.

const SHORTCUTS: Array<{ label: string; send: (conn: Connection) => void }> = [
  { label: 'Ctrl + Alt + Delete', send: conn => conn.sendCtrlAltDel() },
  { label: 'F11', send: conn => { conn.sendKey('F11', true, []); conn.sendKey('F11', false, []) } },
  { label: 'F12', send: conn => { conn.sendKey('F12', true, []); conn.sendKey('F12', false, []) } },
]

function ShortcutMenu({ conn }: { conn: Connection }) {
  const [open, setOpen] = useState(false)
  const ref = useRef<HTMLDivElement>(null)

  useEffect(() => {
    if (!open) return
    const handler = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false)
    }
    document.addEventListener('mousedown', handler)
    return () => document.removeEventListener('mousedown', handler)
  }, [open])

  return (
    <div ref={ref} style={{ position: 'relative' }}>
      <button style={{ ...s.selectBtn, gap: 5 }} onClick={() => setOpen(v => !v)}>
        <span>快捷键</span>
        <span style={{ fontSize: 9, opacity: 0.45, lineHeight: 1 }}>{open ? '▲' : '▼'}</span>
      </button>

      {open && (
        <div style={{ ...s.dropdown, minWidth: 200 }}>
          {SHORTCUTS.map(({ label, send }) => (
            <button key={label} style={s.ctrlItem} onClick={() => { send(conn); setOpen(false) }}>
              <span style={s.ctrlItemIcon}>⌨</span>
              <span style={{ flex: 1 }}>{label}</span>
              <span style={s.shortcut}>发送</span>
            </button>
          ))}
        </div>
      )}
    </div>
  )
}

// ─── Keyboard mapping menu ────────────────────────────────────────────

const MODKEY_OPTS: Array<{ value: ModKey; label: string }> = [
  { value: 'meta', label: 'Command ⌘' },
  { value: 'ctrl', label: 'Control ^'  },
  { value: 'alt',  label: 'Option ⌥'  },
]

const KEYMAP_ROWS: Array<{ field: keyof KeyMap; label: string }> = [
  { field: 'ctrl', label: 'Ctrl 键' },
  { field: 'meta', label: 'Windows / ⌘ 键' },
  { field: 'alt',  label: 'Alt / Option 键' },
]

function KeymapMenu() {
  const [open, setOpen] = useState(false)
  const [km, setKm] = useState<KeyMap>(loadKeymap)
  const ref = useRef<HTMLDivElement>(null)

  useEffect(() => {
    if (!open) return
    const handler = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false)
    }
    document.addEventListener('mousedown', handler)
    return () => document.removeEventListener('mousedown', handler)
  }, [open])

  function update(field: keyof KeyMap, val: ModKey) {
    const next = { ...km, [field]: val }
    setKm(next)
    setKeymapGlobal(next)
  }

  return (
    <div ref={ref} style={{ position: 'relative' }}>
      <button style={{ ...s.selectBtn, gap: 5 }} onClick={() => setOpen(v => !v)}>
        <span>键盘映射</span>
        <span style={{ fontSize: 9, opacity: 0.45, lineHeight: 1 }}>{open ? '▲' : '▼'}</span>
      </button>

      {open && (
        <div style={{
          position: 'absolute', top: 'calc(100% + 8px)', left: '50%', transform: 'translateX(-50%)',
          background: 'var(--ov-popup-bg)', backdropFilter: 'blur(12px)',
          WebkitBackdropFilter: 'blur(12px)',
          border: '1px solid var(--ov-popup-bdr)', borderRadius: 10,
          boxShadow: 'var(--ov-shadow)', zIndex: 200,
          padding: '12px 14px 14px', minWidth: 260,
        }}>
          <div style={{ fontSize: 12, fontWeight: 600, color: 'var(--ov-text)', marginBottom: 3 }}>键盘设置</div>
          <div style={{ fontSize: 11, color: 'var(--ov-text2)', marginBottom: 12, lineHeight: 1.4 }}>
            控制该设备时的修饰键映射
          </div>
          {KEYMAP_ROWS.map(({ field, label }) => (
            <div key={field} style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 8 }}>
              <span style={{ fontSize: 12, color: 'var(--ov-text2)' }}>{label}</span>
              <select
                value={km[field]}
                onChange={e => update(field, e.target.value as ModKey)}
                style={{
                  background: 'var(--ov-input-bg)', color: 'var(--ov-text)',
                  border: '1px solid var(--ov-input-bdr)', borderRadius: 6,
                  padding: '3px 8px', fontSize: 12, cursor: 'pointer', fontFamily: 'inherit',
                }}
              >
                {MODKEY_OPTS.map(o => (
                  <option key={o.value} value={o.value}>{o.label}</option>
                ))}
              </select>
            </div>
          ))}
        </div>
      )}
    </div>
  )
}

// ─── Toggle switch ────────────────────────────────────────────────────

function Toggle({ checked, onToggle }: { checked: boolean; onToggle: () => void }) {
  return (
    <div
      onClick={e => { e.stopPropagation(); onToggle() }}
      style={{
        width: 32, height: 18, borderRadius: 9, flexShrink: 0,
        background: checked ? '#0fb8ab' : 'var(--ov-sep)',
        position: 'relative', cursor: 'pointer',
        transition: 'background 0.2s',
      }}
    >
      <div style={{
        width: 14, height: 14, borderRadius: '50%', background: '#fff',
        position: 'absolute', top: 2, left: checked ? 16 : 2,
        transition: 'left 0.15s',
        boxShadow: '0 1px 3px rgba(0,0,0,0.25)',
      }} />
    </div>
  )
}

// ─── Generic auto/manual dropdown (used for fps and bitrate) ──────────
// Each has its own independent "自动" mode — the server steps it based on
// its own feedback signal — plus a fixed set of manual values.

function AutoSelect<T>({ value, auto, options, formatValue, onChange }: {
  value: T
  auto: boolean
  options: T[]
  formatValue: (v: T) => string
  onChange: (value: T, auto: boolean) => void
}) {
  const [open, setOpen] = useState(false)
  const ref = useRef<HTMLDivElement>(null)

  useEffect(() => {
    if (!open) return
    const handler = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false)
    }
    document.addEventListener('mousedown', handler)
    return () => document.removeEventListener('mousedown', handler)
  }, [open])

  return (
    <div ref={ref} style={{ position: 'relative' }}>
      <button style={s.selectBtn} onClick={() => setOpen(v => !v)}>
        <span>{auto ? `自动 (${formatValue(value)})` : formatValue(value)}</span>
        <span style={{ fontSize: 9, opacity: 0.45, lineHeight: 1 }}>{open ? '▲' : '▼'}</span>
      </button>
      {open && (
        <div style={s.dropdown}>
          <button
            style={{ ...s.dropItem, ...(auto ? s.dropItemActive : {}) }}
            onClick={() => { onChange(value, true); setOpen(false) }}
          >
            <span>自动</span>
            {auto && <span style={{ color: '#0d9488', fontSize: 11 }}>✓</span>}
          </button>
          {options.map(o => {
            const active = !auto && o === value
            return (
              <button
                key={formatValue(o)}
                style={{ ...s.dropItem, ...(active ? s.dropItemActive : {}) }}
                onClick={() => { onChange(o, false); setOpen(false) }}
              >
                <span>{formatValue(o)}</span>
                {active && <span style={{ color: '#0d9488', fontSize: 11 }}>✓</span>}
              </button>
            )
          })}
        </div>
      )}
    </div>
  )
}

// ─── Resolution dropdown ────────────────────────────────────────────
// Unlike fps/bitrate, resolution can't change on a live encoder — the
// server tears down and rebuilds capture+encode at the new size (a brief
// visible gap), so this stays a plain manual choice, never auto-adjusted.

function ResolutionSelect({ value, onChange }: { value: '1080' | '2k'; onChange: (tier: '1080' | '2k') => void }) {
  const [open, setOpen] = useState(false)
  const ref = useRef<HTMLDivElement>(null)
  const current = RESOLUTION_OPTIONS.find(o => o.tier === value) ?? RESOLUTION_OPTIONS[0]

  useEffect(() => {
    if (!open) return
    const handler = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false)
    }
    document.addEventListener('mousedown', handler)
    return () => document.removeEventListener('mousedown', handler)
  }, [open])

  return (
    <div ref={ref} style={{ position: 'relative' }}>
      <button style={s.selectBtn} onClick={() => setOpen(v => !v)}>
        <span>{current.label}</span>
        <span style={{ fontSize: 9, opacity: 0.45, lineHeight: 1 }}>{open ? '▲' : '▼'}</span>
      </button>
      {open && (
        <div style={s.dropdown}>
          {RESOLUTION_OPTIONS.map(o => {
            const active = o.tier === value
            return (
              <button
                key={o.tier}
                style={{ ...s.dropItem, ...(active ? s.dropItemActive : {}) }}
                onClick={() => { onChange(o.tier); setOpen(false) }}
              >
                <span>{o.label}</span>
                {active && <span style={{ color: '#0d9488', fontSize: 11 }}>✓</span>}
              </button>
            )
          })}
        </div>
      )}
    </div>
  )
}

// ─── Icon button ──────────────────────────────────────────────────────

function ToolBtn({ icon, title, onClick, active, badge }: {
  icon: string; title: string; onClick: () => void
  active?: boolean; badge?: number
}) {
  return (
    <button
      style={{ ...s.btn, ...(active ? s.btnActive : {}) }}
      title={title}
      onClick={onClick}
    >
      {icon}
      {badge != null && badge > 0 && (
        <span style={s.badge}>{badge}</span>
      )}
    </button>
  )
}

// ─── Styles ───────────────────────────────────────────────────────────

const s: Record<string, React.CSSProperties> = {
  bar: {
    display: 'flex', alignItems: 'center', gap: 2,
    background: 'var(--ov-bg)',
    backdropFilter: 'blur(12px)',
    WebkitBackdropFilter: 'blur(12px)',
    padding: '5px 10px',
    borderRadius: 20,
    position: 'absolute', top: 12, left: '50%', transform: 'translateX(-50%)',
    boxShadow: '0 4px 20px rgba(0,0,0,0.15), 0 1px 4px rgba(0,0,0,0.08)',
    zIndex: 100,
    border: '1px solid var(--ov-border)',
    pointerEvents: 'auto',
  },
  selectBtn: {
    display: 'flex', alignItems: 'center', gap: 6,
    background: 'var(--ov-input-bg)',
    color: 'var(--ov-text)',
    border: '1px solid var(--ov-input-bdr)',
    borderRadius: 8,
    padding: '5px 10px',
    fontSize: 13,
    cursor: 'pointer',
    fontFamily: 'inherit',
    whiteSpace: 'nowrap',
    height: 30,
  },
  dropdown: {
    position: 'absolute',
    top: 'calc(100% + 8px)',
    left: '50%',
    transform: 'translateX(-50%)',
    background: 'var(--ov-popup-bg)',
    backdropFilter: 'blur(12px)',
    WebkitBackdropFilter: 'blur(12px)',
    border: '1px solid var(--ov-popup-bdr)',
    borderRadius: 10,
    boxShadow: 'var(--ov-shadow)',
    overflow: 'hidden',
    zIndex: 200,
    minWidth: 130,
  },
  dropItem: {
    display: 'flex', alignItems: 'center', justifyContent: 'space-between',
    width: '100%', padding: '9px 16px', fontSize: 13,
    color: 'var(--ov-text)', background: 'transparent',
    cursor: 'pointer', whiteSpace: 'nowrap', gap: 12, fontFamily: 'inherit',
  },
  dropItemActive: { color: '#0d9488', fontWeight: 600, background: 'rgba(13,148,136,0.07)' },
  // control menu items
  ctrlItem: {
    display: 'flex', alignItems: 'center', gap: 10,
    width: '100%', padding: '9px 14px', fontSize: 13,
    color: 'var(--ov-text)', background: 'transparent',
    cursor: 'pointer', fontFamily: 'inherit', whiteSpace: 'nowrap',
  },
  ctrlItemIcon: { fontSize: 14, width: 20, textAlign: 'center', flexShrink: 0 },
  shortcut: { fontSize: 11, color: 'var(--ov-text2)', flexShrink: 0 },
  menuSep: { height: 1, background: 'var(--ov-sep)', margin: '3px 0' },
  // shared
  sep: { width: 1, height: 18, background: 'var(--ov-sep)', margin: '0 4px', flexShrink: 0 },
  btn: {
    position: 'relative', background: 'transparent', color: 'var(--ov-text)',
    padding: '5px 8px', borderRadius: 8, fontSize: 16,
    cursor: 'pointer', transition: 'background 0.1s',
  },
  btnActive: { background: 'rgba(13,148,136,0.13)', color: '#0d9488' },
  badge: {
    position: 'absolute', top: 2, right: 2,
    background: '#e94560', color: '#fff',
    fontSize: 9, fontWeight: 700, borderRadius: 8,
    padding: '0 3px', minWidth: 14, textAlign: 'center', lineHeight: '14px',
  },
}
