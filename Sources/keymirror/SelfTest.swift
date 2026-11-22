import Foundation

// Tiny built-in self-test for the wire helpers that don't need permissions or
// a real network — run with:  keymirror __selftest
// Kept undocumented; handy for verifying protocol changes in CI-less setups.

func runSelfTest() -> Never {
    var fds: [Int32] = [0, 0]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
        print("socketpair failed"); exit(1)
    }
    let a = fds[0], b = fds[1]

    var aSaw: String?
    var bSaw: String?
    let group = DispatchGroup()
    group.enter(); DispatchQueue.global().async { aSaw = exchangeHello(fd: a, myName: "AliceMac"); group.leave() }
    group.enter(); DispatchQueue.global().async { bSaw = exchangeHello(fd: b, myName: "BobMac"); group.leave() }
    group.wait()
    close(a); close(b)

    let ok = (aSaw == "BobMac" && bSaw == "AliceMac")
    print("hello exchange — A saw \"\(aSaw ?? "nil")\", B saw \"\(bSaw ?? "nil")\"  → \(ok ? "PASS" : "FAIL")")
    exit(ok ? 0 : 1)
}
