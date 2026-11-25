import React, { useState, useEffect, useRef } from 'react'
import { Connection } from '../network/Connection'
import { Theme, useTheme, applyTheme } from '../utils/theme'
import { KeyMap, ModKey, loadKeymap, setKeymapGlobal } from '../utils/keymap'
import { VideoDecoder_ } from '../video/Decoder'
import { DisplayInfo, ResolutionTier, ScaleMode, SharpnessLevel, ChromaMode, QualityPreset } from '../types'

interface Props {
  conn: Connection
  onHide: () => void
  onToggleFullscreen: () => void
  qualityPreset: QualityPreset
  onQualityPresetChange: (preset: QualityPreset) => void
  fps: number
  fpsAuto: boolean
  onFpsChange: (fps: number, auto: boolean) => void
  bitrate: number
  bitrateAuto: boolean
  onBitrateChange: (bitrate: number, auto: boolean) => void
  resolution: ResolutionTier
  onResolutionChange: (tier: ResolutionTier) => void
  scaleMode: ScaleMode
  onScaleModeChange: (mode: ScaleMode) => void
  codec: 'h264' | 'h265'
  onCodecChange: (codec: 'h264' | 'h265') => void
  sharpness: SharpnessLevel
  onSharpnessChange: (level: SharpnessLevel) => void
  chromaMode: ChromaMode
  onToggleChroma: () => void
  hdrOn: boolean
  onToggleHdr: () => void
  matchHiDPI: boolean
  onToggleMatchHiDPI: () => void
  toneMap: boolean
  onToggleToneMap: () => void
  lowLatency: boolean
  onToggleLowLatency: () => void
  zoom: number
  onZoomChange: (z: number) => void
  audioOn: boolean
  onToggleAudio: () => void
  micOn: boolean
  onToggleMic: () => void
  privacyOn?: boolean
  onTogglePrivacy?: () => void
  virtualDisplayOn?: boolean
  onToggleVirtualDisplay?: () => void
  inputLocked: boolean
  onToggleInputLock: () => void
  displays: DisplayInfo[]
  activeDisplay: number
  onDisplayChange: (id: number) => void
  transferCount: number
  onToggleTransfers: () => void
  showTransfers: boolean
  imeCalibrating: boolean
  onToggleImeCalibration: () => void
  showStatsHud: boolean
  onToggleStatsHud: () => void
  onMouseEnter?: () => void
  onMouseLeave?: () => void
}

// fps and bitrate are independent — each has its own auto-adjusting mode
// (server steps it based on its own feedback signal: fps on decode-overload,
// bitrate on network backpressure) plus its own manual tiers.
const FPS_TIERS = [30, 60, 90, 120]
const BITRATE_TIERS = [2_000_000, 4_000_000, 8_000_000, 15_000_000, 25_000_000]

function formatBitrate(bps: number): string {
  const mbps = bps / 1_000_000
  return `${Number.isInteger(mbps) ? mbps : mbps.toFixed(1)}Mbps`
}

const RESOLUTION_OPTIONS: Array<{ label: string; tier: ResolutionTier }> = [
  { label: '自适应屏幕', tier: 'match' },
  { label: '原生',     tier: 'native' },
  { label: '1080p',    tier: '1080'   },
  { label: '2K',       tier: '2k'     },
]

const SCALE_MODE_OPTIONS: Array<{ label: string; mode: ScaleMode }> = [
  { label: '等比缩放', mode: 'fit' },
  { label: '拉伸铺满', mode: 'stretch' },
  { label: '原始1:1',  mode: 'original' },
]

const SHARPNESS_OPTIONS: Array<{ label: string; level: SharpnessLevel }> = [
  { label: '关',   level: 'off'    },
  { label: '柔和', level: 'low'    },
  { label: '清晰', level: 'medium' },
  { label: '极致', level: 'high'   },
]

const QUALITY_PRESET_OPTIONS: Array<{ label: string; preset: QualityPreset }> = [
  { label: '自动', preset: 'auto'     },
  { label: '流畅', preset: 'smooth'   },
  { label: '高清', preset: 'hd'       },
  { label: '原画', preset: 'original' },
]

const ZOOM_TIERS = [1, 1.25, 1.5, 2]

