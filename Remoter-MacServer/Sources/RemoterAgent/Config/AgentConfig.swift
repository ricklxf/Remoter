import Foundation

// Persisted config — ~/Library/Application Support/Remoter/config.json
// CLI args always take precedence over this file.
struct AgentConfig: Codable {
    var port: UInt16 = 7788
    var pin: String  = ""
    var relayUrl: String = ""
    // TURN（coturn）共享密钥，首次启动随机生成（见 TurnCredentials.ensureSecret），
    // 不写死在源码里——这个文件不进 git，跟 pin 一样只留在本机。
    var turnSecret: String = ""

    private static let fileURL: URL = {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Remoter", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }()

    static func load() -> AgentConfig {
        guard let data = try? Data(contentsOf: fileURL),
              let cfg  = try? JSONDecoder().decode(AgentConfig.self, from: data)
        else { return AgentConfig() }
        return cfg
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: AgentConfig.fileURL, options: .atomic)
    }
}
