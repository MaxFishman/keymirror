import Foundation
import CryptoKit
import Security

// MARK: - Wire protocol (Phase 2)
//
// Connection lifecycle:
//   1. Receiver (server) sends  HELLO = MAGIC(3) + nonce(16)
//   2. Sender (client) replies  AUTH  = MAGIC(3) + HMAC-SHA256(secret, nonce)(32)
//   3. Receiver replies         1 byte: 0x01 ok / 0x00 reject, then closes on reject
//
// After the handshake, either side sends length-fixed framed messages:
//   KEY  = 0x4B + [keyCode, down(1)/up(0), isRepeat(1/0)]      (sender → receiver)
//   PING = 0x50 + uint64 BE timestamp (sender monotonic nanos) (sender → receiver)
//   PONG = 0x51 + the same uint64 echoed back                  (receiver → sender)
//
// The HMAC challenge-response means the shared secret never crosses the wire,
// and a replayed AUTH can't be reused against a fresh nonce.

let protoMagic: [UInt8] = [0x4B, 0x4D, 0x32]  // "KM2" — bump the last byte on protocol changes

let msgKey:  UInt8 = 0x4B  // 'K'
let msgPing: UInt8 = 0x50  // 'P'
let msgPong: UInt8 = 0x51  // 'Q'

let authOK:   UInt8 = 0x01
let authFail: UInt8 = 0x00

let nonceLen = 16
let macLen   = 32

// MARK: - Integer (de)serialization

func packU64BE(_ v: UInt64) -> [UInt8] {
    (0..<8).map { UInt8(truncatingIfNeeded: v >> (8 * (7 - $0))) }
}

func unpackU64BE(_ b: [UInt8]) -> UInt64 {
    b.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
}

// MARK: - HMAC auth

func computeMAC(secret: String, nonce: [UInt8]) -> [UInt8] {
    let key = SymmetricKey(data: Data(secret.utf8))
    let code = HMAC<SHA256>.authenticationCode(for: Data(nonce), using: key)
    return Array(code)
}

func verifyMAC(secret: String, nonce: [UInt8], mac: [UInt8]) -> Bool {
    let key = SymmetricKey(data: Data(secret.utf8))
    // Constant-time verification.
    return HMAC<SHA256>.isValidAuthenticationCode(Data(mac), authenticating: Data(nonce), using: key)
}

func randomNonce() -> [UInt8] {
    var b = [UInt8](repeating: 0, count: nonceLen)
    if SecRandomCopyBytes(kSecRandomDefault, nonceLen, &b) != errSecSuccess {
        // Fall back to the system CSPRNG-backed generator.
        for i in 0..<nonceLen { b[i] = UInt8.random(in: 0...255) }
    }
    return b
}

// MARK: - Handshake

/// Sender side: prove knowledge of the shared secret. Throws on any mismatch.
func clientHandshake(fd: Int32, secret: String) throws {
    var hello = [UInt8](repeating: 0, count: protoMagic.count + nonceLen)
    guard readFull(fd, &hello, hello.count) == .ok else {
        throw NetError.message("handshake: no server hello (is the receiver running this version?)")
    }
    guard Array(hello.prefix(protoMagic.count)) == protoMagic else {
        throw NetError.message("handshake: bad magic — version/protocol mismatch")
    }
    let nonce = Array(hello[protoMagic.count..<hello.count])

    var resp = protoMagic + computeMAC(secret: secret, nonce: nonce)
    guard writeAll(fd, &resp, resp.count) else {
        throw NetError.message("handshake: write failed")
    }

    var result = [UInt8](repeating: 0, count: 1)
    guard readFull(fd, &result, 1) == .ok else {
        throw NetError.message("handshake: no auth result")
    }
    guard result[0] == authOK else {
        throw NetError.message("handshake: rejected — shared secret mismatch")
    }
}

/// Receiver side: challenge the client and verify its MAC. Throws on failure.
func serverHandshake(fd: Int32, secret: String) throws {
    let nonce = randomNonce()
    var hello = protoMagic + nonce
    guard writeAll(fd, &hello, hello.count) else {
        throw NetError.message("handshake: write hello failed")
    }

    var resp = [UInt8](repeating: 0, count: protoMagic.count + macLen)
    guard readFull(fd, &resp, resp.count) == .ok else {
        throw NetError.message("handshake: no client response")
    }
    guard Array(resp.prefix(protoMagic.count)) == protoMagic else {
        var reject: [UInt8] = [authFail]
        _ = writeAll(fd, &reject, 1)
        throw NetError.message("handshake: bad client magic — version mismatch")
    }
    let mac = Array(resp[protoMagic.count..<resp.count])
    let ok = verifyMAC(secret: secret, nonce: nonce, mac: mac)

    var result: [UInt8] = [ok ? authOK : authFail]
    _ = writeAll(fd, &result, 1)
    guard ok else {
        throw NetError.message("handshake: client failed auth — shared secret mismatch")
    }
}
