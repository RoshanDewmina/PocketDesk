# Brief: landing pass (Opus 5.5) — 29 Sep 2026

I'm getting last night's Farside work merged, tested against the real Mac host and installed on Roshan's iPhone. Roshan needs a build on his phone that he can trust, so he can check the black-screen fix and the new features on a real device. Performance is the product's first priority, so this pass must leave main stable and measurable for the performance lead who works in parallel.

## Read first

`AGENTS.md` (including "Paths and the shared Mac"), `Docs/plans/ORCHESTRATOR-STATE-2026-09-29.md` (the resume checklist), `design/PHONE-PARITY-REPORT.md` and `design/SYSTEM-INTEGRATIONS-REPORT.md`. The repo is `~/Developer/PocketDesk`; main is `pocketdesk-remote-chat`.

## Done means

1. **Phone parity** (branch `worktree-agent-a9c91c9bb117300d3`, tip `66d432e`) is rebased onto current main, reviewed and merged. `MiniMapVideoTests` ran. The phone unit suite, the iPhone UI suite and the iPad parity suite (unit and UI in separate runs) pass on the rebased tip. Recheck the 18 `RemoteCoreTests` failures its report calls environment-only now that the repo is out of `~/Documents`: fix them if they're real, and explain them if they're not.
2. **System integrations** (branch `worktree-agent-a752967d0e530c55c`, tip `153835b`) is rebased after parity, reviewed and merged.
   - Expect conflicts in `RemotePhoneApp.swift`, `HomeView.swift`, `ControlProtocol.swift`, `SessionContinuity.swift` and `project.yml`; regenerate the project with xcodegen.
   - `FARSIDE_ENABLE_PUSH` stays off by default so wildcard-profile device builds still sign.
   - Tests that need a real phone (Lock Screen End button, Siri, Spotlight, Always-On) are skipped on the simulator with a stated reason, not deleted. Restore `testSpotlightOffersTheApp` that way.
3. **Host reinstalled** from integrated main with E2E hooks, via `lockf -k /tmp/farside-xcodebuild.lock script/build_and_run.sh`.
4. **Real-host E2E** scenarios a, b, c, d1–d5 and e have run. Failures are triaged; fix product bugs you can prove, and never loosen an assertion to get green.
5. **iPhone build installed** with the next `CURRENT_PROJECT_VERSION`, and the installed version checked with `devicectl`. Do the same for the iPad if it's connected.
6. **A short report for Roshan:** what was tested at which evidence level, and a five-minute on-phone checklist for him.

## Boundaries

- Before step 3 and before step 4, message the orchestrator and wait for the go-ahead, because Roshan must be told first. The reinstall briefly drops his phone session; E2E puts a Test Pad window on his screen, clicks in it, and scenario e switches Spaces.
- Run one Xcode-heavy process at a time under the shared lock. Shut down simulators when finished. Install to the phone or `/Applications` only from the main checkout.
- No deploys, purchases, DNS changes, account creation or posting.
- Before reporting progress, audit each claim against a tool result from this session. If something isn't verified, say so.
- When a step doesn't need Roshan's input, keep going, and put status notes in the same message as your next action.
- Commit and push after each verified merge.
