import Foundation

// Persistent token store — ~/Library/Application Support/Remoter/tokens.json
// Format: { "token": "username" } — permanent, no expiry.
final class TokenStore {
    static let shared = TokenStore()

    private let fileURL: URL
    private let queue = DispatchQueue(label: "remoter.tokenstore")

    private init() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Remoter", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("tokens.json")
    }

    func generate(username: String) -> String {
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        queue.sync {
            var tokens = load()
            tokens[token] = username
            save(tokens)
        }
        return token
    }

    func lookup(_ token: String) -> String? {
        queue.sync { load()[token] }
    }

    private func load() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return dict
    }

    private func save(_ tokens: [String: String]) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
