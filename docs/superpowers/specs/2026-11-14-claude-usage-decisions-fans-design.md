# Boring Notch fork: Claude usage, Claude decisions, fan control

Date: 2026-11-14 · Status: draft for approval

## Intent

The owner uses Boring Notch daily on a 14" MacBook Pro (Mac14,9, M2 Pro, 2 fans, macOS 27.2) and works heavily in Claude Code (desktop app Code tab and CLI). Three things are missing:

1. Seeing Claude plan limits (5-hour and weekly) at a glance, without opening Claude.
2. Controlling the Mac's fans from the notch, replacing Macs Fan Control (which will be uninstalled once this works).
3. Answering Claude's permission prompts and multiple-choice questions from the notch while working in another app, instead of switching back.

Everything else in the app stays as it is.

## Goals

- Two new tabs in the open notch, after Home and Shelf: **Claude** (usage) and **Fans**.
- A notch pop-up that shows a pending Claude decision and lets the owner answer it.
- The pop-up and the existing TV bridge (`~/.config/tv-bridge/tv_bridge.py`) both offer every decision; first answer wins.

## Non-goals

- Changing existing tabs, HUDs, music, shelf, calendar, settings beyond adding sections for the new features.
- Fan curves or automatic temperature-based profiles (one manual speed for both fans, or Auto).
- Per-fan control.
- Upstreaming to TheBoredTeam (this is a personal fork; no Developer ID).
- Supporting Macs other than this one beyond "don't crash" (fan UI hides itself when there are no fans).

## Anti-goals (failure even if it "works")

- **Claude ever auto-allows something the owner didn't approve.** No answer, an error, or the app not running must all fall back to Claude's normal prompt.
- **A hook that slows down or breaks Claude Code.** All hook failures exit 0 with no output.
- **Fans left stuck in manual at a low speed** after quit, crash, sleep, or helper restart.
- **A root service any process can abuse** (arbitrary SMC writes, unbounded speeds).
- **Invalidating the owner's Claude Code login** (e.g. by refreshing the OAuth token ourselves and rotating the refresh token out from under Claude Code).

## Constraints (from the codebase and spike)

- Main app is sandboxed (`boringNotch.entitlements`: app-sandbox, network.client, network.server). It cannot read another app's Keychain item or open the SMC for writing.
- `BoringNotchXPCHelper` is an XPC service, **not sandboxed**, running as the user. Already used for accessibility and brightness (`XPCHelperClient.swift`). It can read the Keychain (with a one-time "Always allow" prompt) and read SMC/IOHID.
- Tabs: `NotchViews` enum (`enums/generic.swift`), `tabs` array (`components/Tabs/TabSelectionView.swift`), switch in `ContentView.NotchLayout()`. Header visibility of tabs is driven by `BoringHeader` / `alwaysShowTabs`.
- Settings use `Defaults` keys in `models/Constants.swift` and sections in `components/Settings/SettingsView.swift`.
- macOS 14 deployment target, Swift 5.
- No Apple Developer ID → `SMAppService.daemon` is not an option.

### Fan spike result (2026-11-14, run as root on this Mac)

- SMC via `IOServiceOpen("AppleSMC")`, `IOConnectCallStructMethod` selector 2, classic 80-byte `SMCKeyData_t`.
- Keys present: `FNum`=2; per fan `F{i}Ac` (flt, actual), `F{i}Mn`=2317, `F{i}Mx`=6800, `F{i}Tg` (flt, target), `F{i}Md` (ui8, 0=auto, 1=manual). **No `Ftst` key** on this machine; no unlock step needed.
- Reads work as a normal user. Writing `F{i}Md=1` then `F{i}Tg=3000.0` as root: both fans reached ~3000 RPM in ~4 s, held ±30 RPM. Writing `F{i}Md=0` returned them to auto.
- Idle fans report 0 RPM (fans stopped); that's normal and the UI must show it as "Off", not an error.
- Throwaway spike source: scratchpad `fanspike/smcspike.c` (not to be reused as-is).

## Approaches (decided)

### Usage data

- **A — chosen.** The XPC helper reads Claude Code's OAuth token from the Keychain item `Claude Code-credentials` (JSON, `claudeAiOauth.accessToken` / `expiresAt`) and calls the usage endpoint Claude Code's `/usage` screen uses (`GET https://api.anthropic.com/api/oauth/usage` with the OAuth beta header). Real 5-hour and weekly utilisation % and reset times. Risk: undocumented endpoint.
- B — rejected. Estimate from local `~/.claude/projects/*.jsonl` logs (ccusage-style). Can't show % of limit; misses claude.ai/desktop chat usage.

### Decision transport

