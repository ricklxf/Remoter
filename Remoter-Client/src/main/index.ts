import { app, BrowserWindow, ipcMain, shell, dialog } from 'electron'
import { writeFile } from 'fs/promises'
import { join } from 'path'
import { electronApp, optimizer, is } from '@electron-toolkit/utils'

let mainWindow: BrowserWindow | null = null

function createWindow(): void {
  mainWindow = new BrowserWindow({
    width: 1200,
    height: 800,
    minWidth: 800,
    minHeight: 600,
    show: false,
    backgroundColor: '#1a1a2e',
    titleBarStyle: process.platform === 'darwin' ? 'hiddenInset' : 'default',
    autoHideMenuBar: true,
    webPreferences: {
      preload: join(__dirname, '../preload/index.js'),
      sandbox: false,
      // Allow WebCodecs API (H.264 decoding)
      contextIsolation: true
    }
  })

  mainWindow.on('ready-to-show', () => {
    mainWindow!.show()
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

  // Full-screen toggle for remote desktop
  ipcMain.on('toggle-fullscreen', () => {
    if (mainWindow) mainWindow.setFullScreen(!mainWindow.isFullScreen())
  })

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

  createWindow()

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow()
  })
})

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit()
})
