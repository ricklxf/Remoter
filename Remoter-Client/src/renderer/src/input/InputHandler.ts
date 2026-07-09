import { Connection } from '../network/Connection'
import { getKeymap, mapKeyCode, mapModifiers } from '../utils/keymap'

// Translates DOM mouse/keyboard events to remote input commands.
// All coordinates are normalized [0,1] relative to the remote screen.

export class InputHandler {
  private conn: Connection
  private el: HTMLElement | null = null
  private remoteW = 1920
  private remoteH = 1080
  private enabled = false

  // Pointer lock state
  private locked = false
  private curNormX = 0.5
  private curNormY = 0.5

  // Keyboard capture only when mouse is hovering over the remote canvas (or pointer-locked)
  private hovering = false

  // Persistent capture: set when user clicks canvas, cleared when clicking outside
  private captured = false

  // Keys that have been sent as keydown — keyup must be sent regardless of hover state
  private pressedKeys = new Set<string>()

  // Mouse-move send throttle: native mousemove can fire 100-240Hz, each one
  // synchronously injects a CGEvent on the Mac side (an IPC round-trip to
  // WindowServer — the same process that drives the screen compositor
  // ScreenCaptureKit reads from). Flooding it makes capture/encode fps dip
  // while the mouse is actively moving. 120Hz is already more than the eye
  // can tell apart from native movement, so cap sends there with a
  // trailing-edge throttle (never drop the final position).
  private readonly moveThrottleMs = 8
  private lastMoveSentAt = 0
  private pendingMove: { nx: number; ny: number; dragging: string | undefined } | null = null
  private pendingMoveTimer: ReturnType<typeof setTimeout> | null = null

  // Same reasoning and pattern as mouse-move throttling above, for the wheel
  // event — a scroll fling can fire well past 60Hz, and unlike mouse-move
  // there was previously *no* source-level throttle for it at all (only a
  // "don't double-queue a send that's still in flight" guard in Connection,
  // which barely limits anything since a scroll message resolves in under a
  // millisecond). Confirmed via server logs this was enough CGEvent traffic
  // to starve ScreenCaptureKit's own frame delivery through WindowServer.
  // Deltas accumulate across the throttle window instead of being dropped.
  private readonly scrollThrottleMs = 16
  private lastScrollSentAt = 0
  private pendingScroll: { dx: number; dy: number } | null = null
  private pendingScrollTimer: ReturnType<typeof setTimeout> | null = null

  private boundHandlers: Array<[EventTarget, string, EventListenerOrEventListenerObject]> = []

  constructor(conn: Connection) {
    this.conn = conn
  }

  attach(el: HTMLElement, remoteW: number, remoteH: number): void {
    this.el = el
    this.remoteW = remoteW
    this.remoteH = remoteH
    this.enabled = true
    this.addListeners()
  }

  detach(): void {
    this.enabled = false
    this.hovering = false
    this.captured = false
    this.releaseAllKeys()
    this.removeListeners()
    this.el = null
    if (this.locked) document.exitPointerLock?.()
    if (this.pendingMoveTimer) { clearTimeout(this.pendingMoveTimer); this.pendingMoveTimer = null }
    this.pendingMove = null
    if (this.pendingScrollTimer) { clearTimeout(this.pendingScrollTimer); this.pendingScrollTimer = null }
    this.pendingScroll = null
  }

  // Like detach() but keeps listeners attached — for a tab that's hidden
  // (not closed) while other tabs keep streaming in the background. Without
  // this, a tab left in "captured" state when you switch away keeps eating
  // keystrokes meant for whichever tab you switched to, since its document-
  // level keydown listener is still alive (the whole point of staying
  // mounted — its decoder keeps decoding too).
  deactivate(): void {
    this.hovering = false
    this.captured = false
    this.releaseAllKeys()
    if (this.locked) document.exitPointerLock?.()
  }

  setRemoteSize(w: number, h: number): void {
    this.remoteW = w
    this.remoteH = h
  }

  // MARK: - Event registration

  private addListeners(): void {
    if (!this.el) return
    const add = (target: EventTarget, name: string, fn: EventListenerOrEventListenerObject) => {
      target.addEventListener(name, fn)
      this.boundHandlers.push([target, name, fn])
    }

    add(this.el, 'mouseenter',  this.onMouseEnter)
    add(this.el, 'mouseleave',  this.onMouseLeave)
    add(this.el, 'mousemove',   this.onMouseMove)
    add(this.el, 'mousedown',   this.onMouseDown)
    add(this.el, 'mouseup',     this.onMouseUp)
    add(this.el, 'dblclick',    this.onDblClick)
    add(this.el, 'wheel',       this.onWheel)
    add(this.el, 'contextmenu', this.onContextMenu)
    add(document, 'keydown',    this.onKeyDown)
    add(document, 'keyup',      this.onKeyUp)
    add(document, 'pointerlockchange', this.onPointerLockChange)
    add(document, 'mousedown',  this.onDocumentMouseDown)
    add(window,   'blur',       this.onWindowBlur)
  }

