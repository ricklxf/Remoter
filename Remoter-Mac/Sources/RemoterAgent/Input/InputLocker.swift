import Foundation
import CoreGraphics
import AppKit

/// System-wide keyboard/mouse blocker: while locked, real hardware input is
/// swallowed before it reaches any app on this Mac, while Remoter's own
/// injected input (tagged in InputController.timedPost) passes through
/// untouched. Lets a remote controller stop whoever's physically at the
/// machine from fighting for control — mirrors "lock keyboard and mouse" in
/// TeamViewer/AnyDesk. Global to the whole agent process (a CGEventTap is a
/// system-wide resource, not scoped to one session), so this is a singleton.
final class InputLocker {
    static let shared = InputLocker()

    /// Marks a CGEvent as one Remoter injected itself, so the tap below
    /// never blocks our own remote-control input.
    static let injectedTag: Int64 = 0x52656d6f_00000001

    private(set) var isLocked = false
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Fired whenever the lock state actually changes — whether from an
    /// explicit client request or the local escape hatch below. main.swift
    /// wires this to broadcast the new state to every connected session so
    /// each client's toggle stays in sync regardless of who changed it.
    var onLockChanged: ((Bool) -> Void)?

    /// MenuBarController supplies its status item button's screen frame
    /// (Cocoa coordinates — origin bottom-left) so clicks landing on our own
    /// menu bar icon can pass through even while locked. Without this, the
    /// click meant to *open* the unlock menu never reaches AppKit in the
    /// first place — it's swallowed by this same tap before the menu ever
    /// gets a chance to show, so there'd be no way to reach the explicit
    /// "解除键鼠锁定" menu item with the mouse at all once locked.
    var statusItemFrameProvider: (() -> CGRect?)?

    /// Set by MenuBarController for as long as its own menu is open
    /// (menuWillOpen/menuDidClose) — lets every subsequent click through
    /// while the user is actually navigating our menu (their clicks land on
    /// menu item rects elsewhere on screen, not just the icon itself, so the
    /// hit-test above only gets them as far as opening it).
    private var suspended = false
    func setSuspended(_ v: Bool) { suspended = v }

    private init() {}

    func setLocked(_ locked: Bool) {
        guard locked != isLocked else { return }
        isLocked = locked
        // English-input forcing (InputSourceForcer) is a *separate* concern
        // tied to session lifetime, not to this lock — see Session.swift's
        // auth handlers and main.swift's removeSession. Blocking real
        // hardware input only matters when someone might physically be at
        // the machine; forcing English matters whenever a session is
        // controlling it at all, locked or not.
        if locked { installTap() } else { removeTap() }
        ConnectionLogger.shared.logStep(sessionId: "input", step: "input_lock", detail: locked ? "on" : "off")
        onLockChanged?(locked)
    }

    private func installTap() {
        guard eventTap == nil else { return }
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.rightMouseUp.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue) |
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue) |
            (1 << CGEventType.otherMouseDragged.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let locker = Unmanaged<InputLocker>.fromOpaque(refcon).takeUnretainedValue()
            return locker.handle(type: type, event: event)
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: refcon
        ) else {
            print("[InputLocker] failed to create event tap — check Accessibility permission")
            ConnectionLogger.shared.logStep(sessionId: "input", step: "input_lock_tap_failed")
            isLocked = false
            return
        }
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func removeTap() {
        guard let tap = eventTap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The OS disables a tap that's too slow to keep up (or on some
        // manual triggers) — re-enable so a lock doesn't silently stop
        // working until the agent restarts.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        // Our own injected input always passes through untouched.
        if event.getIntegerValueField(.eventSourceUserData) == Self.injectedTag {
            return Unmanaged.passUnretained(event)
        }

        // Our own menu bar dropdown is open — let everything through so the
        // user can actually navigate it and click "解除键鼠锁定".
        if suspended {
            return Unmanaged.passUnretained(event)
        }

        // Clicking directly on our own status bar icon always passes
        // through — the one click that's allowed to actually reach AppKit
        // and open the menu in the first place (see setSuspended above for
        // what happens once it's open).
        if type == .leftMouseDown || type == .leftMouseUp,
           let frame = statusItemFrameProvider?(),
           frame.contains(Self.cocoaPoint(from: event)) {
            return Unmanaged.passUnretained(event)
        }

        // Escape hatch: Control+Option+Command+Escape, physically pressed at
        // this Mac, always breaks the lock — the one way out that doesn't
        // depend on the remote session still being reachable.
        if type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags
            if keyCode == 53, // kVK_Escape
               flags.contains(.maskControl), flags.contains(.maskAlternate), flags.contains(.maskCommand) {
                DispatchQueue.main.async { [weak self] in
                    self?.setLocked(false)
                }
                return nil // swallow the combo itself too
            }
        }

        // Everything else real-hardware-produced is swallowed while locked.
        return nil
    }

    /// CGEvent.location is in Quartz's global display space (origin at the
    /// top-left of the primary screen, Y increasing downward). NSScreen /
    /// NSWindow frames are in Cocoa's space (origin at the *bottom*-left,
    /// Y increasing upward) — comparing the two directly without this
    /// conversion silently mismatches every hit-test.
    private static func cocoaPoint(from event: CGEvent) -> CGPoint {
        let loc = event.location
        let primaryHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height ?? 0
        return CGPoint(x: loc.x, y: primaryHeight - loc.y)
    }
}
