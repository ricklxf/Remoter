import CoreGraphics
import Foundation

let keyCodeNames: [Int: String] = [
    0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
    8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
    16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
    23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
    30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "↩",
    37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",",
    44: "/", 45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space",
    51: "⌫", 53: "⎋", 96: "F5", 97: "F6", 98: "F7", 99: "F3",
    100: "F8", 101: "F9", 103: "F11", 109: "F10", 111: "F12",
    115: "Home", 116: "PgUp", 117: "⌦", 118: "F4", 119: "End",
    120: "F2", 121: "PgDn", 122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑"
]

enum ModifierKey: String, Codable, CaseIterable, Hashable {
    case command, control, option, shift

    var flag: CGEventFlags {
        switch self {
        case .command: return .maskCommand
        case .control: return .maskControl
        case .option:  return .maskAlternate
        case .shift:   return .maskShift
        }
    }

    var symbol: String {
        switch self {
        case .command: return "⌘"
        case .control: return "⌃"
        case .option:  return "⌥"
        case .shift:   return "⇧"
        }
    }

    var displayName: String {
        switch self {
        case .command: return "Command"
        case .control: return "Control"
        case .option:  return "Option"
        case .shift:   return "Shift"
        }
    }
}

struct KeyTrigger: Codable, Hashable {
    var keyCode: Int
    var modifiers: [ModifierKey]

    var displayString: String {
        let order: [ModifierKey] = [.control, .option, .shift, .command]
        let mods = order.filter { modifiers.contains($0) }.map(\.symbol).joined()
        let key = keyCodeNames[keyCode] ?? "Key(\(keyCode))"
        return mods + key
    }

    func matches(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        guard Int(keyCode) == self.keyCode else { return false }
        let relevant = flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
        var expected = CGEventFlags()
        for m in modifiers { expected.insert(m.flag) }
        return relevant == expected
    }

    var cgFlags: CGEventFlags {
        var f = CGEventFlags()
        for m in modifiers { f.insert(m.flag) }
        return f
    }
}

enum MappingAction: Hashable {
    case remap(keyCode: Int, modifiers: [ModifierKey])
    case lockAndSleep

    var displayString: String {
        switch self {
        case .remap(let kc, let mods):
            let order: [ModifierKey] = [.control, .option, .shift, .command]
            let ms = order.filter { mods.contains($0) }.map(\.symbol).joined()
            return "→ " + ms + (keyCodeNames[kc] ?? "Key(\(kc))")
        case .lockAndSleep:
            return "→ Lock & Sleep"
        }
    }
}

extension MappingAction: Codable {
    private enum CodingKeys: String, CodingKey { case type, keyCode, modifiers }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        if type == "lockAndSleep" {
            self = .lockAndSleep
        } else {
            let kc = try c.decode(Int.self, forKey: .keyCode)
            let mods = try c.decode([ModifierKey].self, forKey: .modifiers)
            self = .remap(keyCode: kc, modifiers: mods)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .lockAndSleep:
            try c.encode("lockAndSleep", forKey: .type)
        case .remap(let kc, let mods):
            try c.encode("remap", forKey: .type)
            try c.encode(kc, forKey: .keyCode)
            try c.encode(mods, forKey: .modifiers)
        }
    }
}

enum AppCondition: Hashable {
    case all
    case only([String])
    case except([String])

    func matches(bundleID: String) -> Bool {
        switch self {
        case .all: return true
        case .only(let ids): return ids.contains(bundleID)
        case .except(let ids): return !ids.contains(bundleID)
        }
    }

    var displayString: String {
        switch self {
        case .all: return "All Apps"
        case .only(let ids): return ids.isEmpty ? "(none)" : ids.joined(separator: "\n")
        case .except(let ids): return ids.isEmpty ? "(none excluded)" : ids.joined(separator: "\n")
        }
    }
}

extension AppCondition: Codable {
    private enum CodingKeys: String, CodingKey { case type, bundleIDs }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "all":    self = .all
        case "except": self = .except(try c.decode([String].self, forKey: .bundleIDs))
        default:       self = .only(try c.decode([String].self, forKey: .bundleIDs))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .all:
            try c.encode("all", forKey: .type)
        case .only(let ids):
            try c.encode("only", forKey: .type)
            try c.encode(ids, forKey: .bundleIDs)
        case .except(let ids):
            try c.encode("except", forKey: .type)
            try c.encode(ids, forKey: .bundleIDs)
        }
    }
}

struct KeyMapping: Identifiable, Hashable {
    var id: UUID
    var name: String
    var enabled: Bool
    var trigger: KeyTrigger
    var action: MappingAction
    var condition: AppCondition
    var requireTextSelection: Bool
    // 默认 false：修饰键改动用"原地改事件"方式下发（见 KeybotEventTap），这样对被控端
    // 远程桌面最友好，不会产生修饰键状态跳变。但 Chromium 系浏览器（Edge/Chrome）
    // 对这种原地修改不敏感，识别不出来，需要改成"消耗原事件+发一个全新事件"才行。
    // 只在这类应用上打开，不能设成通用默认值，否则会在远程桌面场景下重新引入
    // 之前修过的修饰键卡住问题。
    var useSyntheticRepost: Bool

    init(id: UUID = UUID(), name: String, enabled: Bool = true,
         trigger: KeyTrigger, action: MappingAction, condition: AppCondition = .all,
         requireTextSelection: Bool = false, useSyntheticRepost: Bool = false) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.trigger = trigger
        self.action = action
        self.condition = condition
        self.requireTextSelection = requireTextSelection
        self.useSyntheticRepost = useSyntheticRepost
    }
}

extension KeyMapping: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, enabled, trigger, action, condition, requireTextSelection, useSyntheticRepost
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        trigger = try c.decode(KeyTrigger.self, forKey: .trigger)
        action = try c.decode(MappingAction.self, forKey: .action)
        condition = try c.decode(AppCondition.self, forKey: .condition)
        // 旧配置文件没有这些字段，缺省为 false 保持兼容
        requireTextSelection = try c.decodeIfPresent(Bool.self, forKey: .requireTextSelection) ?? false
        useSyntheticRepost = try c.decodeIfPresent(Bool.self, forKey: .useSyntheticRepost) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(trigger, forKey: .trigger)
        try c.encode(action, forKey: .action)
        try c.encode(condition, forKey: .condition)
        try c.encode(requireTextSelection, forKey: .requireTextSelection)
        try c.encode(useSyntheticRepost, forKey: .useSyntheticRepost)
    }
}
