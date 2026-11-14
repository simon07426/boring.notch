import XCTest
@testable import NotchExtrasCore

final class BridgeTests: XCTestCase {
    private func permission(_ session: String = "s1") -> DecisionRequest {
        DecisionRequest(session: session, kind: .permission, project: "proj", question: "Run ls?",
                        command: "ls", explain: nil, questions: nil)
    }

    private func req(_ method: String, _ path: String, token: String? = "tok", body: Data = Data()) -> HTTPRequest {
        var h: [String: String] = [:]
        if let token { h["authorization"] = "Bearer \(token)" }
        return HTTPRequest(method: method, path: path, query: [:], headers: h, body: body)
    }

    func testParsesCompleteRequest() {
        let raw = "POST /decision?wait=5&name=a%20b HTTP/1.1\r\nHost: x\r\nAUTHORIZATION: Bearer t\r\nContent-Length: 2\r\n\r\n{}"
        guard case .complete(let r) = HTTPRequest.parse(Data(raw.utf8)) else { return XCTFail("not complete") }
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.path, "/decision")
        XCTAssertEqual(r.query["wait"], "5")
        XCTAssertEqual(r.query["name"], "a b")
        XCTAssertEqual(r.headers["authorization"], "Bearer t")
        XCTAssertEqual(r.body, Data("{}".utf8))
    }

    func testIncompleteUntilBodyArrives() {
        let head = "POST /decision HTTP/1.1\r\nContent-Length: 4\r\n\r\nab"
        guard case .incomplete = HTTPRequest.parse(Data(head.utf8)) else { return XCTFail("expected incomplete") }
        guard case .incomplete = HTTPRequest.parse(Data("POST /decision HTT".utf8)) else { return XCTFail("expected incomplete") }
        guard case .complete(let r) = HTTPRequest.parse(Data((head + "cd").utf8)) else { return XCTFail("expected complete") }
        XCTAssertEqual(r.body, Data("abcd".utf8))
    }

    func testOversizeBodyInvalid() {
        let raw = "POST /decision HTTP/1.1\r\nContent-Length: 1000\r\n\r\n"
        guard case .invalid = HTTPRequest.parse(Data(raw.utf8), maxBody: 100) else { return XCTFail("expected invalid") }
    }

    func testGarbageInvalid() {
        guard case .invalid = HTTPRequest.parse(Data("garbage\r\n\r\n".utf8)) else { return XCTFail("expected invalid") }
        guard case .invalid = HTTPRequest.parse(Data("GET / HTTP/1.1\r\nContent-Length: abc\r\n\r\n".utf8)) else { return XCTFail("expected invalid") }
    }

    func testResponseSerialization() {
        let s = String(decoding: HTTPResponse(status: 201, body: Data("{}".utf8)).serialized(), as: UTF8.self)
        XCTAssertTrue(s.hasPrefix("HTTP/1.1 201 Created\r\n"))
        XCTAssertTrue(s.contains("Content-Type: application/json\r\n"))
        XCTAssertTrue(s.contains("Content-Length: 2\r\n"))
        XCTAssertTrue(s.contains("Connection: close\r\n"))
        XCTAssertTrue(s.hasSuffix("\r\n\r\n{}"))
    }

    func testUnauthorized401() async {
        let router = BridgeRouter(token: "tok", store: DecisionStore())
        let none = await router.handle(req("GET", "/decision/x", token: nil))
        let wrong = await router.handle(req("GET", "/decision/x", token: "nope"))
        XCTAssertEqual(none.status, 401)
        XCTAssertEqual(wrong.status, 401)
    }

    func testMalformedJSON400() async {
        let router = BridgeRouter(token: "tok", store: DecisionStore())
        let r = await router.handle(req("POST", "/decision", body: Data("{nope".utf8)))
        XCTAssertEqual(r.status, 400)
    }

    func testRouterPostGetDelete() async throws {
        let store = DecisionStore()
        let router = BridgeRouter(token: "tok", store: store)
        let body = try JSONEncoder().encode(permission())
        let created = await router.handle(req("POST", "/decision", body: body))
        XCTAssertEqual(created.status, 201)
        let id = try XCTUnwrap((try JSONSerialization.jsonObject(with: created.body) as? [String: String])?["id"])

        var g = req("GET", "/decision/\(id)"); g = HTTPRequest(method: g.method, path: g.path, query: ["wait": "0"], headers: g.headers, body: g.body)
        let got = await router.handle(g)
        XCTAssertEqual(got.status, 200)
        XCTAssertEqual(String(decoding: got.body, as: UTF8.self), #"{"status":"pending"}"#)

        let missing = await router.handle(req("GET", "/decision/unknown"))
        XCTAssertEqual(missing.status, 404)

        let del = await router.handle(req("DELETE", "/decision/\(id)"))
        XCTAssertEqual(del.status, 204)
        let after = await store.status(id)
        XCTAssertEqual(after, .gone)
    }

    func testPostThenWaitReturnsAllowWhenResolved() async {
        let store = DecisionStore()
        let id = await store.add(permission())
        Task { try? await Task.sleep(for: .milliseconds(50)); await store.resolve(id, .allow) }
        let s = await store.wait(id, timeout: .seconds(2))
        XCTAssertEqual(s, .allow)
    }

    func testWaitTimesOutPending() async {
        let store = DecisionStore()
        let id = await store.add(permission())
        let s = await store.wait(id, timeout: .milliseconds(200))
        XCTAssertEqual(s, .pending)
    }

    func testWaitReturnsImmediatelyWhenResolvedAndGoneForUnknown() async {
        let store = DecisionStore()
        let id = await store.add(permission())
        await store.resolve(id, .deny)
        let a = await store.wait(id, timeout: .seconds(5))
        XCTAssertEqual(a, .deny)
        let b = await store.wait("nope", timeout: .seconds(5))
        XCTAssertEqual(b, .gone)
    }

    func testTwoSessionsQueueFIFOAndIndependent() async {
        let store = DecisionStore()
        let a = await store.add(permission("A"))
        let b = await store.add(permission("B"))
        var p = await store.pending
        XCTAssertEqual(p.map(\.id), [a, b])
        await store.resolve(b, .allow)
        let sa = await store.status(a)
        XCTAssertEqual(sa, .pending)
        p = await store.pending
        XCTAssertEqual(p.map(\.id), [a])
    }

    func testDeleteMakesGone() async {
        let store = DecisionStore()
        let id = await store.add(permission())
        let waiter = Task { await store.wait(id, timeout: .seconds(5)) }
        try? await Task.sleep(for: .milliseconds(50))
        await store.remove(id)
        let w = await waiter.value
        XCTAssertEqual(w, .gone)
        let s = await store.status(id)
        XCTAssertEqual(s, .gone)
        let p = await store.pending
        XCTAssertTrue(p.isEmpty)
    }

    func testChangesStreamYields() async {
        let store = DecisionStore()
        var it = store.changes.makeAsyncIterator()
        let id = await store.add(permission())
        await it.next()
        await store.resolve(id, .allow)
        await it.next()
    }

    func testQuestionAnswersSerialize() {
        let json = DecisionStatus.answered(["Which DB?": "Postgres"]).json
        XCTAssertEqual(String(decoding: json, as: UTF8.self), #"{"status":"answer","answers":{"Which DB?":"Postgres"}}"#)
    }

    func testRequestCodableRoundTrip() throws {
        let q = DecisionQuestion(question: "DB?", header: "DB", options: [.init(label: "PG", description: nil)], multiSelect: false)
        let r = DecisionRequest(session: "s", kind: .question, project: nil, question: "DB?", command: nil, explain: nil, questions: [q])
        let back = try JSONDecoder().decode(DecisionRequest.self, from: JSONEncoder().encode(r))
        XCTAssertEqual(back, r)
    }

    /// The exact body tv_bridge.py's NotchTarget.post_decision sends for AskUserQuestion
    /// (see test_question_goes_to_notch_only_and_returns_updated_input): no multiSelect, header or description.
    private let pythonQuestionPayload = #"{"session": "s1", "kind": "question", "project": "nonexistent", "question": "Which?", "questions": [{"question": "Which?", "options": [{"label": "A"}, {"label": "B"}]}]}"#

    func testDecodesPythonQuestionPayloadWithoutMultiSelect() throws {
        let r = try JSONDecoder().decode(DecisionRequest.self, from: Data(pythonQuestionPayload.utf8))
        XCTAssertEqual(r.kind, .question)
        XCTAssertEqual(r.questions, [DecisionQuestion(question: "Which?", header: nil,
                                                      options: [.init(label: "A"), .init(label: "B")], multiSelect: false)])
    }

    func testRouterAcceptsPythonQuestionPayload() async {
        let router = BridgeRouter(token: "tok", store: DecisionStore())
        let r = await router.handle(req("POST", "/decision", body: Data(pythonQuestionPayload.utf8)))
        XCTAssertEqual(r.status, 201)
    }

    // MARK: - PopupPolicy

    func testSuppressedWhenClaudeFrontmost() {
        XCTAssertFalse(PopupPolicy.shouldOpenNotch(frontmost: "com.anthropic.claudefordesktop", popupEnabled: true, showWhenFrontmost: false))
    }

    func testSuppressedForTerminal() {
        XCTAssertFalse(PopupPolicy.shouldOpenNotch(frontmost: "com.apple.Terminal", popupEnabled: true, showWhenFrontmost: false))
    }

    func testOpensWhenOtherAppFrontmost() {
        XCTAssertTrue(PopupPolicy.shouldOpenNotch(frontmost: "com.apple.Safari", popupEnabled: true, showWhenFrontmost: false))
    }

    func testShowWhenFrontmostOverrides() {
        XCTAssertTrue(PopupPolicy.shouldOpenNotch(frontmost: "com.apple.Terminal", popupEnabled: true, showWhenFrontmost: true))
    }

    func testDisabledNeverOpens() {
        XCTAssertFalse(PopupPolicy.shouldOpenNotch(frontmost: "com.apple.Safari", popupEnabled: false, showWhenFrontmost: true))
    }

    func testNilFrontmostOpens() {
        XCTAssertTrue(PopupPolicy.shouldOpenNotch(frontmost: nil, popupEnabled: true, showWhenFrontmost: false))
    }

    // MARK: - Fail closed / eviction

    func testEmptyTokenRejectsEverything() async {
        let router = BridgeRouter(token: "", store: DecisionStore())
        let r1 = await router.handle(req("POST", "/decision", token: "", body: Data("{}".utf8)))
        XCTAssertEqual(r1.status, 401)
        let r2 = await router.handle(req("GET", "/decision/x", token: nil))
        XCTAssertEqual(r2.status, 401)
    }

    func testEvictsResolvedAfterRetention() async {
        let store = DecisionStore()
        let resolved = await store.add(permission())
        let pendingID = await store.add(permission("s2"))
        await store.resolve(resolved, .allow)
        await store.evictResolved(olderThan: 300, now: Date().addingTimeInterval(60))
        var s = await store.status(resolved)
        XCTAssertEqual(s, .allow)
        await store.evictResolved(olderThan: 300, now: Date().addingTimeInterval(301))
        s = await store.status(resolved)
        XCTAssertEqual(s, .gone)
        let p = await store.status(pendingID)
        XCTAssertEqual(p, .pending)
    }

    func testStalePendingExpiresAsWithdrawnThenEvicts() async {
        let store = DecisionStore()
        let t0 = Date()
        let old = await store.add(permission(), now: t0)
        let fresh = await store.add(permission("s2"), now: t0.addingTimeInterval(100))
        await store.expirePending(olderThan: 150, now: t0.addingTimeInterval(149))
        var s = await store.status(old)
        XCTAssertEqual(s, .pending)
        await store.expirePending(olderThan: 150, now: t0.addingTimeInterval(151))
        s = await store.status(old)
        XCTAssertEqual(s, .withdrawn)
        s = await store.status(fresh)
        XCTAssertEqual(s, .pending)
        let ids = await store.pending.map(\.id)
        XCTAssertEqual(ids, [fresh])
        // A late allow for the expired decision is a no-op.
        await store.resolve(old, .allow)
        s = await store.status(old)
        XCTAssertEqual(s, .withdrawn)
        await store.evictResolved(olderThan: 300, now: t0.addingTimeInterval(151 + 301))
        s = await store.status(old)
        XCTAssertEqual(s, .gone)
    }

    // MARK: - PopupTracker

    func testQueuedDecisionPopsWhenPreviousResolvedElsewhere() {
        var t = PopupTracker()
        XCTAssertTrue(t.shouldPost(current: "A", pending: ["A"], policyAllows: true))
        XCTAssertFalse(t.shouldPost(current: "A", pending: ["A", "B"], policyAllows: true))
        // A resolved elsewhere; B moves up and must pop.
        XCTAssertTrue(t.shouldPost(current: "B", pending: ["B"], policyAllows: true))
    }

    func testSameDecisionNotPostedTwice() {
        var t = PopupTracker()
        XCTAssertTrue(t.shouldPost(current: "A", pending: ["A"], policyAllows: true))
        XCTAssertFalse(t.shouldPost(current: "A", pending: ["A"], policyAllows: true))
        XCTAssertFalse(t.shouldPost(current: nil, pending: [], policyAllows: true))
    }

    func testNoPostWhenPolicyDisallows() {
        var t = PopupTracker()
        XCTAssertFalse(t.shouldPost(current: "A", pending: ["A"], policyAllows: false))
        XCTAssertFalse(t.shouldPost(current: "A", pending: ["A"], policyAllows: true))
    }
}
