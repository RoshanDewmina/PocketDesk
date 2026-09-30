# Mac Vitals — design spec

30 September 2026, revision 1. Status: **approved 30 September 2026 (see Decisions); implemented on `farside-mac-vitals` per `MAC-VITALS-IMPLEMENTATION-PLAN-2026-09-30.md`.** Once approved, record the decision in PRODUCT.md under the next free D-number after D38 (D38 is on `farside-big-text`). Labels: **VERIFIED** means read in source at `86d643a` (this worktree) or in Apple documentation/SDK headers today. **INFERRED** means reasoned but not observed. No physical behaviour has been tested.

## 1. What Roshan asked for

- The phone shows the Mac's battery (percentage, charging or on battery), thermal state and a "Mac is busy" load signal, in the Controls panel and connection status.
- Early warnings such as "Mac on battery, 12%", so a laggy session explains itself.
- Brainstorm sizing: small. Reuse the existing host→phone status channel.

Why it matters: today the phone can explain a slow network (`farside-connection-health`) and a slow stream (`MacBusyPill`). It cannot explain a Mac that is dying on battery, or one that is slow because other apps are using it.

**Already there (VERIFIED).** The host reads `thermalState` and `isLowPowerModeEnabled` every statistics second (`HostModel.swift:1615-1621`). They feed the ladder (a thermal step at serious, a 60 fps cap in Low Power Mode, `LadderPolicy.swift:103-104,150-153`) and the pill ("Your Mac is running warm" / "is saving power", `BusyPresentation.swift:17-22`). They also reach the phone in `hostStream`, but only for the statistics overlay (`StreamStatistics.swift:150-152`, `RemotePhoneApp.swift:1124`). Nothing reads battery or whole-Mac load (grep: no `IOPS*`, `host_statistics` or memory-pressure source).

## 2. User experience

**Controls panel (D36).** One SF Mono caption under the "Controls" title: `ash` when normal, `bone` on a warning, never ember (not contact). The 17 pt headline plus 11 pt caption should fit the header's `minHeight: 44` (`NativeSessionView.swift:1276-1292`), so `panelHeight` (`:1242-1248`) is unchanged (INFERRED; check in preview). See Q1.

| Mac state | Caption |
|---|---|
| On battery | `Mac · on battery 64%` |
| On power, charging | `Mac · charging 82%` |
| On power, not charging (full or optimised hold) | `Mac · plugged in` |
| No battery (desktop Mac) | `Mac · running normally` |
| Suffixes, in this order | ` · hot` (critical) or ` · warm` (serious), ` · Low Power Mode`, ` · busy` |

Thermal `fair` is not shown. VoiceOver reads the full sentence ("Your Mac: on battery, 12 percent, Low Power Mode, busy.").

**Notices** use the existing 6 s `FarsideNotice` (`RemotePhoneApp.swift:615-623`). Each shows once per session and re-arms after charging or a 5-point rise:
- Unplugged: "Your Mac is now on battery · 64%."
- 20% or below on battery: "Your Mac is on battery · 18%. Plug it in to keep going."
- 10% or below, or macOS's final warning: "Your Mac is at 9% and may sleep soon. Plug it in or save your work."
- Load busy for 10 s: "Your Mac is busy with other apps, so it may respond slowly."

No thermal notice: the busy pill already names heat and power when the ladder acts, so a visible pill with reason `thermal`/`power` suppresses a second message.

**Dock status line.** Vitals feed `ConnectionHealth` (§9), ranked after connection and picture problems and before a slow network: `Mac battery low · plug it in` (10% or below) and `Mac busy · other apps are using it`.

**Settings → Diagnostics** gets a "Mac" section after "Connection": battery and power source, temperature (normal/warm/hot), Low Power Mode, and load (normal, or busy with processor/memory).

**Older host** (no feature advertised): the caption is hidden. Diagnostics says "Your Mac's Farside is too old to report battery and load. Update it on your Mac."

**Home Mac card** (Q3): no live vitals before connecting. If the last session ended on battery at 10% or below, show "Last seen on battery · 4%" for 12 h. After a Mac-reported sleep, add "It was on battery at 4%, which may be why." That says "may", because the phone cannot know the cause.

**Mac side:** no new UI and no opt-out. The phone already sees the whole screen, including the menu-bar battery (INFERRED judgement).

