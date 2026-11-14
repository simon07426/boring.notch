import Combine
import Foundation
import Network
import NotchExtrasCore
import Security

/// Loopback-only HTTP server the Claude Code hook talks to. Port is chosen by the system and
/// published (with a random token) in `claude-bridge.json` inside Application Support.
final class ClaudeBridgeServer: ObservableObject {
    static let shared = ClaudeBridgeServer()

    @Published private(set) var port: Int?

    private let queue = DispatchQueue(label: "claude.bridge.server")
    private var listener: NWListener?
    private var bridgeFileURL: URL?

    private static let requestReadTimeout: TimeInterval = 5
    private static let maxRequestBytes = 1_100_000
    private static let maxBody = 1_000_000

    func start() throws {
        guard listener == nil else { return }

        let token = try Self.makeToken()
        let router = BridgeRouter(token: token, store: ClaudeDecisionManager.shared.store)

        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params)

        listener.newConnectionHandler = { [weak self] conn in
            self?.handle(conn, router: router)
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard let p = listener?.port?.rawValue else { return }
                do {
                    try self.writeBridgeFile(port: Int(p), token: token)
                    DispatchQueue.main.async { self.port = Int(p) }
                } catch {
                    NSLog("ClaudeBridgeServer: could not write bridge file: \(error)")
                }
            case .failed(let error):
                NSLog("ClaudeBridgeServer: listener failed: \(error)")
                DispatchQueue.main.async { self.port = nil }
            default:
                break
            }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        if let url = bridgeFileURL { try? FileManager.default.removeItem(at: url) }
        bridgeFileURL = nil
        DispatchQueue.main.async { self.port = nil }
    }

    // MARK: - Connections

    private func handle(_ conn: NWConnection, router: BridgeRouter) {
        conn.start(queue: queue)

        let timeout = DispatchWorkItem { [weak conn] in conn?.cancel() }
        queue.asyncAfter(deadline: .now() + Self.requestReadTimeout, execute: timeout)

        func respond(_ response: HTTPResponse) {
            conn.send(content: response.serialized(), completion: .contentProcessed { _ in conn.cancel() })
        }

        func receive(_ buffer: Data) {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                var buffer = buffer
                if let data { buffer.append(data) }

                if buffer.count > Self.maxRequestBytes {
                    timeout.cancel()
                    return respond(HTTPResponse(status: 400))
                }

                switch HTTPRequest.parse(buffer, maxBody: Self.maxBody) {
                case .invalid:
                    timeout.cancel()
                    respond(HTTPResponse(status: 400))
                case .complete(let request):
                    timeout.cancel() // the read deadline covers only the request itself, not the long poll
                    Task { respond(await router.handle(request)) }
                case .incomplete:
                    if error != nil || isComplete {
                        timeout.cancel()
                        conn.cancel()
                    } else {
                        receive(buffer)
                    }
                }
            }
        }
        receive(Data())
    }

    // MARK: - Bridge file

    private func writeBridgeFile(port: Int, token: String) throws {
        let fm = FileManager.default
        let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = support.appendingPathComponent("boringNotch", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let final = dir.appendingPathComponent("claude-bridge.json")
        let tmp = dir.appendingPathComponent(".claude-bridge.json.\(UUID().uuidString).tmp")
        let payload: [String: Any] = ["port": port, "token": token, "pid": Int(ProcessInfo.processInfo.processIdentifier)]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])

        guard fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if rename(tmp.path, final.path) != 0 {
            try? fm.removeItem(at: tmp)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        bridgeFileURL = final
    }

    private static func makeToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw CocoaError(.fileReadUnknown)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
