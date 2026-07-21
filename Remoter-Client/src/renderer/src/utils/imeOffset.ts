import { useState, useEffect } from 'react'

export interface ImeOffset {
  x: number
  y: number
}

const KEY = 'remoter-ime-offset'
const CHANGE_EVENT = 'remoter-ime-offset-change'
// Matches the values the IME anchor was hardcoded to before this became
// user-adjustable — keeps existing installs looking the same until dragged.
const DEFAULT: ImeOffset = { x: -120, y: 0 }

type OffsetMap = Record<string, ImeOffset>

// Keyed by remote resolution ("widthxheight"): the OS candidate window's
// real size/position varies with the remote machine's resolution/DPI
// scaling, so one calibration dragged in against a 1920x1080 session looked
// wrong the moment you connected to a 2560x1440 one instead. A single
// global offset couldn't ever satisfy both — store one per resolution and
// look up whichever one matches the session currently streaming.
function loadMap(): OffsetMap {
  try {
    const raw = localStorage.getItem(KEY)
    if (!raw) return {}
    const parsed = JSON.parse(raw)
    // Migrate the old single-offset format (from before this was
    // resolution-keyed) forward as a fallback default, so a calibration
    // someone already dragged into place isn't silently lost.
    if (parsed && typeof parsed.x === 'number' && typeof parsed.y === 'number') {
      return { '*': parsed }
    }
    return parsed && typeof parsed === 'object' ? parsed : {}
  } catch {
    return {}
  }
}

function saveMap(map: OffsetMap): void {
  localStorage.setItem(KEY, JSON.stringify(map))
  window.dispatchEvent(new Event(CHANGE_EVENT))
}

export function resolutionKey(width: number, height: number): string {
  return `${width}x${height}`
}

export function getImeOffset(resKey: string): ImeOffset {
  const map = loadMap()
  return { ...DEFAULT, ...(map[resKey] ?? map['*']) }
}

export function setImeOffset(resKey: string, offset: ImeOffset): void {
  const map = loadMap()
  map[resKey] = offset
  saveMap(map)
}

export function useImeOffset(resKey: string): ImeOffset {
  const [offset, setOffset] = useState<ImeOffset>(() => getImeOffset(resKey))
  useEffect(() => {
    setOffset(getImeOffset(resKey))
    const handler = (): void => setOffset(getImeOffset(resKey))
    window.addEventListener(CHANGE_EVENT, handler)
    return () => window.removeEventListener(CHANGE_EVENT, handler)
  }, [resKey])
  return offset
}