const THEME_NEXT: Record<Theme, Theme> = { system: 'light', light: 'dark', dark: 'system' }
const THEME_ICON: Record<Theme, string> = { system: '💻', light: '☀️', dark: '🌙' }
const THEME_LABEL: Record<Theme, string> = { system: '跟随系统', light: '浅色', dark: '深色' }

export function Toolbar({
  conn, onHide, onToggleFullscreen,
  qualityPreset, onQualityPresetChange,
  fps, fpsAuto, onFpsChange,
  bitrate, bitrateAuto, onBitrateChange,
  resolution, onResolutionChange,
  scaleMode, onScaleModeChange,
  codec, onCodecChange,
  sharpness, onSharpnessChange,
  chromaMode, onToggleChroma,
  hdrOn, onToggleHdr,
  matchHiDPI, onToggleMatchHiDPI,
  toneMap, onToggleToneMap,
  lowLatency, onToggleLowLatency,
  zoom, onZoomChange,
  audioOn, onToggleAudio,
  micOn, onToggleMic,
  privacyOn, onTogglePrivacy,
  virtualDisplayOn, onToggleVirtualDisplay,
  inputLocked, onToggleInputLock,
  displays, activeDisplay, onDisplayChange,
  transferCount, onToggleTransfers, showTransfers,
  imeCalibrating: _imeCalibrating, onToggleImeCalibration: _onToggleImeCalibration,
  showStatsHud, onToggleStatsHud,
  onMouseEnter, onMouseLeave,
}: Props) {
  const theme = useTheme()

  function cycleTheme() {
    applyTheme(THEME_NEXT[theme])
  }

  return (
    <div style={s.bar} onMouseEnter={onMouseEnter} onMouseLeave={onMouseLeave}>
      <QualityMenu
        qualityPreset={qualityPreset}
        onQualityPresetChange={onQualityPresetChange}
        resolution={resolution}
        onResolutionChange={onResolutionChange}
        scaleMode={scaleMode}
        onScaleModeChange={onScaleModeChange}
        fps={fps}
        fpsAuto={fpsAuto}
        onFpsChange={(f, auto) => {
          onFpsChange(f, auto)
          conn.sendFps(f, auto)
        }}
        bitrate={bitrate}
        bitrateAuto={bitrateAuto}
        onBitrateChange={(b, auto) => {
          onBitrateChange(b, auto)
          conn.sendBitrate(b, auto)
        }}
        codec={codec}
        onCodecChange={c => {
          onCodecChange(c)
          conn.sendSetCodec(c)
        }}
        sharpness={sharpness}
        onSharpnessChange={onSharpnessChange}
        chromaMode={chromaMode}
        onToggleChroma={onToggleChroma}
        hdrOn={hdrOn}
        onToggleHdr={onToggleHdr}
        matchHiDPI={matchHiDPI}
        onToggleMatchHiDPI={onToggleMatchHiDPI}
        toneMap={toneMap}
        onToggleToneMap={onToggleToneMap}
        lowLatency={lowLatency}
        onToggleLowLatency={onToggleLowLatency}
        showStatsHud={showStatsHud}
        onToggleStatsHud={onToggleStatsHud}
        displays={displays}
        activeDisplay={activeDisplay}
        onDisplayChange={id => {
          onDisplayChange(id)
          conn.sendSetDisplay(id)
        }}
      />

      <ZoomMenu zoom={zoom} onZoomChange={onZoomChange} />

      <ControlMenu
        conn={conn}
        audioOn={audioOn} onToggleAudio={onToggleAudio}
        micOn={micOn} onToggleMic={onToggleMic}
        privacyOn={privacyOn} onTogglePrivacy={onTogglePrivacy}
        virtualDisplayOn={virtualDisplayOn} onToggleVirtualDisplay={onToggleVirtualDisplay}
        inputLocked={inputLocked} onToggleInputLock={onToggleInputLock}
      />
      <ShortcutMenu conn={conn} />
      <KeymapMenu />

      <div style={s.sep} />

      <ToolBtn
        icon="🎤"
        title={micOn ? '关闭麦克风回传' : '开启麦克风回传'}
        onClick={onToggleMic}
        active={micOn}
      />

      {displays.length > 1 && (
        <ToolBtn
          icon="🖥️"
          title={`一键切屏 (当前: ${displays.find(d => d.id === activeDisplay)?.name ?? activeDisplay})`}
          onClick={() => {
            const idx = displays.findIndex(d => d.id === activeDisplay)
            const next = displays[(idx + 1) % displays.length]
            if (next) {
              onDisplayChange(next.id)
              conn.sendSetDisplay(next.id)
            }
          }}
        />
      )}
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

// ─── Quality menu ───────────────────────────────────────────────────
// One trigger ("画质") opens a panel holding the three independent
// controls side by side, instead of three separate top-level dropdowns.

function QualityMenu({
  qualityPreset, onQualityPresetChange,
  resolution, onResolutionChange,
  scaleMode, onScaleModeChange,
  fps, fpsAuto, onFpsChange,
  bitrate, bitrateAuto, onBitrateChange,
  codec, onCodecChange,
  sharpness, onSharpnessChange,
  chromaMode, onToggleChroma,
  hdrOn, onToggleHdr,
  matchHiDPI, onToggleMatchHiDPI,
  toneMap, onToggleToneMap,
  lowLatency, onToggleLowLatency,
  showStatsHud, onToggleStatsHud,
  displays, activeDisplay, onDisplayChange,
}: {
  qualityPreset: QualityPreset
  onQualityPresetChange: (preset: QualityPreset) => void
  resolution: ResolutionTier
  onResolutionChange: (tier: ResolutionTier) => void
  scaleMode: ScaleMode
  onScaleModeChange: (mode: ScaleMode) => void
  fps: number
  fpsAuto: boolean
  onFpsChange: (fps: number, auto: boolean) => void
  bitrate: number
  bitrateAuto: boolean
  onBitrateChange: (bitrate: number, auto: boolean) => void
  codec: 'h264' | 'h265'
  onCodecChange: (codec: 'h264' | 'h265') => void
  sharpness: SharpnessLevel
  onSharpnessChange: (level: SharpnessLevel) => void
  chromaMode: ChromaMode
  onToggleChroma: () => void
  hdrOn: boolean
  onToggleHdr: () => void
  matchHiDPI: boolean
  onToggleMatchHiDPI: () => void
  toneMap: boolean
  onToggleToneMap: () => void
  lowLatency: boolean
  onToggleLowLatency: () => void
  showStatsHud: boolean
  onToggleStatsHud: () => void
  displays: DisplayInfo[]
  activeDisplay: number
  onDisplayChange: (id: number) => void
}) {
  const [open, setOpen] = useState(false)
  const [showAdvanced, setShowAdvanced] = useState(false)
  const [h265Available, setH265Available] = useState(false)
  const ref = useRef<HTMLDivElement>(null)

  // HEVC decode is hardware-dependent (Chromium ships no software HEVC) —
  // only offer the option where this client can actually decode it.
  useEffect(() => {
    VideoDecoder_.isH265Supported().then(setH265Available)
  }, [])

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
        <span>画质</span>
        <span style={{ fontSize: 9, opacity: 0.45, lineHeight: 1 }}>{open ? '▲' : '▼'}</span>
      </button>
      {open && (
        <div style={{
          ...s.dropdown, minWidth: 220, width: 'max-content', overflow: 'visible',
          display: 'flex', flexDirection: 'column', gap: 8, padding: 10,
        }}>
          {displays.length > 1 && (
            <DisplaySelect displays={displays} value={activeDisplay} onChange={onDisplayChange} />
          )}

          {/* 画质预设: 自动 / 流畅 / 高清 / 原画 */}
          <div style={{ display: 'flex', flexDirection: 'column', gap: 5 }}>
            <div style={{
              display: 'flex', alignItems: 'center', justifyContent: 'space-between',
              fontSize: 11, color: 'var(--ov-text2)', padding: '0 2px',
            }}>
              <span>画质预设</span>
              {qualityPreset === 'auto' && (
                <span style={{ fontSize: 10, opacity: 0.85 }}>
                  {`${fps}fps · ${formatBitrate(bitrate)}`}
                </span>
              )}
            </div>
            <div style={{
              display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 4,
              background: 'var(--ov-input-bg)', padding: 3, borderRadius: 8,
              border: '1px solid var(--ov-input-bdr)',
            }}>
              {QUALITY_PRESET_OPTIONS.map(o => {
                const active = o.preset === qualityPreset
                return (
                  <button
                    key={o.preset}
                    onClick={() => onQualityPresetChange(o.preset)}
                    style={{
                      padding: '5px 8px',
                      fontSize: 12,
                      fontWeight: active ? 600 : 400,
                      borderRadius: 6,
                      border: 'none',
                      cursor: 'pointer',
                      fontFamily: 'inherit',
                      whiteSpace: 'nowrap',
                      background: active ? '#0d9488' : 'transparent',
                      color: active ? '#fff' : 'var(--ov-text)',
                      transition: 'background 0.15s, color 0.15s',
                    }}
                  >
                    {o.label}
                  </button>
                )
              })}
            </div>
          </div>

          <div style={s.menuSep} />

          <div style={s.qualityToggleRow} title="开启 4:4:4 无色度抽样真彩模式（适合精细代码与文字）">
            <span>真彩 4:4:4</span>
            <Toggle checked={chromaMode === '444'} onToggle={onToggleChroma} />
          </div>
          <div style={s.qualityToggleRow} title="开启 10-bit HDR 捕获与编码">
            <span>HDR 10-bit</span>
            <Toggle checked={hdrOn} onToggle={onToggleHdr} />
          </div>
          <div style={s.qualityToggleRow} title="自动在被控端创建匹配本机逻辑分辨率的 2x Retina HiDPI 虚拟屏">
            <span>匹配本机 HiDPI</span>
            <Toggle checked={matchHiDPI} onToggle={onToggleMatchHiDPI} />
          </div>
          <div style={s.qualityToggleRow} title="在画面右下角显示实时帧率、码率与延迟信息">
            <span>性能浮窗</span>
            <Toggle checked={showStatsHud} onToggle={onToggleStatsHud} />
          </div>

          <div style={s.menuSep} />

          <button
            onClick={() => setShowAdvanced(v => !v)}
            style={{
              display: 'flex', alignItems: 'center', justifyContent: 'space-between',
              width: '100%', padding: '4px 2px', fontSize: 12,
              color: 'var(--ov-text2)', background: 'transparent',
              border: 'none', cursor: 'pointer', fontFamily: 'inherit',
            }}
          >
            <span>高级设置</span>
            <span style={{ fontSize: 10 }}>{showAdvanced ? '▾' : '▸'}</span>
          </button>

          {showAdvanced && (
            <div style={{ display: 'flex', flexDirection: 'column', gap: 8, paddingTop: 2 }}>
              <div style={s.qualityToggleRow}>
                <span>分辨率</span>
                <ResolutionSelect value={resolution} onChange={onResolutionChange} />
              </div>
              <div style={s.qualityToggleRow}>
                <span>缩放模式</span>
                <ScaleModeSelect value={scaleMode} onChange={onScaleModeChange} />
              </div>
              <div style={s.qualityToggleRow}>
                <span>手动帧率</span>
                <AutoSelect value={fps} auto={fpsAuto} options={FPS_TIERS}
                  formatValue={v => `${v}fps`} width={92} onChange={onFpsChange} />
              </div>
              <div style={s.qualityToggleRow}>
                <span>手动码率</span>
                <AutoSelect value={bitrate} auto={bitrateAuto} options={BITRATE_TIERS}
                  formatValue={formatBitrate} width={92} onChange={onBitrateChange} />
              </div>
              <div style={s.qualityToggleRow}>
                <span>锐化强度</span>
                <SharpnessSelect value={sharpness} onChange={onSharpnessChange} />
              </div>
              {h265Available && (
                <div style={s.qualityToggleRow}>
                  <span>编解码器</span>
                  <CodecSelect value={codec} onChange={onCodecChange} />
                </div>
              )}
              <div style={s.qualityToggleRow} title="局域网绕过 WebRTC 抖动缓冲，采用 WebCodecs + WebGL2 零缓冲极速渲染">
                <span>零缓冲极速</span>
                <Toggle checked={lowLatency} onToggle={onToggleLowLatency} />
              </div>
              {hdrOn && (
                <div style={s.qualityToggleRow} title="在 SDR 显示器上自动将 HDR 映射为自然色彩 (ACES)">
                  <span>SDR 映射</span>
                  <Toggle checked={toneMap} onToggle={onToggleToneMap} />
                </div>
              )}
            </div>
          )}
        </div>
      )}
    </div>
  )
}

function SharpnessSelect({ value, onChange }: { value: SharpnessLevel; onChange: (level: SharpnessLevel) => void }) {
  const [open, setOpen] = useState(false)
  const ref = useRef<HTMLDivElement>(null)
  const current = SHARPNESS_OPTIONS.find(o => o.level === value) ?? SHARPNESS_OPTIONS[0]

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
      <button style={{ ...s.selectBtn, width: 120, justifyContent: 'space-between' }} onClick={() => setOpen(v => !v)}>
        <span>锐化: {current.label}</span>
        <span style={{ fontSize: 9, opacity: 0.45, lineHeight: 1, flexShrink: 0 }}>{open ? '▲' : '▼'}</span>
      </button>
      {open && (
        <div style={s.dropdown}>
          {SHARPNESS_OPTIONS.map(o => {
            const active = o.level === value
            return (
              <button
                key={o.level}
                style={{ ...s.dropItem, ...(active ? s.dropItemActive : {}) }}
                onClick={() => { onChange(o.level); setOpen(false) }}
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

function ZoomMenu({ zoom, onZoomChange }: { zoom: number; onZoomChange: (z: number) => void }) {
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

  const pct = Math.round(zoom * 100)

  return (
    <div ref={ref} style={{ position: 'relative' }}>
      <button
        style={{ ...s.selectBtn, gap: 5, ...(zoom !== 1 ? s.btnActive : {}) }}
        onClick={() => setOpen(v => !v)}
        title="缩放视图 (放大后可按住中键或 Alt+拖拽平移)"
      >
        <span>{pct}%</span>
        <span style={{ fontSize: 9, opacity: 0.45, lineHeight: 1 }}>{open ? '▲' : '▼'}</span>
      </button>
      {open && (
        <div style={{ ...s.dropdown, minWidth: 110 }}>
          {ZOOM_TIERS.map(z => {
            const active = Math.abs(zoom - z) < 0.01
            return (
              <button
                key={z}
                style={{ ...s.dropItem, ...(active ? s.dropItemActive : {}) }}
                onClick={() => { onZoomChange(z); setOpen(false) }}
              >
                <span>{Math.round(z * 100)}%</span>
                {active && <span style={{ color: '#0d9488', fontSize: 11 }}>✓</span>}
              </button>
            )
          })}
          {Math.abs(zoom - 1) >= 0.01 && (
            <>
              <div style={s.menuSep} />
              <button
                style={s.dropItem}
                onClick={() => { onZoomChange(1); setOpen(false) }}
              >
                <span>重置缩放</span>
              </button>
            </>
          )}
        </div>
      )}
    </div>
  )
}

// Remote display picker — only rendered when the remote has more than one.
// Switching triggers a full pipeline rebuild server-side (brief gap).
function DisplaySelect({ displays, value, onChange }: {
  displays: DisplayInfo[]
  value: number
  onChange: (id: number) => void
}) {
  const [open, setOpen] = useState(false)
  const ref = useRef<HTMLDivElement>(null)
  const current = displays.find(d => d.id === value) ?? displays[0]

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
      <button style={{ ...s.selectBtn, width: 120, justifyContent: 'space-between' }} onClick={() => setOpen(v => !v)}>
        <span style={{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>🖥 {current?.name ?? '显示器'}</span>
        <span style={{ fontSize: 9, opacity: 0.45, lineHeight: 1, flexShrink: 0 }}>{open ? '▲' : '▼'}</span>
      </button>
      {open && (
        <div style={s.dropdown}>
          {displays.map(d => {
            const active = d.id === value
            return (
              <button
                key={d.id}
                style={{ ...s.dropItem, ...(active ? s.dropItemActive : {}) }}
                onClick={() => { onChange(d.id); setOpen(false) }}
              >
                <span>{d.name}（{d.width}×{d.height}）</span>
                {active && <span style={{ color: '#0d9488', fontSize: 11 }}>✓</span>}
              </button>
            )
          })}
        </div>
      )}
    </div>
  )
}

// H.264 / H.265 picker — same look as the other selects. H.265 halves the
// bitrate needed for the same quality on Apple Silicon's hardware encoder,
// but decode support varies by client GPU, so QualityMenu only renders this
// when the WebCodecs support probe passes.
function CodecSelect({ value, onChange }: { value: 'h264' | 'h265'; onChange: (c: 'h264' | 'h265') => void }) {
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

  const label = (c: 'h264' | 'h265') => c === 'h265' ? 'H.265' : 'H.264'

  return (
    <div ref={ref} style={{ position: 'relative' }}>
      <button style={{ ...s.selectBtn, width: 82, justifyContent: 'space-between' }} onClick={() => setOpen(v => !v)}>
        <span>{label(value)}</span>
        <span style={{ fontSize: 9, opacity: 0.45, lineHeight: 1, flexShrink: 0 }}>{open ? '▲' : '▼'}</span>
      </button>
      {open && (
        <div style={s.dropdown}>
          {(['h264', 'h265'] as const).map(c => {
            const active = c === value
            return (
              <button
                key={c}
                style={{ ...s.dropItem, ...(active ? s.dropItemActive : {}) }}
                onClick={() => { onChange(c); setOpen(false) }}
              >
                <span>{label(c)}</span>
                {active && <span style={{ color: '#0d9488', fontSize: 11 }}>✓</span>}
              </button>
            )
          })}
        </div>
      )}
    </div>
  )
}

// ─── Control menu ─────────────────────────────────────────────────────

function ControlMenu({ conn, audioOn, onToggleAudio, micOn, onToggleMic, privacyOn = false, onTogglePrivacy, virtualDisplayOn = false, onToggleVirtualDisplay, inputLocked, onToggleInputLock }: {
  conn: Connection
  audioOn: boolean
  onToggleAudio: () => void
  micOn: boolean
  onToggleMic: () => void
  privacyOn?: boolean
  onTogglePrivacy?: () => void
  virtualDisplayOn?: boolean
  onToggleVirtualDisplay?: () => void
  inputLocked: boolean
  onToggleInputLock: () => void
}) {
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
    // Client-local now — clipboard sync is one-directional (this controller
    // pushes out, the agent never pushes its own clipboard back), so there's
    // nothing left for the agent to toggle; this just gates the local poll
    // loop directly.
    conn.setClipboardSyncManualEnabled(next)
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

          {/* This client's own input, view-only mode — previously labeled
              "禁用被控端键鼠" ("disable target's keyboard/mouse"), which reads
              as if it affects the target machine. It doesn't: it only stops
              *this* client from sending input at all, the target's own
              physical devices are untouched either way. Renamed to make the
              subject (this end, not the target) unambiguous. */}
          <div style={s.ctrlItem} title="仅影响这个控制端：开启后你在这里的键鼠操作不会发送给被控端">
            <span style={s.ctrlItemIcon}>🖱</span>
            <span style={{ flex: 1 }}>仅观看(本端不操作)</span>
            <Toggle checked={!inputEnabled} onToggle={toggleInput} />
          </div>

          {/* Locks out the target's own physical keyboard/mouse (Mac agent
              only for now) — the opposite direction from the toggle above,
              which only affects what *this* client is allowed to send.
              Machine-wide, not per-session: whoever's physically there loses
              all local keyboard/mouse until unlocked, with Control+Option+
              Command+Escape as their local way out if no controller is
              reachable to release it remotely. */}
          <div style={s.ctrlItem} title="锁定后被控端本地物理键鼠完全失效，被控端可按 Control+Option+Command+Esc 强制解锁">
            <span style={s.ctrlItemIcon}>🔐</span>
            <span style={{ flex: 1 }}>锁定被控端物理键鼠</span>
            <Toggle checked={inputLocked} onToggle={onToggleInputLock} />
          </div>

          {/* Remote audio forwarding (macOS & Windows supported) */}
          <div style={s.ctrlItem}>
            <span style={s.ctrlItemIcon}>🔊</span>
            <span style={{ flex: 1 }}>转发远端声音</span>
            <Toggle checked={audioOn} onToggle={onToggleAudio} />
          </div>

          {/* Local microphone passthrough (opt-in, default OFF) */}
          <div style={s.ctrlItem} title="将本端麦克风声音回传到被控端虚拟音频设备（BlackHole / VB-Cable）">
            <span style={s.ctrlItemIcon}>🎤</span>
            <span style={{ flex: 1 }}>回传本地麦克风</span>
            <Toggle checked={micOn} onToggle={onToggleMic} />
          </div>

          {/* Privacy screen (Curtain Mode) */}
          <div style={s.ctrlItem} title="开启后被控端物理屏幕全黑遮盖，防止本地窥屏">
            <span style={s.ctrlItemIcon}>🛡️</span>
            <span style={{ flex: 1 }}>开启防窥隐私屏</span>
            <Toggle checked={privacyOn} onToggle={onTogglePrivacy ?? (() => {})} />
          </div>

          {/* Virtual extended display */}
          <div style={s.ctrlItem} title="在被控端创建或销毁 HiDPI 虚拟扩展屏，适合无头主机或多屏办公">
            <span style={s.ctrlItemIcon}>🖥️</span>
            <span style={{ flex: 1 }}>虚拟扩展屏</span>
            <Toggle checked={virtualDisplayOn} onToggle={onToggleVirtualDisplay ?? (() => {})} />
          </div>

          <div style={s.menuSep} />

          {/* Power actions (lock / sleep / restart via unified power_action) */}
          <button style={s.ctrlItem} onClick={() => { conn.sendPowerAction('lock'); setOpen(false) }}>
            <span style={s.ctrlItemIcon}>🔒</span>
            <span>锁屏</span>
          </button>

          <button
            style={s.ctrlItem}
            onClick={() => {
              if (window.confirm('确定让远程电脑进入休眠吗？')) {
                conn.sendPowerAction('sleep')
                setOpen(false)
              }
            }}
          >
            <span style={s.ctrlItemIcon}>🌙</span>
            <span>休眠</span>
          </button>

          {/* Logout */}
          <button style={{ ...s.ctrlItem, color: '#d97706' }} onClick={() => { conn.sendLogout(); setOpen(false) }}>
            <span style={s.ctrlItemIcon}>👤</span>
            <span>注销计算机</span>
          </button>

          <button
            style={{ ...s.ctrlItem, color: '#dc2626' }}
            onClick={() => {
              if (window.confirm('确定重启远程电脑吗？')) {
                conn.sendPowerAction('restart')
                setOpen(false)
              }
            }}
          >
            <span style={s.ctrlItemIcon}>🔄</span>
            <span>重启</span>
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

function AutoSelect<T>({ value, auto, options, formatValue, width, onChange }: {
  value: T
  auto: boolean
  options: T[]
  formatValue: (v: T) => string
  width: number
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
      <button style={{ ...s.selectBtn, width, justifyContent: 'space-between' }} onClick={() => setOpen(v => !v)}>
        <span style={{ overflow: 'hidden', textOverflow: 'ellipsis' }}>{formatValue(value)}</span>
        <span style={{ fontSize: 9, opacity: 0.45, lineHeight: 1, flexShrink: 0 }}>{open ? '▲' : '▼'}</span>
      </button>
      {open && (
        <div style={s.dropdown}>
          <button
            style={{ ...s.dropItem, ...(auto ? s.dropItemActive : {}) }}
            onClick={() => { onChange(value, true); setOpen(false) }}
          >
            <span>{`自动 (${formatValue(value)})`}</span>
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

function ResolutionSelect({ value, onChange }: { value: ResolutionTier; onChange: (tier: ResolutionTier) => void }) {
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
      <button style={{ ...s.selectBtn, width: 92, justifyContent: 'space-between' }} onClick={() => setOpen(v => !v)}>
        <span>{current.label}</span>
        <span style={{ fontSize: 9, opacity: 0.45, lineHeight: 1, flexShrink: 0 }}>{open ? '▲' : '▼'}</span>
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

function ScaleModeSelect({ value, onChange }: { value: ScaleMode; onChange: (mode: ScaleMode) => void }) {
  const [open, setOpen] = useState(false)
  const ref = useRef<HTMLDivElement>(null)
  const current = SCALE_MODE_OPTIONS.find(o => o.mode === value) ?? SCALE_MODE_OPTIONS[0]

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
      <button style={{ ...s.selectBtn, width: 92, justifyContent: 'space-between' }} onClick={() => setOpen(v => !v)}>
        <span>{current.label}</span>
        <span style={{ fontSize: 9, opacity: 0.45, lineHeight: 1, flexShrink: 0 }}>{open ? '▲' : '▼'}</span>
      </button>
      {open && (
        <div style={s.dropdown}>
          {SCALE_MODE_OPTIONS.map(o => {
            const active = o.mode === value
            return (
              <button
                key={o.mode}
                style={{ ...s.dropItem, ...(active ? s.dropItemActive : {}) }}
                onClick={() => { onChange(o.mode); setOpen(false) }}
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
  qualityToggleRow: {
    display: 'flex', alignItems: 'center', justifyContent: 'space-between',
    gap: 10, padding: '4px 2px', fontSize: 12, color: 'var(--ov-text)',
    whiteSpace: 'nowrap',
  },
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
