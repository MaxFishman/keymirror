import Cocoa

// MARK: - In-app auto-update
//
// Checks the project's GitHub Releases for a newer version, then downloads the
// KeyMirror.zip asset, swaps the running app bundle in place, and relaunches.
// No third-party framework — just the GitHub REST API + ditto.
//
// NOTE (ad-hoc signing): because each build is ad-hoc signed with a different
// identity, macOS treats an updated build as a "new" app and will re-prompt for
// Accessibility / Input Monitoring after an update. Switching to a stable
// Developer ID signature later makes updates seamless; nothing else here
// changes. See README.

let updateRepoSlug = "MaxFishman/keymirror"

struct ReleaseInfo {
    let version: String   // normalized, e.g. "0.5.0"
    let tag: String       // raw tag, e.g. "v0.5.0"
    let zipURL: URL
    let pageURL: URL
    let notes: String
}

final class Updater {
    static let shared = Updater()

    /// Set when a newer release is found; drives the menu.
    private(set) var available: ReleaseInfo?
    /// Called on the main thread whenever `available` changes.
    var onStateChange: (() -> Void)?

    func currentVersion() -> String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }

    // MARK: Checking

    /// Check in the background. If `userInitiated`, show an alert either way.
    func check(userInitiated: Bool = false) {
        DispatchQueue.global().async {
            guard let latest = self.fetchLatest() else {
                if userInitiated {
                    DispatchQueue.main.async { self.alert("Couldn't check for updates",
                        "Make sure you're online and the repository has a published release.") }
                }
                return
            }
            let newer = self.isNewer(latest.version, than: self.currentVersion())
            DispatchQueue.main.async {
                self.available = newer ? latest : nil
                self.onStateChange?()
                if userInitiated {
                    if newer { self.promptInstall(latest) }
                    else { self.alert("You're up to date",
                        "keymirror \(self.currentVersion()) is the latest version.") }
                }
            }
        }
    }

    private func fetchLatest() -> ReleaseInfo? {
        let url = URL(string: "https://api.github.com/repos/\(updateRepoSlug)/releases/latest")!
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("keymirror-updater", forHTTPHeaderField: "User-Agent")  // GitHub requires a UA

        let sem = DispatchSemaphore(value: 0)
        var result: Data?
        URLSession.shared.dataTask(with: req) { data, _, _ in
            result = data; sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 20)

        guard let data = result,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]] else { return nil }

        // Prefer a .zip asset; that's what the release pipeline uploads.
        let zip = assets.first { ($0["name"] as? String)?.hasSuffix(".zip") == true }
        guard let zipStr = zip?["browser_download_url"] as? String,
              let zipURL = URL(string: zipStr) else { return nil }

        let pageStr = (json["html_url"] as? String) ?? "https://github.com/\(updateRepoSlug)/releases"
        return ReleaseInfo(
            version: normalize(tag),
            tag: tag,
            zipURL: zipURL,
            pageURL: URL(string: pageStr)!,
            notes: (json["body"] as? String) ?? "")
    }

    // MARK: Version comparison

    private func normalize(_ v: String) -> String {
        v.hasPrefix("v") ? String(v.dropFirst()) : v
    }

    /// True if `a` is a strictly newer semantic version than `b`.
    func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0) ?? 0 } }
        let pa = parts(a), pb = parts(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: Installing

    func promptInstall(_ rel: ReleaseInfo) {
        let alert = NSAlert()
        alert.messageText = "Update available — keymirror \(rel.version)"
        var info = "You have \(currentVersion()). Install \(rel.version) now?\n\n"
            + "keymirror will quit, update itself, and relaunch."
        if !rel.notes.isEmpty {
            info += "\n\nWhat's new:\n" + rel.notes.prefix(500)
        }
        info += "\n\nNote: after updating you may need to re-grant Accessibility / "
            + "Input Monitoring (a limitation of ad-hoc signing)."
        alert.informativeText = info
        alert.addButton(withTitle: "Install & Relaunch")
        alert.addButton(withTitle: "View on GitHub")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:  downloadAndInstall(rel)
        case .alertSecondButtonReturn: NSWorkspace.shared.open(rel.pageURL)
        default: break
        }
    }

    private func downloadAndInstall(_ rel: ReleaseInfo) {
        let bundlePath = Bundle.main.bundlePath
        guard bundlePath.hasSuffix(".app") else {
            alert("Can't self-update", "This doesn't look like it's running from an .app bundle. "
                + "Download the update manually from GitHub.")
            NSWorkspace.shared.open(rel.pageURL)
            return
        }

        DispatchQueue.global().async {
            let work = NSTemporaryDirectory() + "keymirror-update-\(rel.version)"
            let fm = FileManager.default
            try? fm.removeItem(atPath: work)
            try? fm.createDirectory(atPath: work, withIntermediateDirectories: true)

            let zipPath = work + "/KeyMirror.zip"
            // Download the zip.
            guard let data = try? Data(contentsOf: rel.zipURL) else {
                DispatchQueue.main.async { self.alert("Download failed",
                    "Couldn't download the update. Try again, or get it from GitHub.") }
                return
            }
            try? data.write(to: URL(fileURLWithPath: zipPath))

            // Extract with ditto.
            let extractDir = work + "/extracted"
            guard self.run("/usr/bin/ditto", ["-x", "-k", zipPath, extractDir]) else {
                DispatchQueue.main.async { self.alert("Update failed", "Couldn't unpack the update.") }
                return
            }
            // Find the extracted .app.
            let newApp = (try? fm.contentsOfDirectory(atPath: extractDir))?
                .first { $0.hasSuffix(".app") }
                .map { extractDir + "/" + $0 }
            guard let newAppPath = newApp else {
                DispatchQueue.main.async { self.alert("Update failed", "The update didn't contain an app.") }
                return
            }
            _ = self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newAppPath])

            // A detached helper waits for us to quit, swaps the bundle, relaunches.
            let pid = getpid()
            let helper = work + "/swap.sh"
            let script = """
            #!/bin/sh
            while kill -0 \(pid) 2>/dev/null; do sleep 0.3; done
            /bin/rm -rf "\(bundlePath)"
            /usr/bin/ditto "\(newAppPath)" "\(bundlePath)"
            /usr/bin/xattr -dr com.apple.quarantine "\(bundlePath)" 2>/dev/null
            /usr/bin/open "\(bundlePath)"
            """
            try? script.write(toFile: helper, atomically: true, encoding: .utf8)
            _ = self.run("/bin/chmod", ["+x", helper])

            DispatchQueue.main.async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/sh")
                p.arguments = [helper]
                try? p.run()   // detached; keeps running after we quit
                Engine.shared.stop()
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: Helpers

    @discardableResult
    private func run(_ path: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 }
        catch { return false }
    }

    private func alert(_ title: String, _ body: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = body
        a.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}
