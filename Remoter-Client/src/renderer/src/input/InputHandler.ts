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

  // Tracks whether an IME composition is currently in progress (set by
  // compositionstart/compositionend) — see onImeInput for why keydown alone
  // (isComposing / key==='Process') can't reliably tell us this on its own.
  private composing = false

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
    if (this.imeEl) add(this.imeEl, 'compositionstart', this.onCompositionStart)
    if (this.imeEl) add(this.imeEl, 'compositionend',   this.onCompositionEnd)
    if (this.imeEl) add(this.imeEl, 'input',            this.onImeInput)
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
    // Focus the hidden textarea (not the canvas): key events still bubble to
    // the document handlers below either way, but only an editable element
    // lets the local IME engage for CJK composition.
    if (this.imeEl) this.imeEl.focus({ preventScroll: true })
    else this.el?.focus()
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
    this.imeEl?.focus({ preventScroll: true })
  }

  // MARK: - Keyboard

  // Punctuation/symbol keys that produce a literal character — same
  // treatment as letters/digits below, for the same reason: any of them can
  // end up intercepted by an IME (candidate reselection, bracket-based
  // input methods, etc.), and guessing wrong either drops the character or
  // duplicates it (see the comment on isPlainTextKey).
  private static readonly PLAIN_SYMBOL_CODES = new Set([
    'Space', 'Minus', 'Equal', 'BracketLeft', 'BracketRight', 'Backslash',
    'Semicolon', 'Quote', 'Comma', 'Period', 'Slash', 'Backquote',
    'NumpadDecimal', 'NumpadAdd', 'NumpadSubtract', 'NumpadMultiply', 'NumpadDivide', 'NumpadEqual',
  ])

  // Plain, unmodified keys that produce a literal character are never
  // forwarded via raw keycode + preventDefault — see onImeInput for why.
  // Covers every key that can actually put a character on screen (letters,
  // digits, numpad digits/operators, punctuation, space); confirmed
  // necessary for more than just letters — digits and brackets have each
  // shown the same "IME intercepts it right after a composition, so
  // preventDefault + raw-forward produces a duplicate or a drop" failure.
  // Everything else (arrows, function keys, Enter/Backspace/Tab, and any
  // key held with Ctrl/Alt/Meta) still goes through the direct keycode path.
  private static isPlainTextKey(ke: KeyboardEvent): boolean {
    if (ke.ctrlKey || ke.altKey || ke.metaKey) return false
    if (/^Key[A-Z]$/.test(ke.code) || /^Digit[0-9]$/.test(ke.code) || /^Numpad[0-9]$/.test(ke.code)) return true
    return InputHandler.PLAIN_SYMBOL_CODES.has(ke.code)
  }

  private onKeyDown = (e: Event): void => {
    if (!this.enabled) return
    if (!this.hovering && !this.locked && !this.captured) return
    const ke = e as KeyboardEvent
    // Never intercept these — let the browser handle its own fullscreen toggle/exit/devtools.
    if (ke.code === 'F11' || ke.code === 'Escape' || ke.code === 'F12') return
    // The local IME is composing — hand off entirely: no preventDefault (the
    // IME needs the event) and no raw-key forwarding (the composed text
    // arrives via compositionend instead, see onCompositionEnd).
    // Deliberately NOT also checking `keyCode === 229`: that legacy signal
    // is unreliable — some browsers report it on genuine, non-composing
    // keystrokes for a while after the IME was last used (confirmed via
    // logging: isComposing false, keyCode 229, on a plain digit key with no
    // candidate list showing), which silently dropped real keystrokes.
    if (ke.isComposing) return

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

    // A plain letter key can *become* the first key of an IME composition —
    // and there is no reliable way to know that in advance. isComposing is
    // still false and key is the literal letter (not 'Process') for exactly
    // this ambiguous first keystroke (confirmed via logging: {code: "KeyD",
    // isComposing: false, key: "d"} immediately preceding a real
    // composition). Forwarding it here via raw keycode, *and* calling
    // preventDefault — which stops the browser from ever handing this key
    // to the IME at all — produced two bugs at once: the letter landed
    // remotely on its own, and the composition that followed was missing
    // that same letter (e.g. typing "da" for a character produced literal
    // "d" *plus* whatever "a" alone composes to).
    //
    // Fix: never preventDefault or raw-keycode-forward a plain letter key.
    // Let the browser's default action happen — into the hidden textarea,
    // same as before — and read back whatever text actually landed there
    // (onImeInput), whether that's plain typing or IME output. This makes
    // the ambiguity irrelevant: we no longer have to guess in advance.
    if (InputHandler.isPlainTextKey(ke)) return

    // Paste shortcut about to be forwarded — the clipboard sync loop only
    // pushes changes once a second, so a copy-then-immediately-paste inside
    // that window would send the remote whatever was on the clipboard
    // *before* the copy. Force an out-of-cycle check right now instead of
    // waiting for the next tick; runs independently of (and doesn't delay)
    // the actual paste keystroke below.
    if (ke.code === 'KeyV' && (ke.ctrlKey || ke.metaKey)) this.conn.syncClipboardNow()

    ke.preventDefault()
    const km = getKeymap()
    this.conn.sendKey(mapKeyCode(ke.code, km), true, mapModifiers(collectModifiers(ke), km))
    this.pressedKeys.add(ke.code)
  }

  private onCompositionStart = (): void => {
    this.composing = true
  }

  private onCompositionEnd = (e: Event): void => {
    if (!this.enabled) return
    this.composing = false
    const ce = e as CompositionEvent
    if (ce.data) this.conn.sendTextInput(ce.data)
    // The committed text also landed in the hidden textarea — clear it so it
    // never accumulates (it's invisible, but selection/arrow keys would start
    // behaving oddly inside a growing buffer).
    if (this.imeEl) this.imeEl.value = ''
  }

  // Catches plain-letter text that landed in the textarea via its default
  // browser behavior (see isPlainTextKey above) — covers both ordinary
  // English typing (no IME involved at all) and the ambiguous first
  // keystroke of a composition that hasn't engaged the IME after all (e.g.
  // a single letter with no matching candidates). Composition-driven input
  // is handled by onCompositionEnd instead, once the whole composition
  // settles, so this must not also forward text while one is in progress.
  private onImeInput = (e: Event): void => {
    if (!this.enabled) return
    const ie = e as InputEvent
    if (this.composing || ie.isComposing) return
    const text = this.imeEl?.value
    if (text) {
      this.conn.sendTextInput(text)
      if (this.imeEl) this.imeEl.value = ''
    }
  }

  private onKeyUp = (e: Event): void => {
    if (!this.enabled) return
    const ke = e as KeyboardEvent
    if (ke.code === 'CapsLock') return  // handled in keydown
    if (ke.isComposing) return
    if (InputHandler.isPlainTextKey(ke)) return   // see onKeyDown — no matching keydown was sent
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
