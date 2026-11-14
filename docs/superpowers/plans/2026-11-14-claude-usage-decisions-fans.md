# Claude Usage, Claude Decisions & Fan Control Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Claude usage tab, a Fans tab (with temperatures), and a notch pop-up for answering Claude Code permission prompts and multiple-choice questions to this Boring Notch fork, without changing existing behaviour.

**Architecture:** Pure, testable logic lives in a new local Swift package `Packages/NotchExtras` (library `NotchExtrasCore`, executable `boring-fand`). The sandboxed app talks to the unsandboxed XPC helper for Keychain/HTTPS usage fetching, sensor reads and fan commands; the helper talks to a root LaunchDaemon (`boring-fand`) over a Unix socket. Claude decisions arrive from a reworked Python hook (moved into this repo, installed to `~/.config/tv-bridge/tv_bridge.py`) via a localhost HTTP server inside the app.

**Tech Stack:** Swift 5 / SwiftUI / AppKit, macOS 14+, Network.framework, IOKit (AppleSMC, IOHID), Security.framework, `Defaults`, `AsyncXPCConnection`; Python 3 standard library for the hook.

**Spec:** `docs/superpowers/specs/2026-11-14-claude-usage-decisions-fans-design.md`

## Global Constraints

- Deployment target macOS 14.0, `SWIFT_VERSION = 5.0`; package `swift-tools-version: 5.9`, platform `.macOS(.v14)`.
- Bundle IDs unchanged: app `theboringteam.boringnotch`, helper `theboringteam.boringnotch.BoringNotchXPCHelper`. Daemon label `theboringteam.boringnotch.fand`.
- Everything else in the app keeps current behaviour; new tabs only appear after Home and Shelf.
- Never auto-allow: any hook error, timeout, or missing app → hook prints nothing and exits 0.
- Hook wait: `DECISION_WAIT_S = 120`, hook timeout 150 s (unchanged in `~/.claude/settings.json`).
- Never refresh or write the Claude OAuth token; read-only Keychain access to service `Claude Code-credentials`.
- Usage endpoint: `GET https://api.anthropic.com/api/oauth/usage`, headers `Authorization: Bearer <accessToken>`, `anthropic-beta: oauth-2025-04-20`.
- Usage refresh: every 120 s, on tab open, and on ↻. Bar colours: ≤ 70 % normal, 70–90 % amber, > 90 % red.
- Fans (this Mac): 2 fans, SMC keys `FNum`, `F{i}Ac`/`F{i}Mn`/`F{i}Mx`/`F{i}Tg` (`flt `, little-endian Float32), `F{i}Md` (`ui8 `, 0 auto / 1 manual). No `Ftst` unlock. Range from SMC (2317–6800 here). Slider step 100 RPM; typed value exact but clamped to [min, max]. 0 RPM displays "Off".
- Fan safety: daemon returns fans to auto on start, SIGTERM, system sleep, and 30 s without a heartbeat while manual; app sends `auto` on terminate; app always starts in Auto.
- Fan UI polling: every 2 s while the Fans tab is visible; none while the notch is closed (heartbeat only, every 10 s, while manual).
- Pop-up suppressed when frontmost app is one of: `com.anthropic.claudefordesktop`, `com.apple.Terminal`, `com.googlecode.iterm2`, `com.mitchellh.ghostty`, `dev.warp.Warp-Stable`, `com.microsoft.VSCode`, `com.todesktop.230313mzl4w4u92` (Cursor) — unless setting "Show pop-up even when Claude is in front" is on (default off).
- Questions (`AskUserQuestion`) go to the notch only; permission prompts go to notch and TV, first answer wins.
- Work on branch `feat/claude-and-fans`, never directly on `main`.

## Review Focus

- **App not running / stale bridge file** (port from a previous launch): hook must give up on the notch within ~1 s and fall back silently. → test in Task 8.
- **Two Claude sessions asking at once:** decisions queue FIFO; answering one never resolves the other. → test in Task 5.
- **Usage response with `null` buckets, extra fields, utilization > 100 or missing `resets_at`:** missing buckets hidden, percent clamped to 0–100, no crash. → test in Task 2.
- **Typed fan speed `""`, `"abc"`, `"-5"`, `"99999"`, `"2350"`:** invalid reverts, out-of-range clamps, valid kept exactly (not snapped). → test in Task 11.
- **Mac sleeps or app crashes while fans are manual:** fans return to auto. → watchdog test in Task 11, manual check in Task 13.

---

### Task 1: Stable code signing

**Files:**
- Modify: `boringNotch.xcodeproj/project.pbxproj` (all `CODE_SIGN_IDENTITY`, `CODE_SIGN_STYLE` entries for both targets, Debug + Release)

- [ ] **Step 1: Create branch** — `git checkout -b feat/claude-and-fans`
- [ ] **Step 2: Owner creates the certificate** (needs the owner at the keyboard): Keychain Access → Certificate Assistant → Create a Certificate… → Name `Boring Notch Dev`, Identity Type *Self-Signed Root*, Certificate Type *Code Signing* → Create. Then in the certificate's Trust settings set *Code Signing: Always Trust*.
- [ ] **Step 3: Verify** — Run `security find-identity -v -p codesigning`. Expected: a line containing `"Boring Notch Dev"`.
- [ ] **Step 4: Set signing** — In every build configuration of both targets set `CODE_SIGN_IDENTITY = "Boring Notch Dev"`, `CODE_SIGN_STYLE = Manual`, `DEVELOPMENT_TEAM = ""`.
- [ ] **Step 5: Build and verify** — Run `xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Debug -derivedDataPath build build` then `codesign -dv --verbose=2 build/Build/Products/Debug/boringNotch.app 2>&1 | grep Authority`. Expected: `Authority=Boring Notch Dev`. Launch the app and confirm the notch still works as before. Add `build/` to `.gitignore` if not ignored.
- [ ] **Step 6: Commit** — `git commit -am "build: sign app and helper with stable local identity"`

