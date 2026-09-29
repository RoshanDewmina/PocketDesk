# Mac companion redesign to Farside "Reach" — report

29 September 2026 · branch `worktree-agent-a6f1c7fc3804e24e8`, rebased onto `pocketdesk-remote-chat` at `d602b1b` (stream tuning merged). Target: `PocketDeskRemoteHost`. Design source: `design/FARSIDE-DESIGN-SYSTEM.md`, concept `design/farside-round1/21-reach.html` (Mac helper section), component rules from `28-dither-os.html`.

Not installed, launched or signed here. Bundle identifier, `PRODUCT_NAME`, signing settings and the installed path are unchanged; the identity guard in `Docs/MAC-PERMISSION-IDENTITY.md` is untouched.

## What changed

| Area | Result |
|---|---|
| Menu-bar icon | The dot-matrix Farside mark (`HostMark`, 14 × 20 pt). Template image when idle; dimmed when paused; ringed tip when setup or sharing needs attention; while a phone is connected the tip is drawn ember and the body follows the menu bar's label colour at draw time (non-template image). Accessible description "Farside, <state>". |
| Popover | `MenuBarExtra` now uses the window style. Halftone strip with the state on a solid plate ("Connected · sharing this Mac", "Paused · back at 10:52", "This Mac is locked"…), who is steering with route · latency · fps parsed from the existing sender diagnostics, Allow control ("Off means view only") and Chime toggles, Pause 10 min + ember Stop Sharing, footer Settings… · Pair a phone… · Quit (⌘, and ⌘Q kept). Approval, paused, off, locked/asleep/switched user, service trouble and setup states each get one main action. |
| Setup window | 800 × 520, hidden title bar. Left rail: halftone art in which the fingertip closes the gap to the pointer step by step; the ember contact dot appears only when a phone is actually connected. Steps Hello · Permissions · Pair your phone · Ready check with dot progress. Permission rows update by themselves; "Watching for the switch", Quit & Reopen, and "Still not detected?" (after 20 s) replace the old always-on recovery paragraph. Pairing keeps the QR (now void on bone), expiry, visible "Copy code instead", approval, replace and service-address states. Ready check rows come from live state (Screen Recording, control, display, connection, pairing, open at login) with inline fixes. Back/Continue move only within what the model allows. |
| Settings | Farside tokens throughout; header with mark, wordmark and status pill; status panel with the state's action; sections Phone · While your iPhone is connected · Permissions · General. Row icons and duplicate actions removed; every previous control kept (pair/remove phone with confirmation, control, keep awake, display picker, permission links, open at login) plus the chime toggle. |
| Naming | `CFBundleDisplayName` is `Farside`; window title "Set Up Farside"; user-visible PocketDesk strings in host views and `HostModel` details now say Farside. Code identifiers unchanged. |
| App icon | `design/farside-mac-icon/generate.py` authors the SVGs (void squircle on the macOS grid, halftone fingertip, crisp bone pointer, ember dot where they meet; 128 px and below use fewer, larger dots, 16 px keeps two dots and the ember dot). `render.sh` renders them with headless Chrome into `RemoteHost/Assets.xcassets/AppIcon.appiconset` (all 10 macOS sizes). `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`; the built bundle carries `AppIcon.icns` and `CFBundleIconName`. |
| Halftone | `RemoteHost/HostHalftoneArt.swift`: host-local, still, 8 × 8 Bayer-dithered dot art (popover strip moods, setup rail reach), drawn once per size and cached. Swap for `RemoteShared/FarsideHalftone` after the phone work merges. |

New behaviour, kept small and built on existing actions (`HostModel`):
- **Pause 10 min** = Stop Sharing now, then Resume Sharing when an in-memory timer fires, unless the user resumes, stops or pairs first. After a relaunch during a pause sharing stays off, as after Stop Sharing.
- **Chime when a phone connects**, on by default (as in Reach), stored in `HostPreferences.chimeOnConnect`; plays the system "Glass" sound after a new connection authenticates and capture starts. Not played on a background resume.
- The view state now carries `accessibilitySkipped`, the timed pause, the parsed session readout, why the Mac is unavailable (locked, asleep, switched user, display asleep) and the name the bundle shows in Finder.

Capture, input, pairing, permission polling, keep-awake, lock/sleep handling, clipboard, pointer telemetry and the relay are unchanged apart from those hooks. Views follow `HostSettingsSection` (no `GroupBox`, no grouped `Form`).

## Files

