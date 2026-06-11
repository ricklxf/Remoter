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
  }
}

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>
)
