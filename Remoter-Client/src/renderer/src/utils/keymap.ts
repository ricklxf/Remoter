export type ModKey = 'ctrl' | 'meta' | 'alt'

export interface KeyMap {
  ctrl: ModKey
  meta: ModKey
  alt: ModKey
}

const STORAGE_KEY = 'remoter-keymap'
const DEFAULT: KeyMap = { ctrl: 'ctrl', meta: 'meta', alt: 'alt' }

export function loadKeymap(): KeyMap {
  try {
    const raw = localStorage.getItem(STORAGE_KEY)
    if (!raw) return { ...DEFAULT }
    return { ...DEFAULT, ...JSON.parse(raw) }
  } catch {
    return { ...DEFAULT }
  }
}

function saveKeymap(km: KeyMap): void {
  localStorage.setItem(STORAGE_KEY, JSON.stringify(km))
}

// Module-level singleton — InputHandler reads this, KeymapPanel writes it
let _current: KeyMap = loadKeymap()

export function getKeymap(): KeyMap {
  return _current
}

export function setKeymapGlobal(km: KeyMap): void {
  _current = km
  saveKeymap(km)
}

// ─── Mapping helpers ──────────────────────────────────────────────────

const MOD_LEFT: Record<ModKey, string>  = { ctrl: 'ControlLeft', meta: 'MetaLeft',  alt: 'AltLeft'  }
const MOD_RIGHT: Record<ModKey, string> = { ctrl: 'ControlRight', meta: 'MetaRight', alt: 'AltRight' }

function codeToModKey(code: string): ModKey | null {
  if (code === 'ControlLeft' || code === 'ControlRight') return 'ctrl'
  if (code === 'MetaLeft'    || code === 'MetaRight')    return 'meta'
  if (code === 'AltLeft'     || code === 'AltRight')     return 'alt'
  return null
}

// Remap a key code if it's a modifier key
export function mapKeyCode(code: string, km: KeyMap): string {
  const src = codeToModKey(code)
  if (!src) return code
  const dst = km[src]
  return code.endsWith('Right') ? MOD_RIGHT[dst] : MOD_LEFT[dst]
}

// Remap modifier list (deduplicates)
export function mapModifiers(mods: string[], km: KeyMap): string[] {
  const mapped = mods.map(m => {
    if (m === 'ctrl')  return km.ctrl
    if (m === 'meta')  return km.meta
    if (m === 'alt')   return km.alt
    return m
  })
  return [...new Set(mapped)]
}
