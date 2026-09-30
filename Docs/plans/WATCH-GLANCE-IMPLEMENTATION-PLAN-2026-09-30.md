# Watch Glance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** "Agent needs you" alerts read correctly on a wrist (Phase 1), and the existing session Live Activity gets a custom `.small` layout for the Apple Watch Smart Stack and CarPlay, built from reusable pieces the future agent Live Activity (LA2) can adopt without redesign (Phase 2). No Watch app.

**Architecture:** Phase 1 is copy, one test and one Settings row in the iPhone app. Phase 2 adds a plain value (`WatchGlance`), a pure session-to-glance mapping, a pure Mac-line formatter for LA2's future presence fields, and one SwiftUI view (`WatchGlanceView`), all in `RemotePhone/ActivityShared` so the app, the widget extension and `RemotePhoneTests` compile the same code. The widget then opts in with `.supplementalActivityFamilies([.small])` and switches on `@Environment(\.activityFamily)`.

**Tech Stack:** Swift 6, SwiftUI, ActivityKit, WidgetKit (`ActivityFamily`, iOS 18+), UserNotifications, XCTest, XcodeGen.

**Spec:** `Docs/plans/WATCH-GLANCE-DESIGN-2026-09-30.md` (commit `e5756ee`, approved 30 Sep with every recommended answer; Watch ownership unanswered, so no Watch is assumed), as amended by Task 0.

## Scope

- **In:** spec §3 Notification (A) and §7 test-alert delay; spec §3 Smart Stack `.small` for the session activity (LA3); the Mac line as a tested, unwired formatter; render and fit checks at every Watch and CarPlay size.
- **Out (do not build):** LA2 / `FarsideAgentAttributes`, any APNs, provider, server or `Backend/` change, host presence or sleep/wake reporting, Mac vitals, a watchOS target, WatchConnectivity, controls, buttons on the wrist. Nothing here depends on branch `farside-mac-vitals`.

## Verified platform facts (checked 30 Sep 2026)

- `ActivityFamily` (`.small`, `.medium`), `EnvironmentValues.activityFamily` and `WidgetConfiguration.supplementalActivityFamilies(_:)`: iOS/iPadOS 18.0+, no beta flag (developer.apple.com JSON for each symbol). Our deployment target is 26.0, so no availability checks. Apple's own sample applies `.supplementalActivityFamilies([.small, .medium])` to the `ActivityConfiguration`.
- The iPhone renders natively as `.medium`; `.small` is what the Watch Smart Stack and CarPlay use once opted in (ActivityFamily docs, HIG Live Activities).
- Smart Stack sizes (HIG, "same dimensions as watchOS widgets"): 40 mm 152×69.5, 41 mm 165×72.5, 44 mm 173×76.5, 45 mm 184×80.5, 49 mm 191×81.5 pt. CarPlay: 240×78, 240×100, 170×78 pt. Newer 42/46 mm cases are not in the HIG table: **[U]**.
- Without a Watch app a tap opens a system full-screen view with a button to open the iPhone app; CarPlay deactivates interactive elements (HIG).
- Toolchain: Xcode 27.0 (27A266a), iOS 27.0 and watchOS 27.0 simulator runtimes.

## Global Constraints

