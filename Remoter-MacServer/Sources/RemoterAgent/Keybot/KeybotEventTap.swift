import Cocoa
import ApplicationServices

private let kcCommand: CGKeyCode = 55
private let kcControl: CGKeyCode = 59
private let kcRightControl: CGKeyCode = 62
// 设备相关的左右修饰键位（NX_DEVICE*KEYMASK），只改 maskControl/maskCommand 会留下残位
private let deviceCtrlBits: UInt64 = 0x0001 | 0x2000
private let deviceCmdBits: UInt64 = 0x0008 | 0x0010

private func keybotTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    KeybotEventTap.shared.handle(proxy: proxy, type: type, event: event)
}

final class KeybotEventTap {
    static let syntheticMarker: Int64 = 0x4B455942
    static let shared = KeybotEventTap()

    var isEnabled: Bool {
        get { KeybotConfigStore.shared.isEnabled }
        set { setEnabled(newValue) }
    }

    private(set) var isRunning = false
    var isCapturingKey = false

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    // 物理上按着 Control，但已对应用宣称"Control 松开、Command 按下"
    private var ctrlSwapped = false
    // 最近一次修饰键事件里各修饰键的状态；用来识别"事件说已松开、系统却仍认为按着"的卡键
    private var lastModFlags = CGEventFlags()
    private var stuckSince: Date?
    private var healTimer: Timer?
    private let healMask: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
    private var chromiumAppCache: [String: Bool] = [:]

    private init() {}

