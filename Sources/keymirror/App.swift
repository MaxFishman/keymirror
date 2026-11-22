import Cocoa
import ServiceManagement
import ApplicationServices

// MARK: - Menu-bar app
//
// The same binary, when launched without a CLI subcommand (e.g. by opening the
// .app bundle), runs as a menu-bar agent. It drives the Engine coordinator:
// pick a mode (Off / Sender / Receiver) and it starts the matching role, shows
// live status + latency, lets you pause, edit the shared secret, grant
// permissions, and launch at login.

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var refreshTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "⌨"
        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu()

        // Restore the last role from config, if one was set.
        let cfg = Config.load()
        if let r = cfg.role, let role = Role(rawValue: r), role != .off {
            _ = Engine.shared.start(role: role, settings: settings(from: cfg))
        }

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }
        refreshStatus()

        // Auto-update: rebuild the menu when a new version is found, check now,
        // then re-check every 6 hours.
        Updater.shared.onStateChange = { [weak self] in self?.rebuildMenu() }
        Updater.shared.check()
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            Updater.shared.check()
        }
    }

    // MARK: Status rendering

    private func refreshStatus() {
        let s = gStatus.snapshot()
        let state = (s["state"] as? String) ?? "idle"
        let dot: String
        switch state {
        case "connected":                                   dot = "🟢"
        case "listening", "searching", "connecting",
             "reconnecting", "starting":                    dot = "🟡"
        case "error", "no-permission":                      dot = "🔴"
        default:                                            dot = ""
        }
        statusItem.button?.title = "⌨\(dot)"

        let role = Engine.shared.role
        let roleName = role == .send ? "Sender" : role == .recv ? "Receiver" : "Off"
        var tip = "keymirror — \(roleName) · \(state)"
        if let rtt = s["rttMs"] as? Double, rtt >= 0 {
            tip += String(format: " · %.1f ms", rtt)
        }
        statusItem.button?.toolTip = tip
    }

    // MARK: Menu

    func menuWillOpen(_ menu: NSMenu) { rebuildMenu() }

    private func rebuildMenu() {
        menu.removeAllItems()
        let s = gStatus.snapshot()
        let role = Engine.shared.role

        // Header: live status lines (disabled items).
        let state = (s["state"] as? String) ?? "idle"
        add(header: "keymirror \(Updater.shared.currentVersion())")
        add(info: "State:  \(state)")
        if let rtt = s["rttMs"] as? Double, rtt >= 0 {
            add(info: String(format: "Latency: %.2f ms", rtt))
        }
        if role == .send, let sent = s["keysSent"] as? Int, sent > 0 {
            add(info: "Keys sent: \(sent)")
        }
        if role == .recv, let inj = s["keysInjected"] as? Int, inj > 0 {
            add(info: "Keys injected: \(inj)")
        }

        // Devices.
        menu.addItem(.separator())
        add(info: "Devices")
        add(info: "   This Mac — \(settings(from: Config.load()).name)")
        addDeviceRows(role: role, status: s, state: state)
        menu.addItem(.separator())

        // Mode selection (radio-style checkmarks).
        add(toggle: "Off",      on: role == .off,  action: #selector(setOff))
        add(toggle: "Sender — this Mac controls the other",
            on: role == .send, action: #selector(setSender))
        add(toggle: "Receiver — this Mac is controlled",
            on: role == .recv, action: #selector(setReceiver))

        // Pause (sender only).
        if role == .send {
            add(toggle: "Pause forwarding  (⌃⌥⌘P)", on: gPaused, action: #selector(togglePause))
        }
        menu.addItem(.separator())

        // Permissions — a prominent fix item when something's missing, plus a
        // submenu with live status and one-click grants. For Off, show what
        // both roles need so you can pre-grant.
        let missing = missingPermissions(for: role == .off ? .send : role)
        if !missing.isEmpty {
            let fix = NSMenuItem(title: "⚠️ Fix permissions: \(missing.joined(separator: ", "))…",
                                 action: #selector(fixAllPermissions), keyEquivalent: "")
            fix.target = self
            menu.addItem(fix)
        }
        let permItem = NSMenuItem(title: "Permissions", action: nil, keyEquivalent: "")
        permItem.submenu = buildPermissionsSubmenu(role: role)
        menu.addItem(permItem)
        menu.addItem(.separator())

        // Preferences + login.
        let prefs = NSMenuItem(title: "Preferences…", action: #selector(showPreferences), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)

        add(toggle: "Launch at Login", on: launchAtLoginEnabled(), action: #selector(toggleLaunchAtLogin))

        // Updates.
        if let rel = Updater.shared.available {
            let item = NSMenuItem(title: "⬆ Install update \(rel.version)…",
                                  action: #selector(installUpdate), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        } else {
            let item = NSMenuItem(title: "Check for Updates…",
                                  action: #selector(checkForUpdates), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit keymirror", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func add(header title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        let font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        item.attributedTitle = NSAttributedString(string: title, attributes: [.font: font])
        menu.addItem(item)
    }

    private func add(info title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func add(toggle title: String, on: Bool, action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
        menu.addItem(item)
    }

    /// Device rows: ● = connected, ○ = available/idle.
    private func addDeviceRows(role: Role, status s: [String: Any], state: String) {
        let peer = (s["peer"] as? String) ?? "-"
        let peerName = (s["peerName"] as? String) ?? "-"
        let connected = state == "connected"
        let label = peerName != "-" ? peerName : (peer != "-" ? peer : "receiver")

        switch role {
        case .off:
            add(info: "   (choose Sender or Receiver below)")
        case .recv:
            add(info: connected ? "   ● \(label) — sender" : "   ○ waiting for a sender…")
        case .send:
            if let devices = gSenderRegistry?.all() {   // auto-discovery mode
                if devices.isEmpty {
                    add(info: connected ? "   ● \(label) — receiver" : "   ○ searching for receivers…")
                } else {
                    for d in devices {
                        let isConn = connected && peer.hasPrefix(d.host + ":")
                        add(info: "   \(isConn ? "●" : "○") \(d.name) — \(d.host)")
                    }
                }
            } else {                                     // fixed host, no discovery
                add(info: connected ? "   ● \(label) — receiver" : "   ○ connecting…")
            }
        }
    }

    // MARK: Mode actions

    private func startRole(_ role: Role) {
        var cfg = Config.load()
        cfg.role = role.rawValue
        try? cfg.save()
        if role == .off {
            Engine.shared.stop()
        } else {
            let ok = Engine.shared.start(role: role, settings: settings(from: cfg))
            if !ok { notifyStartFailure(role) }
        }
        rebuildMenu()
        refreshStatus()
    }

    @objc private func setOff()      { startRole(.off) }
    @objc private func setSender()   { startRole(.send) }
    @objc private func setReceiver() { startRole(.recv) }

    @objc private func togglePause() {
        gPaused.toggle()
        rebuildMenu()
    }

    private func notifyStartFailure(_ role: Role) {
        let alert = NSAlert()
        alert.messageText = "Couldn't start \(role == .send ? "Sender" : "Receiver")"
        alert.informativeText = role == .send
            ? "Grant Accessibility and Input Monitoring permission, then try again."
            : "The port may be in use, or Accessibility permission is missing."
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: Permissions

    private func buildPermissionsSubmenu(role: Role) -> NSMenu {
        let m = NSMenu()

        let ax = accessibilityState()
        let axItem = NSMenuItem(
            title: "\(permGlyph(ax)) Accessibility\(ax == .granted ? "  (granted)" : " — click to grant")",
            action: #selector(fixAccessibility), keyEquivalent: "")
        axItem.target = self
        m.addItem(axItem)

        let im = inputMonitoringState()
        let imItem = NSMenuItem(
            title: "\(permGlyph(im)) Input Monitoring\(im == .granted ? "  (granted)" : " — sender only · click to grant")",
            action: #selector(fixInputMonitoring), keyEquivalent: "")
        imItem.target = self
        m.addItem(imItem)

        let lnItem = NSMenuItem(title: "📡 Local Network — open settings…",
                                action: #selector(fixLocalNetwork), keyEquivalent: "")
        lnItem.target = self
        m.addItem(lnItem)

        m.addItem(.separator())
        let all = NSMenuItem(title: "Grant everything needed…",
                             action: #selector(fixAllPermissions), keyEquivalent: "")
        all.target = self
        m.addItem(all)
        return m
    }

    @objc private func fixAccessibility() { promptAccessibility(); openAccessibilityPane() }
    @objc private func fixInputMonitoring() { promptInputMonitoring(); openInputMonitoringPane() }
    @objc private func fixLocalNetwork() { openLocalNetworkPane() }

    @objc private func fixAllPermissions() {
        promptAccessibility()
        promptInputMonitoring()
        openAccessibilityPane()
    }

    // MARK: Preferences

    @objc private func showPreferences() {
        let cfg = Config.load()
        let alert = NSAlert()
        alert.messageText = "keymirror Preferences"
        alert.informativeText = "The shared secret must match on both Macs.\nLeave Host blank to auto-discover the receiver."

        let width: CGFloat = 320
        let rowH: CGFloat = 26
        let labels = ["Shared secret:", "This Mac's name:", "Host (send, optional):", "Port:"]
        let values = [cfg.secret ?? "", cfg.name ?? defaultName(), cfg.host ?? "",
                      String(cfg.port ?? defaultPort)]
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: rowH * CGFloat(labels.count) + 8))
        var fields: [NSTextField] = []
        for (i, label) in labels.enumerated() {
            let y = container.frame.height - CGFloat(i + 1) * rowH
            let l = NSTextField(labelWithString: label)
            l.frame = NSRect(x: 0, y: y, width: 150, height: 20)
            l.alignment = .right
            container.addSubview(l)
            let f = NSTextField(frame: NSRect(x: 158, y: y - 2, width: width - 158, height: 22))
            f.stringValue = values[i]
            container.addSubview(f)
            fields.append(f)
        }
        alert.accessoryView = container
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var next = cfg
        next.secret = fields[0].stringValue
        next.name = fields[1].stringValue.isEmpty ? nil : fields[1].stringValue
        next.host = fields[2].stringValue.isEmpty ? nil : fields[2].stringValue
        next.port = UInt16(fields[3].stringValue) ?? cfg.port ?? defaultPort
        try? next.save()

        // Apply immediately if a role is running.
        let role = Engine.shared.role
        if role != .off {
            _ = Engine.shared.start(role: role, settings: settings(from: next))
        }
        rebuildMenu()
    }

    // MARK: Launch at login

    private func launchAtLoginEnabled() -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    @objc private func toggleLaunchAtLogin() {
        if #available(macOS 13.0, *) {
            do {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                } else {
                    try SMAppService.mainApp.register()
                }
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn't change Launch at Login"
                alert.informativeText = "\(error.localizedDescription)"
                alert.runModal()
            }
        }
        rebuildMenu()
    }

    @objc private func checkForUpdates() { Updater.shared.check(userInitiated: true) }

    @objc private func installUpdate() {
        if let rel = Updater.shared.available { Updater.shared.promptInstall(rel) }
    }

    @objc private func quit() {
        Engine.shared.stop()
        NSApp.terminate(nil)
    }
}

/// Entry point for menu-bar mode (no CLI subcommand given).
func runApp() -> Never {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)   // menu-bar agent, no Dock icon
    app.run()
    exit(0)
}