- No buttons, `Link`s or intents inside `WatchGlanceView`. The Watch never acts.
- No ember in the `.small` layout (`Farside.Palette.void`, `bone`, `ash`, `panel`, `line2` only). Meaning is carried by words and glyphs, never colour.
- No animation or pulse in the `.small` layout at all (simpler than gating on `isLuminanceReduced` and Reduce Motion, and satisfies both).
- `.privacySensitive()` on the detail and note lines. No prompt text, file names, screen content or latency. The Mac's name appears only through `attributes.macLabel` (already "Your Mac" unless the person opted in); the Mac line itself says "Mac".
- Wire rules for anything Codable in `ActivityShared` (as `FarsideSessionAttributes.swift:6-9`): string raw values and integer Unix seconds, no `Date`, no payload-carrying enums, every new field optional, and an unknown string value must never fail decoding.
- Exact user-facing copy is in the tables below. Change it only if a fit test proves it cannot fit; then report, do not improvise.
- Code comments only where the *why* is non-obvious. No docstrings restating names.
- Repo rules (AGENTS.md): wrap every `xcodebuild`/`xctest` in `lockf -k /tmp/farside-xcodebuild.lock`; never install to a phone or `/Applications`; never run `script/build_and_run.sh`; never touch other worktrees or the main checkout; shut down simulators you boot; commit messages are an imperative subject, a body, and the final line `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **Double Tap only snoozes.** The first action of `AGENT_HELP` stays Snooze, non-destructive, non-foreground. Test: Task 1 `testSnoozeStaysFirstSoAWatchDoubleTapOnlySnoozes`.
2. **Nothing on the wrist acts.** `WatchGlanceView` contains no `Button`, `Link` or `Toggle`; the `.small` branch is the only new code in the widget. Review by reading Task 3 and Task 4 diffs.
3. **Honesty.** A stale session never looks live; the Mac line never claims a Mac is up without a seen time, shows "Not seen since HH:MM" when stale, and omits a missing battery (never "0%"). Tests: Task 2 `testStaleSessionNeverLooksLive`, `testStaleOrUnseenMacNeverLooksAwake`, `testMissingOrImpossibleBatteryIsOmitted`.
4. **Absent-safe presence fields.** `MacPresence` decodes `{}` and unknown `macState` values without throwing. Test: Task 2 `testPresenceDecodesWhenFieldsAreMissingOrUnknown`.
5. **It fits on a 40 mm Watch.** Every session line fits the 40 mm text width at its minimum scale. Test: Task 3 `testEverySessionLineFitsTheSmallestWatch`.
6. **The iPhone Lock Screen is unchanged.** `.medium` still renders `SessionLockScreenView`. Test: the full `RemotePhoneTests` run in Task 4 plus diff review.

---

## Execution model (read first)

- **Waves.** Task 0 (orchestrator) alone. Wave 1: Tasks 1, 2 and 3 in parallel (disjoint files; Task 3 uses literal fixtures, not Task 2's mapping). Wave 2: Task 4. Then a whole-branch review and the ledger (orchestrator).
- **One worktree per task:** `git worktree add -b watch/<task> .claude/worktrees/watch-<task> <farside-watch-glance head>`.
- **Never commit `PocketDesktop.xcodeproj` or `project.yml` in Tasks 1–4.** Task 0 registers every new file. If you ran `xcodegen generate`, `git checkout -- PocketDesktop.xcodeproj` before committing.
- **Builds.** `DD=/Volumes/Studio/Development/Caches/Xcode/DerivedData/watch-<task>`. Check `df -h / /Volumes/Studio` first; stop and report if either has under 20 GB free. The orchestrator deletes your DerivedData after merge.
- **Phone test command** (own simulator, created in Task 0):
  ```bash
  SIM=$(xcrun simctl list devices -j | python3 -c "import json,sys;print([d['udid'] for r in json.load(sys.stdin)['devices'].values() for d in r if d['name']=='Farside Watch iPhone'][0])")
  lockf -k /tmp/farside-xcodebuild.lock sh -c 'xcodebuild -project PocketDesktop.xcodeproj -scheme PocketDeskRemote -destination "id=$0" -derivedDataPath "$1" -parallel-testing-enabled NO -collect-test-diagnostics never -only-testing:RemotePhoneTests/<ClassName> test; rc=$?; xcrun simctl shutdown "$0"; exit $rc' "$SIM" "$DD"
  ```
  Parallel tasks share this simulator, so the shutdown runs **inside** the lock; shutting it down outside would kill another task's run. Several `-only-testing:` flags may be combined in one run.
- **Widget build check** (Tasks 3, 4): `lockf -k /tmp/farside-xcodebuild.lock xcodebuild -project PocketDesktop.xcodeproj -scheme PocketDeskRemote -destination "id=$SIM" -derivedDataPath "$DD" build` (the app scheme embeds and builds `FarsideWidgets`).
- **Report** exact pass/fail/skip counts. A failing unrelated pre-existing test is reported, not "fixed".

---

### Task 0: Scaffold, spec amendments, simulator (orchestrator, alone)

**Files:**
- Create: `RemotePhone/ActivityShared/WatchGlance.swift` and `RemotePhone/ActivityShared/WatchGlanceMetrics.swift` (stubs below), `RemotePhone/ActivityShared/WatchGlanceView.swift` (stub), `RemotePhone/ActivityShared/FarsideMarkGlyph.swift` (moved, real)
- Create (empty test classes): `RemotePhoneTests/WatchGlanceSessionTests.swift`, `RemotePhoneTests/MacGlanceLineTests.swift`, `RemotePhoneTests/WatchGlanceLayoutTests.swift`
- Modify: `FarsideWidgets/SessionLiveActivity.swift` (remove the moved glyph only), `PocketDesktop.xcodeproj` (regenerated; `project.yml` needs no change because targets list folders), `Docs/plans/WATCH-GLANCE-DESIGN-2026-09-30.md` (amendments)

- [ ] **Step 1: Amend the spec.** Append "Amendments — 30 September 2026 (implementation)" to the spec:
  1. **Session stale in `.small`:** the session activity carries no Mac seen time, so the stale row's line 3 cannot exist for it. A stale session shows `Session ended?` / `Check your iPhone.` (matching the Lock Screen's existing "Session ended?"), never a live title or a running clock.
  2. **Session phases the table omits:** reconnecting, and each ended reason, get the short copy in Task 2's table.
  3. **Mac line wording:** `Mac · seen 11:41 · 64%`, not `Your Mac · seen 1 min ago · 64%`. A Live Activity only redraws on an update, and LA2 updates only on a state change, so "1 min ago" would freeze and become false; an absolute time never does and matches `Not seen since 11:42`. "Mac" (not the Mac label) keeps the line inside 40 mm and matches the vitals spec's `Mac · …` lines.
  4. **Times** use SF Pro with monospaced digits (as the existing `SessionClock`), not SF Mono: SF Mono's `Lets go in 0:42` does not fit 40 mm.
  5. **No pulse at all** in `.small` (spec §3 already forbids it on Always-On and Reduce Motion).
  6. **Fit findings for LA2 (not built here):** at 40 mm `Claude Code needs you` does not fit the title width even at the 0.7× minimum (`An agent needs you` does); `12 min · nothing needs you` and `Nothing was sent to your Mac.` do not fit one line at any allowed scale. LA2 must shorten them or let the title wrap; Task 3's fit helper is the check to use.
  7. **Mac presence fields** are modelled now as `MacPresence` (all optional, unknown values decode as not seen) so LA2 can embed them; no existing activity carries them, so nothing shows a Mac line yet.
  8. **Dismissal:** the existing ended-session dismissal (6 s after End, 90 s otherwise, `EndSessionIntent.swift:39-41`) is already shorter than the spec's 2 min, so it stays.
- [ ] **Step 2: Move `FarsideMarkGlyph`** from `FarsideWidgets/SessionLiveActivity.swift:359-386` to `RemotePhone/ActivityShared/FarsideMarkGlyph.swift`, adding `var tip: Color = Farside.Palette.ember` so the Watch can draw it all bone. Behaviour for existing call sites is unchanged.
- [ ] **Step 3: Write the stubs.**

`RemotePhone/ActivityShared/WatchGlance.swift`:
```swift
import CoreGraphics
import Foundation

