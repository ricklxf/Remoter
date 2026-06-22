import { app, BrowserWindow, ipcMain, shell, dialog, clipboard, nativeImage } from 'electron'
import { writeFile, readdir, stat, readFile as fsReadFile } from 'fs/promises'
import { join } from 'path'
import { homedir } from 'os'
import { electronApp, optimizer, is } from '@electron-toolkit/utils'

// Reduce Chromium startup overhead. Must be called before app.whenReady().
app.commandLine.appendSwitch('disable-background-networking')
app.commandLine.appendSwitch('disable-features', 'TranslateUI,AutofillServerCommunication')
if (process.platform === 'darwin') {
  app.commandLine.appendSwitch('enable-features', 'Metal')
}

// Trust the agent's own self-signed cert (CN=Remoter) for internal HTTPS/WSS.
// The agent serves over TLS so browsers get a secure context for WebCodecs(H.264);
// Chromium would otherwise reject the self-signed cert. We only whitelist our own
// cert by common name — all other cert errors still fail.
app.on('certificate-error', (event, _webContents, _url, _error, certificate, callback) => {
  if (certificate.subjectName === 'Remoter' || certificate.issuerName === 'Remoter') {
    event.preventDefault()
    callback(true)
  } else {
    callback(false)
  }
})

// ─── Single-instance lock (fixes Windows double-click no-show) ─────
const gotTheLock = app.requestSingleInstanceLock()
if (!gotTheLock) {
  app.quit()
}

let mainWindow: BrowserWindow | null = null

function focusOrCreateWindow(): void {
  if (mainWindow) {
    if (mainWindow.isMinimized()) mainWindow.restore()
    mainWindow.show()
    mainWindow.focus()
  } else {
    createWindow()
  }
}

// Bring existing window to front when a second instance is launched
app.on('second-instance', focusOrCreateWindow)

function createWindow(): void {
  const isWin = process.platform === 'win32'
  const isMac = process.platform === 'darwin'

  mainWindow = new BrowserWindow({
    width: 420,
    height: 710,
    minWidth: 400,
    minHeight: 580,
    fullscreen: false,     // 防止 macOS 恢复上次的全屏状态
    show: false,
    // Windows: card bg before React renders; Mac: white matches card --bg2
    backgroundColor: isWin ? '#0fb8ab' : '#ffffff',
    titleBarStyle: isMac ? 'hiddenInset' : 'hidden',
    ...(isWin ? {
      titleBarOverlay: {
        color: '#0fb8ab',
        symbolColor: '#ffffff',
        height: 36,
      }
    } : {}),
    autoHideMenuBar: true,
    webPreferences: {
      preload: join(__dirname, '../preload/index.js'),
      sandbox: false,
      contextIsolation: true
    }
  })

  // Grant clipboard-read permission so navigator.clipboard.readText() works in the renderer
  mainWindow.webContents.session.setPermissionRequestHandler((_wc, permission, callback) => {
    callback(permission === 'clipboard-read' || permission === 'clipboard-sanitized-write')
  })
  mainWindow.webContents.session.setPermissionCheckHandler((_wc, permission) => {
    return permission === 'clipboard-read' || permission === 'clipboard-sanitized-write'
  })

  mainWindow.on('ready-to-show', () => {
    mainWindow!.show()
    mainWindow!.focus()
  })

  // Fallback: show window after a short delay in case ready-to-show is delayed
  setTimeout(() => {
    if (mainWindow && !mainWindow.isVisible()) {
      mainWindow.show()
      mainWindow.focus()
    }
  }, 800)

  mainWindow.on('closed', () => { mainWindow = null })

  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    shell.openExternal(url)
    return { action: 'deny' }
  })

  // F12 (and Cmd/Ctrl+Shift+I) toggle DevTools — Electron doesn't bind this
  // itself like a browser does; without it there's no way to see renderer
  // console output/errors at all.
  mainWindow.webContents.on('before-input-event', (_event, input) => {
    const isToggle = input.key === 'F12' ||
      (input.key.toLowerCase() === 'i' && input.shift && (input.control || input.meta))
    if (isToggle) mainWindow?.webContents.toggleDevTools()
  })

  if (is.dev && process.env['ELECTRON_RENDERER_URL']) {
    mainWindow.loadURL(process.env['ELECTRON_RENDERER_URL'])
  } else {
    mainWindow.loadFile(join(__dirname, '../renderer/index.html'))
  }
}

