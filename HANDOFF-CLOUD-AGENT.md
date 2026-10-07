# Farside: handoff for the cloud agent (2026-10-05, 14:30 ET)

Farside (formerly PocketDesk) is a native iPhone client plus a Mac menu-bar host that lets you control your Mac from your phone. You can use it free on the same Wi-Fi. "Farside Anywhere" adds a relay and costs CA$7.99/mo or CA$59.99/yr with a 7-day trial. Bundle IDs stay `com.roshan.PocketDesk.*` on purpose, so the Mac doesn't reset its privacy permissions. The 1.0 scope is **iPhone only** (D62 parks iPad/Duo).

## What to read first
1. `PRODUCT.md`: scope and decisions D01–D62+. `AGENTS.md`: agent rules.
2. `Docs/launch/CURRENT-REVIEW-PACKET.md`: the top section is the 5 Oct checkpoint. The rest is archived history.
3. `Docs/handoff/codex-outputs-2026-10-05/`: copies of the latest Codex outputs, which normally live outside the repo:
   - `farside-current-handoff-2026-10-05.md` is a running log, newest entry first.
   - `farside-release-readiness-2026-10-05.md` and `farside-development-versus-release-reconciliation-2026-10-05.md`
   - `farside-ten-feature-build-report.md` covers the 10-feature MVP build (PR #1).
   - The public Smart Zoom and privacy-draft patches are **not applied yet**. Their `*-handoff.md` files explain them.

## Branches that matter now (newest work first)
| Branch | What it is |
|---|---|
| `codex/combined-regular-20261005` | **Latest integration** (from Codex): quality checkpoint `05bcc22`/`f4a3688` + 10-feature MVPs + Claude's dashboard/phone-controls redesign. The tip is a WIP snapshot of an uncommitted `project.pbxproj` change. Not installed yet. |
| `codex/ten-features` | Draft PR RoshanDewmina/PocketDesk#1 "owner workspace tools and glass lenses". 9 of 10 MVPs are built. #9 (virtual workspace) is blocked on a supported display provider. Sub-lanes: `codex/ten-*`, `codex/glass-lens`, `codex/notification-lifecycle`. |
| `pocketdesk-remote-chat` | Default branch, "production checkout" (`4524689` + docs). **Installed on Mac + phone: regular dev build 20261004.9** (Debug). |
| `codex/overnight-quality-20261004`, `codex/workspace-phone-beta-20261004` | Workspace/Smart Zoom private beta (phone 105, Mac 106). Kept separate from regular. |
| `claude/simplify-*`, `claude/phone-controls`, `claude/settings-redesign` | 4 Oct UI simplification lanes. Already merged into combined-regular. |
| `claude/b7…b14-*`, `claude/batch-*` | Build packs from 2–3 Oct. Most of this reached 20261004.9. |
| `website/*` | Marketing site (Astro, Cloudflare Pages project `farside-site`). Latest: `website/research-corrections-20261005`, `website/launch-oct27`. |
| `main` | Stale since 12 Sep. Don't use it. |
| `wip/*`, `backup/local-*` | Safety snapshots pushed on 5 Oct (detached worktrees and diverged local agent branches). Only look at these if something seems lost. |

On 5 Oct, every dirty worktree was committed with the message "WIP snapshot before cloud-agent handoff (2026-10-05)". Treat those tip commits as unreviewed.

## Where the work stopped
- **Controls polish campaign (R3–R6) on combined-regular:** a native UI test requires every tap target to be at least 44 pt. The Settings sheet "Done" button measured 36×36 (`ProductionControlPolishUITests.swift:314`). R4 tried a label-only fix and it didn't work. R5 reused the existing `controlsDoneButton` in the `settingsForm` toolbar, but its run stopped at project generation because the Host CopyFiles phase order changed. R6 restored the canonical PBX phase order, and its first native case was running when the log ended. **Next step:** get the 44-pt Done fix passing, then run the full UI suite on combined-regular.
- Apply the public Smart Zoom foundation and UI-wiring patches to combined-regular, then build and test.
- **Owner's latest instruction:** combine the completed regular and beta features, install the regular build on both devices, and remove the beta only after its replacements are verified. Hands-on/manual testing (including Keyboard manual acceptance) is **parked**.
- Performance (from headless HEVC loopback on the M4): about 54 decoded fps. Sustained physical 60 fps is not proven. Quality/sharpness is the owner's #1 complaint.

## Still open before launch (owner/account items, not code)
Signed Release archives (Developer ID for Mac, Apple Distribution for iOS), notarization (keychain profile `farside-notary`), and Developer ID permission migration. Paid Apps tax: W-8BEN/Form 506 is blocked on Apple Finance case 22589260, so purchases stay disabled. Also open: live APNs/domain/provider checks, physical input/privacy/recovery/audio/files checks, privacy/legal text, and App Store submission. **No build has been uploaded to App Store Connect yet** (app ID 6817532560).

## Rules
- Never put secrets in the repo. Cloudflare staging only; never deploy to production without the owner. Remove the `DEV_RELAY_ROOMS` staging secret once sandbox subscriptions work.
- iOS/Mac builds need macOS and Xcode 27.0. A Linux cloud agent can do source work, backend (`backend/` Cloudflare Workers, bun), website, and docs, but **can't verify Swift builds**. Mark Swift changes "unverified on device".
- Keep the user surface simple: one intuitive default per thing, no option bloat. Target users are non-technical.
- Don't regress: a regression gate plus a device smoke test runs before any install. Risky device-only changes default to off.
