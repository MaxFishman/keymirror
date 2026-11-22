import Foundation
import CoreGraphics
import ApplicationServices

// MARK: - Sender role (the "primary" / controlling Mac)
//
// Installs a *passive* (listen-only) session-level event tap so it sees every
// key-down / key-up system-wide, regardless of which app is focused, without
// swallowing them — so local playback on this Mac still responds normally.
// Matching keys are framed and written to the TCP link.
//
// Threads:
//   • main thread — event-tap run loop (captures keys) + Carbon pause hotkey
//   • connection thread — connect → authenticate → read PONGs → reconnect
//   • ping timer (GCD) — sends PING every 1s, tracks RTT, resets a stale link
// All socket writes funnel through LinkManager, which serializes them under a
// lock, so the three threads never corrupt a frame.

/// Thread-safe owner of the current connection's fd + link stats.
final class LinkManager {
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var _connected = false
    private var _lastPongUptime: UInt64 = 0
    private var _lastRTTms: Double = -1

    /// Called by the connection thread once authenticated.
    func install(_ newFD: Int32) {
        lock.lock()
        fd = newFD
        _connected = true
        _lastPongUptime = DispatchTime.now().uptimeNanoseconds
        lock.unlock()
    }

    /// Serialized write of one framed message. False if the link is down.
    @discardableResult
    func send(_ bytes: [UInt8]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard _connected, fd >= 0 else { return false }
        var b = bytes
        return writeAll(fd, &b, b.count)
    }

    /// Connection thread calls this when its read loop ends; it then closes the
    /// returned fd exactly once (sole owner of close()).
    func take() -> Int32 {
        lock.lock(); defer { lock.unlock() }
        let old = fd
        fd = -1
        _connected = false
        return old
    }

    /// Ping timer calls this to unblock a stuck read without closing the fd
    /// (shutdown is safe to call from another thread; close is not).
    func forceReset() {
        lock.lock(); let cur = _connected ? fd : -1; lock.unlock()
        if cur >= 0 { shutdown(cur, SHUT_RDWR) }
    }

    func markPong(rttMs: Double) {
        lock.lock()
        _lastRTTms = rttMs
        _lastPongUptime = DispatchTime.now().uptimeNanoseconds
        lock.unlock()
    }

    func isConnected() -> Bool { lock.lock(); defer { lock.unlock() }; return _connected }
    func rttMs() -> Double { lock.lock(); defer { lock.unlock() }; return _lastRTTms }

    func secondsSincePong() -> Double {
        lock.lock(); defer { lock.unlock() }
        let now = DispatchTime.now().uptimeNanoseconds
        return Double(now &- _lastPongUptime) / 1e9
    }
}

/// Minimal thread-safe boolean, used as the sender's run flag.
final class AtomicBool {
    private let lock = NSLock()
    private var v: Bool
    init(_ initial: Bool) { v = initial }
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return v }
        set { lock.lock(); v = newValue; lock.unlock() }
    }
}

// Globals referenced from the C event-tap callback (which cannot capture Swift
// context) and shared across the sender's threads.
let gLink = LinkManager()
let gSenderRunning = AtomicBool(false)
/// Discovered receivers (set while the sender is auto-discovering); read by the
/// Devices menu. Nil when a fixed --host is used or the sender is off.
var gSenderRegistry: PeerRegistry?
private var gTap: CFMachPort?
private var gTapSource: CFRunLoopSource?
private var gPingTimer: DispatchSourceTimer?
private var gBrowser: BonjourBrowser?

