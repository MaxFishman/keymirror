import Foundation

// MARK: - Keys we mirror
//
// macOS virtual keycodes for the five keys this tool forwards. Everything
// else the sender sees is ignored and never leaves the machine.

let kcLeft:  Int64 = 123
let kcRight: Int64 = 124
let kcDown:  Int64 = 125
let kcUp:    Int64 = 126
let kcSpace: Int64 = 49

/// The set the sender filters on.
let keysOfInterest: Set<Int64> = [kcLeft, kcRight, kcDown, kcUp, kcSpace]

/// Human-readable name for logging.
func keyName(_ code: Int64) -> String {
    switch code {
    case kcLeft:  return "←"
    case kcRight: return "→"
    case kcDown:  return "↓"
    case kcUp:    return "↑"
    case kcSpace: return "space"
    default:      return "key(\(code))"
    }
}
