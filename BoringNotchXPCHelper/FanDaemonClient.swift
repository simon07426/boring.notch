import Foundation

/// Talks to the root fan daemon over its unix socket. One request line, one reply line.
enum FanDaemonClient {
    static let socketPath = "/var/run/theboringteam.boringnotch.fand.sock"

    /// Blocking; call off the main queue. Returns nil if the daemon is unreachable or does not answer.
    static func send(_ line: String, path: String = socketPath) -> String? {
        // The daemon reads one line of <= 64 bytes; never forward embedded newlines.
        let cleaned = line.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        let payload = Array((cleaned + "\n").utf8)
        guard payload.count <= 64 else { return nil }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            for (i, b) in pathBytes.enumerated() { dst[i] = UInt8(bitPattern: b) }
        }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }

        let written = payload.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == payload.count else { return nil }

        var reply = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while reply.count < 65_536 {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            reply.append(contentsOf: chunk[0..<n])
            if reply.last == 10 { break }
        }
        guard !reply.isEmpty else { return nil }
        return String(decoding: reply, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