## 3. Data sources and sampling (host only; the phone samples nothing new)

| Signal | API (VERIFIED docs/SDK 27.0) | Rate |
|---|---|---|
| Battery %, charging, source | `IOPSCopyPowerSourcesInfo`/`IOPSCopyPowerSourcesList`/`IOPSGetPowerSourceDescription` (`Current Capacity`, `Max Capacity`, `Is Charging`, `Power Source State`, `InternalBattery`), `IOPSGetProvidingPowerSourceType` | `IOPSNotificationCreateRunLoopSource` callback, ≤1 read/s |
| macOS warning | `IOPSGetBatteryWarningLevel` (Early ≈20 min, Final ≈10 min left, not guaranteed) | With battery |
| Thermal | `ProcessInfo.thermalState` + `thermalStateDidChangeNotification` (read before registering, per docs) | Event |
| Low Power Mode | `isLowPowerModeEnabled` + `NSProcessInfoPowerStateDidChange` (macOS 12+) | Event |
| Processor load | `host_statistics(HOST_CPU_LOAD_INFO)` deltas minus own `getrusage(RUSAGE_SELF)` (`E2ESupport.swift:295-296`) | 2 s |
| Memory | `DispatchSource.makeMemoryPressureSource` | Event |

**Load level:** `busy` when processor use excluding Farside averages 85% or more for 10 s, or memory pressure is critical. It clears below 70% for 10 s, or when pressure returns to normal. The cause is `processor` or `memory`. Only the level is sent, never a percentage.

**Lifetime:** installed in `beginLoadMonitor` and removed in `endLoadMonitor` (`HostModel.swift:1596-1612`), so there is no sampling without a session. Cost is one Mach call every 2 s plus notifications (INFERRED negligible; measured in §7).

**Privacy:** aggregates only, with no process names, PIDs or per-app data. The only thing stored is the Home last-session value, on the phone. IOKit power sources are not a required-reason API, and the host ships outside the Mac App Store (D30) (INFERRED).

## 4. Protocol

- **Capability:** `SessionFeature.macVitals = "vitals.1"`, added to `SessionFeature.host` (`SessionContinuity.swift:24-25`).
- **Field:** optional `RemoteAction.macVitals: MacVitals?`, on `capture` status only. Contents: `power` (≤12 chars: `battery`/`ac`/`ups`), `batteryPercent` 0…100, `charging`, `batteryWarning` 1…3, `thermal` 0…3, `lowPowerMode`, `load` (≤12: `ok`/`busy`), `loadCause` (≤12).
- **Validation:** mirror `busy`. Before the extension early returns, run `try macVitals?.validate()` and `guard macVitals == nil || action == "capture"` (`ControlProtocol.swift:59-61`). That keeps it off `displays`/extension actions without touching their stray-field lists (`DisplaySelection.swift:48-53`, `SessionContinuity.swift:111-114`), as with `ladder`/`busy`.
  - A failed validation ends the session (`RemoteCoordinator.swift:599-604`). So the host clamps first (like `hostSummary`, `StreamStatistics.swift:454-455`), strings are checked by length and charset rather than by enum, and the phone maps unknown values to nil (like `PrivacyCurtainState`, `SessionContinuity.swift:34`).
- **Cadence:** sent on every capture status, which goes out every 0.25 s (`HostModel.swift:1273,1288`) from `sendCaptureHealth` (`:1648-1670`). About 120 bytes each (INFERRED). The phone keeps no state and drops vitals when status is stale (`RemotePhoneApp.swift:1110`).
- **Older peers:** `RemoteAction` uses synthesized `Codable` with no custom decoder (`ControlProtocol.swift:3`), so older phones ignore the key (VERIFIED). A newer phone with an older host sees no `vitals.1` and hides the UI. The phone sends nothing new.
- **Not `hostState`:** that single string already carries presence or `accessibilityOff` on the health branch.

## 5. Free vs Anywhere

Identical. Vitals ride the encrypted control channel on whatever route the session has: local (Free), or direct/relay (Anywhere). The service gets no new fields, so D28 enforcement is untouched. Relay overhead is under 0.3% of a 1.5 Mb/s stream (INFERRED). Pre-connect vitals (Q3-C) would need service work.

## 6. Edge cases

