import { WebSocketServer, WebSocket } from 'ws'
import { createServer as createHttp, IncomingMessage } from 'http'
import { createServer as createHttps } from 'https'
import * as crypto from 'crypto'
import * as fs from 'fs'

const PORT = parseInt(process.env.PORT ?? '7789')

// TLS: set TLS_CERT + TLS_KEY env vars to enable WSS
// e.g.  TLS_CERT=/etc/ssl/cert.pem TLS_KEY=/etc/ssl/key.pem npm start
const tlsCert = process.env.TLS_CERT
const tlsKey  = process.env.TLS_KEY
const useTLS  = !!(tlsCert && tlsKey)

interface Session {
  id: string
  pin: string
  host: WebSocket | null
  client: WebSocket | null
  createdAt: number
}

const sessions = new Map<string, Session>()

function generateId(): string {
  return crypto.randomBytes(3).toString('hex').toUpperCase()
}

setInterval(() => {
  const now = Date.now()
  for (const [id, s] of sessions) {
    if (now - s.createdAt > 86_400_000 && (!s.host || s.host.readyState !== WebSocket.OPEN))
      sessions.delete(id)
  }
}, 3_600_000)

function send(ws: WebSocket, obj: object) {
  if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(obj))
}

function parseQuery(url: string): Record<string, string> {
  const out: Record<string, string> = {}
  new URL(url, 'http://localhost').searchParams.forEach((v, k) => { out[k] = v })
  return out
}

// Request handler (health check)
function requestHandler(req: IncomingMessage, res: { writeHead: Function; end: Function }) {
  if (req.url === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' })
    res.end(JSON.stringify({ ok: true, tls: useTLS, sessions: sessions.size }))
    return
  }
  res.writeHead(404).end()
}

// Create HTTP or HTTPS server based on env
const httpServer = useTLS
  ? createHttps(
      { cert: fs.readFileSync(tlsCert!), key: fs.readFileSync(tlsKey!) },
      requestHandler
    )
  : createHttp(requestHandler)

const wss = new WebSocketServer({ server: httpServer })

wss.on('connection', (ws: WebSocket, req: IncomingMessage) => {
  const { role, session, pin } = parseQuery(req.url ?? '/')

  if (role === 'host') {
    const sid = generateId()
    const s: Session = { id: sid, pin: pin ?? '', host: ws, client: null, createdAt: Date.now() }
    sessions.set(sid, s)
    send(ws, { type: 'registered', session_id: sid })
    console.log(`[+] Host session ${sid} (${useTLS ? 'WSS' : 'WS'})`)

    ws.on('message', (data: Buffer, isBinary: boolean) => {
      const s = sessions.get(sid)
      if (s?.client?.readyState === WebSocket.OPEN) s.client.send(data, { binary: isBinary })
    })

    ws.on('close', () => {
      const s = sessions.get(sid)
      if (s?.client?.readyState === WebSocket.OPEN) {
        send(s.client, { type: 'host_disconnected' })
        s.client.close()
      }
      sessions.delete(sid)
      console.log(`[-] Session ${sid} closed`)
    })

  } else if (role === 'client') {
    const s = sessions.get((session ?? '').toUpperCase())
    if (!s)                                             { send(ws, { type: 'error', code: 'session_not_found' }); ws.close(); return }
    if (pin !== s.pin)                                  { send(ws, { type: 'error', code: 'auth_failed' });       ws.close(); return }
    if (!s.host || s.host.readyState !== WebSocket.OPEN){ send(ws, { type: 'error', code: 'host_offline' });      ws.close(); return }

    s.client = ws
    send(ws, { type: 'connected', session_id: s.id })
    send(s.host, { type: 'client_connected' })
    console.log(`[+] Client joined ${s.id}`)

    ws.on('message', (data: Buffer, isBinary: boolean) => {
      if (s.host?.readyState === WebSocket.OPEN) s.host.send(data, { binary: isBinary })
    })
    ws.on('close', () => {
      s.client = null
      if (s.host?.readyState === WebSocket.OPEN) send(s.host, { type: 'client_disconnected' })
      console.log(`[-] Client left ${s.id}`)
    })

  } else {
    send(ws, { type: 'error', code: 'invalid_role' })
    ws.close()
  }

  ws.on('error', (err: Error) => console.error(`[!] ${err.message}`))
})

httpServer.listen(PORT, () =>
  console.log(`Remoter relay on :${PORT} (${useTLS ? 'WSS/TLS' : 'WS plain — set TLS_CERT+TLS_KEY for production'})`)
)
