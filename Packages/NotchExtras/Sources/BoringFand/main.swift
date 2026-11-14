// boring-fand: root fan daemon. Listens on a unix socket and understands exactly four
// commands (status, set <rpm>, auto, ping). There is no generic SMC write.
// Everything runs on the main dispatch queue, so SMC writes are never concurrent.
import Foundation
import IOKit
import IOKit.pwr_mgt
import NotchExtrasCore

let defaultSocketPath = "/var/run/theboringteam.boringnotch.fand.sock"

func log(_ s: String) {
    FileHandle.standardError.write(Data("boring-fand: \(s)\n".utf8))
}

func fail(_ s: String) -> Never {
    log(s)
    exit(1)
}

/// Monotonic-derived clock so wall-clock jumps cannot suppress the watchdog revert.
func monotonicNow() -> Date {
    Date(timeIntervalSinceReferenceDate: ProcessInfo.processInfo.systemUptime)
}

// MARK: - Fan controller

final class FanController {
    private let smc: SMC
    private let fanCount: Int
    private let modeKeys: [String?]
    private var watchdog = FanWatchdog(timeout: 30)
    /// True after a successful `set` until the next `auto`.
    private(set) var manual = false

    init(smc: SMC) {
        self.smc = smc
        let n = Int(smc.readByte("FNum") ?? 0)
        fanCount = min(n, 10)
        modeKeys = (0..<fanCount).map { i in
            ["F\(i)Md", "F\(i)md"].first { smc.info($0) != nil }
        }
        watchdog.touch(at: monotonicNow())
    }

    func touch() { watchdog.touch(at: monotonicNow()) }

    func revertIfStale() {
        if watchdog.shouldRevert(now: monotonicNow(), manual: manual) {
            log("watchdog: no heartbeat, reverting to auto")
            autoWithRetry()
        }
    }

    /// Returns an error message, or nil when every fan accepted auto mode.
    @discardableResult
    func auto() -> String? {
        var firstError: String?
        for i in 0..<fanCount {
            guard let key = modeKeys[i] else { continue }
            if let err = smc.writeByte(key, 0), firstError == nil { firstError = err }
        }
        if firstError == nil { manual = false }
        return firstError
    }

    /// Fail-safe revert: retry up to 3 times, ~0.2 s apart, instead of waiting for the next tick.
    @discardableResult
    func autoWithRetry() -> String? {
        var err = auto()
        for _ in 0..<2 where err != nil {
            usleep(200_000)
            err = auto()
        }
        if let err { log("auto failed after retries: \(err)") }
        return err
    }

    func status() -> FanStatus {
        FanStatus(fans: (0..<fanCount).map { i in
            FanInfo(
                index: i,
                actual: smc.readFloat("F\(i)Ac") ?? 0,
                min: smc.readFloat("F\(i)Mn") ?? 0,
                max: smc.readFloat("F\(i)Mx") ?? 0,
                target: smc.readFloat("F\(i)Tg") ?? 0,
                manual: modeKeys[i].flatMap { smc.readByte($0) } == 1
            )
        })
    }

    /// Clamps `rpm` to each fan's SMC [min, max], switches it to manual and sets the target.
    func set(_ rpm: Double) -> String? {
        guard fanCount > 0 else { return "no fans" }
        // Total mode-write retry budget for one `set`, across all fans (the client waits longer than this).
        let retryDeadline = monotonicNow().addingTimeInterval(3)
        for i in 0..<fanCount {
            guard let modeKey = modeKeys[i] else { return "fan \(i): no mode key" }
            guard let lo = smc.readFloat("F\(i)Mn"), let hi = smc.readFloat("F\(i)Mx"), lo > 0, hi >= lo else {
                autoWithRetry()
                return "fan \(i): cannot read range"
            }
            let target = Swift.min(Swift.max(rpm, lo), hi)
            // The mode write can be refused for a moment after a mode change: bounded retry.
            var modeErr: String? = "unattempted"
            while true {
                modeErr = smc.writeByte(modeKey, 1)
                if modeErr == nil || monotonicNow() >= retryDeadline { break }
                usleep(300_000)
            }
            if let modeErr {
                autoWithRetry()
                return "fan \(i): manual mode refused (\(modeErr))"
            }
            manual = true
            if let err = smc.writeFloat("F\(i)Tg", target) {
                autoWithRetry()
                return "fan \(i): target write failed (\(err))"
            }
        }
        return nil
    }
}

// MARK: - Command handling

func handle(line: String, fans: FanController) -> String {
    guard let command = FanCommand.parse(line) else { return FanReply.error("unknown command") }
    fans.touch()
    switch command {
    case .ping:
        return FanReply.ok
    case .status:
        guard let data = try? JSONEncoder().encode(fans.status()) else { return FanReply.error("encode failed") }
        return String(decoding: data, as: UTF8.self)
    case .auto:
        return fans.auto().map(FanReply.error) ?? FanReply.ok
    case .set(let rpm):
        return fans.set(rpm).map(FanReply.error) ?? FanReply.ok
    }
}

