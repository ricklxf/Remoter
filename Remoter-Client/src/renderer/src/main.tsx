import React from 'react'
import ReactDOM from 'react-dom/client'
import App from './App'
import './global.css'

// 浏览器环境 polyfill：Electron preload 已注入 window.remoterAPI，
// 普通浏览器没有，这里补上 Web 原生实现。
if (!window.remoterAPI) {
  window.remoterAPI = {
    toggleFullscreen: () => {
      if (!document.fullscreenElement) {
        document.documentElement.requestFullscreen().catch(() => {})
      } else {
        document.exitFullscreen()
      }
    },
    saveFileDialog: async (name: string) => name,
  }
}

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>
)
