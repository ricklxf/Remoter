export type ConnectMode = 'direct' | 'relay'

export interface ConnectParams {
  mode: ConnectMode
  // direct: ws://host:port
  directUrl?: string
  // relay: session ID from Mac agent
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

export interface TransferFile {
  id: string
  name: string
  size: number
  received: number
  done: boolean
}