  private removeListeners(): void {
    this.boundHandlers.forEach(([target, name, fn]) => target.removeEventListener(name, fn))
    this.boundHandlers = []
  }

  // MARK: - Mouse

  private onMouseMove = (e: Event): void => {
    if (!this.enabled) return
    const me = e as MouseEvent
    me.preventDefault()
    // me.buttons is a bitmask of buttons currently held during this move —
    // without it the remote side can't tell "moving" from "dragging", and
    // anything that listens for a drag specifically (text selection, sliders,
    // drag-and-drop) never sees it, even though plain clicks still work.
    const dragging = buttonsToDragName(me.buttons)

    if (this.locked) {
      // Pointer lock: accumulate raw deltas
      this.curNormX = clamp(this.curNormX + me.movementX / this.remoteW, 0, 1)
      this.curNormY = clamp(this.curNormY + me.movementY / this.remoteH, 0, 1)
      this.sendMouseMoveThrottled(this.curNormX, this.curNormY, dragging)
    } else if (this.el) {
      const { nx, ny } = this.getCoords(me)
      this.sendMouseMoveThrottled(nx, ny, dragging)
    }
  }

  private sendMouseMoveThrottled(nx: number, ny: number, dragging: string | undefined): void {
    const now = performance.now()
    const elapsed = now - this.lastMoveSentAt
    if (elapsed >= this.moveThrottleMs) {
      if (this.pendingMoveTimer) { clearTimeout(this.pendingMoveTimer); this.pendingMoveTimer = null }
      this.pendingMove = null
      this.lastMoveSentAt = now
      this.conn.sendMouseMove(nx, ny, dragging)
      return
    }
    this.pendingMove = { nx, ny, dragging }
    if (this.pendingMoveTimer) return
    this.pendingMoveTimer = setTimeout(() => {
      this.pendingMoveTimer = null
      if (!this.pendingMove) return
      const { nx, ny, dragging } = this.pendingMove
      this.pendingMove = null
      this.lastMoveSentAt = performance.now()
      this.conn.sendMouseMove(nx, ny, dragging)
    }, this.moveThrottleMs - elapsed)
  }

  private sendScrollThrottled(dx: number, dy: number): void {
    if (this.pendingScroll) {
      this.pendingScroll.dx += dx
      this.pendingScroll.dy += dy
    } else {
      this.pendingScroll = { dx, dy }
    }
    const now = performance.now()
    const elapsed = now - this.lastScrollSentAt
    if (elapsed >= this.scrollThrottleMs) {
      if (this.pendingScrollTimer) { clearTimeout(this.pendingScrollTimer); this.pendingScrollTimer = null }
      const { dx: adx, dy: ady } = this.pendingScroll
      this.pendingScroll = null
      this.lastScrollSentAt = now
      this.conn.sendMouseScroll(adx, ady)
      return
    }
    if (this.pendingScrollTimer) return
    this.pendingScrollTimer = setTimeout(() => {
      this.pendingScrollTimer = null
      if (!this.pendingScroll) return
      const { dx: adx, dy: ady } = this.pendingScroll
      this.pendingScroll = null
      this.lastScrollSentAt = performance.now()
      this.conn.sendMouseScroll(adx, ady)
    }, this.scrollThrottleMs - elapsed)
  }

  private onMouseDown = (e: Event): void => {
    if (!this.enabled) return
    const me = e as MouseEvent
    me.preventDefault()
    this.el?.focus()
    const { nx, ny } = this.getCoords(me)
    this.conn.sendMouseButton(buttonName(me.button), true, nx, ny)
  }

  // Track clicks anywhere on document to manage captured state
  private onDocumentMouseDown = (e: Event): void => {
    if (!this.enabled) return
    const target = (e as MouseEvent).target as Node | null
    this.captured = !!(this.el && target && this.el.contains(target))
  }

  private onMouseUp = (e: Event): void => {
    if (!this.enabled) return
    const me = e as MouseEvent
    me.preventDefault()
    const { nx, ny } = this.getCoords(me)
    this.conn.sendMouseButton(buttonName(me.button), false, nx, ny)
  }

