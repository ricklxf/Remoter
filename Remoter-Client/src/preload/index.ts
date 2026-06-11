import { contextBridge, ipcRenderer } from 'electron'
import { electronAPI } from '@electron-toolkit/preload'

const api = {
  platform:          process.platform,
  toggleFullscreen:  () => ipcRenderer.send('toggle-fullscreen'),
  enterFullscreen:   () => ipcRenderer.send('enter-fullscreen'),
  exitFullscreen:    () => ipcRenderer.send('exit-fullscreen'),
  isFullscreen:      (): Promise<boolean> => ipcRenderer.invoke('is-fullscreen'),
  onFullscreenChange:(cb: (isFS: boolean) => void) => {
    const handler = (_: unknown, isFS: boolean) => cb(isFS)
    ipcRenderer.on('fullscreen-changed', handler)
    return () => ipcRenderer.off('fullscreen-changed', handler)
  },
  saveFileDialog:   (name: string): Promise<string | null> => ipcRenderer.invoke('save-file-dialog', name),
  saveFile:         (path: string, data: Uint8Array): Promise<void> => ipcRenderer.invoke('save-file', path, data),
  homeDir:          (): Promise<string> => ipcRenderer.invoke('home-dir'),
  listDir:          (path: string): Promise<{ path: string; entries: Array<{ name: string; size: number; isDir: boolean; modified: number }> }> =>
    ipcRenderer.invoke('list-dir', path),
  readFile:         (path: string): Promise<Uint8Array> => ipcRenderer.invoke('read-file', path),
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