/// What a Live Activity shows in its `.small` family (Watch Smart Stack and CarPlay): at most three
/// lines and no controls. A plain value so the session activity today and LA2 later draw the same way.
struct WatchGlance: Equatable {
    enum Mark: Equatable { case plain, needsYou }

    enum Detail: Equatable {
        case text(String)
        /// A system-drawn clock, so the glance stays right between updates.
        case clock(prefix: String?, interval: ClosedRange<Date>, countsDown: Bool)
    }

    var mark: Mark
    var title: String
    var detail: Detail
    var note: String?
    var accessibilityLabel: String
}

enum SessionGlance {
    static func glance(attributes: FarsideSessionAttributes, state: FarsideSessionAttributes.ContentState,
                       isStale: Bool, now: Date = .now) -> WatchGlance {
        WatchGlance(mark: .plain, title: "", detail: .text(""), note: nil, accessibilityLabel: "")
    }
}

/// Mac presence as LA2's content state will carry it (names from the Mac vitals spec). Every field is
/// optional and an unknown state decodes as not seen, because a state that fails to decode silently
/// stops a Live Activity from updating.
struct MacPresence: Codable, Hashable {
    enum State: String { case awake, asleep, notSeen }

    var macState: String?
    var macSeenUnix: Int?
    var batteryPercent: Int?
    var power: String?