private let tapCallback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = gTap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }

    let keycode = event.getIntegerValueField(.keyboardEventKeycode)
    if keysOfInterest.contains(keycode) && !gPaused {
        let down: UInt8 = (type == .keyDown) ? 1 : 0
        let isRepeat: UInt8 = event.getIntegerValueField(.keyboardEventAutorepeat) != 0 ? 1 : 0
        let frame: [UInt8] = [msgKey, UInt8(truncatingIfNeeded: keycode), down, isRepeat]
        let ok = gLink.send(frame)
        let tag = down == 1 ? (isRepeat == 1 ? "↻" : "▼") : "▲"
        let line = ok ? "  \(tag) \(keyName(keycode))\n"
                      : "  ✗ link down — dropped \(keyName(keycode))\n"
        FileHandle.standardError.write(Data(line.utf8))
        if ok {
            gStatus.inc("keysSent")
            gStatus.set("lastKey", "\(tag) \(keyName(keycode))")
        }
    }
    // Listen-only: return value is ignored, but pass the event through.
    return Unmanaged.passUnretained(event)
}

/// Resolve the target endpoint: a fixed --host, or wait for Bonjour discovery.
/// Returns nil if the sender is stopped while waiting.
private func resolveTarget(hostOpt: String?, port: UInt16,
                           registry: PeerRegistry?) -> (host: String, port: UInt16)? {
    if let h = hostOpt { return (h, port) }
    let reg = registry!   // auto mode always has a registry
    var waited = 0
    while gSenderRunning.value {
        if let best = reg.best() {
            fputs("🔍 found receiver \"\(best.name)\" at \(best.host):\(best.port)\n", stderr)
            return (best.host, best.port)
        }
        if waited % 6 == 0 {
            fputs("""
            🔍 searching for a keymirror receiver on the LAN…
               (make sure the receiver is running; or restart with --host <ip>.
                macOS may prompt your terminal for Local Network access.)
            """, stderr)
        }
        gStatus.set("state", "searching")
        reg.waitForChange(timeout: 3)
        waited += 3
    }
    return nil
}

/// Connection thread: resolve target, connect, authenticate, consume PONGs,
/// reconnect until stopped.
private func senderConnectionLoop(hostOpt: String?, port: UInt16, secret: String,
                                  myName: String, registry: PeerRegistry?) {
    var backoff: UInt32 = 1
    while gSenderRunning.value {
        guard let target = resolveTarget(hostOpt: hostOpt, port: port, registry: registry) else { break }
        gStatus.set("state", "connecting")
        gStatus.set("peer", "\(target.host):\(target.port)")
        do {
            let fd = try connectTCP(host: target.host, port: target.port)
            setRecvTimeout(fd, seconds: 5)          // bound the handshake
            try clientHandshake(fd: fd, secret: secret)
            let peerName = exchangeHello(fd: fd, myName: myName) ?? target.host
            gStatus.set("peerName", peerName)
            setRecvTimeout(fd, seconds: 0)          // blocking reads afterwards
            gLink.install(fd)
            backoff = 1
            gStatus.set("state", "connected")
            fputs("✓ connected to \"\(peerName)\" (\(target.host):\(target.port))\n", stderr)

            // Read PONGs until the link drops.
            var type = [UInt8](repeating: 0, count: 1)
            readLoop: while true {
                if readFull(fd, &type, 1) != .ok { break readLoop }
                if type[0] == msgPong {
                    var ts = [UInt8](repeating: 0, count: 8)
                    if readFull(fd, &ts, 8) != .ok { break readLoop }
                    let sent = unpackU64BE(ts)
                    let now = DispatchTime.now().uptimeNanoseconds
                    gLink.markPong(rttMs: Double(now &- sent) / 1e6)
                } else {
                    break readLoop  // unexpected frame — reset the link
                }
            }
            let old = gLink.take()
            if old >= 0 { close(old) }
            gStatus.set("state", "reconnecting")
            gStatus.set("rttMs", -1)
            gStatus.set("peerName", "-")
            fputs("… link down — reconnecting\n", stderr)
        } catch {
            gStatus.set("state", "reconnecting")
            fputs("   \(error) — retry in \(backoff)s\n", stderr)
            sleep(backoff)
            backoff = min(backoff * 2, 5)
        }
    }
    gStatus.set("state", "idle")
}

