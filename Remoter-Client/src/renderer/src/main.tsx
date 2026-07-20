import React from 'react'
import ReactDOM from 'react-dom/client'
import App from './App'
import './global.css'

// 浏览器环境 polyfill：Electron preload 已注入 window.remoterAPI，
// 普通浏览器没有，这里补上 Web 原生实现。
if (!window.remoterAPI) {
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
    writeClipboard: (text: string) => { navigator.clipboard?.writeText(text).catch(() => {}) },
    writeClipboardImage: (data: string) => {
      try {
        const bytes = Uint8Array.from(atob(data), c => c.charCodeAt(0))
        const blob  = new Blob([bytes], { type: 'image/png' })
        navigator.clipboard.write([new ClipboardItem({ 'image/png': blob })]).catch(() => {})
      } catch { /* ignore */ }
    },
  }
}

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>
)
