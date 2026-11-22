import Foundation

// MARK: - Low-level POSIX socket helpers
//
// Tiny, dependency-free TCP helpers. We use raw sockets (rather than
// Network.framework) so the data path is completely explicit: fixed-size
// framed messages in each direction. TCP_NODELAY is set on both ends so key
// events are flushed immediately instead of being coalesced by Nagle.

enum NetError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self {
        case .message(let m): return m
        }
    }
}

/// Outcome of a blocking fixed-size read.
enum ReadResult {
    case ok       // got all requested bytes
    case closed   // peer closed the connection (EOF)
    case timeout  // SO_RCVTIMEO elapsed before data arrived
    case failed   // socket error
}

/// Enable TCP_NODELAY (disable Nagle) on a connected socket.
func setNoDelay(_ fd: Int32) {
    var on: Int32 = 1
    setsockopt(fd, Int32(IPPROTO_TCP), TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
}

/// Set a receive timeout in seconds; 0 disables it (blocking reads).
func setRecvTimeout(_ fd: Int32, seconds: Int) {
    var tv = timeval(tv_sec: seconds, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
}

/// Resolve host:port and open a connected TCP client socket. Blocks until
/// connected or throws. Works with IPv4/IPv6 literals and hostnames.
func connectTCP(host: String, port: UInt16) throws -> Int32 {
    var hints = addrinfo()
    hints.ai_family = AF_UNSPEC
    hints.ai_socktype = SOCK_STREAM

    var info: UnsafeMutablePointer<addrinfo>? = nil
    let status = getaddrinfo(host, String(port), &hints, &info)
    if status != 0 {
        let msg = String(cString: gai_strerror(status))
        throw NetError.message("getaddrinfo(\(host):\(port)) failed: \(msg)")
    }
    defer { freeaddrinfo(info) }

    var lastErr = "no addresses resolved"
    var p = info
    while let addr = p {
        let fd = socket(addr.pointee.ai_family, addr.pointee.ai_socktype, addr.pointee.ai_protocol)
        if fd >= 0 {
            if connect(fd, addr.pointee.ai_addr, addr.pointee.ai_addrlen) == 0 {
                setNoDelay(fd)
                return fd
            }
            lastErr = String(cString: strerror(errno))
            close(fd)
        }
        p = addr.pointee.ai_next
    }
    throw NetError.message("connect(\(host):\(port)) failed: \(lastErr)")
}

/// Open a listening TCP socket bound to all interfaces on `port`.
func listenTCP(port: UInt16) throws -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    if fd < 0 { throw NetError.message("socket() failed: \(String(cString: strerror(errno)))") }

    var yes: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = INADDR_ANY.bigEndian
    addr.sin_port = port.bigEndian

    let bindResult = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    if bindResult != 0 {
        let e = String(cString: strerror(errno))
        close(fd)
        throw NetError.message("bind(:\(port)) failed: \(e)")
    }
    if listen(fd, 1) != 0 {
        let e = String(cString: strerror(errno))
        close(fd)
        throw NetError.message("listen() failed: \(e)")
    }
    return fd
}

/// Accept one inbound connection (blocking). Returns the connected fd and a
/// printable description of the peer.
func acceptOne(_ listenFD: Int32) throws -> (fd: Int32, peer: String) {
    var addr = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let fd = withUnsafeMutablePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            accept(listenFD, $0, &len)
        }
    }
    if fd < 0 { throw NetError.message("accept() failed: \(String(cString: strerror(errno)))") }
    setNoDelay(fd)

    var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    inet_ntop(AF_INET, &addr.sin_addr, &ipBuf, socklen_t(INET_ADDRSTRLEN))
    let ip = String(cString: ipBuf)
    let peerPort = UInt16(bigEndian: addr.sin_port)
    return (fd, "\(ip):\(peerPort)")
}

/// Write exactly `count` bytes, handling partial writes. Returns false on error.
@discardableResult
func writeAll(_ fd: Int32, _ bytes: UnsafePointer<UInt8>, _ count: Int) -> Bool {
    var sent = 0
    while sent < count {
        let n = write(fd, bytes + sent, count - sent)
        if n <= 0 {
            if n < 0 && errno == EINTR { continue }
            return false
        }
        sent += n
    }
    return true
}

/// Read exactly `count` bytes into `buf`, distinguishing EOF/timeout/error.
/// A timeout after a partial read is reported as `.timeout` and the caller
/// should treat the connection as lost (the frame is now out of sync).
func readFull(_ fd: Int32, _ buf: UnsafeMutablePointer<UInt8>, _ count: Int) -> ReadResult {
    var got = 0
    while got < count {
        let n = read(fd, buf + got, count - got)
        if n == 0 { return .closed }
        if n < 0 {
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { return .timeout }
            return .failed
        }
        got += n
    }
    return .ok
}