/// Whether the current process is trusted for Accessibility (key capture/post).
func isTrustedForAccessibility(prompt: Bool) -> Bool {
    AXIsProcessTrustedWithOptions(
        [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): prompt] as CFDictionary)
}

/// Start the sender engine. MUST be called on the main thread (the event tap is
/// added to the main run loop). Non-blocking. Returns false if the tap could not
/// be created (almost always a missing permission). The host run loop
/// (CFRunLoopRun for the CLI, NSApp.run for the app) keeps it alive.
@discardableResult
func startSender(host: String?, port: UInt16, secret: String, preferName: String?) -> Bool {
    gStatus.set("role", "send")
    gStatus.set("state", "starting")
    gSenderRunning.value = true

    _ = isTrustedForAccessibility(prompt: true)
    installPauseControls()

    // Install the passive tap on the MAIN run loop.
    let mask: CGEventMask =
        (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
    guard let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .listenOnly,
        eventsOfInterest: mask,
        callback: tapCallback,
        userInfo: nil
    ) else {
        gSenderRunning.value = false
        gStatus.set("state", "no-permission")
        fputs("""
        ✗ Failed to create event tap. This almost always means Accessibility /
          Input Monitoring permission is not granted yet.
        """, stderr)
        return false
    }
    gTap = tap
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    gTapSource = source
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)

    let myName = preferName ?? defaultName()

    // Auto-discovery when no fixed host is given.
    var registry: PeerRegistry? = nil
    if host == nil {
        let reg = PeerRegistry()
        reg.preferName = preferName
        gBrowser = BonjourBrowser(registry: reg)
        gBrowser?.start()
        registry = reg
        gSenderRegistry = reg
        fputs("🔍 no host set — auto-discovering a receiver via Bonjour…\n", stderr)
    }

    // Background connection/reconnection thread.
    Thread.detachNewThread {
        senderConnectionLoop(hostOpt: host, port: port, secret: secret,
                             myName: myName, registry: registry)
    }

    // Heartbeat / latency timer (PING every 1s).
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
    timer.schedule(deadline: .now() + 1, repeating: 1.0)
    var pingCount = 0
    timer.setEventHandler {
        guard gSenderRunning.value, gLink.isConnected() else { return }
        let ts = DispatchTime.now().uptimeNanoseconds
        gLink.send([msgPing] + packU64BE(ts))

        if gLink.secondsSincePong() > 3.5 {
            fputs("⚠ no PONG in >3.5s — resetting link\n", stderr)
            gLink.forceReset()
            return
        }
        gStatus.set("rttMs", gLink.rttMs())
        pingCount += 1
        if pingCount % 5 == 0 {
            let rtt = gLink.rttMs()
            if rtt >= 0 {
                let suffix = gPaused ? "  (paused)" : ""
                fputs(String(format: "● link up — RTT %.2f ms%@\n", rtt, suffix), stderr)
            }
        }
    }
    timer.resume()
    gPingTimer = timer

    let dest = host.map { "\($0):\(port)" } ?? "auto-discovered receiver"
    fputs("● mirroring  ← → ↑ ↓ space  → \(dest)\n", stderr)
    return true
}

/// Stop the sender engine and tear everything down. Safe to call on the main
/// thread; blocks only briefly while threads notice the run flag.
func stopSender() {
    guard gSenderRunning.value else { return }
    gSenderRunning.value = false

    gPingTimer?.cancel()
    gPingTimer = nil

    if let tap = gTap { CGEvent.tapEnable(tap: tap, enable: false) }
    if let source = gTapSource {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
    }
    gTap = nil
    gTapSource = nil

    // Unblock the connection thread's read, and drop any live link.
    gLink.forceReset()
    let old = gLink.take()
    if old >= 0 { close(old) }

    gBrowser?.stop()
    gBrowser = nil
    gSenderRegistry = nil

    gStatus.set("state", "idle")
    gStatus.set("rttMs", -1)
    gStatus.set("peer", "-")
    gStatus.set("peerName", "-")
}