    var state: State { .notSeen }
    var seenAt: Date? { nil }
}

enum MacGlanceLine {
    static func text(for presence: MacPresence?, isStale: Bool,
                     timeZone: TimeZone = .current, locale: Locale = .current) -> String? { nil }
}
```

`RemotePhone/ActivityShared/WatchGlanceMetrics.swift`:
```swift
import CoreGraphics

enum WatchGlanceMetrics {
    struct Surface: Equatable {
        let name: String
        let size: CGSize
    }

    static let titleSize: CGFloat = 15
    static let detailSize: CGFloat = 13
    static let noteSize: CGFloat = 12
    static let horizontalPadding: CGFloat = 8
    static let verticalPadding: CGFloat = 6
    static let glyphHeight: CGFloat = 13
    static let glyphSpacing: CGFloat = 5
    static let lineSpacing: CGFloat = 2
    static let titleMinimumScale: CGFloat = 0.7
    static let lineMinimumScale: CGFloat = 0.85

    static let watchSurfaces: [Surface] = []
    static let carPlaySurfaces: [Surface] = []
    static var allSurfaces: [Surface] { watchSurfaces + carPlaySurfaces }

    static func lineWidth(in size: CGSize) -> CGFloat { 0 }
    static func titleWidth(in size: CGSize) -> CGFloat { 0 }
}
```

`RemotePhone/ActivityShared/WatchGlanceView.swift`:
```swift
import SwiftUI

struct WatchGlanceView: View {
    let glance: WatchGlance

