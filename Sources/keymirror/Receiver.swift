import Foundation
import CoreGraphics
import ApplicationServices

// MARK: - Receiver role (the "redundant" Mac)
//
// Listens for the sender, authenticates it, then synthesizes each incoming KEY
// with CGEvent + post(). The OS delivers the synthetic key to whatever app is
// focused on THIS Mac (your playback software) — our process never needs focus.
// Posting synthetic keys requires Accessibility permission.
//
// Single-threaded per connection: one accept → handshake → read loop. PINGs are
// echoed as PONGs on the same thread, so no locking is needed here.

private let eventSource = CGEventSource(stateID: .hidSystemState)
private var gPublisher: BonjourPublisher?
private var gListenFD: Int32 = -1
let gReceiverRunning = AtomicBool(false)

private func inject(keycode: Int64, down: Bool, isRepeat: Bool) {
    guard let e = CGEvent(keyboardEventSource: eventSource,
                          virtualKey: CGKeyCode(keycode),
                          keyDown: down) else { return }
    if isRepeat { e.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
    e.post(tap: .cghidEventTap)
}

/// Handle one authenticated connection until it drops.
private func serveConnection(_ fd: Int32) {
    // Sender PINGs every 1s; if we see nothing for 3s the sender is gone.
    setRecvTimeout(fd, seconds: 3)

    var type = [UInt8](repeating: 0, count: 1)
    loop: while gReceiverRunning.value {
        switch readFull(fd, &type, 1) {
        case .ok:
            break
        case .timeout:
            // No data within the window. If we're stopping, exit quietly;
            // otherwise the sender is gone.
            if !gReceiverRunning.value { break loop }
            fputs("… no data for 3s — assuming sender gone\n", stderr)
            break loop
        case .closed, .failed:
            break loop
        }

        switch type[0] {
        case msgKey:
            var body = [UInt8](repeating: 0, count: 3)
            guard readFull(fd, &body, 3) == .ok else { break loop }
            let keycode = Int64(body[0])
            let down = body[1] == 1
            let isRepeat = body[2] == 1
            guard keysOfInterest.contains(keycode) else { continue }
            inject(keycode: keycode, down: down, isRepeat: isRepeat)
            let tag = down ? (isRepeat ? "↻" : "▼") : "▲"
            fputs("  \(tag) \(keyName(keycode))\n", stderr)
            gStatus.inc("keysInjected")
            gStatus.set("lastKey", "\(tag) \(keyName(keycode))")

        case msgPing:
            var ts = [UInt8](repeating: 0, count: 8)
            guard readFull(fd, &ts, 8) == .ok else { break loop }
            var pong = [msgPong] + ts
            guard writeAll(fd, &pong, pong.count) else { break loop }

        default:
            fputs("… unexpected frame type 0x\(String(type[0], radix: 16)) — dropping link\n", stderr)
            break loop
        }
    }
}

/// Accept loop, run on a background thread until stopped.
private func receiverAcceptLoop(secret: String, myName: String) {
    while gReceiverRunning.value {
        let conn: (fd: Int32, peer: String)
        do {
            conn = try acceptOne(gListenFD)
        } catch {
            if gReceiverRunning.value {
                fputs("   accept error: \(error)\n", stderr)
            }
            break   // listen fd was closed by stopReceiver, or a real error
        }

        setRecvTimeout(conn.fd, seconds: 5)  // bound the handshake + hello
        do {
            try serverHandshake(fd: conn.fd, secret: secret)
        } catch {
            fputs("✗ \(conn.peer) rejected: \(error)\n", stderr)
            close(conn.fd)
            continue
        }
        let senderName = exchangeHello(fd: conn.fd, myName: myName) ?? conn.peer
        gStatus.set("state", "connected")
        gStatus.set("peer", conn.peer)
        gStatus.set("peerName", senderName)
        fputs("✓ sender connected: \"\(senderName)\" (\(conn.peer))\n", stderr)

        serveConnection(conn.fd)
        close(conn.fd)
        if gReceiverRunning.value {
            gStatus.set("state", "listening")
            gStatus.set("peer", "-")
            gStatus.set("peerName", "-")
            fputs("… sender disconnected — waiting for reconnect\n", stderr)
        }
    }
    gStatus.set("state", "idle")
}

/// Start the receiver engine (non-blocking): open the listen socket, advertise
/// over Bonjour, and run the accept loop on a background thread. Returns false if
/// the port could not be bound.
@discardableResult
func startReceiver(port: UInt16, secret: String, name: String) -> Bool {
    gStatus.set("role", "recv")
    gStatus.set("state", "starting")

    _ = isTrustedForAccessibility(prompt: true)

    do {
        gListenFD = try listenTCP(port: port)
    } catch {
        gStatus.set("state", "error")
        fputs("✗ \(error)\n", stderr)
        return false
    }

    gReceiverRunning.value = true

    // Advertise over Bonjour so senders can auto-discover us.
    gPublisher = BonjourPublisher()
    gPublisher?.start(name: name, port: port)

    gStatus.set("state", "listening")
    fputs("● listening on :\(port)  — injecting ← → ↑ ↓ space into the focused app\n", stderr)

    Thread.detachNewThread { receiverAcceptLoop(secret: secret, myName: name) }
    return true
}

/// Stop the receiver engine and tear everything down.
func stopReceiver() {
    guard gReceiverRunning.value else { return }
    gReceiverRunning.value = false

    gPublisher?.stop()
    gPublisher = nil

    // Closing the listen fd unblocks accept() in the background thread.
    if gListenFD >= 0 { close(gListenFD); gListenFD = -1 }

    gStatus.set("state", "idle")
    gStatus.set("peer", "-")
}
