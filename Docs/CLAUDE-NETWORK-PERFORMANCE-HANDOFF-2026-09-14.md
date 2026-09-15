# PocketDesk: Claude Code handoff — network reliability, latency and physical acceptance

Prepared 14 September 2026, Malaysia time. This is a self-contained continuation packet, not a claim that outstanding work has passed. Roshan will provide this to Claude Code; no Claude task was dispatched by Codex. Product scope remains in PRODUCT.md, execution evidence in Docs/IMPLEMENTATION-PLAN.md.

## 1. Roshan's request and priority

Review what has been built and tested, finish the networking/performance work thoroughly, and make PocketDesk more responsive without compromising image quality or code readability. Roshan wants evidence that it works well, not another synthetic-only success. He mentioned beating the reported 87 ms: **that number is a loaded internet HTTP-test median, not measured PocketDesk latency**, so do not use it as the application's starting result or invent a before/after improvement.

Primary work: establish actual session route and end-to-end latency, improve measured bottlenecks, and finish physical reliability/useful-task acceptance. Preserve sharp text, punctuation, working controls and security. Prefer a small private result over broad redesign.

Secondary, later work: research and plan smooth automatic zoom toward the clicked/focused input field, inspired by Screen Studio. Do not implement it ahead of network and physical acceptance. No Screen Studio purchase or installation is requested.

This packet is a plan for the receiving executor. Follow Roshan's accompanying instruction on whether to execute or review. Current handoff preparation changed no application code or networking settings. Earlier authorization covers local implementation, private testing and scoped fixes. Public/provider setup remains paused; this packet does not authorize publishing, paid services, weakening permissions, or treating an untested remote-access path as done.

## 2. Workspace and continuation rules

- Repository: `/Users/roshansilva/Documents/ChatGPT/Saas/PocketDesk`.
- Mac companion: `/Applications/PocketDesk Host.app`.
- Read repository `AGENTS.md`, `PRODUCT.md`, `Docs/IMPLEMENTATION-PLAN.md` (especially dated entries at the end), `Docs/APPLE-API-REFERENCE.md`, `Docs/BROWSER-TESTING.md`, and `Docs/MAC-PERMISSION-IDENTITY.md`.
- Canonical local conventions: `/Users/roshansilva/.hermes/knowledge-base/AGENTS.md`. Keep project records here; do not create personal-memory or wiki copies. Do not read secure personal stores.
- The working tree contains extensive important modified and untracked source. Preserve it. A fresh clone/default-branch worktree will omit meaningful implementation. Do not clean/reset or replace files wholesale. Record current state and isolate changes carefully.
- Older headings in the plan/testing guide describe historical permission failures and unvalidated video. The later dated entries establish the repaired permissions and first physical Safari success. Resolve contradictions by current evidence, not the document's first status sentence.
- Roshan explicitly selected Claude Code for this handoff. Earlier GPT-only/no-Astra delegation notes describe the prior Codex workflow; they do not invalidate his present choice of Claude. This is not blanket authorization to change other tools/providers or delegate further. Keep shared edits serialized and obtain independent review for security-sensitive changes.
- Verify SDK/OS/dependency/API assumptions against the local setup and official documentation. Line numbers below may drift.
- Update the real host only through `script/build_and_run.sh`; retain its signing identity, bundle ID and installed path. Never bypass identity checks, install an ad hoc replacement, or automatically reset permissions.
- Use `HostSettingsSection` instead of SwiftUI `GroupBox` in the current host UI; GroupBox crashed the tested computer-use helper. See `Docs/CUA-GROUPBOX-BUG-REPORT.md`.

## 3. What has actually been completed

### Foundation and automated evidence

Implemented Mac capture/input host, native phone route, WebRTC media/control, connection service, browser viewer, separate browser trust and explicit approval. The browser uses authenticated negotiation and frame freshness gating. Generated-source harnesses support deterministic local checks.

Historical September 13 checkpoint: 48 native tests and 49 service tests passed, Mac and phone simulator builds passed; Chromium interactive receipt recorded 18 checks plus four lifecycle/race probes; view-only recorded 12 checks. Combined JavaScript suites recorded 61 tests/274 assertions, overlapping those counts. These are historical receipts, not a fresh test run or proof of real phone behavior.

A local automated WebKit run failed to receive media. Cause remained unproven. Later physical Safari video worked, so do not interpret the automated failure as proof Safari cannot support this path or change codecs solely because of it.

### Mac setup repaired

Enabled Settings switches initially referred to stale ad hoc signing identities. A scoped, user-approved one-time repair plus fresh approval produced true runtime Screen Recording and Accessibility checks. Real display enumeration then succeeded. A build/install identity guard now prevents silent signing identity changes. Do not repeat that repair unless a new failure is actually diagnosed and authorized.