| Case | Behaviour |
|---|---|
| Desktop Mac | No battery fields; "running normally" plus suffixes |
| UPS | `power: ups`; percentage only if reported |
| Optimised charging at 80% | "plugged in" |
| Battery read fails | Battery fields omitted |
| Hovering at 20%/10% | 5-point hysteresis |
| Mac sleeps at low battery | Existing `.sleeping` path; Home shows last-seen battery, no claimed cause |
| Phone backgrounded | No status; resumes with the stream |
| Farside is the heavy process | Own CPU subtracted |
| Browser viewer | Out of scope |

## 7. Testing

**Automated**, using an injected `MacVitalsSources` (power-source reading, thermal, Low Power Mode, CPU ticks and own usage, memory events, clock):
- IOPS parsing: internal battery, UPS, none, missing keys, non-percent capacity.
- Load hysteresis (85/70, 10 s) and own-CPU subtraction.
- Validation and clamping; rejection on non-`capture` actions; an old-shape `RemoteAction` decoding new JSON; unknown strings becoming nil; feature gating.
- Copy, thresholds, re-arm, and pill suppression.
- `ConnectionHealth` ordering; Home last-seen expiry.
- `--ui-vitals=battery12` launch option (like `--ui-status=`, `HomeView.swift:441`) for layout checks at the largest Dynamic Type.

**Physical** (quiet window):
- Unplug and replug the M4 Air (the caption flips within about 2 s).
- Toggle Low Power Mode.
- Run `yes > /dev/null` on every core for 20 s (busy appears, then clears in about 10–15 s).
- Measure host CPU with `top -l`, with and without vitals.
- The 20%/10% notices and thermal can't be forced: record them as unverified unless they happen naturally.

## 8. Size and order

About 2–3 engineer-days, after `farside-connection-health` merges:
1. `MacVitals`, validation, feature flag and tests (0.5 d)
2. Host sources behind the injection protocol (0.75 d)
3. Phone model, caption, notices and Diagnostics (0.75 d)
4. `ConnectionHealth` evidence and Home last-seen (0.25 d)
5. Physical checks (0.25 d)

This is not a 3 November launch gate unless Roshan decides otherwise.

## 9. Overlap with `farside-connection-health` (unmerged, `84d871e`)

VERIFIED by `git diff 86d643a...farside-connection-health`: the branch adds `ConnectionHealth` (dock line, Home card, Diagnostics "Connection"), `MacShareBlocker` on `hostState`, and edits `sendCaptureHealth`. To avoid duplicate work:
1. Build on that branch after it merges, not in parallel.
2. Vitals are extra **evidence** in `ConnectionHealth.SessionEvidence` (branch `ConnectionHealth.swift:127-138`), not a second status system.
3. Naming clash: the branch's `.macBusy` means "Another session is open" (`:114-117`). Name the new state `.macUnderLoad` (copy "Mac busy"), or rename the old one `.sessionTaken`.
4. Diagnostics "Mac" goes after the branch's `connectionHealthSection`. `hostState` stays for presence and blockers. `sendCaptureHealth` gains one argument (trivial merge).

## 10. Open questions for Roshan

**Q1. Where do vitals sit in the Controls panel?**
- A) A caption under "Controls", with no panel height change **(recommended)**
- B) A dedicated "Mac" row under Hide Mac screen/Display, about 53 pt taller
- C) Settings → Diagnostics only, plus notices

**Q2. What does "Mac is busy" cover?**
- A) Only today's stream-based busy pill
- B) Also a coarse whole-Mac load level (processor at 85% or more excluding Farside, or critical memory pressure), with no percentages sent **(recommended)**
- C) Send live processor percentages

**Q3. What does the Home Mac card show?**
- A) Nothing: vitals are session-only
- B) The last-session warning only, for example "Last seen on battery · 4%", for 12 h **(recommended)**
- C) Live vitals before connecting, through the service (server work plus tier questions)

**Q4. When should battery warnings fire (on battery only)?**
- A) At 20% and at 10%, once each per session, plus a notice on unplug **(recommended)**
- B) Only at macOS's own warning levels (about 20 and 10 minutes remaining)
- C) At 20% only, with no unplug notice

## Decisions — 30 September 2026

Roshan approved this design and every recommended answer to the open questions above ("Sounds good … go ahead"). Implementation is authorized on a feature branch; no install, merge into `pocketdesk-remote-chat`, deployment or submission without his separate go-ahead.
