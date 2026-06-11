import { useState, useEffect } from 'react'

export type Theme = 'system' | 'light' | 'dark'

const KEY = 'remoter-theme'
const CHANGE_EVENT = 'remoter-theme-change'

function resolved(t: Theme): 'light' | 'dark' {
  return t === 'system'
    ? (window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light')
    : t
}

export function getTheme(): Theme {
  return (localStorage.getItem(KEY) as Theme) ?? 'system'
}

export function applyTheme(t: Theme): void {
  document.documentElement.setAttribute('data-theme', resolved(t))
  localStorage.setItem(KEY, t)
  window.dispatchEvent(new Event(CHANGE_EVENT))
}

export function initTheme(): void {
  applyTheme(getTheme())
  window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => {
    if (getTheme() === 'system') applyTheme('system')
  })
}

export function useTheme(): Theme {
  const [theme, setTheme] = useState<Theme>(getTheme)
  useEffect(() => {
    const handler = () => setTheme(getTheme())
    window.addEventListener(CHANGE_EVENT, handler)
    return () => window.removeEventListener(CHANGE_EVENT, handler)
  }, [])
  return theme
}