The computer-use crash was traced to GroupBox, reproduced in a minimal app, and fixed in the host layout. The sanitized bug was delivered to OpenAI support; no engineering acceptance/case number was provided.

### Real iPhone Safari observations

- Real iPhone 17, using iPhone Mirroring for interaction, loaded the private HTTPS viewer.
- View-only enrollment and Mac approval succeeded; actual changing Mac desktop video appeared.
- Local zoom and pan worked. Whole-desktop fit makes small code difficult to read in portrait; full readability acceptance is pending.
- View-only enrollment was revoked/forgotten before a fresh interactive enrollment.
- A Safari-sent Command–Space opened Mac Spotlight. This proves one actual OS shortcut, not full text editing.
- Leaving Safari ended the session and concealed the video. Returning required explicit Connect; reconnection worked.
- Native phone pairing was not changed.

### Shortcut bug fixed, physical retest pending

Safari autocapitalized `a` to `A`, while the native symbolic-key map used lowercase. BrowserClient/index.html disables autocapitalization/autocorrection/spellcheck in the relevant fields; app.js and src/control/input.js normalize symbolic key names only. Text payload casing and text receipt IDs remain exact. Parent ran 11 browser tests/34 assertions; fresh independent review approved. No native rebuild was needed. The Mac locked before the physical reload/retest, so actual Command–A, edit/save and text-result success remain unverified.

## 4. Network baseline — measured, not inferred

Receipts: `outputs/network-check-20260914/REPORT.md`, `summary.json`, `network-quality.json`, and ping text files. Measured around 10:17–10:23 MYT on September 14.

| Measurement | Result |
| --- | --- |
| Internet throughput on Mac Wi-Fi | 157.9 Mbps down / 62.8 Mbps up |
| Apple endpoint idle RTT | 15.8 ms |
| Apple responsiveness | 912 RPM |
| Busy-connection self HTTP requests | median 87 ms; p95 312 ms; maximum 650 ms |
| Mac to iPhone local IP, 50 active samples | median 5.45 ms; p95 7.87 ms; max 49.52 ms; 0% loss |
| Mac to iPhone Tailscale IP, concurrent 50 samples | median 24.88 ms; p95 46.17 ms; max 85.05 ms; 0% loss |
| Mac to router repeat | median 2.91 ms; p95 3.64 ms; 0% loss |
| Mac Wi-Fi | 802.11ac, 5 GHz, 80 MHz; −39 dBm signal / −92 dBm noise; 433 Mbps PHY |

Default route was en0 through 192.168.1.1; Mac local address 192.168.1.32, iPhone direct endpoint 192.168.1.30. Addresses are historical and must be rediscovered. Phone tailnet address was 100.102.48.125. All twelve Tailscale discovery probes used a direct local endpoint. A Singapore home-relay label did not mean traffic was being relayed. Netcheck reported UDP available, no usable IPv6, and a Singapore relay latency around 13 ms.

The Apple speed test ran upload/download concurrently, with a 45-second maximum and normal TLS verification; it completed in about 16 seconds and transferred approximately 423 MB. Do not repeatedly saturate the network without a concrete reason.

Important limits:

- 433 Mbps PHY is not usable throughput. Internet throughput does not measure local video capacity.
- Initial router/internet probes contained >100 ms outliers; a more frequent repeat was steadier. Probe cadence, power saving and background activity confound cause attribution.
- Loaded-ping files cover the test and recovery. Whole-file statistics are not load-only. Do not compare mismatched probe cadences as proof of bufferbloat or VPN overhead.
- Direct Tailscale discovery is not the actual WebRTC media-route measurement. HTTPS/WSS signaling route and media candidate selection are distinct.
- No measured PocketDesk glass-to-glass or input-to-visible latency, physical-session codec, achieved bitrate or frame rate exists yet.
- Never subtract unsynchronized Mac/phone timestamps. Do not label RTT/2 as measured one-way delay.

## 5. Implementation map and suspected costs

