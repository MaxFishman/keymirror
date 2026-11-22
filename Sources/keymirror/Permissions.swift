import Cocoa
import ApplicationServices
import IOKit.hid

// MARK: - Permission status + prompts
//
// keymirror needs macOS privacy grants:
//   • Accessibility     — both roles (capture + inject keys)
//   • Input Monitoring  — sender only (the passive keyboard tap)
//   • Local Network     — both, for Bonjour auto-discovery (no API to query it)
// This wraps status checks and the "grant" actions the menu exposes.

enum PermState { case granted, denied, unknown }

func permGlyph(_ s: PermState) -> String {
    switch s {
    case .granted: return "✅"
    case .denied:  return "⛔️"
    case .unknown: return "⚠️"
    }
}

// MARK: Accessibility

func accessibilityState() -> PermState {
    AXIsProcessTrusted() ? .granted : .denied
}

func promptAccessibility() {
    _ = AXIsProcessTrustedWithOptions(
        [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
}

// MARK: Input Monitoring (IOKit HID)

func inputMonitoringState() -> PermState {
    switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
    case kIOHIDAccessTypeGranted: return .granted
    case kIOHIDAccessTypeDenied:  return .denied
    default:                      return .unknown
    }
}

func promptInputMonitoring() {
    _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
}

// MARK: Deep links to the right Settings pane

func openPrivacyPane(_ anchor: String) {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
        NSWorkspace.shared.open(url)
    }
}

func openAccessibilityPane()   { openPrivacyPane("Privacy_Accessibility") }
func openInputMonitoringPane() { openPrivacyPane("Privacy_ListenEvent") }
func openLocalNetworkPane()    { openPrivacyPane("Privacy_LocalNetwork") }

// MARK: Role-aware summary

/// Permissions that still need granting for `role`. Local Network can't be
/// queried, so it's not included here (it's offered separately in the menu).
func missingPermissions(for role: Role) -> [String] {
    var missing: [String] = []
    if accessibilityState() != .granted { missing.append("Accessibility") }
    if role == .send, inputMonitoringState() != .granted { missing.append("Input Monitoring") }
    return missing
}
