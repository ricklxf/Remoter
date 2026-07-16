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

export function getImeOffset(): ImeOffset {
  try {
    const raw = localStorage.getItem(KEY)
    if (!raw) return { ...DEFAULT }
    return { ...DEFAULT, ...JSON.parse(raw) }
  } catch {
    return { ...DEFAULT }
  }
}

export function setImeOffset(offset: ImeOffset): void {
  localStorage.setItem(KEY, JSON.stringify(offset))
  window.dispatchEvent(new Event(CHANGE_EVENT))
}

export function useImeOffset(): ImeOffset {
  const [offset, setOffset] = useState<ImeOffset>(getImeOffset)
  useEffect(() => {
    const handler = () => setOffset(getImeOffset())
    window.addEventListener(CHANGE_EVENT, handler)
    return () => window.removeEventListener(CHANGE_EVENT, handler)
  }, [])
  return offset
}
