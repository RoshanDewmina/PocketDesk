# First-picture recovery — 4 October 2026

## Physical failure and isolation

Installed .8 / 20261003.3 on Roshan’s iPhone 17 and Mac. At 19:25 ET the authenticated direct session connected, host capture/encoding continued, and the phone remained on “Waiting for your Mac’s screen…”. Detailed fresh-run phone counters show HEVC Main444, received 54–57 fps, decoded/rendered zero, about44 MB received. Big Text applied a display-size change; timing alone does not establish it as the cause.

The same installed binary relaunched with `-farsideExperimentalFullColorHEVC444 NO` showed the desktop, confirmed by the owner. Ordinary HEVC Main counters decoded25–30 fps, rendered24.5–29.9 fps, presented22.6–27.1 fps. This isolates the failed full-color path; its exact internal rejection remains unconfirmed. Earlier stored phone statistics were stale and were excluded.

## Repair candidate

- Build20261004.1 based on .8 revision619c803.
- Main444 held out of normal launches and distribution, even if an old experimental preference remains enabled. Only a DEBUG launch with `--farside-full-color-recovery-check` and the existing preference can enable it for controlled regression testing.
- First-picture HEVC watchdog uses actual cumulative inbound counters and negotiated profile, never rendered FPS or host intent. Sustained received frames without decoded frames triggers existing codec-failure negotiation once. Authorization, privacy and route admission remain unchanged.
- No publication, App Store upload/submission or production download replacement.

## Validation ledger

Source review, scoped tests, signed builds and physical corrected-build acceptance: PENDING.

Current session evidence is in the Oct4 Codex task work/manual-test-2026-10-04 directory; raw logs are local and are not uploaded.