    var body: some View {
        EmptyView()
    }
}
```

Each test file: `import XCTest` / `@testable import PocketDeskRemote` / `final class <Name>: XCTestCase {}` (`WatchGlanceLayoutTests` is `@MainActor`).
- [ ] **Step 4:** `xcodegen generate`; create simulator `Farside Watch iPhone` (iPhone 17 Pro, iOS 27.0); build the app scheme (which builds the widget) with DerivedData `watch-task0`; commit "Scaffold Watch glance interfaces, tests and spec amendments"; push `farside-watch-glance`.

---

### Task 1: Notification polish for the wrist (Phase 1)

**Files:**
- Modify: `RemotePhone/en.lproj/Localizable.strings:5`, `RemotePhone/SystemIntegrations/AgentAlertCenter.swift` (one constant), `RemotePhone/SystemIntegrations/AgentAlertViews.swift` (one row, one action), `RemotePhoneTests/AgentAlertPayloadTests.swift`, `RemotePhoneTests/AgentAlertCenterTests.swift`, `RemotePhoneUITests/SystemIntegrationsUITests.swift`
- Consumes: nothing from other tasks.

- [ ] **Step 1: Failing tests first.**
  - `AgentAlertPayloadTests.testAlertCopyLivesInTheBundleAndIsLiteral`: expect `AGENT_NEEDS_YOU_BODY` = `Stuck on something only a human can click. Open Farside on your iPhone to look.`; add `XCTAssertFalse(body.contains("Tap"), "On a Watch, a tap leads nowhere")`.
  - New `AgentAlertPayloadTests.testSnoozeStaysFirstSoAWatchDoubleTapOnlySnoozes`: the `AGENT_HELP` category's `actions.first` is `SNOOZE_15`, with no `.destructive`, `.foreground` or `.authenticationRequired`; the reminder category's first action is `NOT_NOW` (it has no Snooze). Failure message names the reason: Double Tap on Series 9 / Ultra 2 runs the first non-destructive action.
  - New `AgentAlertCenterTests.testTheWatchTestAlertWaitsTenSeconds`: with access allowed, `await center.sendTestAlert(after: AgentAlertCenter.watchTestDelay)` adds one request whose trigger interval is `10` and whose content equals the ordinary test alert's title and body.
- [ ] **Step 2: Implement.**
  - Strings: the new body above. Nothing else in the file changes. `Backend/src/push.ts` sends the key, not the text, so it needs no change.
  - `AgentAlertCenter`: `static let watchTestDelay: TimeInterval = 10` next to `sendTestAlert`.
  - `AgentAlertViews` Settings: directly after the "Send test alert" row, on iPhone only (`UIDevice.current.userInterfaceIdiom == .phone`; a Watch pairs with an iPhone), a row with the same styling, `label("Send test alert in 10 s", watchTestStatus ?? "Lock your iPhone to see it on your Watch.")`, `Image(systemName: "applewatch")`, disabled and 0.4 opacity when alerts are off, identifier `agent.settings.testWatch`. The previous row's `divider:` becomes `true`. Its action sets `watchTestStatus = "Sending…"`, then `await center.sendTestAlert(after: AgentAlertCenter.watchTestDelay)`, then `"Sent. Lock your iPhone now."` or `"Turn on agent alerts first."`.
  - `SystemIntegrationsUITests.testTheSwitchTurnsAlertsOnThroughPrimingAndIOSAndOffAgain`: where it checks `agent.settings.test`, also check `agent.settings.testWatch` exists and is enabled when alerts are on, and disabled after they are turned off.
- [ ] **Step 3: Verify.** Run `AgentAlertPayloadTests`, `AgentAlertCenterTests`, `AgentAlertFromMacTests` (unit) and `RemotePhoneUITests/SystemIntegrationsUITests/testTheSwitchTurnsAlertsOnThroughPrimingAndIOSAndOffAgain` (UI; `-only-testing:RemotePhoneUITests/...`). Grep the repo (excluding `.claude/`) for `Tap to look at your Mac` and update any doc that quotes the old body.
- [ ] **Step 4: Commit** "Point wrist alerts at the iPhone and add a 10 s Watch test alert".

---

### Task 2: Session glance mapping and the Mac line (Phase 2, pure)

**Files:**
- Modify: `RemotePhone/ActivityShared/WatchGlance.swift` (`SessionGlance`, `MacPresence`, `MacGlanceLine`; do not change the `WatchGlance` type)
- Test: `RemotePhoneTests/WatchGlanceSessionTests.swift`, `RemotePhoneTests/MacGlanceLineTests.swift`
- Consumes: Task 0 stubs.

**Session copy** (`macLabel` is `attributes.macLabel`; `started` is `attributes.startedAt`; `grace` is `state.graceEndsAt`):

| Case | title | detail | note |
|---|---|---|---|
| live | `Live · \(macLabel)` | `.clock(prefix: nil, interval: started...started+8 h, countsDown: false)` | `End it on your iPhone.` |
| paused, `grace > now` | `Paused` | `.clock(prefix: "Lets go in", interval: now...grace, countsDown: true)` | nil |
| paused, no or past grace | `Paused` | `.text("Lets go soon.")` | nil |
| reconnecting | `Reconnecting` | `.text("Hold on.")` | nil |
| ended `.user` (or nil reason) | `Session ended` | `.text("Mac handed back.")` | nil |
| ended `.timeout` | `Farside let go` | `.text("You were away.")` | nil |
| ended `.macStopped` | `Sharing stopped` | `.text("Stopped at the Mac.")` | nil |
| ended `.error` | `Session ended` | `.text("Nothing left open.")` | nil |
| `isStale` (any phase) | `Session ended?` | `.text("Check your iPhone.")` | nil |
| `attributes.isPreview` | as above | as above | `Sample · preview` (replaces any note) |

`mark` is always `.plain`. `accessibilityLabel` is `SessionActivityCopy.accessibilitySummary(for: state, stale: isStale)`, prefixed with `Sample. ` for a preview.

**Mac line** (`MacGlanceLine.text`). `HH:MM` is `Date.FormatStyle().hour().minute()` with the given locale and time zone.

| Input | Output |
|---|---|
| `presence == nil` | `nil` (no line) |
| `isStale`, or `state == .notSeen`, or `.awake` with no `macSeenUnix` | `Not seen since HH:MM` if `macSeenUnix` is known, else `Mac not seen lately` |
| `.awake` with a seen time | `Mac · seen HH:MM`, plus ` · NN%` when `batteryPercent` is in 1…100 |
| `.asleep` (only ever set by the host announcing sleep) | `Mac · asleep since HH:MM`, or `Mac · asleep` with no seen time; never a battery |

`MacPresence.state`: `State(rawValue: macState ?? "") ?? .notSeen`. `seenAt`: `macSeenUnix` as a `Date`. `power` is carried for LA2 but not shown.

- [ ] **Step 1: Failing tests** (`WatchGlanceSessionTests`): one test per row of the session table with exact strings and exact `Detail` values (use fixed `now`, `startedAtUnix`, `graceEndsAtUnix`); `testStaleSessionNeverLooksLive` (every phase with `isStale: true` gives `Session ended?`, a `.text` detail, no note); `testNoSessionGlanceHasAMacLineOrAButtonWord` (no title/detail/note contains `seen`, `%`, `Tap`, `End session`); `testTheMacNameOnlyAppearsThroughTheLabel` (label `Your Mac` vs `Roshan's Mac`); `testPreviewIsLabelled`; `testAccessibilityReusesTheLockScreenSummary`.
- [ ] **Step 2: Failing tests** (`MacGlanceLineTests`, `TimeZone(identifier: "UTC")`, `Locale(identifier: "en_GB")` for `HH:MM`): each row of the Mac table; `testStaleOrUnseenMacNeverLooksAwake` (no output for a stale, not-seen or unknown state contains `seen HH` or `awake`); `testMissingOrImpossibleBatteryIsOmitted` (nil, 0, -5, 101, 250 → no `%`; 64 → ` · 64%`); `testAsleepNeverShowsBattery`; `testPresenceDecodesWhenFieldsAreMissingOrUnknown` (`{}` → all nil, `.notSeen`; `{"macState":"hibernating"}` → `.notSeen`; a full payload round-trips); `testPresenceEncodesToPlainStringsAndIntegers` (keys exactly `macState`, `macSeenUnix`, `batteryPercent`, `power`; values strings and integers).
- [ ] **Step 3: Implement** until green. Run both classes plus `SessionActivityWireTests` (regression; it shares `ActivityShared`).
- [ ] **Step 4: Commit** "Map the session to a Watch glance and format an honest Mac line".

