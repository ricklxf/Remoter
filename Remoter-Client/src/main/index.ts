import { app, BrowserWindow, ipcMain, shell, dialog } from 'electron'
import { writeFile, readdir, stat, readFile as fsReadFile } from 'fs/promises'
import { join } from 'path'
import { homedir } from 'os'
import { electronApp, optimizer, is } from '@electron-toolkit/utils'

let mainWindow: BrowserWindow | null = null

function createWindow(): void {
  const isWin = process.platform === 'win32'
  const isMac = process.platform === 'darwin'

  mainWindow = new BrowserWindow({
    width: 1200,
    height: 800,
    minWidth: 800,
    minHeight: 600,
    show: false,
    backgroundColor: '#1a1a2e',
    titleBarStyle: isMac ? 'hiddenInset' : 'hidden',
    ...(isWin ? {
      titleBarOverlay: {
        color: '#1a1a2e',
        symbolColor: '#eaeaea',
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
  })

  mainWindow.on('enter-full-screen', () => {
    mainWindow?.webContents.send('fullscreen-changed', true)
  })
  mainWindow.on('leave-full-screen', () => {
    mainWindow?.webContents.send('fullscreen-changed', false)
  })

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

  // Full-screen controls
  ipcMain.on('toggle-fullscreen', () => {
    if (mainWindow) mainWindow.setFullScreen(!mainWindow.isFullScreen())
  })
  ipcMain.on('enter-fullscreen', () => {
    if (mainWindow && !mainWindow.isFullScreen()) mainWindow.setFullScreen(true)
  })
  ipcMain.on('exit-fullscreen', () => {
    if (mainWindow && mainWindow.isFullScreen()) mainWindow.setFullScreen(false)
  })
  ipcMain.handle('is-fullscreen', () => mainWindow?.isFullScreen() ?? false)

  // File save dialog for received files
  ipcMain.handle('save-file-dialog', async (_, name: string) => {
    const { filePath } = await dialog.showSaveDialog(mainWindow!, {
      defaultPath: name,
      title: 'Save received file'
    })
    return filePath ?? null
  })

  // Write file to disk (used after save-file-dialog returns a path)
  ipcMain.handle('save-file', async (_, filePath: string, data: Uint8Array) => {
    await writeFile(filePath, Buffer.from(data))
  })

  // Home directory
  ipcMain.handle('home-dir', () => homedir())

  // List directory contents
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

  // Read local file for upload
  ipcMain.handle('read-file', async (_, filePath: string) => {
    return fsReadFile(filePath)
  })

  createWindow()

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow()
  })
})

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit()
})
