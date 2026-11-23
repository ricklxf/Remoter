import { Connection } from '../network/Connection'
import { getKeymap, mapKeyCode, mapModifiers } from '../utils/keymap'

// Translates DOM mouse/keyboard events to remote input commands.
// All coordinates are normalized [0,1] relative to the remote screen.

export class InputHandler {
  private conn: Connection
  private el: HTMLElement | null = null
  // Hidden textarea that holds focus while capturing: an IME will only
  // engage on an editable element, so without this, typing Chinese/Japanese/
  // Korean through the *local* input method is impossible (the remote end's
  // IME had to be used instead). Composition happens in here invisibly;
  // compositionend hands us the final committed text to inject remotely.
  private imeEl: HTMLTextAreaElement | null = null
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

  // Modifiers captured at the paste-shortcut keydown, consumed by onPaste
  // once the browser's native paste ClipboardEvent actually fires — see
  // onKeyDown's KeyV branch for why the two are split apart.
  private pendingPasteMods: string[] = []

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

  private boundHandlers: Array<[EventTarget, string, EventListenerOrEventListenerObject]> = []

  constructor(conn: Connection) {
    this.conn = conn
  }

  attach(el: HTMLElement, remoteW: number, remoteH: number, imeEl?: HTMLTextAreaElement): void {
    this.el = el
    this.imeEl = imeEl ?? null
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
    this.imeEl?.blur()
    this.el = null
    this.imeEl = null
    if (this.locked) document.exitPointerLock?.()
    if (this.pendingMoveTimer) { clearTimeout(this.pendingMoveTimer); this.pendingMoveTimer = null }
    this.pendingMove = null
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
    this.imeEl?.blur()
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
    add(window,   'focus',      this.onWindowFocus)
    add(document, 'paste',      this.onPaste)
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

  // Sub-unit remainders carried between sends so nothing is lost to rounding.
  private scrollRem = { px: 0, py: 0, lx: 0, ly: 0 }

  /** Sends both forms: whole pixels (agents that support pixel-precise
   * scrolling) and whole wheel notches (older agents / Windows, which only
   * read dx/dy). 100px = one notch, Chromium's per-notch delta on Windows. */
  private flushScroll(dxPx: number, dyPx: number, isPrecise = false): void {
    const r = this.scrollRem
    r.px += dxPx; r.py += dyPx; r.lx += dxPx / 100; r.ly += dyPx / 100
    const px = Math.trunc(r.px), py = Math.trunc(r.py)
    const lx = Math.trunc(r.lx), ly = Math.trunc(r.ly)
    r.px -= px; r.py -= py; r.lx -= lx; r.ly -= ly
    if (px !== 0 || py !== 0 || lx !== 0 || ly !== 0) {
      this.conn.sendMouseScroll(lx, ly, px, py, isPrecise)
    }
  }

  private onMouseDown = (e: Event): void => {
    if (!this.enabled) return
    const me = e as MouseEvent
    me.preventDefault()
    // Focus the non-editable canvas container so the browser never activates
    // local IME (UU Remote / Parsec model: raw keycodes flow directly to the
    // remote host and use the host's native IME at the real remote cursor).
    this.el?.focus({ preventScroll: true })
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
    // Raw pixel deltas, not pre-rounded "lines": Math.round(delta / 120)
    // per event threw away every delta under 60px — i.e. nearly all of a
    // precision touchpad's or smooth-scroll mouse's output — and turned the
    // rest into whole-line jumps. deltaMode 1 = lines (Firefox), 2 = pages.
    const unit = we.deltaMode === 1 ? 40 : we.deltaMode === 2 ? 800 : 1
    let dx = we.deltaX * unit
    let dy = we.deltaY * unit

    // Soft axis lock: eliminate accidental drift on perpendicular axis only when one axis dominates
    const ax = Math.abs(dx), ay = Math.abs(dy)
    if (ay > ax * 3) {
      dx = 0
    } else if (ax > ay * 3) {
      dy = 0
    }

    if (dx === 0 && dy === 0) return

    // Precise continuous touchpad vs discrete mechanical mouse wheel:
    // Flush both immediately with 0ms client-side batching latency
    const isPrecise = we.deltaMode === 0 && (!Number.isInteger(dy) || (Math.abs(dy) < 40 && Math.abs(dx) < 40))
    this.flushScroll(dx, dy, isPrecise)
  }

  private onContextMenu = (e: Event): void => e.preventDefault()

  private onMouseEnter = (): void => { this.hovering = true }
  private onMouseLeave = (): void => { this.hovering = false }
  private onWindowBlur = (): void => { this.releaseAllKeys(); this.captured = false }
  // Switching back to this window/tab (Cmd+Tab, clicking the taskbar icon,
  // etc.) without first clicking inside the canvas left a gap: `captured`
  // stays false (cleared by the blur above) and imeEl isn't refocused until
  // the *next* click, so a keystroke typed immediately after switching back
  // — before any click — fails the hovering/captured gate in onKeyDown and
  // keyboard focus is still wherever it was before this window lost it,
  // silently going to whatever else has it instead of the remote canvas.
  // Re-establish both the instant this window is frontmost again.
  private onWindowFocus = (): void => {
    if (!this.enabled) return
    this.captured = true
    this.el?.focus({ preventScroll: true })
  }

  // MARK: - Keyboard

  private onKeyDown = (e: Event): void => {
    if (!this.enabled) return
    if (!this.hovering && !this.locked && !this.captured) return
    const ke = e as KeyboardEvent
    // Never intercept these — let the browser handle its own fullscreen toggle/devtools.
    // Escape is deliberately NOT in this list (see toolbar's fullscreen
    // toggle button for exiting fullscreen instead): forwarding it to the
    // target lets it close remote dialogs/menus like a real keypress would.
    if (ke.code === 'F11' || ke.code === 'F12') return

    if (ke.code === 'CapsLock') {
      // Send unconditionally — server reads its own current CapsLock state to decide direction.
      // Do NOT use getModifierState: IMEs (e.g. WeChat) may intercept CapsLock without changing
      // the OS CapsLock state, making getModifierState always return the same value and causing
      // the deduplication to suppress all subsequent presses.
      ke.preventDefault()
      this.conn.sendKey('CapsLock', true, [])
      this.conn.sendKey('CapsLock', false, [])
      return
    }

    // Paste shortcut — deliberately NOT preventDefault'd, and no keycode
    // sent yet: letting the browser run its own paste command is what
    // makes it fire a native `paste` ClipboardEvent on the focused hidden
    // textarea (see onPaste), handing us clipboardData synchronously with
    // no permission grant needed at all. This replaced an earlier design
    // built on the Async Clipboard API (navigator.clipboard.readText),
    // whose read permission can be silently denied per-origin or, worse,
    // leave its promise pending forever — which once meant the paste
    // keystroke itself silently never reached the target, even for a pure
    // target-side-local paste with no controller clipboard involved at
    // all. The native paste event is what production web remote-desktop
    // clients (Chrome Remote Desktop, Guacamole) use for exactly this
    // reason. onPaste does the actual sendKey once it has the data.
    if (ke.code === 'KeyV' && (ke.ctrlKey || ke.metaKey)) {
      this.pendingPasteMods = mapModifiers(collectModifiers(ke), getKeymap())
      this.pressedKeys.add(ke.code)
      return
    }

    ke.preventDefault()
    const km = getKeymap()
    const mappedCode = mapKeyCode(ke.code, km)
    const mods = mapModifiers(collectModifiers(ke), km)
    this.pressedKeys.add(ke.code)
    this.conn.sendKey(mappedCode, true, mods)
  }

  // The browser's own paste command, fired synchronously as the default
  // action of the Cmd+V/Ctrl+V keydown that onKeyDown deliberately left
  // un-prevented (see there for why). clipboardData is available here with
  // no permission check at all — this is the whole point of using the
  // native event instead of the Async Clipboard API. preventDefault stops
  // the browser from also inserting the pasted content into the hidden
  // textarea itself (harmless either way since it's invisible, but there's
  // no reason to let it accumulate there).
  private onPaste = (e: Event): void => {
    if (!this.enabled) return
    if (!this.hovering && !this.locked && !this.captured) return
    const ce = e as ClipboardEvent
    ce.preventDefault()

    const text = ce.clipboardData?.getData('text/plain')
    if (text) this.conn.sendClipboard(text)

    let imageFile: File | null = null
    const items = ce.clipboardData?.items
    if (items) {
      for (let i = 0; i < items.length; i++) {
        if (items[i].type.startsWith('image/')) { imageFile = items[i].getAsFile(); break }
      }
    }

    const km = getKeymap()
    const mappedCode = mapKeyCode('KeyV', km)
    const mods = this.pendingPasteMods

    // The image (if any) must land on the target *before* the paste
    // keystroke, same reasoning as the text case above — but reading it
    // out of the File is itself async, so the keystroke has to wait for
    // that specifically, not just for the (already-synchronous) text path.
    if (imageFile) {
      const reader = new FileReader()
      reader.onload = () => {
        const base64 = (reader.result as string).split(',')[1]
        if (base64) this.conn.sendClipboardImage(base64)
        this.conn.sendKeyViaWS(mappedCode, true, mods)
      }
      reader.readAsDataURL(imageFile)
    } else {
      this.conn.sendKeyViaWS(mappedCode, true, mods)
    }
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
