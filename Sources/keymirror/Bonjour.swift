import Foundation

// MARK: - Bonjour / mDNS discovery
//
// The receiver advertises a `_keymirror._tcp.` service on the LAN; the sender
// browses for it and resolves an IP + port, so you don't have to type an
// address. Discovery is best-effort: if it finds nothing (e.g. macOS Local
// Network permission not yet granted), you can always fall back to `--host`.
//
// NetService needs a run loop on the thread it's used from. The receiver's main
// thread blocks in accept() and the sender's main thread runs the event tap, so
// each Bonjour object gets its own dedicated thread with its own run loop.

let bonjourType = "_keymirror._tcp."
let bonjourDomain = "local."

/// Extract the first IPv4 dotted-quad from a NetService's resolved addresses.
private func firstIPv4(_ addresses: [Data]?) -> String? {
    guard let addresses = addresses else { return nil }
    for data in addresses {
        let ip: String? = data.withUnsafeBytes { raw -> String? in
            guard let base = raw.baseAddress else { return nil }
            let sa = base.assumingMemoryBound(to: sockaddr.self)
            guard sa.pointee.sa_family == sa_family_t(AF_INET) else { return nil }
            var sin = base.assumingMemoryBound(to: sockaddr_in.self).pointee
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &sin.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
            return String(cString: buf)
        }
        if let ip = ip { return ip }
    }
    return nil
}

// MARK: - Publisher (receiver side)

final class BonjourPublisher: NSObject, NetServiceDelegate {
    private var service: NetService?
    private var runLoop: CFRunLoop?

    func start(name: String, port: UInt16) {
        // Capture self strongly: the thread (and thus this object, the service,
        // and its delegate) must outlive start().
        let thread = Thread {
            self.runLoop = CFRunLoopGetCurrent()
            let svc = NetService(domain: bonjourDomain, type: bonjourType,
                                 name: name, port: Int32(port))
            svc.delegate = self
            svc.schedule(in: RunLoop.current, forMode: .default)
            svc.publish()
            self.service = svc
            CFRunLoopRun()
        }
        thread.name = "keymirror-bonjour-publish"
        thread.start()
    }

    func stop() {
        service?.stop()
        service = nil
        if let rl = runLoop { CFRunLoopStop(rl) }
    }

    func netServiceDidPublish(_ sender: NetService) {
        fputs("📡 advertising on Bonjour as \"\(sender.name)\" (\(bonjourType))\n", stderr)
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        fputs("""
        ⚠️  Bonjour publish failed (\(errorDict)).
            Senders on the LAN won't auto-discover this Mac; they can still use
            --host <this-mac-ip>. On macOS you may need to allow this app under
            System Settings → Privacy & Security → Local Network.

        """, stderr)
    }
}

// MARK: - Peer registry (sender side)

/// Thread-safe store of discovered receivers, keyed by Bonjour instance name.
final class PeerRegistry {
    private let lock = NSLock()
    private var peers: [String: (host: String, port: UInt16)] = [:]
    private let changed = DispatchSemaphore(value: 0)

    /// If set, prefer this peer name; otherwise any discovered peer is used.
    var preferName: String?

    func upsert(name: String, host: String, port: UInt16) {
        lock.lock(); peers[name] = (host, port); lock.unlock()
        changed.signal()
    }

    func drop(name: String) {
        lock.lock(); peers[name] = nil; lock.unlock()
        changed.signal()
    }

    /// Best current target: the preferred name if present, else any peer.
    func best() -> (name: String, host: String, port: UInt16)? {
        lock.lock(); defer { lock.unlock() }
        if let want = preferName, let p = peers[want] { return (want, p.host, p.port) }
        if let (n, p) = peers.first { return (n, p.host, p.port) }
        return nil
    }

    /// All discovered receivers, sorted by name — for the Devices menu.
    func all() -> [(name: String, host: String, port: UInt16)] {
        lock.lock(); defer { lock.unlock() }
        return peers.map { (name: $0.key, host: $0.value.host, port: $0.value.port) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Block up to `timeout` seconds for the peer set to change.
    func waitForChange(timeout: TimeInterval) {
        _ = changed.wait(timeout: .now() + timeout)
    }
}

// MARK: - Browser (sender side)

final class BonjourBrowser: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private let browser = NetServiceBrowser()
    private let registry: PeerRegistry
    private var resolving: Set<NetService> = []   // retain while resolving

    private var runLoop: CFRunLoop?

    init(registry: PeerRegistry) {
        self.registry = registry
    }

    func start() {
        // Capture self strongly — see BonjourPublisher.start for why.
        let thread = Thread {
            self.runLoop = CFRunLoopGetCurrent()
            self.browser.delegate = self
            self.browser.schedule(in: RunLoop.current, forMode: .default)
            self.browser.searchForServices(ofType: bonjourType, inDomain: bonjourDomain)
            CFRunLoopRun()
        }
        thread.name = "keymirror-bonjour-browse"
        thread.start()
    }

    func stop() {
        browser.stop()
        if let rl = runLoop { CFRunLoopStop(rl) }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        resolving.insert(service)
        service.resolve(withTimeout: 5)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        registry.drop(name: service.name)
        fputs("🔍 receiver \"\(service.name)\" went away\n", stderr)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        if let ip = firstIPv4(sender.addresses) {
            registry.upsert(name: sender.name, host: ip, port: UInt16(truncatingIfNeeded: sender.port))
        }
        resolving.remove(sender)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        resolving.remove(sender)
    }
}
