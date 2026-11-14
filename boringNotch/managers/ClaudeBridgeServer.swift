import Combine
import Foundation
import Network
import NotchExtrasCore
import Security

/// Loopback-only HTTP server the Claude Code hook talks to. Port is chosen by the system and
/// published (with a random token) in `~/.config/boring-notch/claude-bridge.json` (via the XPC helper).
final class ClaudeBridgeServer: ObservableObject {
    static let shared = ClaudeBridgeServer()

    @Published private(set) var port: Int?

    private let queue = DispatchQueue(label: "claude.bridge.server")
    private var listener: NWListener?

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
                DispatchQueue.main.async { self.port = Int(p) }
                Task {
                    guard let json = Self.bridgeJSON(port: Int(p), token: token),
                          await XPCHelperClient.shared.writeClaudeBridgeFile(json) else {
                        NSLog("ClaudeBridgeServer: helper could not write the bridge file; the hook will not find the app")
                        return
                    }
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
        // Best-effort removal called from applicationWillTerminate on the main thread. The XPC
        // client hops to the main actor, so pump the run loop (at most 1 s) instead of blocking it.
        final class Flag: @unchecked Sendable { var done = false }
        let flag = Flag()
        Task {
            if !(await XPCHelperClient.shared.removeClaudeBridgeFile()) {
                NSLog("ClaudeBridgeServer: helper could not remove the bridge file")
            }
            flag.done = true
        }
        let deadline = Date().addingTimeInterval(1)
        while !flag.done && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
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

    // MARK: - Bridge file (written by the unsandboxed XPC helper)

    private static func bridgeJSON(port: Int, token: String) -> Data? {
        let payload: [String: Any] = ["port": port, "token": token, "pid": Int(ProcessInfo.processInfo.processIdentifier)]
        return try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    private static func makeToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw CocoaError(.fileReadUnknown)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