### Task 2: NotchExtras package + usage parsing

**Files:**
- Create: `Packages/NotchExtras/Package.swift`
- Create: `Packages/NotchExtras/Sources/NotchExtrasCore/ClaudeUsage.swift`
- Create: `Packages/NotchExtras/Sources/BoringFand/main.swift` (empty placeholder until Task 12)
- Test: `Packages/NotchExtras/Tests/NotchExtrasCoreTests/ClaudeUsageTests.swift`
- Modify: `boringNotch.xcodeproj/project.pbxproj` (add local package, link `NotchExtrasCore` to app and helper targets)

**Interfaces:**
- Produces:
  - `public struct UsageBucket: Equatable { public let percent: Double /*0–100*/; public let resetsAt: Date? }`
  - `public struct UsageSnapshot: Equatable { public let fiveHour: UsageBucket?; public let weekly: UsageBucket?; public let weeklyModelName: String?; public let weeklyModelBucket: UsageBucket? }`
  - `public static func UsageSnapshot.parse(_ data: Data) throws -> UsageSnapshot` — reads `five_hour`, `seven_day`, and the first non-null `seven_day_<model>` bucket (e.g. `seven_day_opus` → name `"Opus"`; ignore `seven_day_oauth_apps`); each bucket `{utilization: Number, resets_at: ISO8601 with or without fractional seconds | null}`.
  - `public enum UsageLevel { case normal, warning, critical }`; `public static func UsageLevel.of(_ percent: Double) -> UsageLevel`
  - `public func resetText(_ date: Date?, now: Date, calendar: Calendar = .current) -> String`

- [ ] **Step 1: Create package** with library product `NotchExtrasCore`, executable product `boring-fand` (target `BoringFand` depending on `NotchExtrasCore`), test target `NotchExtrasCoreTests`.
- [ ] **Step 2: Write failing tests**

```swift
func testParsesBuckets() throws {
    let json = #"{"five_hour":{"utilization":46.0,"resets_at":"2026-11-14T15:00:00.123+00:00"},"seven_day":{"utilization":27,"resets_at":"2026-11-19T09:00:00+00:00"},"seven_day_opus":null,"extra":1}"#
    let s = try UsageSnapshot.parse(Data(json.utf8))
    XCTAssertEqual(s.fiveHour?.percent, 46)
    XCTAssertEqual(s.weekly?.percent, 27)
    XCTAssertNotNil(s.fiveHour?.resetsAt)
    XCTAssertNil(s.weeklyModelBucket)
}
func testNullBucketsHiddenAndPercentClamped() throws {
    let s = try UsageSnapshot.parse(Data(#"{"five_hour":{"utilization":130,"resets_at":null},"seven_day":null}"#.utf8))
    XCTAssertEqual(s.fiveHour?.percent, 100); XCTAssertNil(s.fiveHour?.resetsAt); XCTAssertNil(s.weekly)
}
func testModelBucket() throws {
    let s = try UsageSnapshot.parse(Data(#"{"seven_day_opus":{"utilization":5,"resets_at":null}}"#.utf8))
    XCTAssertEqual(s.weeklyModelName, "Opus"); XCTAssertEqual(s.weeklyModelBucket?.percent, 5)
}
func testGarbageThrows() { XCTAssertThrowsError(try UsageSnapshot.parse(Data("nope".utf8))) }
func testLevels() {
    XCTAssertEqual(UsageLevel.of(70), .normal); XCTAssertEqual(UsageLevel.of(70.1), .warning)
    XCTAssertEqual(UsageLevel.of(90), .warning); XCTAssertEqual(UsageLevel.of(90.1), .critical)
}
func testResetText() {
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
    let now = Date(timeIntervalSince1970: 0) // Thu 1970-01-01 00:00 UTC
    XCTAssertEqual(resetText(now.addingTimeInterval(2*3600 + 14*60), now: now, calendar: cal), "resets in 2h 14m")
    XCTAssertEqual(resetText(now.addingTimeInterval(40*60), now: now, calendar: cal), "resets in 40m")
    XCTAssertEqual(resetText(now.addingTimeInterval(5*86400 + 9*3600), now: now, calendar: cal), "resets Tue 09:00")
    XCTAssertEqual(resetText(nil, now: now, calendar: cal), "")
}
```

- [ ] **Step 3: Run** `swift test --package-path Packages/NotchExtras` — Expected: FAIL (symbols missing).
- [ ] **Step 4: Implement** `ClaudeUsage.swift` (`JSONSerialization` for tolerance; ≥ 24 h away uses `"resets EEE HH:mm"` with `en_US_POSIX`).
- [ ] **Step 5: Run tests** — Expected: PASS.
- [ ] **Step 6: Link package into Xcode project**, add `import NotchExtrasCore` to one app file, build with the Task 1 `xcodebuild` command — Expected: `BUILD SUCCEEDED`.
- [ ] **Step 7: Commit** — `git add Packages boringNotch.xcodeproj && git commit -m "feat: add NotchExtras package with Claude usage parsing"`

### Task 3: Helper fetches Claude usage

