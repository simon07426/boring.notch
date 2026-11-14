import Foundation

public struct BridgeRouter: Sendable {
    private let token: String
    private let store: DecisionStore

    public init(token: String, store: DecisionStore) {
        self.token = token
        self.store = store
    }

    public func handle(_ r: HTTPRequest) async -> HTTPResponse {
        guard authorized(r) else { return Self.error(401, "unauthorized") }

        let parts = r.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.first == "decision" else { return Self.error(404, "not found") }

        switch (r.method, parts.count) {
        case ("POST", 1):
            guard let req = try? JSONDecoder().decode(DecisionRequest.self, from: r.body) else {
                return Self.error(400, "malformed body")
            }
            let id = await store.add(req)
            return HTTPResponse(status: 201, body: Data(#"{"id":"\#(id)"}"#.utf8))

        case ("GET", 2):
            let id = parts[1]
            let seconds = min(max(Int(r.query["wait"] ?? "") ?? 0, 0), 55)
            let status = await store.wait(id, timeout: .seconds(seconds))
            return HTTPResponse(status: status == .gone ? 404 : 200, body: status.json)

        case ("DELETE", 2):
            await store.remove(parts[1])
            return HTTPResponse(status: 204)

        default:
            return Self.error(parts.count <= 2 ? 405 : 404, "no such route")
        }
    }

    private func authorized(_ r: HTTPRequest) -> Bool {
        guard !token.isEmpty else { return false }
        guard let header = r.headers["authorization"], header.hasPrefix("Bearer ") else { return false }
        let given = Array(header.dropFirst("Bearer ".count).utf8)
        let expected = Array(token.utf8)
        guard given.count == expected.count else { return false }
        var diff: UInt8 = 0
        for (a, b) in zip(given, expected) { diff |= a ^ b }
        return diff == 0
    }

    private static func error(_ status: Int, _ message: String) -> HTTPResponse {
        HTTPResponse(status: status, body: Data(#"{"error":"\#(message)"}"#.utf8))
    }
}