app.whenReady().then(() => {
  electronApp.setAppUserModelId('com.remoter.client')

  app.on('browser-window-created', (_, win) => {
    optimizer.watchWindowShortcuts(win)
  })

  // Window controls
  ipcMain.on('toggle-fullscreen', () => {
    if (mainWindow) mainWindow.setFullScreen(!mainWindow.isFullScreen())
  })

  ipcMain.handle('read-clipboard',       ()             => clipboard.readText())
  ipcMain.on('write-clipboard',          (_e, text: string) => clipboard.writeText(text))
  ipcMain.handle('read-clipboard-image', () => {
    const img = clipboard.readImage()
    if (img.isEmpty()) return null
    return img.toPNG().toString('base64')
  })
  ipcMain.on('write-clipboard-image', (_e, data: string) => {
    clipboard.writeImage(nativeImage.createFromBuffer(Buffer.from(data, 'base64')))
  })

  ipcMain.on('set-title-bar-overlay', (_e, color: string, symbolColor: string) => {
    if (mainWindow && process.platform === 'win32') {
      mainWindow.setTitleBarOverlay({ color, symbolColor, height: 36 })
    }
  })
  ipcMain.on('maximize', () => {
    if (mainWindow) mainWindow.isMaximized() ? mainWindow.unmaximize() : mainWindow.maximize()
  })
  ipcMain.on('unmaximize', () => {
    if (mainWindow?.isMaximized()) mainWindow.unmaximize()
  })
  ipcMain.on('expand-window', () => {
    if (!mainWindow) return
    mainWindow.setMinimumSize(800, 600)
    if (!mainWindow.isMaximized()) mainWindow.maximize()
  })
  ipcMain.on('shrink-window', () => {
    if (!mainWindow) return
    mainWindow.setMinimumSize(400, 480)
    const resize = () => {
      if (!mainWindow) return
      const { screen } = require('electron')
      const { workArea } = screen.getPrimaryDisplay()
      const w = 420, h = 600
      mainWindow.setBounds({
        x: Math.round(workArea.x + (workArea.width  - w) / 2),
        y: Math.round(workArea.y + (workArea.height - h) / 2),
        width: w, height: h,
      })
    }
    if (mainWindow.isMaximized()) {
      mainWindow.once('unmaximize', resize)
      mainWindow.unmaximize()
    } else {
      resize()
    }
  })

  // File save dialog for received files
  ipcMain.handle('save-file-dialog', async (_, name: string) => {
    const { filePath } = await dialog.showSaveDialog(mainWindow!, {
      defaultPath: name,
      title: 'Save received file'
    })
    return filePath ?? null
  })

  ipcMain.handle('save-file', async (_, filePath: string, data: Uint8Array) => {
    await writeFile(filePath, Buffer.from(data))
  })

  ipcMain.handle('home-dir', () => homedir())

  ipcMain.handle('list-dir', async (_, dirPath: string) => {
    const expanded = dirPath.startsWith('~') ? join(homedir(), dirPath.slice(1)) : dirPath
    const names = await readdir(expanded)
    const entries = await Promise.all(names.map(async (name) => {
      try {
        const s = await stat(join(expanded, name))
        return { name, size: s.isDirectory() ? 0 : s.size, isDir: s.isDirectory(), modified: s.mtimeMs }
      } catch {
        return { name, size: 0, isDir: false, modified: 0 }
      }
    }))
    entries.sort((a, b) => {
      if (a.isDir !== b.isDir) return a.isDir ? -1 : 1
      return a.name.localeCompare(b.name)
    })
    return { path: expanded, entries }
  })

  ipcMain.handle('read-file', async (_, filePath: string) => {
    return fsReadFile(filePath)
  })

  createWindow()

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow()
    else focusOrCreateWindow()
  })
})

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit()
})