**Files:**
- Create: `Packages/NotchExtras/Sources/NotchExtrasCore/ClaudeCredentials.swift`
- Test: `Packages/NotchExtras/Tests/NotchExtrasCoreTests/ClaudeCredentialsTests.swift`
- Create: `BoringNotchXPCHelper/ClaudeUsageFetcher.swift`
- Modify: `BoringNotchXPCHelper/BoringNotchXPCHelperProtocol.swift`, `boringNotch/XPCHelperClient/BoringNotchXPCHelperProtocol.swift` (keep both copies identical), `BoringNotchXPCHelper/BoringNotchXPCHelper.swift`, `boringNotch/XPCHelperClient/XPCHelperClient.swift`

**Interfaces:**
- Produces:
  - `public struct ClaudeCredentials { public let accessToken: String; public let expiresAt: Date?; public static func parse(_ keychainData: Data) throws -> ClaudeCredentials; public func isExpired(now: Date) -> Bool }` — JSON `{"claudeAiOauth":{"accessToken":String,"expiresAt":Int(ms since epoch)}}`; expired when `expiresAt <= now + 60 s`.
  - `public enum UsageFetchError: String, Error { case noCredentials, keychainDenied, expired, network, badResponse }`
  - XPC: `func fetchClaudeUsage(with reply: @escaping (Data?, String?) -> Void)` — `(json, nil)` on success, `(nil, UsageFetchError.rawValue)` on failure.
  - Client: `func fetchClaudeUsage() async -> Result<Data, UsageFetchError>` on `XPCHelperClient`.

- [ ] **Step 1: Write failing tests** — `testParsesTokenAndExpiry` (expiresAt `1731600000000` → `Date(timeIntervalSince1970: 1731600000)`), `testExpiredWithin60s` (expires now+30 s → expired; now+120 s → not), `testMissingTokenThrows` (`{"claudeAiOauth":{}}`).
- [ ] **Step 2: Run** `swift test --package-path Packages/NotchExtras --filter ClaudeCredentials` — Expected: FAIL.
- [ ] **Step 3: Implement** `ClaudeCredentials.swift`.
- [ ] **Step 4: Run** — Expected: PASS.
- [ ] **Step 5: Implement helper** `ClaudeUsageFetcher.fetch() async -> Result<Data, UsageFetchError>`: `SecItemCopyMatching` (`kSecClassGenericPassword`, `kSecAttrService = "Claude Code-credentials"`, `kSecReturnData`); `errSecItemNotFound` → `.noCredentials`; `errSecAuthFailed`/`errSecUserCanceled`/`errSecInteractionNotAllowed` → `.keychainDenied`; expired → `.expired`; `URLSession` GET with the Global Constraints headers, 15 s timeout; 401 → `.expired`, other non-200 → `.badResponse`, transport error → `.network`. Wire the XPC method and client wrapper following the existing brightness methods' pattern. The token never crosses XPC.
- [ ] **Step 6: Manual verify** — temporary `Task { print(await XPCHelperClient.shared.fetchClaudeUsage()) }` at launch; build, run, click *Always Allow* on the Keychain prompt. Expected: `.success` with JSON containing `five_hour`. Rebuild and relaunch: Expected no second Keychain prompt. Remove the temporary line.
- [ ] **Step 7: Commit** — `git commit -am "feat: helper fetches Claude usage via Keychain OAuth token"`

### Task 4: Claude usage tab

**Files:**
- Create: `boringNotch/managers/ClaudeUsageManager.swift`
- Create: `boringNotch/components/Claude/ClaudeUsageView.swift`
- Modify: `boringNotch/enums/generic.swift` (`NotchViews`: add `.claude`, `.fans`), `boringNotch/components/Tabs/TabSelectionView.swift`, `boringNotch/ContentView.swift` (switch in `NotchLayout()`; `.fans` shows `EmptyView()` until Task 13), `boringNotch/components/Notch/BoringHeader.swift:19`, `boringNotch/models/Constants.swift`, `boringNotch/components/Settings/SettingsView.swift`, `boringNotch/boringNotchApp.swift`

**Interfaces:**
- Consumes: `UsageSnapshot`, `UsageLevel`, `resetText` (Task 2); `XPCHelperClient.fetchClaudeUsage()` (Task 3).
- Produces:
  - `Defaults.Keys.showClaudeTab: Bool = true`, `.showFansTab: Bool = true`, `.claudeDecisionPopup: Bool = true`, `.claudePopupWhenFrontmost: Bool = false`, `.fanSensorsExpanded: Bool = false`.
  - `@MainActor final class ClaudeUsageManager: ObservableObject { static let shared; @Published private(set) var snapshot: UsageSnapshot?; @Published private(set) var error: UsageFetchError?; @Published private(set) var lastUpdated: Date?; func refresh() async; func start(); func stop() }`
  - `let tabs` becomes a computed `visibleTabs: [TabModel]`: Home always; Shelf when `Defaults[.boringShelf]`; `TabModel(label: "Claude", icon: "sparkle", view: .claude)` when `showClaudeTab`; `TabModel(label: "Fans", icon: "fan", view: .fans)` when `showFansTab`.

