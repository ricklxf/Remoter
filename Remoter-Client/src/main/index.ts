import { app, BrowserWindow, ipcMain, shell, dialog } from 'electron'
import { writeFile, readdir, stat, readFile as fsReadFile } from 'fs/promises'
import { join } from 'path'
import { homedir } from 'os'
import { electronApp, optimizer, is } from '@electron-toolkit/utils'

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
    width: 1200,
    height: 800,
    minWidth: 800,
    minHeight: 600,
    show: false,
    backgroundColor: '#f0f4f8',
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
  ipcMain.on('maximize', () => {
    if (mainWindow) mainWindow.isMaximized() ? mainWindow.unmaximize() : mainWindow.maximize()
  })
  ipcMain.on('unmaximize', () => {
    if (mainWindow?.isMaximized()) mainWindow.unmaximize()
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