New: `RemoteHost/HostPresentation.swift` (pure state → copy/actions, setup flow, ready check, readout parser, timed pause), `HostPopoverView.swift` (replaces `HostMenuContent.swift`), `HostMark.swift`, `HostHalftoneArt.swift`, `Assets.xcassets`, `RemoteTests/HostPresentationTests.swift`, `design/farside-mac-icon/*`.
Rewritten: `HostSetupView.swift`, `HostSettingsView.swift`, `HostStyle.swift` (Farside components, fonts, buttons, switches), `HostSettingsSection.swift`, `RemoteHostApp.swift`. Edited: `HostModel.swift`, `HostViewState.swift`, `HostReadiness.swift` (chime preference), `HostAppActivation.swift`, `HostUITests/HostUISnapshotTests.swift`, `project.yml`, regenerated `PocketDesktop.xcodeproj`. `RemoteShared/FarsideTheme.swift` is untouched; host-only tokens live in `HostTheme`.

For the Mac parity work: popover session toggles are rows of a `HostHairlineList` in `HostPopoverView.sessionToggles`; Settings rows go in the existing `HostSettingsSection`s (General holds Open at login); the ready check reads `openAtLogin`, so a launch-at-login default flows through. Controls carry `farside.popover.*`, `farside.setup.*`, `farside.settings.*` accessibility identifiers for automation.

## Verification

- `xcodegen generate`; `PocketDeskRemoteHost` Debug build (unsigned override on the command line, project signing untouched): passes, no warnings in the changed files. Built Info.plist: identifier `com.roshan.PocketDesk.RemoteHost`, executable and `CFBundleName` `PocketDeskRemoteHost`, `CFBundleDisplayName` `Farside`, `CFBundleIconName` `AppIcon`.
- `RemoteCoreTests` (`xcrun xctest`, as in `scripts/verify-remote.sh`): after the rebase onto `d602b1b`, 250 tests, 3 skipped (pre-existing/upstream), 0 failures; 16 of them are the new `HostPresentationTests`. Before the rebase: 229 tests, 1 skip, 0 failures.
- `HostUISnapshotTests`: 5 tests, 0 failures: popover states, menu-bar mark (template flags, ember only while live, body follows light and dark menu bars), halftone rules (no dots under caption plates, ember only for contact), setup steps and Settings rendered offscreen in dark appearance.
- All `xcodebuild` runs used `lockf -k /tmp/farside-xcodebuild.lock`.

Review screenshots (offscreen `NSHostingView` renders, not the live menu bar): `~/Downloads/farside-mac-*.png` — `menubar`, `popover-live`, `popover-view-only`, `popover-ready`, `popover-approval`, `popover-paused`, `popover-off`, `popover-locked`, `popover-unavailable`, `popover-needs-setup`, `setup-1-hello`, `setup-2-permissions`, `setup-2b-permissions-waiting`, `setup-2c-permissions-granted`, `setup-3-pair`, `setup-3b-approve`, `setup-3c-expired`, `setup-3d-replace`, `setup-4-ready-check`, `setup-4b-ready-live`, `setup-4c-ready-issues`, `settings`, `settings-live-two-displays`, `settings-needs-attention`, and `icon` (all icon sizes on dark and light).

## Open issues

1. **Accent fonts are not bundled.** No Doto or Instrument Serif files exist in the repo and none were downloaded. Headings fall back to SF Pro Semibold and New York Italic; the wordmark is drawn in dots. `HostFonts.registerBundledFonts()` registers any `.ttf`/`.otf` in the app bundle, so adding the OFL files under `RemoteHost/` (xcodegen picks them up as resources) switches the display type on.
2. **Two names on disk.** The installed bundle must stay `/Applications/PocketDesk Host.app` and `CFBundleName` follows `PRODUCT_NAME`, so Finder shows "PocketDesk Host". System Settings privacy lists may show either name; setup says "It may be listed as “PocketDesk Host”" using the bundle's real Finder name at runtime. Check on the installed build: app menu name, Settings window title, the TCC prompt and list entries.
3. **Live checks needed after install** (`script/build_and_run.sh` from the integrated checkout): popover opening/closing and `dismiss()` before Settings/pairing, ⌘, and ⌘Q inside the popover, the live icon's colour on light/dark and tinted menu bars, VoiceOver on the custom switches (they expose native toggles via `accessibilityRepresentation`), hidden-title-bar setup window dragging, the chime, and Pause 10 min resuming.
4. The UX audit preferred a native menu; the chosen Reach design is a popover, which is what shipped here.
5. PRODUCT.md should record Pause 10 min and the connect chime as product behaviour (not edited here to avoid conflicts with parallel agents).
6. Not done (need capture or protocol work): a live "this is what your iPhone will see" thumbnail on the ready check, the phone's real device name ("Your iPhone" until the handshake carries it), an auto-refreshing pairing code, App Store QR / Send to iPhone.
7. The app icon is a first pass for owner review; macOS 26 Icon Composer layers were not produced. Power-assertion names seen in `pmset` still say PocketDesk.