- **A — chosen.** Boring Notch runs a localhost-only HTTP server. One combined hook (the existing `tv_bridge.py` extended) posts each decision to both the notch and the TV and returns whichever answer comes first. Shared-secret token.
- B — rejected. File-drop queue in a shared folder; awkward under the sandbox and slower.

### Fan/sensor privilege

- **A — chosen.** A tiny root LaunchDaemon ("fan daemon"), installed once via an admin-password prompt, that exposes only bounded fan commands and sensor reads.
- B — rejected. `SMAppService` privileged helper; needs Developer ID signing.
- C — rejected. setuid SMC CLI; any local process could drive the fans.

## Design

### 0. Stable code signing (first step, owner's decision)

The app and XPC helper are currently ad-hoc signed (`CODE_SIGN_IDENTITY = "-"`, no team), so Keychain "Always allow" grants would be lost on every rebuild. Before any feature work: create a self-signed code-signing certificate (or a free Apple Development one) in the owner's login keychain and sign all targets (app, XPC helper, fan daemon) with it, keeping bundle IDs fixed. This also gives the fan daemon a stable identity.

### 1. Claude usage tab

**UI** (new `NotchViews.claude`, icon e.g. `sparkle` / `gauge.medium`, label "Claude"):

```
 Claude usage                         updated 1m ago  ↻
 5-hour   ███████░░░░░░░░  46%   resets in 2h 14m
 Weekly   ████░░░░░░░░░░░  27%   resets Thu 09:00
```

