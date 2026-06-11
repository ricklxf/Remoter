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
      if (!document.fullscreenElement) {
        document.documentElement.requestFullscreen().catch(() => {})
      } else {
        document.exitFullscreen()
      }
    },
    maximize:   () => {},
    unmaximize: () => {},
    saveFileDialog: async (name: string) => name,
    saveFile: async (_path: string, data: Uint8Array) => {
      const blob = new Blob([data])
      const url  = URL.createObjectURL(blob)
      const a    = Object.assign(document.createElement('a'), { href: url, download: _path })
      a.click()
      URL.revokeObjectURL(url)
    },
    homeDir:  async () => '/',
    listDir:  async () => ({ path: '/', entries: [] }),
    readFile: async () => new Uint8Array(),
    readClipboard:  () => navigator.clipboard?.readText()  ?? Promise.resolve(''),
    writeClipboard: (text: string) => { navigator.clipboard?.writeText(text).catch(() => {}) },
    readClipboardImage: async () => {
      try {
        const items = await navigator.clipboard.read()
        for (const item of items) {
          if (item.types.includes('image/png')) {
            const blob = await item.getType('image/png')
            return new Promise<string>((resolve) => {
              const reader = new FileReader()
              reader.onload = () => resolve((reader.result as string).split(',')[1])
              reader.readAsDataURL(blob)
            })
          }
        }
      } catch { /* ignore */ }
      return null
    },
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
