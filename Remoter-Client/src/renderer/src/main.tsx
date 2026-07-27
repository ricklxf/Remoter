import React from 'react'
import ReactDOM from 'react-dom/client'
import App from './App'
import './global.css'

// 浏览器环境 polyfill：Electron preload 已注入 window.remoterAPI，
// 普通浏览器没有，这里补上 Web 原生实现。
if (!window.remoterAPI) {
  // navigator.clipboard.writeText/write throw "Document is not focused"
  // whenever this tab/window isn't the one with real OS focus at that
  // exact instant — and a reverse clipboard-sync push from the target can
  // arrive at any time, not tied to any user action, so it very often
  // isn't. This is specifically a browser-API limitation (Electron's own
  // preload bridge uses Node's native clipboard module instead, with no
  // such restriction — see preload/index.ts), so the retry-on-focus logic
  // belongs here in the web-only polyfill, not in shared app code that
  // would otherwise needlessly gate the Electron path on the same check.
  let pendingWriteText: string | null = null
  let pendingWriteImage: string | null = null
  const flushPendingWrites = (): void => {
    if (!document.hasFocus()) return
    if (pendingWriteText !== null) {
      const t = pendingWriteText
      pendingWriteText = null
      navigator.clipboard?.writeText(t).catch(() => { pendingWriteText = t })
    }
    if (pendingWriteImage !== null) {
      const data = pendingWriteImage
      pendingWriteImage = null
      writeImageNow(data).catch(() => { pendingWriteImage = data })
    }
  }
  window.addEventListener('focus', flushPendingWrites)

  async function writeImageNow(data: string): Promise<void> {
    const bytes = Uint8Array.from(atob(data), c => c.charCodeAt(0))
    const blob  = new Blob([bytes], { type: 'image/png' })
    await navigator.clipboard.write([new ClipboardItem({ 'image/png': blob })])
  }

  window.remoterAPI = {
    platform: 'web',
    toggleFullscreen: () => {
      // Fullscreen the content container, not the whole <html> — fullscreening
      // documentElement has been observed to break hit-testing for pointer
      // events on its descendants in some browsers, while keyboard (which
      // bubbles via document, not positional hit-testing) kept working.
      const target = document.getElementById('remoter-content') ?? document.documentElement
      if (!document.fullscreenElement) {
        target.requestFullscreen().catch(() => {})
      } else {
        document.exitFullscreen()
      }
    },
    maximize:   () => {},
    unmaximize: () => {},
    saveFileDialog: async (name: string) => name,
    saveFile: async (_path: string, data: Uint8Array) => {
      const blob = new Blob([data as BlobPart])
      const url  = URL.createObjectURL(blob)
      const a    = Object.assign(document.createElement('a'), { href: url, download: _path })
      a.click()
      URL.revokeObjectURL(url)
    },
    homeDir:  async () => '/',
    listDir:  async () => ({ path: '/', entries: [] }),
    readFile: async () => new Uint8Array(),
    writeClipboard: (text: string) => {
      if (!document.hasFocus()) { pendingWriteText = text; return }
      navigator.clipboard?.writeText(text).catch(() => { pendingWriteText = text })
    },
    writeClipboardImage: (data: string) => {
      if (!document.hasFocus()) { pendingWriteImage = data; return }
      writeImageNow(data).catch(() => { pendingWriteImage = data })
    },
  }
}

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>
)