/// Reads at most one line of <= 64 bytes within ~1 s. Nil on timeout, EOF without data, or overlong input.
func readLine(fd: Int32) -> String? {
    var tv = timeval(tv_sec: 0, tv_usec: 250_000)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    let deadline = monotonicNow().addingTimeInterval(1)
    var buf = [UInt8]()
    var chunk = [UInt8](repeating: 0, count: 65)
    while monotonicNow() < deadline {
        let n = read(fd, &chunk, 65 - buf.count)
        if n <= 0 { break }
        buf.append(contentsOf: chunk[0..<n])
        if let nl = buf.firstIndex(of: 10) {
            return nl <= 64 ? String(decoding: buf[0..<nl], as: UTF8.self) : nil
        }
        if buf.count > 64 { return nil }
    }
    // EOF without newline: accept what we have (e.g. `echo -n`).
    return buf.isEmpty || buf.count > 64 ? nil : String(decoding: buf, as: UTF8.self)
}

func serve(fd client: Int32, allowedUID: uid_t, fans: FanController) {
    defer { close(client) }
    var noSigPipe: Int32 = 1
    setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    var peerUID: uid_t = 0, peerGID: gid_t = 0
    guard getpeereid(client, &peerUID, &peerGID) == 0, peerUID == allowedUID || peerUID == 0 else { return }
    let reply: String
    if let line = readLine(fd: client) {
        reply = handle(line: line, fans: fans)
    } else {
        reply = FanReply.error("bad request")
    }
    let out = Array((reply + "\n").utf8)
    _ = out.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
}

// MARK: - Socket

func makeListener(path: String, uid: uid_t) -> Int32 {
    var st = stat()
    if lstat(path, &st) == 0 {
        guard (st.st_mode & S_IFMT) == S_IFSOCK else { fail("refusing: \(path) exists and is not a socket") }
        unlink(path)
    }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { fail("socket() failed: \(errno)") }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8CString)
    guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { fail("socket path too long") }
    withUnsafeMutableBytes(of: &addr.sun_path) { dst in
        for (i, b) in pathBytes.enumerated() { dst[i] = UInt8(bitPattern: b) }
    }
    let old = umask(0o177)
    let bound = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    umask(old)
    guard bound == 0 else { fail("bind(\(path)) failed: errno \(errno)") }
    guard chown(path, uid, gid_t.max) == 0 else { unlink(path); fail("chown failed: errno \(errno)") }
    guard chmod(path, 0o600) == 0 else { unlink(path); fail("chmod failed: errno \(errno)") }
    guard listen(fd, 8) == 0 else { unlink(path); fail("listen failed: errno \(errno)") }
    return fd
}

// MARK: - Arguments

var uidArg: uid_t?
var socketPath = defaultSocketPath
var args = Array(CommandLine.arguments.dropFirst())
while let a = args.first {
    args.removeFirst()
    switch a {
    case "--uid":
        guard let v = args.first, let n = UInt32(v) else { fail("--uid needs a numeric uid") }
        args.removeFirst(); uidArg = n
    case "--socket":
        guard let v = args.first, v.hasPrefix("/") else { fail("--socket needs an absolute path") }
        args.removeFirst(); socketPath = v
    default:
        fail("usage: boring-fand --uid <uid> [--socket <path>]")
    }
}
guard let allowedUID = uidArg else { fail("usage: boring-fand --uid <uid> [--socket <path>]") }

if geteuid() != 0 { log("warning: not running as root, SMC writes will fail") }
guard let smc = SMC() else { fail("cannot open AppleSMC") }

let fans = FanController(smc: smc)
if let err = fans.auto() { log("startup auto failed: \(err)") }

// MARK: - Run loop wiring (all on the main queue)

func shutdown() -> Never {
    _ = fans.auto()
    unlink(socketPath)
    exit(0)
}

let listener = makeListener(path: socketPath, uid: allowedUID)
let acceptSource = DispatchSource.makeReadSource(fileDescriptor: listener, queue: .main)
acceptSource.setEventHandler {
    let client = accept(listener, nil, nil)
    if client >= 0 { serve(fd: client, allowedUID: allowedUID, fans: fans) }
}
acceptSource.resume()

let watchdogTimer = DispatchSource.makeTimerSource(queue: .main)
watchdogTimer.schedule(deadline: .now() + 1, repeating: 1)
watchdogTimer.setEventHandler { fans.revertIfStale() }
watchdogTimer.resume()

var signalSources: [DispatchSourceSignal] = []
signal(SIGPIPE, SIG_IGN)
for sig in [SIGTERM, SIGINT, SIGHUP] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler { shutdown() }
    src.resume()
    signalSources.append(src)
}

var powerRoot: io_connect_t = 0
var powerPort: IONotificationPortRef?
var powerNotifier: io_object_t = 0
// iokit_common_msg(x) = 0xe0000000 | x; the C macros are not importable into Swift.
let kMessageCanSystemSleep: UInt32 = 0xe000_0270
let kMessageSystemWillSleep: UInt32 = 0xe000_0280
let powerCallback: IOServiceInterestCallback = { _, _, messageType, messageArgument in
    switch messageType {
    case kMessageSystemWillSleep:
        _ = fans.auto()
        IOAllowPowerChange(powerRoot, Int(bitPattern: messageArgument))
    case kMessageCanSystemSleep:
        IOAllowPowerChange(powerRoot, Int(bitPattern: messageArgument))
    default:
        break
    }
}
powerRoot = IORegisterForSystemPower(nil, &powerPort, powerCallback, &powerNotifier)
if powerRoot != 0, let powerPort {
    IONotificationPortSetDispatchQueue(powerPort, .main)
} else {
    log("warning: could not register for sleep notifications")
}

log("ready on \(socketPath) for uid \(allowedUID)")
dispatchMain()
