# App Store claim verification

Run from any checkout of the integrated build to be uploaded:

```sh
python3 script/claims/run.py all --dd /Volumes/Studio/Development/Caches/b7-claims/DD --output /Users/roshansilva/Documents/Codex/2026-10-01/perf-push/b7-claims
```

The runner creates timestamped source scans, Xcode settings, command logs, JSON exit receipts and simulator `.xcresult` bundles. It builds the isolated Mac companion for architecture/minimum-OS inspection but never launches/installs it and never targets a real device. It waits for PAUSE-BUILDS, PRIORITY-BUILD and QUIET-GRANTED-* before each build/test, checks them again after acquiring `lockf -k`, keeps package resolution pinned, and refuses builds below 10 GiB internal free disk. It uses Debug because the lane rules require it; Release effective settings are separately audited. The uploaded Release build still needs integration/release and physical acceptance.

Stages `auto`, `build`, `phone`, `ipad`, `duo`, `core`, `backend`, `host` can be rerun separately. `phone`/`ipad` require a successful `build` on the **same source**, DD and test binary. The runner hashes source before/after compilation, binds complete app/test bundles (including debug dylibs and resources), and rechecks identity under the shared lock before and after testing. Simulator cleanup stays under that lock. Stop and rebuild after integration; never apply an old `.xcresult` to a changed build. `--phone`, `--ipad`, `--duo` override explicitly lane-owned simulator UUIDs. The default phone and iPad are the assigned acceptance simulators; do not substitute another lane's active simulator. The one Duo attempt is bounded to 180 seconds and is not retried; a terminal migration failure is rejected even if simctl exits zero. Backend renewal/route checks use only local Cloudflare fixtures and matching shared lockfile dependencies, never deployment/provider actions. Every simulator run shuts down its explicitly assigned simulator, never all simulators.

Claim UI tests live in the existing `RemotePhoneUITests/FarsideRedesignUITests.swift` file, so source membership needs no project regeneration. Offline fixtures do not pair or contact a real Mac. Audit callbacks collect all reported issues, attach screen/hierarchy reports, and assert zero issues after enumeration; an audit test failure is expected when issues are present. Inspect findings by screen; do not suppress contrast/hit-region/Dynamic Type failures merely to get green tests. Simulator gesture generation and preview text do not prove hardware haptic feel, microphone transcription, actual remote key delivery, PiP thumbnails, or physical fold alignment.

Core C4/C5 source/test/harness limitations and the scoped test selection are in `HOST-AUDIT.md` in the output folder. A standalone media bench is not a no-session-cap test. No >=35-minute actual native session was run by this lane; see the hands checklist.

Pass/fail results update evidence, not nomination/ASC settings. Keep `CLAIMS-MATRIX.md`, `CLAIMS-VERDICT.md` and `HANDS-CHECKLIST.md` with the exact integrated commit and uploaded build receipt before public claim changes.
