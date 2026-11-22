import Foundation

// MARK: - Status surface
//
// A tiny thread-safe bag of key/value status fields that every part of the
// engine updates (role, state, peer, RTT, counters). It exists so a UI can
// observe the engine without parsing stderr. In Phase 4 the menu-bar app reads
// this object directly; right now `--status-file` can also mirror it to a JSON
// file every second for external tools or debugging.

final class EngineStatus {
    private let lock = NSLock()
    private var d: [String: Any] = [
        "role": "-",
        "state": "idle",
        "peer": "-",
        "rttMs": -1,
        "keysSent": 0,
        "keysInjected": 0,
        "paused": false,
    ]

    func set(_ key: String, _ value: Any) {
        lock.lock(); d[key] = value; lock.unlock()
    }

    func inc(_ key: String) {
        lock.lock(); d[key] = ((d[key] as? Int) ?? 0) + 1; lock.unlock()
    }

    func snapshot() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }; return d
    }

    func json() -> Data {
        let snap = snapshot()
        return (try? JSONSerialization.data(withJSONObject: snap,
                                            options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }
}

/// Shared engine status, updated by both roles.
let gStatus = EngineStatus()

private var gStatusTimer: DispatchSourceTimer?

/// Begin mirroring status to `path` as JSON once per second.
func startStatusFileWriter(path: String) {
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
    timer.schedule(deadline: .now() + 1, repeating: 1.0)
    timer.setEventHandler {
        gStatus.set("paused", gPaused)
        try? gStatus.json().write(to: url, options: .atomic)
    }
    timer.resume()
    gStatusTimer = timer
    fputs("🗎 writing status JSON to \(url.path) every 1s\n", stderr)
}
