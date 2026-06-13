import { contextBridge, ipcRenderer } from 'electron'
import { electronAPI } from '@electron-toolkit/preload'

const api = {
  platform:         process.platform,
  toggleFullscreen: () => ipcRenderer.send('toggle-fullscreen'),
  maximize:         () => ipcRenderer.send('maximize'),
  unmaximize:       () => ipcRenderer.send('unmaximize'),
  expandWindow:     () => ipcRenderer.send('expand-window'),
  shrinkWindow:     () => ipcRenderer.send('shrink-window'),
  saveFileDialog:   (name: string): Promise<string | null> => ipcRenderer.invoke('save-file-dialog', name),
  saveFile:         (path: string, data: Uint8Array): Promise<void> => ipcRenderer.invoke('save-file', path, data),
  homeDir:          (): Promise<string> => ipcRenderer.invoke('home-dir'),
  listDir:          (path: string): Promise<{ path: string; entries: Array<{ name: string; size: number; isDir: boolean; modified: number }> }> =>
    ipcRenderer.invoke('list-dir', path),
  readFile:         (path: string): Promise<Uint8Array> => ipcRenderer.invoke('read-file', path),
  setTitleBarOverlay: (color: string, symbolColor: string): void =>
    ipcRenderer.send('set-title-bar-overlay', color, symbolColor),
  readClipboard:       (): Promise<string>       => ipcRenderer.invoke('read-clipboard'),
  writeClipboard:      (text: string): void       => ipcRenderer.send('write-clipboard', text),
  readClipboardImage:  (): Promise<string | null> => ipcRenderer.invoke('read-clipboard-image'),
  writeClipboardImage: (data: string): void       => ipcRenderer.send('write-clipboard-image', data),
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