- [ ] **Step 1: Header rule** — tab row shows when `((!tvm.isEmpty || coordinator.alwaysShowTabs) && Defaults[.boringShelf]) || showClaudeTab || showFansTab`. (Today the row hides when the shelf is off, which would hide the new tabs.) If `coordinator.currentView` points at a tab that becomes hidden, fall back to `.home`.
- [ ] **Step 2: Implement manager** — 120 s timer started from `AppDelegate.applicationDidFinishLaunching` when `showClaudeTab`; `refresh()` on tab appear and ↻; keep last snapshot on error.
- [ ] **Step 3: Implement view** per spec mock: rows "5-hour", "Weekly", optional "<Model> weekly"; colour by `UsageLevel` (normal white, warning `.orange`, critical `.red`); "updated Xm ago"; ↻ button. Error texts exactly: `noCredentials` "Sign in to Claude Code", `keychainDenied` "Keychain access denied — click to retry" (tap → `refresh()`), `expired` "Open Claude Code to refresh login", `network`/`badResponse` "Couldn't reach Anthropic" (last values greyed).
- [ ] **Step 4: Settings** — new "Claude" section with toggles: Show Claude tab, Show decision pop-up, Show pop-up even when Claude is in front; plus a temporary "Show Fans tab" toggle (moved in Task 13).
- [ ] **Step 5: Verify** — build, hover notch: Expected tabs Home · Shelf · Claude · Fans; Claude tab percentages match `/usage` in Claude Code. Toggle "Show Claude tab" off → tab disappears. Home/Shelf unchanged.
- [ ] **Step 6: Commit** — `git commit -am "feat: Claude usage tab"`

### Task 5: Decision bridge core (HTTP parsing, store, router)

**Files:**
- Create: `Packages/NotchExtras/Sources/NotchExtrasCore/Bridge/HTTPMessage.swift`, `Bridge/Decision.swift`, `Bridge/DecisionStore.swift`, `Bridge/BridgeRouter.swift`
- Test: `Packages/NotchExtras/Tests/NotchExtrasCoreTests/BridgeTests.swift`

**Interfaces:**
- Produces:
  - `public struct HTTPRequest { public let method: String; path: String; query: [String: String]; headers: [String: String] /*lowercased keys*/; body: Data }`; `public enum HTTPParse { case incomplete, invalid, complete(HTTPRequest) }`; `public static func HTTPRequest.parse(_ buffer: Data, maxBody: Int = 256_000) -> HTTPParse`
  - `public struct HTTPResponse { public let status: Int; public let body: Data; public func serialized() -> Data }` (`Content-Type: application/json`, `Connection: close`)
  - `public struct DecisionQuestion: Codable, Equatable { question: String; header: String?; options: [Option]; multiSelect: Bool; struct Option: Codable, Equatable { label: String; description: String? } }`
  - `public struct DecisionRequest: Codable, Equatable { session: String; kind: Kind /* "permission" | "question" */; project: String?; question: String; command: String?; explain: String?; questions: [DecisionQuestion]? }`
  - `public enum DecisionStatus: Equatable { case pending, allow, deny, answered([String: String]), withdrawn, gone }` — wire JSON `{"status":"pending|allow|deny|answer|withdrawn|gone","answers":{…}}`
  - `public actor DecisionStore { func add(_ r: DecisionRequest) -> String; func resolve(_ id: String, _ s: DecisionStatus); func remove(_ id: String); func status(_ id: String) -> DecisionStatus; func wait(_ id: String, timeout: Duration) async -> DecisionStatus; var pending: [PendingDecision] /*FIFO, unresolved only*/; nonisolated let changes: AsyncStream<Void> }` with `public struct PendingDecision: Equatable { id: String; request: DecisionRequest }`
  - `public struct BridgeRouter { public init(token: String, store: DecisionStore); public func handle(_ r: HTTPRequest) async -> HTTPResponse }` — `POST /decision` → 201 `{"id":…}`; `GET /decision/{id}?wait=N` (N clamped 0…55, seconds) → 200 status JSON, 404 unknown; `DELETE /decision/{id}` → 204; missing/wrong `Authorization: Bearer <token>` → 401; malformed JSON → 400.

- [ ] **Step 1: Write failing tests** — `testParsesCompleteRequest`, `testIncompleteUntilBodyArrives`, `testOversizeBodyInvalid`, `testGarbageInvalid`, `testUnauthorized401`, `testPostThenWaitReturnsAllowWhenResolved` (resolve after 50 ms, wait 2 s → `.allow`), `testWaitTimesOutPending` (wait 0.2 s → `.pending`), `testTwoSessionsQueueFIFOAndIndependent` (add A, add B; `pending.map(\.id) == [A, B]`; resolve B → A still `.pending`, `pending.map(\.id) == [A]`), `testDeleteMakesGone`, `testQuestionAnswersSerialize` (`.answered(["Which DB?":"Postgres"])` → `{"status":"answer","answers":{"Which DB?":"Postgres"}}`).
- [ ] **Step 2: Run** `swift test --package-path Packages/NotchExtras --filter Bridge` — Expected: FAIL.
- [ ] **Step 3: Implement** the four files.
- [ ] **Step 4: Run** — Expected: PASS.
- [ ] **Step 5: Commit** — `git commit -am "feat: decision bridge core (http, store, router)"`

### Task 6: Bridge server, decision manager, pop-up policy (app)

**Files:**
- Create: `Packages/NotchExtras/Sources/NotchExtrasCore/Bridge/PopupPolicy.swift`; tests appended to `BridgeTests.swift`
- Create: `boringNotch/managers/ClaudeBridgeServer.swift`, `boringNotch/managers/ClaudeDecisionManager.swift`
- Modify: `boringNotch/boringNotchApp.swift` (start in `applicationDidFinishLaunching`, stop + delete bridge file in `applicationWillTerminate`)

