import Foundation
import Combine

struct KeybotGlobalSettings: Codable {
    var excludedBundleIDs: [String] = []
    var isEnabled: Bool = true

    init(excludedBundleIDs: [String] = [], isEnabled: Bool = true) {
        self.excludedBundleIDs = excludedBundleIDs
        self.isEnabled = isEnabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        excludedBundleIDs = try c.decodeIfPresent([String].self, forKey: .excludedBundleIDs) ?? []
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
}

final class KeybotConfigStore: ObservableObject {
    static let shared = KeybotConfigStore()

    @Published var mappings: [KeyMapping] {
        didSet { save() }
    }

    @Published var globalSettings: KeybotGlobalSettings {
        didSet { saveSettings() }
    }

    var isEnabled: Bool {
        get { globalSettings.isEnabled }
        set {
            guard globalSettings.isEnabled != newValue else { return }
            globalSettings.isEnabled = newValue
        }
    }

    private let storePath: URL
    private let settingsPath: URL

    private init() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("Remoter").appendingPathComponent("keybot")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        storePath = dir.appendingPathComponent("config.json")
        settingsPath = dir.appendingPathComponent("settings.json")

        // Automatic one-time migration from standalone Keybot config directory
        // (uses Data(contentsOf:) so dotfiles symlinks resolve cleanly).
        let legacyDir = support.appendingPathComponent("Keybot")
        Self.migrateIfNeeded(from: legacyDir.appendingPathComponent("config.json"), to: storePath, label: "config.json")
        Self.migrateIfNeeded(from: legacyDir.appendingPathComponent("settings.json"), to: settingsPath, label: "settings.json")

        let loaded = Self.load(from: storePath) ?? Self.defaultMappings()
        mappings = loaded
        globalSettings = Self.loadSettings(from: settingsPath) ?? KeybotGlobalSettings()

        if !fm.fileExists(atPath: storePath.path) {
            if let data = try? JSONEncoder().encode(loaded) {
                try? data.write(to: storePath, options: .atomic)
            }
        }
        if !fm.fileExists(atPath: settingsPath.path) {
            if let data = try? JSONEncoder().encode(globalSettings) {
                try? data.write(to: settingsPath, options: .atomic)
            }
        }
    }

    private static func migrateIfNeeded(from legacyURL: URL, to destURL: URL, label: String) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destURL.path),
              fm.fileExists(atPath: legacyURL.path),
              let data = try? Data(contentsOf: legacyURL),
              !data.isEmpty else {
            return
        }
        do {
            try data.write(to: destURL, options: .atomic)
            ConnectionLogger.shared.logStep(
                sessionId: "keybot",
                step: "migrated_legacy_config",
                detail: "Migrated \(label) from ~/Library/Application Support/Keybot/ (\(data.count) bytes)"
            )
        } catch {
            ConnectionLogger.shared.logStep(
                sessionId: "keybot",
                step: "migration_failed",
                detail: "\(label): \(error)"
            )
        }
    }

    var enabledMappings: [KeyMapping] {
        mappings.filter(\.enabled)
    }

    func isGloballyExcluded(_ bundleID: String) -> Bool {
        globalSettings.excludedBundleIDs.contains(bundleID)
    }

    private static func load(from url: URL) -> [KeyMapping]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([KeyMapping].self, from: data)
    }

    private static func loadSettings(from url: URL) -> KeybotGlobalSettings? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(KeybotGlobalSettings.self, from: data)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(mappings) else { return }
        // 不用 .atomic：atomic 写入是"写临时文件再 rename"，rename 会把 dotfiles 符号链接替换成普通文件，导致同步静默失效
        try? data.write(to: storePath)
    }

    private func saveSettings() {
        guard let data = try? JSONEncoder().encode(globalSettings) else { return }
        try? data.write(to: settingsPath)
    }

    func resetToDefaults() {
        mappings = Self.defaultMappings()
    }

    static func defaultMappings() -> [KeyMapping] {
        let terminalIDs = ["com.apple.Terminal", "com.googlecode.iterm2"]

        let ctrlToCmd: [(String, Int)] = [
            ("Ctrl+C → Cmd+C", 8),
            ("Ctrl+V → Cmd+V", 9),
            ("Ctrl+X → Cmd+X", 7),
            ("Ctrl+Z → Cmd+Z", 6),
            ("Ctrl+A → Cmd+A", 0),
            ("Ctrl+S → Cmd+S", 1),
            ("Ctrl+F → Cmd+F", 3),
            ("Ctrl+P → Cmd+P", 35),
        ]

        var result = ctrlToCmd.map { name, kc in
            KeyMapping(
                name: name,
                trigger: KeyTrigger(keyCode: kc, modifiers: [.control]),
                action: .remap(keyCode: kc, modifiers: [.command]),
                // Ctrl+C 在 Terminal/iTerm2 里交给下面那条选中态规则处理，这里排除掉
                condition: kc == 8 ? .except(terminalIDs) : .all
            )
        }

        // Terminal/iTerm2 里 Ctrl+C：选中文本时复制，没选中时保留中断（SIGINT）
        result.insert(KeyMapping(
            name: "Ctrl+C → Cmd+C (Terminal, if selected)",
            trigger: KeyTrigger(keyCode: 8, modifiers: [.control]),
            action: .remap(keyCode: 8, modifiers: [.command]),
            condition: .only(terminalIDs),
            requireTextSelection: true
        ), at: 0)

        result.append(KeyMapping(
            name: "Ctrl+L → Lock & Sleep",
            trigger: KeyTrigger(keyCode: 37, modifiers: [.control]),
            action: .lockAndSleep
        ))

        result.append(KeyMapping(
            name: "ESC → Cmd+W (Finder/WeChat/QQ)",
            trigger: KeyTrigger(keyCode: 53, modifiers: []),
            action: .remap(keyCode: 13, modifiers: [.command]),
            condition: .only(["com.apple.finder", "com.tencent.xinWeChat", "com.tencent.qq"])
        ))

        result.append(KeyMapping(
            name: "F5 → Cmd+R (Edge)",
            trigger: KeyTrigger(keyCode: 96, modifiers: []),
            action: .remap(keyCode: 15, modifiers: [.command]),
            condition: .only(["com.microsoft.edgemac"])
        ))

        return result
    }
}
