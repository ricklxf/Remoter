import Foundation
import CoreGraphics

/// Returns true when running in the macOS pre-login LoginWindow session (or explicitly passed `--loginwindow`).
func isLoginWindowSession() -> Bool {
    if CommandLine.arguments.contains("--loginwindow") {
        return true
    }
    if getuid() == 0 {
        return true
    }
    if let dict = CGSessionCopyCurrentDictionary() as? [String: Any] {
        let user = (dict[kCGSessionUserNameKey as String] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if user.isEmpty || user.lowercased() == "loginwindow" {
            return true
        }
    }
    return false
}

// Persisted config — ~/Library/Application Support/Remoter/config.json
// Falls back to /Library/Application Support/Remoter/config.json in LoginWindow / pre-login sessions.
// CLI args always take precedence over this file.
struct AgentConfig: Codable {
    var port: UInt16 = 7788
    var pin: String  = ""
    var relayUrl: String = ""
    // TURN（coturn）共享密钥，首次启动随机生成（见 TurnCredentials.ensureSecret），
    // 不写死在源码里——这个文件不进 git，跟 pin 一样只留在本机。
    var turnSecret: String = ""

    static let systemSupportDir = URL(fileURLWithPath: "/Library/Application Support/Remoter", isDirectory: true)

    private static let userSupportDir: URL = {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Remoter", isDirectory: true)
        return dir
    }()

    static var activeSupportDir: URL {
        let fm = FileManager.default
        let userConfig = userSupportDir.appendingPathComponent("config.json")
        let systemConfig = systemSupportDir.appendingPathComponent("config.json")
        if isLoginWindowSession() {
            if fm.fileExists(atPath: systemConfig.path) {
                return systemSupportDir
            }
            if !fm.fileExists(atPath: userConfig.path) {
                return systemSupportDir
            }
        }
        if !fm.fileExists(atPath: userConfig.path), fm.fileExists(atPath: systemConfig.path) {
            return systemSupportDir
        }
        try? fm.createDirectory(at: userSupportDir, withIntermediateDirectories: true)
        return userSupportDir
    }

    private static var fileURL: URL {
        activeSupportDir.appendingPathComponent("config.json")
    }

    static func load() -> AgentConfig {
        let fm = FileManager.default
        let primary = fileURL
        if let data = try? Data(contentsOf: primary),
           let cfg = try? JSONDecoder().decode(AgentConfig.self, from: data) {
            return cfg
        }
        let fallback = systemSupportDir.appendingPathComponent("config.json")
        if fallback != primary,
           fm.fileExists(atPath: fallback.path),
           let data = try? Data(contentsOf: fallback),
           let cfg = try? JSONDecoder().decode(AgentConfig.self, from: data) {
            return cfg
        }
        return AgentConfig()
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        let dest = Self.fileURL
        try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: dest, options: .atomic)
    }
}