| Area | Files / observation |
| --- | --- |
| Capture | RemoteHost/RemoteCapture.swift: requests width up to 1920, even dimensions, 60 fps, queueDepth 3, NV12, cursor on, audio off. Observed display 1920×1243 implies requested capture 1920×1242. Queue capacity is not measured latency. |
| Frame marker | RemoteHost/BrowserFrameMarker.swift: adds 48-pixel footer, yielding 1920×1290 at that geometry; allocates BGRA output, converts NV12 to another BGRA buffer, copies full scanlines. |
| Media/stats | RemoteShared/PeerMedia.swift: H.264 preferred via default factory; no explicit sender bitrate cap/framerate/degradation or receiver jitter target in repository code. It resolves selected ICE pair, RTT, codec and fps, but browser controller does not expose onDiagnostics. |
| Browser host | RemoteHost/BrowserPeerController.swift, BrowserMediaSession.swift; signal and control delivery. |
| Browser rendering | BrowserClient/app.js decodeFrame currently draws and reads the whole decoded video frame per presented callback. src/viewer/marker.js samples only 200 pixels within the bottom-right 88×48 marker region. |
| Browser input | app.js sends each pointermove immediately over reliable ordered channel; no browser bufferedAmount guard/coalescing. Backlog is a hypothesis until measured. Native send has a 64 KiB buffered bound. |
| Safety | RemoteHost/BrowserInputGate.swift and browser controls enforce 600 ms token freshness; RemoteCapture has its own capture health. |

The first optimization candidate is cropping marker readback to the intrinsic bottom-right 88×48 region: approximately 586 times fewer readback pixels at the observed geometry. This is **not a measured latency improvement**. It differs from zooming/cropping the desktop for the user. Preserve the full user-visible video and marker semantics.

Potential subsequent work, only if measurement justifies it: host buffer reuse/conversion reduction; latest-movement coalescing without losing required ordering; bitrate/frame-rate adaptation. Do not lower resolution, blur small text, switch codecs, shorten security margins, or change frame rate blindly.

## 6. Execution plan and evidence gates

### A. Re-establish a controlled private baseline

Inspect current checkout, relevant source and receipts. Confirm host identity, runtime permissions, selected display, awake/unlocked Mac, phone/browser versions and private reachability. Check currently running processes/routes before changing anything; prior session state is not guaranteed current.

Restore a bounded private session using the existing browser testing runbook. Initially use the known readable scratch window. Keep unrelated apps/services/routes and native pairing intact. Confirm explicit view/control scope. A disposable diagnostic fixture can provide early measurements without OS input, but it does not pass physical acceptance.

### B. Add small, useful instrumentation before tuning

Capture structured, opt-in diagnostic samples without desktop content, raw credentials or typed text:

- Selected ICE candidate pair, protocol, direct/relay classification, redacted local/tailnet/public address class, route changes and RTT. Absent fields are unavailable, never zero.
- Actual dimensions, codec, fps and bitrate; host total encode-time/frame deltas, sender delay and CPU/bandwidth limitation when exposed.
- Browser decode-time/frame deltas, jitter-buffer delay/frame, dropped/rendered frames and marker callback duration. Feature-detect Safari stats and report unavailable values honestly.
- Data-channel buffered amount and input receipt/injection timing without logging key/text contents. Review any protocol changes; do not add authority through diagnostics.
- Browser-send to visible response using one browser monotonic clock: an authorized disposable target changes a known color tile on a benchmark key; detect the resulting tile in a presented video frame. A synthetic target and real OS-input target must be labelled separately. This excludes touch-before-send and physical display scanout; label it accurately. High-frame-rate camera measurement may be added if true physical touch-to-photon measurement is necessary.

Take a small baseline first, then at least 100 interactions for a meaningful reported p95. Record sample count, median/p95/max, errors, stale rejections and dropped frames. Avoid instrumentation that itself reads the entire frame unnecessarily or materially changes the workload. Record resolution, frame rate, route, load, device state and measurement overhead.

### C. Isolate the network contribution

First record the actual app-selected media route. The earlier 5.5 ms versus 24.9 ms pings are leads, not proof of application overhead. If the app selects a less suitable route, inspect why before changing candidates or routing. Retain authentication and a usable fallback; do not globally disable interfaces or Tailscale as a shortcut.

Compare idle and bounded-load sessions with matched probe cadence, route and phone state. Keep load phases separate from idle baseline and label recovery. Distinguish Wi-Fi contention, overlay path, transport loss, encoder limitation, receiver buffering and main-thread cost. Do not prescribe router upgrades/settings or congestion algorithms from one short run.

### D. Implement the smallest supported optimization

If marker readback is material, implement the bounded 88×48 crop first. Test valid/invalid/corrupt markers, minimum and changing dimensions, actual encoded frames, missing video and stale frames. Decode intrinsic video pixels, not CSS-scaled coordinates. Keep both 600 ms checks, correct revision binding, capture health and fail-closed behavior unchanged.

A/B at the same route, device state, source content, bitrate/resolution/frame-rate conditions. Compare callback cost and actual input-to-visible distributions. Preserve small punctuation, indentation, selection and syntax colors in light/dark editors. Have Roshan judge readability where subjective. Report no proven benefit if the change does not improve the measured experience.