- Bar colour: normal ≤ 70%, amber 70–90%, red > 90% (builder's default).
- If the endpoint also returns a model-specific weekly bucket (e.g. Opus), show it as a third, smaller row only when present.
- Refresh every 2 min while the app runs, immediately when the tab opens, and on ↻. Cache last result in memory; show "updated Xm ago".
- States: loading; ok; "Sign in to Claude Code" (no Keychain item); "Keychain access denied — click to retry" (user declined the Keychain prompt); "Open Claude Code to refresh login" (token expired — **we never refresh the token ourselves**); "Couldn't reach Anthropic" (network/other error, keep showing last value greyed).

**Data flow:** `ClaudeUsageManager` (main app, `ObservableObject`, singleton like other managers) → `XPCHelperClient` → new helper method `fetchClaudeUsage(reply: (Data?, String?) -> Void)` → helper reads Keychain, checks `expiresAt`, does the HTTPS call, returns raw JSON or an error code. Parsing happens in the app so endpoint changes are a one-file fix. The token never leaves the helper.

### 2. Claude decisions pop-up

**Hook side (in `~/.config/tv-bridge/tv_bridge.py`, which is already installed for `PermissionRequest` with a 150 s timeout):**

- The owner approved restructuring this file; nothing else depends on it. Today `handle_hook` returns immediately when the TV is unreachable and a TV error disables everything (`mark_down`). Rework it into a multi-target bridge: each target (TV, notch) has its own config/pairing, reachability and backoff; session state is kept even with no TV; progress events, snapshots and `install`/`uninstall` keep their current behaviour.
- **Permission prompts** go to both targets; first answer wins. **Multiple-choice questions** go to the notch only (the TV app only supports allow/deny); the TV may show its existing "answer on the Mac" card. If the TV reports `approvalsOff`, the hook keeps waiting on the notch.

- Add a "notch" target next to the TV: `POST http://127.0.0.1:<port>/decision` with a bearer token read from a bridge file the app writes (`{port, token}`; builder picks a path the sandboxed app can write and the hook can read).
- `handle_permission` posts to every reachable target (notch, TV), then polls them concurrently; the first `allow`/`deny`/`answer` wins, and the hook `DELETE`s the decision on the other targets so they dismiss. No reachable target → no output (normal Claude prompt). Timeout stays 120 s → no output.
- Payload adds `kind`: `permission` or `question`. For `AskUserQuestion`, include the full `questions` array (question, header, options with label/description, multiSelect).
- Any other hook event for the same session clears a pending decision on all targets (existing `cancel_pending` behaviour, extended to the notch) — this is how "answered in Claude" dismisses the notch.
- Return value for a question: `allow` with `updatedInput` containing the original `questions` plus the chosen `answers` (builder must verify the exact shape Claude Code expects for `AskUserQuestion` via `PermissionRequest`; if not answerable that way, fall back to showing the question read-only with an "Answer in Claude" button only).
- Keep the hook standard-library-only and fail-safe, matching the file's current rules.

**App side:**

- `ClaudeBridgeServer`: localhost-only (`127.0.0.1`) HTTP server using `Network.framework` (`NWListener`), random port + random token generated per launch and written to the bridge file. Endpoints mirror the TV: `POST /decision`, `GET /decision/{id}?wait=N` (long-poll), `DELETE /decision/{id}`. Rejects requests without the token.
- `ClaudeDecisionManager` holds the queue (FIFO; one shown at a time, "+2 more" badge).
- When a decision arrives:
  - If the frontmost app is Claude (`com.anthropic.claudefordesktop`) or a terminal/editor likely running Claude Code (Terminal, iTerm2, Ghostty, Warp, VS Code, Cursor — builder's list), **don't open the notch**; keep the decision available (the normal Claude prompt is on screen anyway).
  - Otherwise open the notch on the screen with the notch and show the decision view (a transient view, not a tab), with a subtle haptic.
  - The notch must not auto-close on mouse-exit while a decision is showing.
- **Permission view:**
  ```
  Claude · boring.notch                     (+1 more)
  Allow running:  git push origin feat/fans
  "Push the branch to GitHub"
  [ Deny ]   [ Answer in Claude ]   [ Allow ]
  ```
  "Answer in Claude" withdraws the notch's offer (hook keeps waiting on the TV/normal prompt) and brings the Claude desktop app to the front (decisions from terminal sessions also just activate the Claude app — builder's call; payload has no terminal identity).
- **Question view:** question text, options as rows (label + description), radio for single-select, checkboxes + Submit for multiSelect, "Answer in Claude" button. Multiple questions in one call: show one at a time with "1 of 3".
- After answering: brief "Sent" confirmation, then the notch closes (or shows the next queued decision).

### 3. Fans tab

**UI** (new `NotchViews.fans`, icon `fan`, label "Fans"):

```
 Fans                                   [ Auto ]
 Left 2990 rpm · Right 3005 rpm         Manual
 ───────────●──────────────  [ 3000 ] rpm
 CPU 52°C   GPU 47°C                         ⌄
   SSD 38°C · Trackpad 31°C · Power mgr 44°C · Battery 30°C …
```

- Slider spans the fans' real min–max from SMC (2317–6800 here), snaps to 100 RPM; the min end is labelled with the real min. Text field accepts any integer, clamped to min–max on commit (Return / focus loss); invalid input reverts.
- Dragging the slider or committing the field switches to Manual and sends the speed to both fans. **Auto** returns both fans to system control.
- "0 rpm" displays as "Off".
- Readings refresh every 2 s while the tab is visible; no polling while the notch is closed.
- Chevron reveals the extra sensors; the expanded state persists (`Defaults`).
- If the fan daemon isn't installed: the tab shows sensors (readable without root via the helper) and an **"Enable fan control"** button that runs the installer (admin prompt).

**Sensors:** read in the non-root XPC helper. Apple Silicon temperatures come from IOHID temperature sensors (`IOHIDEventSystemClient`, `kIOHIDEventTypeTemperature`) and/or SMC `T***` keys. The builder discovers the names on this Mac and maps them to: CPU (aggregate of core die sensors), GPU, SSD (NAND), Trackpad, Power manager (PMU), Battery; unknown extras go in the expanded list with their raw names. Names that don't exist are hidden.

**Fan daemon (root):**

- Small Swift command-line target in this repo, installed as `/Library/PrivilegedHelperTools/<id>.fand` + `/Library/LaunchDaemons/<id>.fand.plist` (KeepAlive). Installed and uninstalled via `osascript … with administrator privileges` (run from the app or the unsandboxed helper; builder decides).
- Talks to the app over a Unix domain socket or localhost TCP (builder's call within the sandbox's limits), accepting only:
  - `status` → fan count, min, max, actual, target, mode.
  - `set <rpm>` → clamps to [min, max] and sets both fans manual + target.
  - `auto` → both fans mode 0.
- Caller check: only the console user can talk to it (socket permissions, or a token file readable only by that user for TCP). No generic SMC write path.
- **Safety:** the daemon resets fans to Auto when the app stops sending a heartbeat for ~30 s (covers crash/quit), on system sleep, on daemon start, and on SIGTERM. The app also sends `auto` on `applicationWillTerminate`.
- Manual speed is not persisted across app restarts (always start in Auto) — builder's default.

### Settings

A new "Claude" section and a "Fans" section in `SettingsView`:

- Claude: toggle usage tab; toggle decision pop-up; "Show pop-up even when Claude is in front" (default off); bridge status ("Hook connected" / "Hook not reachable").
- Fans: toggle fans tab; fan daemon status + Enable/Uninstall.

## Left to the builder

- Exact SF Symbols, spacing, colours within the existing notch style.
- Exact IOHID/SMC sensor names and the CPU aggregation formula.
- Socket vs TCP for the fan daemon; bridge-file location reachable by both sandboxed app and hook.
- Verifying the `AskUserQuestion` answer shape for `PermissionRequest` hooks against the installed Claude Code.
- Verifying the usage endpoint response fields against a live call (tolerant parsing: unknown fields ignored, missing buckets hidden).
- Build order: usage → decisions → fans.