**Interfaces:**
- Consumes: Task 5 types.
- Produces:
  - `public enum PopupPolicy { public static let suppressingBundleIDs: Set<String> /* list in Global Constraints */; public static func shouldOpenNotch(frontmost: String?, popupEnabled: Bool, showWhenFrontmost: Bool) -> Bool }`
  - Bridge file: `FileManager.urls(.applicationSupportDirectory)` + `boringNotch/claude-bridge.json`, contents `{"port": Int, "token": String, "pid": Int}`, permissions 0600, rewritten each launch. Real path seen by the hook: `~/Library/Containers/theboringteam.boringnotch/Data/Library/Application Support/boringNotch/claude-bridge.json`.
  - `@MainActor final class ClaudeDecisionManager: ObservableObject { static let shared; let store: DecisionStore; @Published private(set) var current: PendingDecision?; @Published private(set) var queuedCount: Int; func allow(); func deny(); func answer(_ answers: [String: String]); func handBack() /* resolve .withdrawn, activate com.anthropic.claudefordesktop */ }`
  - `Notification.Name.claudeDecisionArrived`
  - `final class ClaudeBridgeServer { static let shared; func start() throws; func stop() }` — `NWListener` bound to `127.0.0.1` port 0 (random); token = 32 random bytes hex.

- [ ] **Step 1: Failing tests** — `testSuppressedWhenClaudeFrontmost`, `testSuppressedForTerminal` (`com.apple.Terminal`), `testOpensWhenOtherAppFrontmost` (`com.apple.Safari`), `testShowWhenFrontmostOverrides`, `testDisabledNeverOpens`, `testNilFrontmostOpens`.
- [ ] **Step 2: Run, implement `PopupPolicy`, run** — Expected FAIL then PASS.
- [ ] **Step 3: Implement server** — accumulate bytes per connection until `HTTPRequest.parse` is `.complete`/`.invalid` (invalid → 400), call router, send, close; 5 s read timeout for the request itself.
- [ ] **Step 4: Implement manager** — consume `store.changes`; when `current` changes to a new decision and `PopupPolicy.shouldOpenNotch(frontmost: NSWorkspace.shared.frontmostApplication?.bundleIdentifier, …)`, post `.claudeDecisionArrived`.
- [ ] **Step 4b: Settings status** — in the "Claude" settings section show `Bridge listening on port <N>` and `Last decision received <relative time>` (or `No decisions yet`); the sandboxed app can't inspect the hook install, so this is the hook-health indicator.
- [ ] **Step 5: Verify with curl** — build & run, then:

```bash
B="$HOME/Library/Containers/theboringteam.boringnotch/Data/Library/Application Support/boringNotch/claude-bridge.json"
PORT=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['port'])" "$B"); TOK=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['token'])" "$B")
curl -s -X POST -H "Authorization: Bearer $TOK" -d '{"session":"s","kind":"permission","question":"Allow running ls?","command":"ls"}' localhost:$PORT/decision
curl -s -o /dev/null -w "%{http_code}\n" localhost:$PORT/decision/x
```

Expected: `{"id":"…"}` then `401`.
- [ ] **Step 6: Commit** — `git commit -am "feat: localhost Claude bridge server and decision manager"`

### Task 7: Decision pop-up UI

**Files:**
- Create: `boringNotch/components/Claude/ClaudeDecisionView.swift`, `boringNotch/components/Claude/ClaudeQuestionView.swift`
- Modify: `boringNotch/ContentView.swift` — while `ClaudeDecisionManager.shared.current != nil` and the notch is open, show the decision view in place of the tab content; open the notch on `.claudeDecisionArrived`; add `ClaudeDecisionManager.shared.current == nil` to every hover-exit / auto-close condition that currently checks `SharingStateManager.shared.preventNotchClose`.

**Interfaces:**
- Consumes: `ClaudeDecisionManager`, `PendingDecision` (Task 6), `DecisionQuestion` (Task 5).

- [ ] **Step 1: Permission view** per spec mock: header `Claude · <project>` + `(+N more)` when `queuedCount > 0`; question text; command monospaced, max 3 lines, full text in `.help`; explain in quotes; buttons `Deny` · `Answer in Claude` · `Allow` (Allow accent-coloured).
- [ ] **Step 2: Question view** — one question at a time with `1 of N`; single-select: tapping a row selects and advances (last one submits); multiSelect: checkboxes + `Submit`; `Answer in Claude` always visible. Answers map `question text → label`; multiSelect labels joined with `", "`.
- [ ] **Step 3: After answer** show "Sent" for 0.8 s, then the next queued decision or close the notch.
- [ ] **Step 4: Verify** — Safari frontmost, POST a permission decision (Task 6 Step 5): notch opens; moving the mouse away doesn't close it; Allow → `curl -H "Authorization: Bearer $TOK" "localhost:$PORT/decision/<id>?wait=0"` returns `{"status":"allow"}`. With Claude app frontmost: notch stays closed. POST `{"session":"s","kind":"question","question":"Which DB?","questions":[{"question":"Which DB?","options":[{"label":"Postgres"},{"label":"SQLite"}],"multiSelect":false}]}`, pick Postgres → `{"status":"answer","answers":{"Which DB?":"Postgres"}}`.
- [ ] **Step 5: Commit** — `git commit -am "feat: notch pop-up for Claude decisions"`

### Task 8: Multi-target hook (TV + notch)

**Files:**
- Create: `ClaudeBridge/tv_bridge.py` (start from a copy of `~/.config/tv-bridge/tv_bridge.py`; this repo copy becomes the source of truth; `install` copies it to `~/.config/tv-bridge/tv_bridge.py` as today)
- Test: `ClaudeBridge/tests/test_bridge.py`

