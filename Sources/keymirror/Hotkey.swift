import Foundation
import Carbon.HIToolbox

// MARK: - Pause control (sender only)
//
// Lets you temporarily stop forwarding keys (e.g. to type on the primary Mac
// without it bleeding to the redundant one) without quitting.
//
// Two ways to toggle, both flip `gPaused`:
//   • Global hotkey  ⌃⌥⌘P  — registered via Carbon so the chord is swallowed
//     (it does NOT type "p" into the focused app).
//   • Signal fallback: `kill -USR1 <pid>` — always works, even if the hotkey
//     can't register in a given environment.

// Read on the hot path by the event-tap callback; written from the hotkey
// handler / signal handler. A plain Bool flag — a torn read is harmless here.
var gPaused = false

private var gHotKeyRef: EventHotKeyRef?

private func logPauseState() {
    let s = gPaused
        ? "⏸  PAUSED — keys NOT forwarded (primary still works locally)"
        : "▶  RESUMED — forwarding keys"
    FileHandle.standardError.write(Data("\(s)\n".utf8))
}

private var gPauseInstalled = false

func installPauseControls() {
    guard !gPauseInstalled else { return }
    gPauseInstalled = true

    // Signal fallback.
    signal(SIGUSR1) { _ in
        gPaused.toggle()
        let s = gPaused ? "⏸  PAUSED\n" : "▶  RESUMED\n"
        FileHandle.standardError.write(Data(s.utf8))
    }

    // Global hotkey ⌃⌥⌘P.
    var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                  eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { (_, _, _) -> OSStatus in
        gPaused.toggle()
        logPauseState()
        return noErr
    }, 1, &eventType, nil, nil)

    let hotKeyID = EventHotKeyID(signature: OSType(0x4B4D5054) /* 'KMPT' */, id: 1)
    let mods = UInt32(cmdKey | optionKey | controlKey)
    let status = RegisterEventHotKey(UInt32(kVK_ANSI_P), mods, hotKeyID,
                                     GetApplicationEventTarget(), 0, &gHotKeyRef)

    let pid = getpid()
    if status == noErr {
        FileHandle.standardError.write(Data(
            "⏯  pause: ⌃⌥⌘P   (fallback: kill -USR1 \(pid))\n".utf8))
    } else {
        FileHandle.standardError.write(Data(
            "⏯  pause: kill -USR1 \(pid)   (hotkey unavailable, status \(status))\n".utf8))
    }
}