---

### Task 3: The `.small` layout and its render checks (Phase 2, view)

**Files:**
- Modify: `RemotePhone/ActivityShared/WatchGlanceView.swift`, `RemotePhone/ActivityShared/WatchGlanceMetrics.swift`
- Test: `RemotePhoneTests/WatchGlanceLayoutTests.swift`
- Consumes: Task 0 stubs and `FarsideMarkGlyph(height:tip:)`. Uses literal `WatchGlance` fixtures, not `SessionGlance`.

**Layout** (all on `Farside.Palette.void`; the widget sets the activity background):
- Row 1: `FarsideMarkGlyph(height: glyphHeight, tip: Farside.Palette.bone)`; for `.needsYou` the glyph sits inside a hollow `Circle().strokeBorder(Farside.Palette.bone, lineWidth: 1.5)` of `glyphHeight + 6` (the ring is the only difference). Then the title: `.system(size: titleSize, weight: .semibold)`, bone, `lineLimit(1)`, `minimumScaleFactor(titleMinimumScale)`.
- Row 2 (full width): the detail. `.text`: `.system(size: detailSize, weight: .medium)`, ash. `.clock`: the same font with `.monospacedDigit()`; `Text(timerInterval:pauseTime: nil, countsDown:showsHours: false)` with the prefix joined by a space through `Text` interpolation. `lineLimit(1)`, `minimumScaleFactor(lineMinimumScale)`, `.privacySensitive()`.
- Row 3 (only when `note != nil`): `.system(size: noteSize, weight: .medium)`, ash, same limits, `.privacySensitive()`.
- `VStack(alignment: .leading, spacing: lineSpacing)`, `frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)`, padding `horizontalPadding` / `verticalPadding`. `.accessibilityElement(children: .ignore)` with `glance.accessibilityLabel`. No `Button`, `Link`, `Toggle`, animation or ember.
- `#Preview` blocks: live session, paused, needs-you with a Mac line, each framed at 152×69.5 on `Farside.Palette.void`.