  private onDblClick = (e: Event): void => {
    if (!this.enabled) return
    const me = e as MouseEvent
    me.preventDefault()
    const { nx, ny } = this.getCoords(me)
    this.conn.sendMouseDoubleClick(buttonName(me.button), nx, ny)
  }

  private onWheel = (e: Event): void => {
    if (!this.enabled) return
    const we = e as WheelEvent
    we.preventDefault()
    const dx = Math.round(we.deltaX / 120)
    const dy = Math.round(we.deltaY / 120)
    if (dx !== 0 || dy !== 0) this.sendScrollThrottled(dx, dy)
  }

  private onContextMenu = (e: Event): void => e.preventDefault()

  private onMouseEnter = (): void => { this.hovering = true }
  private onMouseLeave = (): void => { this.hovering = false }
  private onWindowBlur = (): void => { this.releaseAllKeys(); this.captured = false }

  // MARK: - Keyboard

  private onKeyDown = (e: Event): void => {
    if (!this.enabled) return
    if (!this.hovering && !this.locked && !this.captured) return
    const ke = e as KeyboardEvent
    // Never intercept these — let the browser handle its own fullscreen toggle/exit/devtools.
    if (ke.code === 'F11' || ke.code === 'Escape' || ke.code === 'F12') return
    ke.preventDefault()

    if (ke.code === 'CapsLock') {
      // Send unconditionally — server reads its own current CapsLock state to decide direction.
      // Do NOT use getModifierState: IMEs (e.g. WeChat) may intercept CapsLock without changing
      // the OS CapsLock state, making getModifierState always return the same value and causing
      // the deduplication to suppress all subsequent presses.
      this.conn.sendKey('CapsLock', true, [])
      this.conn.sendKey('CapsLock', false, [])
      return
    }

    const km = getKeymap()
    this.conn.sendKey(mapKeyCode(ke.code, km), true, mapModifiers(collectModifiers(ke), km))
    this.pressedKeys.add(ke.code)
  }

  private onKeyUp = (e: Event): void => {
    if (!this.enabled) return
    const ke = e as KeyboardEvent
    if (ke.code === 'CapsLock') return  // handled in keydown
    // Send keyup only if we previously sent keydown for this key.
    // This ensures keyup always pairs with keydown regardless of hover state,
    // preventing stuck keys when the mouse drifts out of the canvas.
    if (!this.pressedKeys.has(ke.code)) return
    ke.preventDefault()
    this.pressedKeys.delete(ke.code)
    const km = getKeymap()
    this.conn.sendKey(mapKeyCode(ke.code, km), false, mapModifiers(collectModifiers(ke), km))
  }

  private releaseAllKeys(): void {
    const km = getKeymap()
    for (const code of this.pressedKeys) {
      this.conn.sendKey(mapKeyCode(code, km), false, [])
    }
    this.pressedKeys.clear()
  }

  // MARK: - Pointer lock

  private onPointerLockChange = (): void => {
    this.locked = document.pointerLockElement === this.el
  }

  requestPointerLock(): void {
    this.el?.requestPointerLock()
  }

  releasePointerLock(): void {
    if (this.locked) document.exitPointerLock()
  }

  // MARK: - Helpers

  private getCoords(e: MouseEvent): { nx: number; ny: number } {
    if (!this.el) return { nx: 0.5, ny: 0.5 }
    const rect = this.el.getBoundingClientRect()
    const cr   = this.contentRect(rect)
    return {
      nx: clamp((e.clientX - cr.left) / cr.width,  0, 1),
      ny: clamp((e.clientY - cr.top)  / cr.height, 0, 1)
    }
  }

  // canvas uses object-fit: fill — content occupies the full element rect
  private contentRect(rect: DOMRect): { left: number; top: number; width: number; height: number } {
    return { left: rect.left, top: rect.top, width: rect.width, height: rect.height }
  }
}

function buttonName(b: number): string {
  return b === 2 ? 'right' : b === 1 ? 'middle' : 'left'
}

// MouseEvent.buttons is a bitmask (1=left, 2=right, 4=middle), unrelated to
// MouseEvent.button's index encoding above — don't reuse buttonName here.
function buttonsToDragName(buttons: number): string | undefined {
  if (buttons & 1) return 'left'
  if (buttons & 2) return 'right'
  if (buttons & 4) return 'middle'
  return undefined
}

function collectModifiers(e: KeyboardEvent): string[] {
  const m: string[] = []
  if (e.metaKey)  m.push('meta')
  if (e.ctrlKey)  m.push('ctrl')
  if (e.altKey)   m.push('alt')
  if (e.shiftKey) m.push('shift')
  return m
}

function clamp(v: number, lo: number, hi: number): number {
  return Math.max(lo, Math.min(hi, v))
}
