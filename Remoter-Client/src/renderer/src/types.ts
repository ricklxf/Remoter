export type ConnectMode = 'direct' | 'relay'

export interface ConnectParams {
  mode: ConnectMode
  directUrl?: string
  relayUrl?: string
  sessionId?: string
  pin: string
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
      toggleFullscreen: () => void
      saveFileDialog: (name: string) => Promise<string | null>
      saveFile: (path: string, data: Uint8Array) => Promise<void>
    }
  }
}
