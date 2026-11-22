import Foundation

// MARK: - Persisted configuration
//
// Settings live in ~/Library/Application Support/keymirror/config.json so the
// CLI and (Phase 4) the menu-bar app share one source of truth. Resolution
// order everywhere is: explicit CLI flag > environment > config file > default.

struct Config: Codable {
    var role: String?     // "send" | "recv"
    var port: UInt16?
    var secret: String?
    var name: String?     // Bonjour instance name (receiver) / preferred peer (sender)
    var host: String?     // optional fixed host for send (skips auto-discovery)

    static func directory() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("keymirror", isDirectory: true)
    }

    static func fileURL() -> URL {
        directory().appendingPathComponent("config.json")
    }

    static func load() -> Config {
        guard let data = try? Data(contentsOf: fileURL()),
              let cfg = try? JSONDecoder().decode(Config.self, from: data) else {
            return Config()
        }
        return cfg
    }

    func save() throws {
        try FileManager.default.createDirectory(at: Config.directory(),
                                                withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: Config.fileURL(), options: .atomic)
    }
}

/// Default Bonjour / peer name for this machine (its host name, minus .local).
func defaultName() -> String {
    var n = ProcessInfo.processInfo.hostName
    if n.hasSuffix(".local") { n = String(n.dropLast(6)) }
    return n.isEmpty ? "Mac" : n
}