**Interfaces:**
- Consumes: bridge file + HTTP API from Tasks 5–6.
- Produces:
  - `class Target` with `name`, `available() -> bool` (per-target backoff `DOWN_BACKOFF_S = 60`, marker `STATE/<name>.down`), `post_decision(payload) -> str | None`, `poll(id, wait) -> dict | None`, `delete(id)`, `event(**fields)` (TV sends; notch no-op). `TvTarget` wraps today's `Tv` class.
  - `class NotchTarget(Target)` reads the bridge file (path in Task 6); connect timeout 1 s; missing file or refused connection → unavailable (missing file doesn't set backoff).
  - `def race(targets, payload, deadline) -> dict | None` — posts to each available target, polls all concurrently (threads, `wait ≤ 55`), returns the first `{"status": "allow" | "deny" | "answer", …}`, then `delete`s the decision on every other target. TV `approvalsOff` → TV leaves the race, others continue.
  - `handle_hook` no longer returns early when the TV is down; session state always saved; `cancel_pending` deletes the pending id on every target (state stores `{target_name: id}`).
  - Output: allow → `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}`; deny → `behavior: "deny"`, message `"Declined on the TV"` or `"Declined in the notch"`; answer → `behavior: "allow"`, `updatedInput: {**tool_input, "answers": answers}`.
  - `tool_name == "AskUserQuestion"` → payload `kind="question"`, `question` = first question's text, `questions=tool_input["questions"]`; sent to the notch only.

- [ ] **Step 1: Failing tests** (`unittest`; fake targets are in-process `http.server` threads; point `HOME`-derived paths at a temp dir): `test_notch_allow_wins_and_tv_deleted`, `test_tv_deny_wins`, `test_no_targets_prints_nothing`, `test_stale_bridge_file_falls_back_within_2s` (bridge file points at a closed port; `handle_hook` returns `None` in < 2 s), `test_tv_down_notch_still_works`, `test_question_goes_to_notch_only_and_returns_updated_input`, `test_timeout_prints_nothing` (deadline 1 s), `test_approvals_off_keeps_waiting_on_notch`, `test_other_event_cancels_pending_on_all_targets`.
- [ ] **Step 2: Run** `python3 -I -m unittest discover -s ClaudeBridge/tests -v` — Expected: FAIL.
- [ ] **Step 3: Implement** the restructure; keep progress events, snapshots, `pair`/`status`/`unpair`/`install`/`uninstall` behaviour; `status` also reports the notch.
- [ ] **Step 4: Run tests** — Expected: PASS.
- [ ] **Step 5: Install** — `python3 -I ClaudeBridge/tv_bridge.py install` then `diff ClaudeBridge/tv_bridge.py ~/.config/tv-bridge/tv_bridge.py` — Expected: no diff; `~/.claude/settings.json` hook entries unchanged.
- [ ] **Step 6: Commit** — `git add ClaudeBridge && git commit -m "feat: multi-target Claude hook racing TV and notch"`

### Task 9: End-to-end check with real Claude Code

- [ ] **Step 1:** App running, Safari frontmost; in a Claude Code CLI session in a scratch folder ask it to run `ls` (not pre-allowed). Expected: notch pops up; Allow → command runs; Deny → Claude reports it was declined.
- [ ] **Step 2:** Ask Claude to "ask me a multiple-choice question using AskUserQuestion". Expected: question appears in the notch; Claude receives the chosen option. If not, adjust the answer shape in `tv_bridge.py` to what the installed Claude Code accepts (check `claude --version` and its hooks docs), update `test_question_goes_to_notch_only_and_returns_updated_input`, re-run Task 8 tests. If no shape works, make question decisions read-only (only "Answer in Claude") per the spec fallback.
- [ ] **Step 3:** Answer one prompt in the terminal instead. Expected: notch dismisses after Claude's next hook event.
- [ ] **Step 4:** Quit Boring Notch, trigger a prompt. Expected: normal Claude prompt within ~1 s (no 2-minute stall).
- [ ] **Step 5: Commit** any fixes — `git commit -am "fix: align question answers with Claude Code"`

### Task 10: Temperature sensors

**Files:**
- Create: `Packages/NotchExtras/Sources/NotchExtrasCore/Sensors.swift`; Test: `Packages/NotchExtras/Tests/NotchExtrasCoreTests/SensorsTests.swift`
- Create: `BoringNotchXPCHelper/SensorReader.swift` (IOHID: `IOHIDEventSystemClientCreate`, `IOHIDServiceClientCopyEvent` with `kIOHIDEventTypeTemperature` via `dlsym`; plus SMC `T***` key reads for GPU if IOHID lacks one)
- Modify: both protocol files, `BoringNotchXPCHelper.swift`, `XPCHelperClient.swift`

**Interfaces:**
- Produces:
  - `public struct SensorReading: Codable, Equatable { name: String; celsius: Double }`
  - `public struct SensorSummary: Equatable { cpu: Double?; gpu: Double?; extras: [SensorReading] /* name = display label */ }`
  - `public enum SensorMap { public static func summarize(_ r: [SensorReading]) -> SensorSummary }` — CPU = max of CPU-die sensors, GPU = max of GPU sensors; extras in order SSD, Trackpad, Power manager, Battery, then unrecognised raw names sorted; readings ≤ 0 or ≥ 130 °C dropped.
  - XPC `func readSensors(with reply: @escaping (Data?) -> Void)` (JSON `[SensorReading]`); client `func readSensors() async -> [SensorReading]`.

- [ ] **Step 1: Discover names** — temporary helper call printing all readings on this Mac; record which names map to CPU, GPU, SSD (`NAND…`), Trackpad, Power manager (`PMU…`), Battery (`gas gauge…`/`battery`) as the matching rules at the top of `Sensors.swift`.
- [ ] **Step 2: Failing tests** using those recorded names: `testCpuIsMaxOfDieSensors`, `testGpuMapped`, `testExtrasOrderAndLabels` (`"SSD"`, `"Trackpad"`, `"Power manager"`, `"Battery"`), `testOutOfRangeDropped`, `testMissingCategoriesHidden`.
- [ ] **Step 3: Run, implement, run** — `swift test --package-path Packages/NotchExtras --filter Sensors`: FAIL then PASS.
- [ ] **Step 4: Commit** — `git commit -am "feat: temperature sensor reading and mapping"`

### Task 11: Fan core logic

**Files:**
- Create: `Packages/NotchExtras/Sources/NotchExtrasCore/Fans.swift`; Test: `Packages/NotchExtras/Tests/NotchExtrasCoreTests/FansTests.swift`

**Interfaces:**
- Produces:
  - `public struct FanInfo: Codable, Equatable { index: Int; actual: Double; min: Double; max: Double; target: Double; manual: Bool }`; `public struct FanStatus: Codable, Equatable { fans: [FanInfo] }`
  - `public enum FanMath { static func snap(_ v: Double, min: Double, max: Double, step: Double = 100) -> Double; static func parseTyped(_ s: String, min: Double, max: Double) -> Double?; static func display(_ rpm: Double) -> String }` — `snap`: nearest multiple of `step`, clamped, range ends returned exactly; `parseTyped`: trims whitespace, nil unless an integer, else clamped; `display`: `< 1` → `"Off"`, else `"2990 rpm"` (rounded).
  - `public enum FanCommand: Equatable { case status, set(Double), auto, ping; static func parse(_ line: String) -> FanCommand? }` — wire: one line `status` | `set <int>` | `auto` | `ping`; reply one JSON line (`FanStatus`, `{"ok":true}` or `{"error":"…"}`).
  - `public struct FanWatchdog { public init(timeout: TimeInterval = 30); public mutating func touch(at: Date); public func shouldRevert(now: Date, manual: Bool) -> Bool }`
  - `public enum SMCValue { static func encodeFloat(_ v: Float) -> [UInt8] /* little-endian */; static func decodeFloat(_ b: [UInt8]) -> Float; static func fourCC(_ s: String) -> UInt32 }`

- [ ] **Step 1: Failing tests** — `testParseTyped` (`""`→nil, `"abc"`→nil, `"-5"`→2317, `"99999"`→6800, `"2350"`→2350, `" 3000 "`→3000; min 2317, max 6800), `testSnap` (2317→2317, 2360→2400, 6790→6800, 3049→3000), `testDisplay` (0→"Off", 2990.4→"2990 rpm"), `testCommandParse` (`"set 3000"`→`.set(3000)`, `"set"`→nil, `"set abc"`→nil, `"reboot"`→nil, `"status\n"`→`.status`), `testWatchdog` (manual & last touch 31 s ago → true; 29 s → false; not manual → false), `testFloatEncoding` (3000 → `[0x00,0x80,0x3B,0x45]`, round-trips), `testFourCC` (`"F0Md"` → `0x46304D64`).
- [ ] **Step 2: Run, implement, run** — `swift test --package-path Packages/NotchExtras --filter Fans`: FAIL then PASS.
- [ ] **Step 3: Commit** — `git commit -am "feat: fan math, command protocol and watchdog"`

### Task 12: `boring-fand` daemon + installer

**Files:**
- Modify: `Packages/NotchExtras/Sources/BoringFand/main.swift`; Create: `Packages/NotchExtras/Sources/BoringFand/SMC.swift` (AppleSMC client using the 80-byte `SMCKeyData_t` layout proven in the spike: struct method selector 2; key info `data8 = 9`, read `5`, write `6`)
- Create: `Packages/NotchExtras/Resources/theboringteam.boringnotch.fand.plist` (template with `__UID__` placeholder)
- Create: `BoringNotchXPCHelper/FanDaemonClient.swift`, `BoringNotchXPCHelper/FanDaemonInstaller.swift`
- Modify: both protocol files, `BoringNotchXPCHelper.swift`, `XPCHelperClient.swift`; app target in `project.pbxproj`: Run Script build phase "Build boring-fand" — `swift build -c release --package-path "$SRCROOT/Packages/NotchExtras" --product boring-fand`, copy the binary and plist into `$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/`, `codesign -f -s "Boring Notch Dev"` the binary.

**Interfaces:**
- Consumes: Task 11 types.
- Produces:
  - Daemon args: `--uid <uid>` (required), `--socket <path>` (default `/var/run/theboringteam.boringnotch.fand.sock`). Socket `chown <uid>`, `chmod 0600`. On start: all fans auto. `set` clamps to SMC min/max, writes `F{i}Md=1` then `F{i}Tg`. `auto` writes `F{i}Md=0`. Every command touches the watchdog; a 1 s timer reverts via `FanWatchdog`. `IORegisterForSystemPower` `kIOMessageSystemWillSleep` → auto (then `IOAllowPowerChange`). SIGTERM/SIGINT → auto, exit. Only the four commands exist; no generic SMC write.
  - Installed files: `/Library/PrivilegedHelperTools/theboringteam.boringnotch.fand` (root:wheel 0755), `/Library/LaunchDaemons/theboringteam.boringnotch.fand.plist` (root:wheel 0644, `RunAtLoad`, `KeepAlive`, `ProgramArguments = [binary, "--uid", "<console uid>"]`).
  - XPC: `func fanCommand(_ line: String, with reply: @escaping (String?) -> Void)`, `func isFanDaemonInstalled(with reply: @escaping (Bool) -> Void)`, `func installFanDaemon(_ resourcesPath: String, with reply: @escaping (Bool, String?) -> Void)`, `func uninstallFanDaemon(with reply: @escaping (Bool, String?) -> Void)`. Client: `fanCommand(_:) async -> String?`, `isFanDaemonInstalled() async -> Bool`, `installFanDaemon() async -> Result<Void, FanInstallError>`, `uninstallFanDaemon() async -> Result<Void, FanInstallError>` with `struct FanInstallError: Error { let message: String }`.
  - Installer: one `NSAppleScript` `do shell script "…" with administrator privileges` (run in the helper) that copies binary + plist from the app's Resources, substitutes `__UID__` with `getuid()`, sets owners/modes, `launchctl bootstrap system <plist>`. Uninstall: send `auto`, `launchctl bootout system/theboringteam.boringnotch.fand`, remove both files.

- [ ] **Step 1: Implement daemon**; run locally without installing: `swift build --package-path Packages/NotchExtras --product boring-fand` then `sudo Packages/NotchExtras/.build/debug/boring-fand --uid $(id -u) --socket /tmp/fand-test.sock` (owner runs this; needs password).
- [ ] **Step 2: Verify protocol** (Macs Fan Control quit) — `printf 'status\n' | nc -U /tmp/fand-test.sock` → JSON, 2 fans, min 2317, max 6800; `printf 'set 3000\n' | nc -U /tmp/fand-test.sock`, `status` after 5 s → actual ≈ 3000; send nothing for 35 s → `status` shows `"manual":false`; `set 99999` → target 6800; `printf 'write F0Md 1\n'` → `{"error":…}`; Ctrl-C daemon → fans auto.
- [ ] **Step 3: Implement helper client, installer, build phase**; build app — Expected: `boringNotch.app/Contents/Resources/theboringteam.boringnotch.fand` exists and `codesign -dv` on it shows `Authority=Boring Notch Dev`.
- [ ] **Step 4: Commit** — `git commit -am "feat: root fan daemon with watchdog and installer"`

### Task 13: Fans tab

**Files:**
- Create: `boringNotch/managers/FanManager.swift`, `boringNotch/components/Fans/FansView.swift`
- Modify: `boringNotch/ContentView.swift` (`.fans` → `FansView()`), `boringNotch/boringNotchApp.swift` (`applicationWillTerminate`: best-effort `fanCommand("auto")` with ≤ 1 s wait), `boringNotch/components/Settings/SettingsView.swift` (new "Fans" section: Show Fans tab, daemon status, Enable / Uninstall buttons; remove the temporary toggle from Task 4)

**Interfaces:**
- Consumes: `FanStatus`, `FanMath`, `SensorMap`, `SensorSummary` (Tasks 10–11); XPC client fan/sensor methods (Tasks 10, 12).
- Produces: `@MainActor final class FanManager: ObservableObject { static let shared; @Published private(set) var status: FanStatus?; @Published private(set) var sensors: SensorSummary?; @Published private(set) var daemonInstalled: Bool; @Published private(set) var manualTarget: Double?; func setSpeed(_ rpm: Double); func setAuto(); func startPolling(); func stopPolling(); func installDaemon() async; func uninstallDaemon() async }`

- [ ] **Step 1: Implement manager** — `startPolling()` on Fans tab appear (every 2 s: `status` + `readSensors`), `stopPolling()` on disappear or notch close; while `manualTarget != nil` send `ping` every 10 s regardless of polling; slider changes debounced 300 ms before `set`.
- [ ] **Step 2: Implement view** per spec mock: RPMs via `FanMath.display` ("Left"/"Right" for 2 fans, "Fan N" otherwise); `Auto` button (highlighted when not manual) and "Manual" label when manual; slider `min…max` through `FanMath.snap`; text field committing via `FanMath.parseTyped` (nil → revert to current target); CPU/GPU row; chevron toggling `Defaults[.fanSensorsExpanded]` revealing `extras`. Without daemon: sensors + "Enable fan control" button. Tab hidden when `status?.fans.isEmpty == true`.
- [ ] **Step 3: Verify** (Macs Fan Control quit) — Enable fan control (admin prompt) → `sudo launchctl print system/theboringteam.boringnotch.fand` shows `state = running`. Slider to 3000 → both fans ≈ 3000 within 5 s; type `4250` + Return → ≈ 4250; type `abc` → reverts; `Auto` → system control. Set 3000 and quit the app → auto within a few seconds. Set 3000 and `kill -9` the app → auto within ~30 s. Set 3000, sleep and wake → auto. Temperatures show CPU, GPU and the expanded extras.
- [ ] **Step 4: Full regression** — `swift test --package-path Packages/NotchExtras` (PASS), `python3 -I -m unittest discover -s ClaudeBridge/tests` (PASS), app build (`BUILD SUCCEEDED`); click through Home, Shelf (drop a file), music controls, volume/brightness HUD: unchanged.
- [ ] **Step 5: Commit** — `git commit -am "feat: Fans tab with temperatures"`
