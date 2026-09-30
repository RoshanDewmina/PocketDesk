# Connection-quality continuation — 30 September 2026

Source checkpoint on `codex/continue-quality`, based on `ca99d6efca9b01846cb3b691e005ba6138623949`. This package continues the user-authorized connection-quality work after recovering the interrupted Claude author and independent verifier. It changes source only. Root owns shared product records, project membership, integration and full-target verification.

## Recovered review and resolved requirements

The recovered scratch plan predates the final edits. The complete verifier transcript `work/recovered-scratch/agent-a0425c5b387576c98.txt` in the continuation chat records final approval after two re-reviews. The original author transcript is `work/farside-history/claude-agent-ab59f8073ee0e8491.txt`. The implementation follows the final review, with deliberately more cautious picture-health wording.

| Required correction | Implemented contract |
| --- | --- |
| RTT hold band and repeated STUN values | `SessionEvidence.slowRoundTripMs` is non-nil only while latched slow; Health never applies a second threshold. Fresh RTT uses `ΔtotalRoundTripTime / ΔresponsesReceived` on the same selected pair. No new response means no sample; a stale 10-second gap clears/restarts RTT evidence. |
| Correct in-flight model | Frame windows use cumulative successful encoded output versus renderer arrival. Subtract the change in estimated in-flight frames, using the last mark rate and pacer + jitter buffer + decode + 16 ms. RTT/2 is excluded. The estimate is capped at 15 frames. This is picture health, including possible decoder omissions, not proven network packet/frame loss. |
| Expired history and repeated marks | Windows require at least 60 encoded outputs, close at ≥2.9 seconds, ignore the first measured window, deduplicate mark time, reset/re-settle on counter regression or a >5-second mark gap, and expire previous-window evidence after 10 seconds. Quiet time clears a warning after 10 seconds. Stale host summaries produce no mark. |
| Count all successful encoded output | `encodedFrameAccepted()` is called only after the inner WebRTC callback returns true, independently of the latency trace lookup. Totals survive drain and encoder restarts on that media instance. Host clamps totals to a separate trillion-frame bound. |
| Per-message receiver snapshot | Each control packet carries its renderer count **and monotonic arrival time** captured before the first main-queue hop. The pre-gate buffer preserves both. `RemoteCoordinator` captures both before its own Task and exposes them only during validated synchronous `onControl` delivery. No shared later snapshot can overwrite a packet's mark. |
| Honest Mac interface evidence | Only a selected **host candidate** whose address matches `getifaddrs` and a Network interface type resolves. IPv4, scoped IPv6 and bracketed addresses are handled. Unknown, reflexive and relay addresses have no fallback. `en0` does not imply Wi-Fi. The Mac's Wi-Fi is named only on `lan`, never inferred on `p2p`. |
| Actual resume lever | `.background → .inactive` starts the existing return path while the existing privacy shield is up, without requesting background execution again. Input still requires active scene/readiness gates. Leaving again cancels an open timing measurement. |
| Resume fallback and timing boundaries | A return starts held/reconnect/manual timing. Failed resume send and watchdog fallback preserve the original start and require a new frame. Generic session teardown does not cancel it; user End/dismissal, leaving again and the 60-second ceiling do. First renderer arrival, active-scene wait and display/viewport settlement remain separate. The Mac logs resume-to-first-complete-capture-callback. |
| Copy and overlap | One observed condition + one optional fix. `Picture struggling` is the unknown-condition title. No claim that Wi-Fi/cellular/relay/AirDrop caused missing picture frames. Existing `wifiStall` stays the sole evidence field. Quality ranks after critical Mac battery and before Mac busy; existing trust/permission states remain above it. |

## Behavior and UI

A quality banner appears only during a connected Picture session with poor measured picture health or an observed burst pattern. Poor wins. Tapping a condition hides that condition for the entire session; it stays dismissed across quiet-clear/re-entry. A different observed condition can still appear. The dock and Diagnostics retain evidence. The banner stays hidden behind concealment/privacy shielding, announces on appearance, supports Reduce Motion and accepts touches only inside its plate.

Poor thresholds follow Moonlight: ≥30% in one measured window, or ≥15% in two consecutive measured windows; clear at ≤5%. Short unmeasured intervals preserve measured-window adjacency, but old evidence expires. RTT: median ≥150 ms twice or ≥300 ms once; clear at ≤110 ms; the 111–149 ms hold band remains latched. Variation uses up to 10 fresh samples. Route changes, authentication, pause/resume, display-change acknowledgement and teardown reset quality evidence. Session counters survive these evidence resets and restart on authentication.

The host adds only optional `HostStreamSummary.framesEncodedTotal` and `macLink`. Old peers omit these and decode normally. The tuned desktop encoder supplies marks; legacy/stock encoder paths remain unmeasured. Report/export fields are diagnostic only: receiver frame mark, frame-health percentage, quality, fresh RTT, RTT spread and counters. Stream logging stays local and records the annotated phone report once.