**Metrics:** `watchSurfaces` = 40 mm 152×69.5, 41 mm 165×72.5, 44 mm 173×76.5, 45 mm 184×80.5, 49 mm 191×81.5; `carPlaySurfaces` = 170×78, 240×78, 240×100 (names like `watch-40mm`, `carplay-170x78`). `lineWidth(in:)` = `size.width - 2 * horizontalPadding`; `titleWidth(in:)` = `lineWidth(in:) - glyphColumn - glyphSpacing`, where `glyphColumn` is the ring diameter `glyphHeight + 6` (reserve it for both marks so titles never shift).

- [ ] **Step 1: Failing tests** (`WatchGlanceLayoutTests`, `@MainActor`). A helper measures a string with `UIFont.systemFont(ofSize:weight:)` (use `UIFont.monospacedDigitSystemFont` for clock lines) via `NSString.size(withAttributes:)`. For a clock line measure the worst case with the prefix plus `88:88`.
  - `testSurfacesMatchTheHIG`: exact sizes and count 5 + 3.
  - `testEverySessionLineFitsTheSmallestWatch`: at 40 mm, each literal session string from Task 2's table (`Live · Your Mac`, `Paused`, `Reconnecting`, `Session ended`, `Farside let go`, `Sharing stopped`, `Session ended?` as titles; `Lets go in 88:88`, `88:88`, `Lets go soon.`, `Hold on.`, `Mac handed back.`, `You were away.`, `Stopped at the Mac.`, `Nothing left open.`, `Check your iPhone.` as details; `End it on your iPhone.`, `Sample · preview` as notes) fits its width at its minimum scale; session titles fit at 0.9.
  - `testTheMacLineFitsTheSmallestWatch`: `Mac · seen 88:88 · 100%`, `Not seen since 88:88`, `Mac · asleep since 88:88`, `Mac not seen lately` fit at `lineMinimumScale`.
  - `testLA2CopyFindingsStayRecorded`: at 40 mm `An agent needs you` fits the title width at `titleMinimumScale` but `Claude Code needs you` does not; `12 min · nothing needs you` and `Nothing was sent to your Mac.` do not fit at `lineMinimumScale` (so amendment 6 stays true; if the fonts change, this test says so).
  - `testThreeLinesFitTheShortestSurface`: max(title `UIFont.lineHeight`, ring diameter) + detail and note line heights + 2 × `lineSpacing` + 2 × `verticalPadding` ≤ 69.5.
  - `testTheViewRendersAtEverySurface`: for each surface and fixtures (live with note, paused clock, needs-you with Mac line, stale), `ImageRenderer(content: WatchGlanceView(glance:).frame(width:height:).background(Farside.Palette.void))` with `scale = 2` yields a `uiImage` of the expected pixel size that is not a single flat colour. If `FARSIDE_SNAPSHOT_DIR` is set, write `watch-glance-<fixture>-<surface>.png` there (pattern: `HostUITests/HostUISnapshotTests.swift:10,250`; pass it as `TEST_RUNNER_FARSIDE_SNAPSHOT_DIR`).
