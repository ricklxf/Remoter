export type ConnectMode = 'direct' | 'relay'
export type AuthMethod = 'pin' | 'credentials' | 'token'

export interface ConnectParams {
  mode: ConnectMode
  directUrl?: string
  relayUrl?: string
  sessionId?: string
  pin: string
  // Auth extension
  authMethod?: AuthMethod
  username?: string
  password?: string
  token?: string
}

export interface StreamInfo {
  width: number
  height: number
}

export type ConnectionState =
  | 'idle'
  | 'connecting'
  | 'authenticating'
  | 'streaming'
  | 'disconnected'
  | 'error'

export interface DirEntry {
  name: string
  size: number
  isDir: boolean
  modified: number  // ms timestamp
}

export interface FileTransfer {
  id: string
  name: string
  size: number
  transferred: number
  direction: 'upload' | 'download'
  speedBps: number
  done: boolean
  error?: string
}

declare global {
  interface Window {
    remoterAPI?: {
      platform: string
      toggleFullscreen: () => void
      maximize: () => void
      unmaximize: () => void
      saveFileDialog: (name: string) => Promise<string | null>
      saveFile: (path: string, data: Uint8Array) => Promise<void>
      homeDir: () => Promise<string>
      listDir: (path: string) => Promise<{ path: string; entries: DirEntry[] }>
      readFile: (path: string) => Promise<Uint8Array>
      setTitleBarOverlay?: (color: string, symbolColor: string) => void
      readClipboard: () => Promise<string>
      writeClipboard: (text: string) => void
      readClipboardImage?: () => Promise<string | null>
      writeClipboardImage?: (data: string) => void
    }
  }
}
