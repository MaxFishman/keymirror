import Foundation

// keymirror — Phase 3
// Mirror ← → ↑ ↓ space from a primary Mac to a redundant Mac over the LAN, with
// shared-secret auth, heartbeat/latency, auto-reconnect, pause, Bonjour
// auto-discovery, persisted config, and a status surface.
//
//   keymirror recv [--port 52525] [--secret <s>] [--name <n>] [--status-file <p>]
//   keymirror send [--host <ip>] [--port 52525] [--secret <s>] [--name <n>] [--status-file <p>]
//   keymirror config show
//   keymirror config set [--role recv|send] [--port n] [--secret s] [--name n] [--host ip]
//
// Resolution order for every setting: explicit flag > environment > config file
// > built-in default.

let defaultPort: UInt16 = 52525
let defaultSecret = "keymirror-default-secret"

func usage() -> Never {
    fputs("""
    keymirror — mirror arrow keys + space to a second Mac (Phase 3)

    USAGE:
      keymirror recv [options]
          Run on the REDUNDANT Mac. Advertises itself via Bonjour, authenticates
          the sender, and injects keys into the currently-focused app.

      keymirror send [options]
          Run on the PRIMARY Mac. Captures ← → ↑ ↓ space system-wide and
          forwards them. With no --host, auto-discovers the receiver via Bonjour.

      keymirror config show
      keymirror config set [--role ...] [--port ...] [--secret ...] [--name ...] [--host ...]
          View or persist defaults in ~/Library/Application Support/keymirror/config.json

    OPTIONS:
      --host <ip>        Receiver address (send). Omit to auto-discover.
      --port <n>         TCP port (default \(defaultPort)); auto-discovery uses the advertised port.
      --secret <s>       Shared secret; must match on both Macs (or $KEYMIRROR_SECRET).
      --name <n>         Bonjour name to advertise (recv) / prefer (send). Default: host name.
      --status-file <p>  Write live status JSON to this path every second.

    PAUSE (sender): ⌃⌥⌘P toggles forwarding, or `kill -USR1 <pid>`.

    EXAMPLE (zero-config discovery):
      # redundant Mac:
      keymirror recv --secret hunter2
      # primary Mac (finds the receiver automatically):
      keymirror send --secret hunter2

    """, stderr)
    exit(2)
}

func parseOption(_ args: [String], _ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

/// Resolve the shared secret: --secret, then env, then config, then default.
func resolveSecret(_ args: [String], _ cfg: Config) -> String {
    if let s = parseOption(args, "--secret"), !s.isEmpty { return s }
    if let s = ProcessInfo.processInfo.environment["KEYMIRROR_SECRET"], !s.isEmpty { return s }
    if let s = cfg.secret, !s.isEmpty { return s }
    fputs("""
    ⚠️  No --secret / KEYMIRROR_SECRET / config secret set — using the built-in
        default. Anyone on your LAN running this tool could connect. Set a shared
        secret (same value on both Macs) for real use.

    """, stderr)
    return defaultSecret
}

let args = Array(CommandLine.arguments.dropFirst())
let cfg = Config.load()

// No subcommand (e.g. the .app bundle was opened) → run the menu-bar app.
// A leading option (-psn_… from LaunchServices, or any --flag) also means app.
let cliCommands: Set<String> = ["recv", "receive", "receiver", "send", "sender",
                                "config", "-h", "--help", "help"]
guard let role = args.first, cliCommands.contains(role) else {
    runApp()
}

// Shared resolved options (flag > config > default).
let port: UInt16 = {
    if let s = parseOption(args, "--port"), let p = UInt16(s) { return p }
    return cfg.port ?? defaultPort
}()
let name: String = parseOption(args, "--name") ?? cfg.name ?? defaultName()
let statusFile: String? = parseOption(args, "--status-file")

if let path = statusFile { startStatusFileWriter(path: path) }

switch role {
case "config":
    let sub = args.count > 1 ? args[1] : "show"
    switch sub {
    case "show":
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = (try? enc.encode(cfg)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        print(json)
        print("(file: \(Config.fileURL().path))")
        exit(0)
    case "set":
        var next = cfg
        if let r = parseOption(args, "--role") { next.role = r }
        if let p = parseOption(args, "--port"), let pp = UInt16(p) { next.port = pp }
        if let s = parseOption(args, "--secret") { next.secret = s }
        if let n = parseOption(args, "--name") { next.name = n }
        if let h = parseOption(args, "--host") { next.host = h }
        do {
            try next.save()
            fputs("✓ saved \(Config.fileURL().path)\n", stderr)
        } catch {
            fputs("✗ could not save config: \(error)\n", stderr)
            exit(1)
        }
        exit(0)
    default:
        fputs("✗ unknown config subcommand: \(sub)  (use: show | set)\n", stderr)
        exit(2)
    }

case "recv", "receive", "receiver":
    if !startReceiver(port: port, secret: resolveSecret(args, cfg), name: name) {
        exit(1)
    }
    fputs("  (Ctrl-C to stop)\n", stderr)
    CFRunLoopRun()

case "send", "sender":
    // --host explicit, else config host, else nil → auto-discover.
    let host = parseOption(args, "--host") ?? cfg.host
    if !startSender(host: host, port: port, secret: resolveSecret(args, cfg), preferName: name) {
        fputs("""
          Grant your terminal Accessibility + Input Monitoring, then re-run.
        """, stderr)
        exit(1)
    }
    fputs("  (Ctrl-C to stop)\n", stderr)
    CFRunLoopRun()

case "-h", "--help", "help":
    usage()

default:
    fputs("✗ unknown role: \(role)\n\n", stderr)
    usage()
}