- [ ] **Step 2: Implement** until green. Run the class with `TEST_RUNNER_FARSIDE_SNAPSHOT_DIR=$HOME/Downloads/farside-watch-glance-snapshots` and look at the PNGs (Read tool) for clipping, overlap and ember. Build the app scheme (widget compiles the view).
- [ ] **Step 3: Commit** "Draw the Watch and CarPlay glance with render and fit checks".

---

### Task 4: Opt the session Live Activity in to `.small` (Phase 2, wiring)

**Files:**
- Modify: `FarsideWidgets/SessionLiveActivity.swift`
- Test: none new (widget sources are not in `RemotePhoneTests`); regression run of the whole `RemotePhoneTests` bundle.
- Consumes: Tasks 2 and 3 merged.

- [ ] **Step 1:** Replace the Lock Screen closure's body with a `SessionActivityFamilyView(content:)` that reads `@Environment(\.activityFamily)`: `.small` → `WatchGlanceView(glance: SessionGlance.glance(attributes: content.attributes, state: content.state, isStale: content.isStale))`; `.medium` and `@unknown default` → `SessionLockScreenView(content: content)`. Keep `.activityBackgroundTint`, `.activitySystemActionForegroundColor` and `.widgetURL(SessionActivityLinks.session)` on it (the Watch's "Open on iPhone" uses the same route).
- [ ] **Step 2:** Add `.supplementalActivityFamilies([.small])` to the `ActivityConfiguration` (after the `dynamicIsland:` closure, as Apple's sample). Leave the Dynamic Island untouched.
- [ ] **Step 3:** Build the app scheme for the simulator; run the full `RemotePhoneTests` bundle (`-only-testing:RemotePhoneTests`) and report counts. Optionally tap Settings → "Preview on Lock Screen" in the simulator and screenshot the Lock Screen to show `.medium` is unchanged; the `.small` family cannot be seen without a paired Watch.
- [ ] **Step 4: Commit** "Show the session glance in the Watch Smart Stack and CarPlay".

---

### Close-out (orchestrator)

- Whole-branch review against this plan and the spec (fresh reviewer).
- `Docs/IMPLEMENTATION-PLAN.md`: a dated top entry with task SHAs, test counts and evidence levels (compiled / unit-tested / physically verified: none).
- `PRODUCT.md`: a decision row with the next free D number (checked across all branches) recording the approved Watch glance scope and its status.
- Unverified until a Watch is available: forwarding of the new body; Double Tap snoozing; the `.small` layout on a real Smart Stack (margins the system may add, the 42/46 mm sizes, Always-On dimming); "Open on iPhone" routing; CarPlay rendering; Focus/Time Sensitive mirroring.
