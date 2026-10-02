# Batch-7a .3 device smoke — 2 October 2026

**Ten-minute hands-on ceiling; ordered by regression risk.** This runbook has not been executed by the evidence worker. It covers the 28 active historical rows with symptom checks or explicit conditional/pending obligations. G21 (Home Session check pill) is RETIRED BY OWNER and excluded. The quick pass cannot establish every historical claim in ten minutes; do not label an unperformed step PASS.

The requested candidate is **20261002.3 on batch-7a**, superseding the original `20aded1` baseline request. Before installation, the orchestrator must have a passing automated gate on the exact candidate revision and record its `summary.json`. Preparation/install time is outside this ten-minute hands-on budget. The worker must not install, launch, stop or replace the installed host or physical apps.

## Preparation owned by the orchestrator

1. Record candidate commit, host/phone CFBundleVersion and phone model/OS, gate receipt path and start time. A simulator artifact is not a physical app. If matching signed `.3` artifacts or a passing gate are absent, stop: **BLOCKED**.
2. Install only through the integrated main checkout at `~/Developer/PocketDesk`. Mac updates go through `script/build_and_run.sh` with the existing host identity guard; never install from a worktree or bypass identity continuity. Physical phone install/launch belongs to the orchestrator’s authorized device round. Existing phone pairing stays intact; fresh pairing is a separate isolated check.
3. Set up a harmless changing Test Pad/page and long-scroll document, disposable Notes text, a Chrome field and Claude draft field (no send). Prepare one tiny known-content file on each endpoint and its SHA-256 before the clock starts. Record original Mac display mode and window positions for Big Text restoration.
4. Keep builds, simulators, headless browsers and unrelated test services stopped for the physical feel portion. iPhone Mirroring may check labels/buttons/navigation, but can distort busy/lag/gesture results. Disconnect Mirroring and use Roshan’s real touch for pinch/scroll/Couch/PiP feel and dwell. Do not use mirrored smoothness as a hands-on PASS.
5. Start host PDSTATS and phone logs in separate terminals, with a new receipt directory. Avoid environment/credential dumps; copy only sanitized report facts. Stop the log processes afterwards. If a log channel is unavailable, record it without inventing a sample.

Verified CLI syntax from installed `devicectl --help` on 2 October (instructions only; not executed on a device by this worker):

```sh
# Orchestrator only, after gate and candidate verification.
# Assign smoke_signed_app to the already prepared physical .3 app,
# smoke_receipts to a new receipt folder, and smoke_device to the chosen device.
xcrun devicectl device install app --device "$smoke_device" "$smoke_signed_app" --json-output "$smoke_receipts/phone-install.json"
xcrun devicectl device process launch --device "$smoke_device" com.roshan.PocketDesk.Remote --json-output "$smoke_receipts/phone-launch.json"

# Capture in separate terminals; stop with Ctrl-C at end.
idevicesyslog -u "$smoke_device" > "$smoke_receipts/phone-syslog.txt"
tail -n 0 -F "$HOME/Library/Caches/PocketDeskStreamStats.jsonl" > "$smoke_receipts/host-pdstats.jsonl"
```

Use the currently selected device identifier; do not infer that the friend’s iPad or owner’s phone is free to re-pair. Bundle identifier is `com.roshan.PocketDesk.Remote` (`project.yml`). Do not change permissions or create/deploy staging entitlements as preparation.

## Timed sequence

Start the clock with the candidate installed, artifacts prepared and phone in hand. Record row IDs beside each outcome. Stop on host exit, persistent blanking, stuck held input, phone crash or misleading completion; retain receipts and return the candidate to the orchestrator for diagnosis. Log no PASS for steps not reached.