    @discardableResult
    func start() -> Bool {
        if isRunning, let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
            return true
        }
        guard AXIsProcessTrusted() else { return false }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: keybotTapCallback,
            userInfo: nil
        ) else {
            ConnectionLogger.shared.logStep(sessionId: "keybot", step: "event_tap_create_failed")
            return false
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isRunning = true
        healTimer?.invalidate()
        healTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.healStuckModifiers()
        }
        ConnectionLogger.shared.logStep(
            sessionId: "keybot",
            step: "event_tap_started",
            detail: "rules=\(KeybotConfigStore.shared.enabledMappings.count)"
        )
        return true
    }

    func stop() {
        healTimer?.invalidate()
        healTimer = nil
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            CFMachPortInvalidate(tap)
        }
        tap = nil
        runLoopSource = nil
        ctrlSwapped = false
        stuckSince = nil
        if isRunning {
            isRunning = false
            ConnectionLogger.shared.logStep(sessionId: "keybot", step: "event_tap_stopped")
        }
    }

    func setEnabled(_ enabled: Bool) {
        KeybotConfigStore.shared.isEnabled = enabled
        if enabled {
            let started = start()
            ConnectionLogger.shared.logStep(
                sessionId: "keybot",
                step: "keybot_enabled",
                detail: "started=\(started)"
            )
        } else {
            stop()
            ConnectionLogger.shared.logStep(sessionId: "keybot", step: "keybot_disabled")
        }
    }

    // 远控软件（如 UU）偶尔漏发修饰键松开：事件流里已经松开，系统状态却仍卡着，
    // 表现为一直按着 Command/Ctrl。不一致持续 0.3 秒以上就补发一个松开（实测卡着时 0.7 秒内按回车会变成 Cmd+回车，所以不能等太久；
    // 正常的事件先后顺序造成的不一致只有几毫秒）。
    private func healStuckModifiers() {
        guard isRunning, isEnabled, !ctrlSwapped, !isCapturingKey else { stuckSince = nil; return }
        let sys = CGEventSource.flagsState(.hidSystemState).intersection(healMask)
        let stuck = sys.subtracting(lastModFlags)
        guard !stuck.isEmpty else { stuckSince = nil; return }
        guard let since = stuckSince else { stuckSince = Date(); return }
        guard Date().timeIntervalSince(since) >= 0.3 else { return }
        stuckSince = nil
        let keys: [(CGEventFlags, CGKeyCode)] = [(.maskCommand, kcCommand), (.maskControl, kcControl),
                                                 (.maskAlternate, 58), (.maskShift, 56)]
        var remaining = sys
        for (flag, kc) in keys where stuck.contains(flag) {
            remaining.remove(flag)
            guard let e = CGEvent(keyboardEventSource: nil, virtualKey: kc, keyDown: false) else { continue }
            e.type = .flagsChanged
            e.flags = remaining
            e.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
            e.post(tap: .cghidEventTap)
        }
    }

    func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // 系统会在回调响应慢或被判定异常时自动禁用 tap，需主动重新启用，否则按键全部失效直到重启
            if isRunning, isEnabled, let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passRetained(event)
        case .keyDown, .keyUp:
            guard isEnabled else { return Unmanaged.passRetained(event) }
            return handleKey(proxy: proxy, type: type, event: event)
        case .flagsChanged:
            guard isEnabled else { return Unmanaged.passRetained(event) }
            return handleFlags(proxy: proxy, event: event)
        case .leftMouseDown, .leftMouseUp:
            guard isEnabled else { return Unmanaged.passRetained(event) }
            return handleMouse(event: event)
        default:
            return Unmanaged.passRetained(event)
        }
    }

    private func handleKey(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMarker {
            return Unmanaged.passRetained(event)
        }
        if isCapturingKey {
            return Unmanaged.passRetained(event)
        }

        let frontApp = NSWorkspace.shared.frontmostApplication
        let bundleID = frontApp?.bundleIdentifier ?? ""

        if KeybotConfigStore.shared.isGloballyExcluded(bundleID) {
            return Unmanaged.passRetained(event)
        }

        let flags = event.flags
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let isDown = type == .keyDown

        for mapping in KeybotConfigStore.shared.enabledMappings {
            guard mapping.trigger.matches(keyCode: keyCode, flags: flags) else { continue }
            guard mapping.condition.matches(bundleID: bundleID) else { continue }
            guard !mapping.requireTextSelection || hasSelectedText() else { continue }

            switch mapping.action {
            case .lockAndSleep:
                if isDown { lockAndSleep() }
                return nil
            case .remap(let targetKC, let targetMods):
                var f = CGEventFlags()
                for m in targetMods { f.insert(m.flag) }
                // Ctrl+键 → Cmd+键 时，应用（尤其 Chromium/Electron）只看到 Control 的按下/松开，
                // 中间却夹着带 Command 的按键，内部修饰键状态会错乱成"Ctrl 卡住"（远程桌面必现）。
                // 所以先补发配套的修饰键事件，让 Control/Command 的按下松开序列自洽
                if flags.contains(.maskControl), !flags.contains(.maskCommand),
                   f.contains(.maskCommand), !f.contains(.maskControl) {
                    beginCtrlSwap(proxy: proxy, flags: flags)
                } else {
                    endCtrlSwap(proxy: proxy, flags: flags, afterEvent: !isDown)
                }
                if mapping.useSyntheticRepost || isChromiumOrElectronApp(frontApp) {
                    // Chromium/Electron 系应用（Claude/Edge/Chrome/VSCode/Cursor/Antigravity 等）
                    // 对原地改 CGEvent 不敏感，必须消耗原事件再发一个全新的合成事件才能稳定触发快捷键
                    postKey(CGKeyCode(targetKC), modifiers: f, isDown: isDown)
                    return nil
                }
                // 原地修改事件，避免消耗原始事件再发合成事件
                // 消耗+重发会产生修饰键状态跳变，导致被控端远程桌面修饰键卡住
                event.setIntegerValueField(.keyboardEventKeycode, value: Int64(targetKC))
                event.flags = f
                return Unmanaged.passRetained(event)
            }
        }

        // 按住 Ctrl 期间按了不改的键（如 Ctrl+K），先把 Control 还给应用
        endCtrlSwap(proxy: proxy, flags: flags, afterEvent: !isDown)
        return Unmanaged.passRetained(event)
    }

    // 修饰键事件只能改变它自己那一位：远控服务端拼 flags 时会吸入系统当前状态，
    // 比如发一个 Control 松开却带着 Keybot 刚设的 Command，把 Command 重新断言成按下，
    // 之后没有人再松开它。这里把"上一次状态里没有、又不属于该键码"的多余位去掉
    func stripPhantomModifiers(_ event: CGEvent) {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let table: [CGKeyCode: (CGEventFlags, UInt64)] = [
            55: (.maskCommand, deviceCmdBits), 54: (.maskCommand, deviceCmdBits),
            59: (.maskControl, deviceCtrlBits), 62: (.maskControl, deviceCtrlBits),
            58: (.maskAlternate, 0x20 | 0x40), 61: (.maskAlternate, 0x20 | 0x40),
            56: (.maskShift, 0x2 | 0x4), 60: (.maskShift, 0x2 | 0x4),
        ]
        guard let own = table[keyCode]?.0 else { return }
        let phantom = event.flags.intersection(healMask).subtracting(lastModFlags).subtracting(own)
        guard !phantom.isEmpty else { return }
        var raw = event.flags.rawValue
        for (flag, bits) in table.values where phantom.contains(flag) {
            raw &= ~(flag.rawValue | bits)
        }
        event.flags = CGEventFlags(rawValue: raw)
    }

    private func handleFlags(proxy: CGEventTapProxy, event: CGEvent) -> Unmanaged<CGEvent>? {
        if event.getIntegerValueField(.eventSourceUserData) != Self.syntheticMarker {
            stripPhantomModifiers(event)
            lastModFlags = event.flags.intersection(healMask)
        }
        guard ctrlSwapped, event.getIntegerValueField(.eventSourceUserData) != Self.syntheticMarker else {
            return Unmanaged.passRetained(event)
        }
        let flags = event.flags
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        if (keyCode == kcControl || keyCode == kcRightControl), !flags.contains(.maskControl) {
            // 松开物理 Ctrl → 对应用来说是松开 Command
            ctrlSwapped = false
            event.setIntegerValueField(.keyboardEventKeycode, value: Int64(kcCommand))
            event.flags = withoutCtrlCmd(flags)
            return Unmanaged.passRetained(event)
        }
        if !flags.contains(.maskControl) {
            // 漏掉了 Ctrl 松开（如 tap 曾被系统暂停），补一个 Command 松开自愈
            endCtrlSwap(proxy: proxy, flags: flags)
            return Unmanaged.passRetained(event)
        }
        // 交换期间按下/松开其他修饰键：继续对应用呈现 Command 而不是 Control
        event.flags = withoutCtrlCmd(flags).union(CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x0008))
        return Unmanaged.passRetained(event)
    }

    private func beginCtrlSwap(proxy: CGEventTapProxy, flags: CGEventFlags) {
        guard !ctrlSwapped else { return }
        ctrlSwapped = true
        let released = CGEventFlags(rawValue: flags.subtracting(.maskControl).rawValue & ~deviceCtrlBits)
        postModifier(proxy: proxy, keyCode: kcControl, flags: released)
        postModifier(proxy: proxy, keyCode: kcCommand,
                     flags: released.union(CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x0008)))
    }

    // afterEvent：按键松开事件自己还带着 cmd 标记，补发的 Command 松开必须排在它后面，
    // 否则这个事件会把 Command 重新设成按下，要等自愈检查才能清掉
    private func endCtrlSwap(proxy: CGEventTapProxy, flags: CGEventFlags, afterEvent: Bool = false) {
        guard ctrlSwapped else { return }
        ctrlSwapped = false
        if afterEvent {
            let base = withoutCtrlCmd(flags)
            let restoreCtrl = flags.contains(.maskControl)
            DispatchQueue.main.async { [weak self] in
                self?.postModifierHID(keyCode: kcCommand, flags: base)
                if restoreCtrl {
                    self?.postModifierHID(keyCode: kcControl,
                                          flags: base.union(CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue | 0x0001)))
                }
            }
            return
        }
        postModifier(proxy: proxy, keyCode: kcCommand, flags: withoutCtrlCmd(flags))
        if flags.contains(.maskControl) {
            postModifier(proxy: proxy, keyCode: kcControl,
                         flags: withoutCtrlCmd(flags).union(CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue | 0x0001)))
        }
    }

    private func withoutCtrlCmd(_ flags: CGEventFlags) -> CGEventFlags {
        CGEventFlags(rawValue: flags.subtracting([.maskControl, .maskCommand]).rawValue & ~(deviceCtrlBits | deviceCmdBits))
    }

    private func postModifierHID(keyCode: CGKeyCode, flags: CGEventFlags) {
        guard let e = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true) else { return }
        e.type = .flagsChanged
        e.flags = flags
        e.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
        e.post(tap: .cghidEventTap)
    }

    // tapPostEvent 插在本 tap 之后、当前事件之前送达，保证修饰键事件先于被改写的按键
    private func postModifier(proxy: CGEventTapProxy, keyCode: CGKeyCode, flags: CGEventFlags) {
        guard let e = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true) else { return }
        e.type = .flagsChanged
        e.flags = flags
        e.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
        e.tapPostEvent(proxy)
    }

    private func hasSelectedText() -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        // 目标 App 卡住/无响应时，Accessibility 查询会一直等它回应——这个查询
        // 跟所有按键事件挤在同一条处理队列里，卡住等于把全系统键盘输入都拖死。
        // 设个超时上限，超时就当查不到处理，不能让它无限期等下去。
        AXUIElementSetMessagingTimeout(systemWide, 0.2)
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused else { return false }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.2)

        // 优先查选区长度（kAXSelectedTextRangeAttribute），比取选中文本内容
        // （kAXSelectedTextAttribute）更可靠——部分应用（如 Terminal）对后者
        // 的实现不准确，可能在没有选区时也返回非空内容
        var rangeValue: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
           let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) {
                return range.length > 0
            }
        }

        var selected: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selected) == .success,
              let text = selected as? String else { return false }
        return !text.isEmpty
    }

    private func handleMouse(event: CGEvent) -> Unmanaged<CGEvent>? {
        let flags = event.flags
        if flags.contains(.maskControl), !flags.contains(.maskCommand) {
            var newFlags = flags
            newFlags.remove(.maskControl)
            newFlags.insert(.maskCommand)
            event.flags = newFlags
        }
        return Unmanaged.passRetained(event)
    }

    func isChromiumOrElectronBundle(at bundleURL: URL) -> Bool {
        let frameworksURL = bundleURL.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        let markers = [
            "Electron Framework.framework",
            "Google Chrome Framework.framework",
            "Microsoft Edge Framework.framework",
            "Chromium Embedded Framework.framework",
            "Brave Browser Framework.framework",
            "Arc Framework.framework",
            "Opera Framework.framework",
            "Vivaldi Framework.framework",
        ]
        let fm = FileManager.default
        for marker in markers {
            if fm.fileExists(atPath: frameworksURL.appendingPathComponent(marker).path) {
                return true
            }
        }
        return false
    }

    private func isChromiumOrElectronApp(_ app: NSRunningApplication?) -> Bool {
        guard let app, let bundleID = app.bundleIdentifier, !bundleID.isEmpty else { return false }
        if let cached = chromiumAppCache[bundleID] {
            return cached
        }
        let detected = app.bundleURL.map { isChromiumOrElectronBundle(at: $0) } ?? false
        chromiumAppCache[bundleID] = detected
        return detected
    }

    private func postKey(_ keyCode: CGKeyCode, modifiers: CGEventFlags, isDown: Bool) {
        guard let e = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: isDown) else { return }
        e.flags = modifiers
        e.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
        e.post(tap: .cgSessionEventTap)
    }

    private func lockAndSleep() {
        postKey(12, modifiers: [.maskControl, .maskCommand], isDown: true)
        postKey(12, modifiers: [.maskControl, .maskCommand], isDown: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            task.arguments = ["sleepnow"]
            try? task.run()
        }
    }
}
