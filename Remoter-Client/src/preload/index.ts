import { contextBridge, ipcRenderer } from 'electron'
import { electronAPI } from '@electron-toolkit/preload'

const api = {
  toggleFullscreen: () => ipcRenderer.send('toggle-fullscreen'),
  saveFileDialog: (name: string): Promise<string | null> =>
    ipcRenderer.invoke('save-file-dialog', name),
  saveFile: (path: string, data: Uint8Array): Promise<void> =>
    ipcRenderer.invoke('save-file', path, data)
}

if (process.contextIsolated) {
  try {
    contextBridge.exposeInMainWorld('electron', electronAPI)
    contextBridge.exposeInMainWorld('remoterAPI', api)
  } catch (e) {
    console.error(e)
  }
} else {
  // @ts-ignore
  window.electron = electronAPI
  // @ts-ignore
  window.remoterAPI = api
}
