import Foundation

/// Runs an executable directly (no shell) and captures its output.
/// Blocks the calling thread; call it off the main thread.
enum ProcessRunner {
    struct Outcome {
        var status: Int32
        var stdout: Data
        var stderr: Data
        var timedOut: Bool
    }

    /// `timeout == nil` waits indefinitely. On timeout the process is terminated.
    /// Returns nil when the process could not be launched.
    static func run(_ executable: String, arguments: [String], timeout: TimeInterval?) -> Outcome? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return nil }

        // Drain both pipes concurrently so a chatty child cannot block on a full pipe.
        var outData = Data()
        var errData = Data()
        let drain = DispatchGroup()
        drain.enter()
        DispatchQueue.global().async {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            drain.leave()
        }
        drain.enter()
        DispatchQueue.global().async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            drain.leave()
        }

        var timedOut = false
        if let timeout {
            if finished.wait(timeout: .now() + timeout) == .timedOut {
                timedOut = true
                process.terminate()
                finished.wait()
            }
        } else {
            finished.wait()
        }
        drain.wait()
        return Outcome(status: process.terminationStatus, stdout: outData, stderr: errData, timedOut: timedOut)
    }
}
