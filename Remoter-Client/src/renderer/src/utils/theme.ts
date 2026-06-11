export type Theme = 'system' | 'light' | 'dark'

const KEY = 'remoter-theme'

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
}

export function initTheme(): void {
  applyTheme(getTheme())
  window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => {
    if (getTheme() === 'system') applyTheme('system')
  })
}