| Elapsed budget | Rows | Action and pass criterion |
|---|---|---|
| 0:00–1:30 | G01–G06, G16, G18 | Same-Wi-Fi Connect in portrait. Require a **new moving picture** and host still running. Move one finger and tap a disposable target once. Pinch in/out six times around text, then pan while zoomed and scroll up/down at normal and larger zoom. PASS only if pointer/click work, scroll remains scroll, picture never blanks and no crop/scale jumps or repeated jitter/sharpening occur. No Waiting-for-screen/controls-paused notice while healthy. Observe on phone with real touch. |
| 1:30–2:30 | G17, G18, G25 symptom | Leave a still readable page untouched for **60 s**. Require no false busy/slow pill, healthy picture/input admission and no sleep. This covers G17’s quick symptom and only 60-second G25; ten-minute keep-awake remains **PENDING**. Log actual notice text if it appears. |
| 2:30–3:30 | G07–G12 | Reveal Controls; all buttons reachable. Spaces left/right once each; Mission Control once and dismiss; right-click a harmless target; double-click a test folder; Hold click a disposable title bar, move, then Drop. Require intended single action and no remaining drag. Ten-second auto-drop timing was never physically accepted; do not invent a PASS for it. |
| 3:30–4:30 | G13, G14, G29 | Portrait: click text fields in Notes, Safari, Chrome and Claude. Keyboard must appear; draft plus Done/Hide remain reachable without rotation. Enter a harmless short word in Notes and verify its exact content on Mac, then Hide. Do not send the Claude draft. Field-opening alone cannot PASS text delivery; log per-app outcomes. |
| 4:30–5:15 | G19, G20 | Use Big Text’s currently intended default/manual affordance; require Mac text really changes and phone matches, without a contradictory failed/changing pill. End the session and time original-mode restoration, including window placement. Record seconds and display modes; delayed restoration is a finding, not an invented threshold. Exact instant restore was never accepted. Reconnect for files. |
| 5:15–6:15 | G15 | Send the prepared tiny file phone→Mac and Mac→phone via the intended entry points. Open both, compare known contents/SHA-256 and require honest completed status. Record each direction separately. Do not substitute a toast or grouped praise for integrity. If picker latency exceeds the budget, mark unfinished direction PENDING. |
| 6:15–7:00 | G22 | End picture session; enter Couch. Move pointer and enter one harmless key while looking at Mac, with no streamed picture. Require control and no stuck hold. Record jitter/lag separately: historical function was usable, smooth feel was explicitly rejected. End Couch and reconnect picture. |
| 7:00–7:45 | G23, G24 | Start **manual** PiP, go Home while Test Pad/page moves, then return by tapping PiP. Require window appears, frames continue and return does not crash. Record automatic Home trigger as an extra unresolved feature if tested. Historical receipts approve only narrow window/frame behavior; frozen/live-but-jittery/crash must be reported, never full PiP PASS. |
| 7:45–8:15 | G27; G26 continuity only | Open available stream stats; Copy Diagnostics and paste into a disposable local note. Require nonempty sanitized diagnostics, consistent current session facts/PDSTATS and no clipboard-content claim. Existing paired Connect/reconnect without account is a **continuity-only** G26 check, not fresh QR/paste acceptance. |
| 8:15–9:00 | G28 conditional | **Only if** the existing approved staging developer pass and an off-home-network route are already available: connect for at least 35 s and record direct internet `route/routeDetail`. A same-LAN direct route cannot pass Anywhere. Entitlement/off-network prerequisite unavailable → BLOCKED. No forced TURN, cellular endurance or renewal PASS from this step. Reconnect normal local route afterwards. |
| 9:00–10:00 | G26 conditional / wrap-up | Fresh QR or pasted invitation may be checked **only on a disposable already-isolated setup**, with Mac approval and no account, without replacing the owner’s active trust. Record which invitation form was used; it cannot approve both. If no isolated setup, G26 fresh pairing is PENDING. End sessions; ensure no stuck keys/drag, Big Text original mode restored and temporary files/log capture cleaned up. Save row outcomes with end time. |

The intervals total **10:00**. Setup/preparation is outside the clock, but time-consuming prerequisites do not permit an unlimited smoke: mark them BLOCKED/PENDING, preserve current pairing and stop at ten minutes. All active rows are named; not all are fully certified by the short procedure.

## Obligations the quick pass cannot clear

- **G25 full dwell:** after the quick pass, run a separately recorded hands-off ten-minute video session, with exact start/end timestamps and no touch/input. Require neither phone nor Mac screen sleeps and continuing fresh frames. Passive dwell costs no extra hands-on manipulation, but extends elapsed session time; until performed, G25 full duration is PENDING.
- **G26 fresh enrollment:** continuity does not cover QR/paste invitation approval. Use a disposable isolated setup later if unavailable. Never unpair the owner’s phone merely to fill a checkbox.
- **G28:** 35-second direct staging success is not TURN/cellular/long-session acceptance. Missing prerequisite stays BLOCKED, not waived. Route evidence must establish off-LAN direct traffic.
- **PiP and Couch quality:** narrow historical receipts remain partial. Full safe PiP lifecycle and acceptable Couch smoothness require fresh evidence beyond their old grouped functional receipt.
- **Clipboard, mic and audio:** none has a historical confirmed-success row. Preserve NOT CONFIRMED from the golden ledger. Optional future acceptance must check content clipboard both directions, mic permission/cancel/dictation into a disposable field, and audible Mac audio separately; do not silently squeeze these into or count them as golden PASS.
- **iPad/new shell:** universal device support and simulator layout checks do not certify real iPad feel, multitasking or Pencil. Repeat relevant active rows on the intended iPad in a separate device pass; never transfer the iPhone PASS label.

## Receipt and disposition

Use a per-device record with candidate revision, installed host/phone build, gate path, device/OS, real-touch vs MIRROR tag, elapsed time and each row’s status. Example:

```text
G04 FAIL — .3 / iPhone17 / real touch / 00:48 — repeated zoomed crop jumps; recording + PDSTATS paths
G15 phone→Mac PASS / Mac→phone PENDING — only one direction completed
G21 RETIRED BY OWNER — no active obligation
G25 QUICK-SYMPTOM PASS, FULL-DWELL PENDING — 60 s observed; no ten-minute claim
G26 CONTINUITY PASS, FRESH-PAIR PENDING — existing owner pair retained
G28 BLOCKED — off-LAN route/approved pass unavailable
```

Keep quick symptom, grouped/partial function and full behavior acceptance distinct. Any FAIL blocks promotion of that behavior. BLOCKED/PENDING items remain in the candidate report; the parent decides scope and installation readiness from exact receipts, not historical labels or green proxies. See `REGRESSION-GOLDEN.md` for each source and test mapping.