Only pursue host allocation/conversion or movement queuing changes when diagnostics identify them. Preserve clicks/keys/text/releases and held-state cleanup. Comparing 30/60 fps is acceptable as an explicit experiment, not an invisible quality reduction. Obtain a fresh review for changes touching marker/security/input contracts.

### E. Finish physical useful-task and failure acceptance

Use a harmless scratch file. The earlier `/tmp/pocketdesk-physical-acceptance-20260914/hello.py` contained a greeting function and assert; inspect or recreate a disposable file if missing. Never type into the user's real project by assumption.

1. Retest the symbolic-key capitalization fix on actual Safari. Confirm Command–A and ordinary text casing independently.
2. From the phone, focus the intended Mac editor, make a small correct edit, save, run its harmless check, and observe the actual saved text and output. A send acknowledgement alone is insufficient.
3. Test pointer movement, click, right/double click, scrolling, modifiers, text/Unicode/IME and receipt/reconnect behavior.
4. Check portrait/landscape, keyboard-open viewport, fit/zoom/pan, small code punctuation and readability.
5. While holding remote input, background Safari, lock the phone, stop on the host, and interrupt network in separate controlled tests. Observe actual release, hidden stale video, disabled controls, fresh reconnect and no replay. Use a harmless target because release can complete a drag/drop.
6. Verify view-only cannot inject input; revoke browser authority and confirm denial; re-enroll without disturbing native pairing.
7. Record each case as passed, failed or not tested with evidence and recovery requirements. Avoid bundled claims such as “all testing passed.”

### F. Away-access gate — remains separately blocked by paused provider work

Same-Wi-Fi success does not complete the product's away-access objective. Cellular, another external Wi-Fi network, and forced relay require their own tests and selected-route receipts. The private browser service currently lacks configured TURN. Provider/public deployment must be explicitly resumed before that work; report the remaining dependency rather than bypassing it.

Later, once resumed, test authenticated public signaling, reviewed trusted browser-code delivery, short-lived relay credentials, abuse/cost bounds, direct and forced-relay connectivity, interruptions and a useful task without someone touching the Mac. The current prototype supports an awake/unlocked Mac, not login-screen access, sleep recovery or remote permission repair.

PRODUCT's larger follow-up budgets include 19/20 connections within 10 seconds and physical input-to-visible p95 up to 150 ms on reference LAN / 400 ms on declared relay, with at least 100 interactions. These are provisional product targets, not achieved results or permission to postpone a first useful test. Do not redefine 87 ms as a passed or failed app target. No finite test proves every network works “100%”; deliver a precise supported-condition matrix and remaining failures.

## 7. Existing verification tools

From repository root, inspect scripts before running. Select checks appropriate to the changes; scripts sharing Xcode generation/build output must not run concurrently.

```sh
bun test BrowserClient/tests BrowserFixtures
./scripts/verify-browser.sh interactive
./scripts/verify-browser.sh view
./scripts/verify-remote.sh
```

The browser harness uses synthetic media and in-memory fixture trust; its automatic fixture approval is not appropriate for the real host. It needs installed Node/Bun/Xcode/XcodeGen/Playwright and a browser. Existing environment overrides include POCKETDESK_PLAYWRIGHT and POCKETDESK_CHROMIUM; discover actual local locations. Each run requires a fresh receipt directory. Do not repeat full suites without changes or unresolved failures. A browser-only change need not replace the signed host.

## 8. Private run details and cleanup obligations

Historical working private origin: `https://roshans-macbook-air.tail8c17ee.ts.net:8444`, loopback browser service port 8788. These are routing details, not credentials. Verify availability/ownership first.

```sh
POCKETDESK_BROWSER_PORT=8788 POCKETDESK_BROWSER_ORIGIN=https://roshans-macbook-air.tail8c17ee.ts.net:8444 POCKETDESK_BROWSER_DURATION=3600 bun scripts/browser-dev.ts
tailscale serve --bg --https=8444 http://127.0.0.1:8788
```

Use exact Origin/Host config and explicit Mac approval. Enrollment secrets must not enter reports/screenshots/source. No public Funnel route is requested. Existing routes on 443, 8443 and 10000 belonged to other work; preserve them. Remove only a route this test owns, using `tailscale serve --https=8444 off`, never a global reset. Stop only owned processes.

Prior pause cleanup completed: private service and temporary keep-awake stopped; temporary 8444 route removed; previous proxy config verified restored; diagnostic screenshots deleted. No active browser control session remained at that pause.