The burst-pattern tip offers one optional fix: AirDrop **Receiving Off**. The Mac is named only when its Wi-Fi host interface was established on LAN; otherwise the phone/tablet is named. It does not identify AWDL activity or a responsible device. Secondary Diagnostics may suggest Handoff. `WiFiStallTip.defaultGuidance` provides the one-constant `.causeOnly` fallback. This preserves the current authorized guidance; App Review 2.4.4 exposure remains an explicit release risk, not a resolved acceptance claim. Location Services and router/channel changes are excluded because they alter broader system/router behavior and do not provide one bounded in-app remedy. Nothing recommends disabling Wi-Fi.

Resume time is a renderer/scene observation, **not measured glass presentation**. A first frame may precede requested display/viewport restoration, so `settledMs` is recorded separately. A 4 Hz heartbeat and existing 5-second watchdog/25-second hold/45-second host pause are unchanged. No “instant” latency guarantee is claimed before device measurements.

## Validation receipt

30 September 2026 local source checks:

- `swiftc -frontend -parse` passed for the 18 changed/new Swift source and test files.
- `git diff --check` passed.
- `python3 Docs/plans/receipts/connection-quality-2026-09-30/pure-check.py` passed: **32 test methods, 167 assertions, 0 failures**. This compiles the actual pure monitor/timing/link/copy implementations and extracts their real test methods. Minimal report/interface fixtures and plain Swift assertions replace target dependencies/XCTest discovery. It is not a full target build or XCTest receipt. The reproducible harness and exact result are adjacent.
- Swift 6.4 (`swiftlang-6.4.0.34.1`), arm64 macOS 27 target; selected developer path `/Applications/Xcode.app/Contents/Developer`.
- Initial standalone XCTest attempts could not load XCTest, then found the framework without its overlay, then found the overlay without Linux `XCTMain` APIs. These harness setup failures did not execute tests. The final plain Swift harness above ran successfully.

Full Mac core target, phone unit target (existing natural StoreKit expiry fixture excluded from this package), generic phone/device build and host build remain required after root regenerates project membership and resolves overlapping performance edits. New wire/counter/scene/banner target tests have parsed but have not run. No Xcode job was queued by this worker. Fresh independent source review remains required before integration.

## Integration boundaries and remaining acceptance

Root must preserve both this package and performance-package changes to `StreamStatistics`, `PeerMedia` and `DesktopH264Encoder`. Shared contracts to retain: accepted-output count outside optional latency trace; per-message count/time through both queue hops; annotated phone export recorded once; marks absent on uninstrumented encoder paths; fresh same-pair RTT deltas. `SessionEvidence` appends quality after existing vitals. Root owns PRODUCT decision numbering and final Xcode source membership; this worker changed neither shared product documents nor project membership.

Deferred human/device checks: clean moving LAN with no false warning; forced degradation with bounded warning/clear behavior; relay and direct-internet copy; wired-Mac versus Wi-Fi-Mac burst guidance; inactive shield/input safety; 5/20/40-second app switches and lock return; wrong-display restoration settlement; AirDrop interaction and 2.4.4 ship decision; real glass/performance timing. No devices were installed, permissions changed, network settings modified, service deployed or production actions taken.

## Sources checked

- Moonlight local primary source: `reports/src/farside-competitors-2026-09-30/repos/moonlight-common-c/src/ControlStream.c`, threshold constants 125–128 and `connectionSawFrame` 471–515, reread this turn. Its transport frame-index loss metric differs from Farside's renderer-deficit approximation.
- Existing source-backed NVIDIA capture: `research/cloud-raw-2026-09-30/A-GFN-XCLOUD.md` §1c–1d, [Mac stutter guidance](https://nvidia.custhelp.com/app/answers/detail/a_id/4504) and [quality indicator](https://nvidia.custhelp.com/app/answers/detail/a_id/4658). These support optional mitigation and the quiet-until-trouble pattern, not a causal diagnosis from Farside's counters.
- [Apple AirDrop on iPhone/iPad](https://support.apple.com/en-us/119857), refreshed this turn; Receiving Off is a real named option. The current [Mac guide](https://support.apple.com/guide/mac-help/use-airdrop-to-send-items-to-nearby-devices-mh35868/mac) was also checked; labels vary by OS, so the banner has no settings-pane path.
- [Apple App Review 2.4.4](https://developer.apple.com/app-store/review/guidelines/#hardware-compatibility), refreshed this turn. Optional wording does not eliminate review risk.
- [NWPath.availableInterfaces](https://developer.apple.com/documentation/network/nwpath/availableinterfaces) and [ScenePhase.inactive](https://developer.apple.com/documentation/swiftui/scenephase/inactive) were checked live; the reader returned JavaScript-only pages and their Markdown links failed. Existing code and the installed compiler supply source feasibility here; these reads do not establish new OS/device acceptance.
- `design/FARSIDE-DESIGN-SYSTEM.md` §4: plain labels, one fix, no label jokes.
