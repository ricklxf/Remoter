import { Connection } from '../network/Connection'

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
  private accX = 0
  private accY = 0
  private curNormX = 0.5
  private curNormY = 0.5

  // Track CapsLock state to detect real toggles (macOS may suppress CapsLock keydown)
  private lastCapsLock: boolean | null = null

  private boundHandlers: Array<[string, EventListenerOrEventListenerObject]> = []

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
    this.removeListeners()
    this.el = null
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
      this.boundHandlers.push([name, fn])
    }

    add(this.el, 'mousemove',   this.onMouseMove)
    add(this.el, 'mousedown',   this.onMouseDown)
    add(this.el, 'mouseup',     this.onMouseUp)
    add(this.el, 'dblclick',    this.onDblClick)
    add(this.el, 'wheel',       this.onWheel)
    add(this.el, 'contextmenu', this.onContextMenu)
    add(document, 'keydown',    this.onKeyDown)
    add(document, 'keyup',      this.onKeyUp)
    add(document, 'pointerlockchange', this.onPointerLockChange)
  }

  private removeListeners(): void {
    this.boundHandlers.forEach(([name, fn]) => {
      this.el?.removeEventListener(name, fn)
      document.removeEventListener(name, fn)
    })
    this.boundHandlers = []
  }

  // MARK: - Mouse

  private onMouseMove = (e: Event): void => {
    if (!this.enabled) return
    const me = e as MouseEvent
    me.preventDefault()

    if (this.locked) {
      // Pointer lock: accumulate raw deltas
      this.curNormX = clamp(this.curNormX + me.movementX / this.remoteW, 0, 1)
      this.curNormY = clamp(this.curNormY + me.movementY / this.remoteH, 0, 1)
      this.conn.sendMouseMove(this.curNormX, this.curNormY)
    } else if (this.el) {
      const { nx, ny } = this.getCoords(me)
      this.conn.sendMouseMove(nx, ny)
    }
  }

  private onMouseDown = (e: Event): void => {
    if (!this.enabled) return
    const me = e as MouseEvent
    me.preventDefault()
    this.el?.focus()
    const { nx, ny } = this.getCoords(me)
    this.conn.sendMouseButton(buttonName(me.button), true, nx, ny)
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
    if (dx !== 0 || dy !== 0) this.conn.sendMouseScroll(dx, dy)
  }

  private onContextMenu = (e: Event): void => e.preventDefault()

  // MARK: - Keyboard

  private onKeyDown = (e: Event): void => {
    if (!this.enabled) return
    const ke = e as KeyboardEvent
    if (ke.code === 'F11') return
    ke.preventDefault()

    if (ke.code === 'CapsLock') {
      // CapsLock is a toggle key. getModifierState gives the NEW state after this press.
      // Only send once per actual state change (macOS may fire duplicate or suppress events).
      const capsOn = ke.getModifierState('CapsLock')
      if (this.lastCapsLock !== capsOn) {
        this.lastCapsLock = capsOn
        this.conn.sendKey('CapsLock', true, [])
        this.conn.sendKey('CapsLock', false, [])
      }
      return
    }

    this.conn.sendKey(ke.code, true, collectModifiers(ke))
  }

  private onKeyUp = (e: Event): void => {
    if (!this.enabled) return
    const ke = e as KeyboardEvent
    ke.preventDefault()
    if (ke.code === 'CapsLock') return  // handled entirely in onKeyDown
    this.conn.sendKey(ke.code, false, collectModifiers(ke))
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