Remaining UI cleanup at last observation: revoke/forget the test browser enrollment, restore Stage Manager to on, and restore the phone's Tailscale connection to its original off state after tests no longer need it. The network check used the still-connected phone; it did not resolve these UI obligations. Recheck current state first and honor any newer user preference.

Computer-use lessons: keep the iPhone locked for Mirroring, Mac awake and unlocked. Direct phone use disconnects Mirroring. Stage Manager caused thumbnail-sized tool captures; user authorized native macOS screenshots as a fallback, not arbitrary alternate UI automation. Only use controls permitted in the receiving environment. Typing immediately after focus changes sometimes lost text; verify focus before typing, especially because remote input can otherwise land back in Mirroring. Native screenshot permission does not authorize retaining private desktop content in reports. If remote typing requires the Mac editor focused, verify that actual target and do not assume a tool acknowledgement proves focus.

## 9. Later feature: smooth focus zoom, researched only

Roshan recalled Screen Studio. Its official [Auto Zoom guide](https://screen.studio/guide/auto-zoom) confirms zooms center on click locations in recorded footage; its [product page](https://screen.studio/) describes automatic zoom and smooth animations. This validates the inspiration, not semantic input-field detection or real-time remote-control feasibility.

Proposed later PocketDesk experiment: optional, smoothly animated zoom toward an editing target with one-tap Fit/undo and immediate manual override. Treat it as a viewport/readability feature, separate from transport optimization. Local enlargement cannot restore detail lost during encoding.

Important design questions and acceptance plan:

- The current control surface is a relative trackpad; its touch location is not necessarily the remote cursor/field position. Use a verified remote target position or reviewed focus metadata, not raw phone touch coordinates.
- A video stream has pixels, not remote DOM input boxes. Mac accessibility focus geometry is a possible later approach, but needs platform verification, permission/scope review, geometry mapping and fallback. Do not claim arbitrary field detection is implemented. Avoid collecting field values, passwords or keystrokes for this feature.
- Account for selected-display origin/scaling, orientation, current pan/zoom and keyboard occlusion. Keep the target stable during typing; avoid chasing every click or repeatedly zooming in/out.
- Do not move/scale the target while a drag is held or inject extra clicks to discover focus. Preserve input coordinate mapping and stale-frame gates. Manual zoom/pan wins; provide Reduce Motion behavior and an easy disable option.
- Prototype later against disposable fields/editors; compare task errors, readability, motion comfort and latency with zoom off/on. No change to streamed resolution by default. Only pursue server-side crop encoding if separate evidence warrants it.

Do not add this to the current networking implementation scope. Record it as the user's requested future experiment in the product backlog when the receiving task updates product planning.

## 10. Required return report and stop line

Deliver a concise user explanation plus file-backed evidence:

- What changed and why; exact affected files and independent review outcome.
- Before/after measured route, dimensions, codec/fps/bitrate, encode/decode/callback cost and actual input-to-visible statistics, with sample sizes and limitations.
- Readability/quality evidence; disclose any adaptation and tradeoff rather than claiming quality preserved automatically.
- Physical edit/save/run result and a case-by-case interruption/revocation/control matrix.
- Updated Docs/IMPLEMENTATION-PLAN.md with receipts, outstanding dependencies, and cleanup state. Keep product decisions in PRODUCT.md.
- A verdict: works for the tested task/conditions, needs a specific fix, or unvalidated because of a named dependency.

Stop at the authorized private feasibility result. Do not automatically build accounts, billing, multi-device support, virtual displays, clipboard/file transfer, audio, public release, or the later zoom feature. If provider/phone access is unavailable, finish independent local work and report the remaining physical/public gate honestly rather than declaring networking complete.

## Evidence index

- Current network report and raw data: `outputs/network-check-20260914/`.
- Physical Safari partial acceptance/paused cleanup: `outputs/private-safari-20260914/resumed-paused-receipt.json` and the end of `Docs/IMPLEMENTATION-PLAN.md`.
- Mobile shortcut fix/review: `outputs/private-safari-20260914/mobile-key-fix.json`.
- Permission repair: `outputs/permission-identity-20260913/post-repair-verification.json`.
- Host UI workaround/install: `outputs/cua-window-diagnosis/receipt.json`, `outputs/host-run-20260913T132727Z/`.
- Historical local verification: paths enumerated in `Docs/BROWSER-TESTING.md`.
- Interpretation references: [Apple network responsiveness](https://developer.apple.com/videos/play/wwdc2021/10239/), [Tailscale connection types](https://tailscale.com/docs/reference/connection-types), [WebRTC statistics specification](https://www.w3.org/TR/webrtc-stats/).
