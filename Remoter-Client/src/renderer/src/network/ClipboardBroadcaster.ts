import type { Connection } from './Connection'

// Reads the *local* clipboard once and pushes it to every currently
// connected session, regardless of which tab is in front — this is the
// controller's clipboard broadcast to however many machines it's
// controlling, not a per-tab pull. A single module-level poll loop (not one
// per Connection) is what makes "broadcast to all" possible: each
// Connection used to poll independently and only push to its own target
// while its tab was active, which meant a background tab's target never
// got the update at all until you switched to it.
function clipRead(): Promise<string> {
  if (window.remoterAPI) return window.remoterAPI.readClipboard()
  return navigator.clipboard.readText()
}

async function clipReadImage(): Promise<string | null> {
  if (window.remoterAPI?.readClipboardImage) {
    return window.remoterAPI.readClipboardImage()
  }
  try {
    const items = await navigator.clipboard.read()
    for (const item of items) {
      if (item.types.includes('image/png')) {
        const blob = await item.getType('image/png')
        return new Promise<string>((resolve) => {
          const reader = new FileReader()
          reader.onload = () => resolve((reader.result as string).split(',')[1])
          reader.readAsDataURL(blob)
        })
      }
    }
  } catch { /* ignore */ }
  return null
}

class ClipboardBroadcaster {
  private connections = new Set<Connection>()
  private timer: ReturnType<typeof setInterval> | null = null
  private lastText = ''
  private lastImgLen = -1

  register(conn: Connection): void {
    this.connections.add(conn)
    this.ensureRunning()
  }

  unregister(conn: Connection): void {
    this.connections.delete(conn)
    if (this.connections.size === 0) this.stop()
  }

  private ensureRunning(): void {
    if (this.timer) return
    clipRead().then(t => { this.lastText = t }).catch(() => {})
    clipReadImage().then(img => { if (img) this.lastImgLen = img.length }).catch(() => {})
    this.timer = setInterval(() => { this.checkOnce() }, 1000)
  }

  private stop(): void {
    if (this.timer) { clearInterval(this.timer); this.timer = null }
  }

  private async checkOnce(): Promise<void> {
    try {
      const text = await clipRead()
      if (text && text !== this.lastText) {
        this.lastText = text
        for (const conn of this.connections) conn.receiveClipboardBroadcast(text, undefined)
      }
    } catch (e) {
      console.warn('[Clipboard] text read failed:', e)
    }
    try {
      const img = await clipReadImage()
      if (img && img.length !== this.lastImgLen) {
        this.lastImgLen = img.length
        for (const conn of this.connections) conn.receiveClipboardBroadcast(undefined, img)
      }
    } catch (e) {
      console.warn('[Clipboard] image read failed:', e)
    }
  }

  /** Forces an out-of-cycle check instead of waiting for the next 1s poll
   * tick — called right as a paste shortcut (Cmd+V / Ctrl+V) is detected,
   * so a copy-then-immediately-paste within that same second doesn't send
   * a still-stale clipboard. Awaiting this and only sending the paste
   * keystroke afterward guarantees wire order — see InputHandler.onKeyDown. */
  async forceSyncNow(): Promise<void> {
    await this.checkOnce()
  }
}

export const clipboardBroadcaster = new ClipboardBroadcaster()
