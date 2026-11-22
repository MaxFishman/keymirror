import Foundation

// MARK: - Engine coordinator
//
// Thin layer over the sender/receiver start/stop functions so a host (the CLI
// or the menu-bar app) can switch roles at runtime. The CLI uses the start
// functions directly and then runs its run loop; the app drives this
// coordinator from menu actions.

enum Role: String {
    case send
    case recv
    case off
}

struct Settings {
    var port: UInt16
    var secret: String
    var name: String
    var host: String?   // send only; nil = auto-discover
}

/// Build runtime settings from persisted config, filling defaults.
func settings(from cfg: Config) -> Settings {
    let secret = (cfg.secret?.isEmpty == false) ? cfg.secret! : defaultSecret
    return Settings(port: cfg.port ?? defaultPort,
                    secret: secret,
                    name: cfg.name ?? defaultName(),
                    host: (cfg.host?.isEmpty == false) ? cfg.host : nil)
}

final class Engine {
    static let shared = Engine()
    private(set) var role: Role = .off

    /// Switch to `role`. Must be called on the main thread (the sender's event
    /// tap attaches to the main run loop). Returns false if the role failed to
    /// start (e.g. missing permission or port in use).
    @discardableResult
    func start(role newRole: Role, settings s: Settings) -> Bool {
        stop()
        role = newRole
        switch newRole {
        case .send:
            return startSender(host: s.host, port: s.port, secret: s.secret, preferName: s.name)
        case .recv:
            return startReceiver(port: s.port, secret: s.secret, name: s.name)
        case .off:
            return true
        }
    }

    func stop() {
        stopSender()
        stopReceiver()
        role = .off
        gStatus.set("role", "-")
        gStatus.set("state", "idle")
    }
}
