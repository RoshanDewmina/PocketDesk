# Lock/login unlock — Phase 1 feasibility tests U1–U4 (for Roshan)

2 October 2026. Prototype: `script/unlock-prototype/`. Only Roshan runs live tests. **Never run install, permission prompts, capture or input on the in-use shared Mac.** Use another test Mac, or a separately scheduled human-controlled window after saving all work. Agents build/sign/test policy only. This is standalone and never loads shipping Farside code, calls `build_and_run.sh`, or changes the installed host. No agent may lock, log out, sleep, restart, enable Remote Login or change this Mac's settings.

## Why and stop line

U1 asks whether the agent delivers real lock-screen frames. U2 asks whether HID-tap CGEvents actually unlock a **disposable standard account**. U3 asks whether the root GUI agent captures the **post-logout LoginWindow**, a separate context. U4 is excluded. Compile and unit-test success do not establish these results. `POSTED_NOT_VERIFIED` only says events were submitted; watch the screen yourself.

Phase 1 substitutes a local root-only CLI for the future phone/network transport. It proves OS primitives, not phone authentication, encrypted password transport, wake, latency or launch readiness. Password input is deliberately restricted to lowercase ASCII letters/digits (1–64 bytes), ABC/U.S. keyboard layout, no modifiers, no mouse or field selection. U3 capture only; it does not type a login-window password. No accessibility field values, pasteboard contents, key interception or Secure Event Input changes are used.

## Before you start

1. Ensure Python 3 is available on the test Mac (`python3 --version`); the cleanup helper requires it and installation refuses without it. Select a test Apple-silicon Mac on **macOS 26 or 27**, on power with lid open. Save work. Keep the current installed Farside host untouched; no running Farside control session during these tests.
2. Create a disposable **standard, non-admin** user manually in Users & Groups, e.g. `farsideunlocktest`. Give it a fresh lowercase/digit password used nowhere else. Never enter your real administrator/owner password into the prototype. Record its numeric UID (`id -u farsideunlocktest`) without recording the password.
3. Use a second administrator account and a second computer/terminal to control the test. If using SSH, only Roshan enables Remote Login on the test Mac, restricts allowed users, and records its previous state. Keep the second SSH admin connection alive; use `ssh -t` so the CLI has a TTY. This guide never puts either password in command arguments, pipes, environment variables, shell history or files. Do not use terminal recording, `set -x`, a debugger, core dumps or screen recordings during password entry.
4. Obtain artifacts signed by the named Roshan Developer ID (or development certificate of the **same team 39HM2X8GS6**). On the development checkout:

   ```sh
   script/unlock-prototype/test.sh
   script/unlock-prototype/build.sh
   ```

   Both use `lockf -k`, the shared testing gates, and `/Volumes/Studio/Development/Caches/b7-unlock/DD/SPM`. Build signs only; it does not install or notarize. Signing an unnotarized lab artifact is not release distribution approval. Copy the `artifacts/` directory and `script/unlock-prototype/` scripts/plists to the test Mac through your normal trusted local transfer. If using a development identity, `UNLOCK_SIGN_IDENTITY='Apple Development: …' script/unlock-prototype/build.sh` must still produce team 39HM2X8GS6; do not weaken signature requirements or Gatekeeper.

## Exact installation (human only, on the test Mac)

From the copied repository/script tree, replace `502` with the disposable UID and `/path/to/artifacts` with the transferred artifacts directory:

```sh
sudo script/unlock-prototype/lab.sh install 502 /path/to/artifacts
```

Type `TEST-MAC` at its interactive confirmation. It refuses an administrator test account and existing prototype paths. Installed paths are exactly:

- `/Library/Application Support/FarsideUnlockPrototype/UnlockDaemon`
- `/Library/Application Support/FarsideUnlockPrototype/UnlockControl`
- `/Library/Application Support/FarsideUnlockPrototype/UnlockAgent.app`
- `/Library/Application Support/FarsideUnlockPrototype/config.plist` (root-owned; Enabled and DisposableUID only)
- `/Library/LaunchDaemons/com.roshan.Farside.UnlockPrototype.daemon.plist`
- `/Library/LaunchAgents/com.roshan.Farside.UnlockPrototype.agent.plist`

The installer runs:

```sh
sudo launchctl bootstrap system /Library/LaunchDaemons/com.roshan.Farside.UnlockPrototype.daemon.plist
```

Log in locally as the disposable user. While that GUI session exists, use the separate admin terminal:

```sh
sudo launchctl bootstrap gui/502 /Library/LaunchAgents/com.roshan.Farside.UnlockPrototype.agent.plist
sudo launchctl print gui/502/com.roshan.Farside.UnlockPrototype.agent
sudo launchctl print system/com.roshan.Farside.UnlockPrototype.daemon
```

If the agent auto-loaded at this login, bootstrap may report “already loaded”; `print` must show the expected unique executable. Do not bootout an entire `gui/502` domain. From a terminal **inside the unlocked disposable account**, request the prototype's own permissions:

```sh
open -n '/Library/Application Support/FarsideUnlockPrototype/UnlockAgent.app' --args --consent
```

Launch through `open` so LaunchServices attributes the consent request to the prototype app. Approve Screen Recording and Accessibility for **Farside Unlock Prototype** using ordinary macOS Settings only; if the prompt instead names the terminal, cancel and add only the prototype app in Settings manually. Record before/after grant state. Relaunch only its exact agent if macOS says permission takes effect after relaunch:

```sh
sudo launchctl bootout gui/502/com.roshan.Farside.UnlockPrototype.agent
sudo launchctl bootstrap gui/502 /Library/LaunchAgents/com.roshan.Farside.UnlockPrototype.agent.plist
```

Never grant the daemon or shipping host new permissions, edit TCC databases, disable SIP, or reset global grants. Root does not imply TCC approval. LoginWindow capture may need additional approved entitlement/PPPC support; a failure is useful evidence, not permission to bypass macOS. Do not add `com.apple.developer.persistent-content-capture` or `com.apple.developer.hid.virtual.device` without Apple's approval/profile.

## U0 — safe refusal checks

While the disposable account is **unlocked**, from the separate administrator terminal run:

```sh
sudo '/Library/Application Support/FarsideUnlockPrototype/UnlockControl' type
```

Type `DISPOSABLE`, then only the disposable password at the hidden prompt. Expected: `DENIED`, no typing at all. Run capture while unlocked; expect refusal and no output file. As an unprivileged caller, either command must say `ROOT_REQUIRED`. Test revoked Accessibility before U2 and restored Accessibility only for the test; expect input refusal. Do not revoke shipping host grants. Test the kill switch with `lab.sh disable`: capture/type refuse. To resume, uninstall/reinstall the prototype; there is no production defaults key or UI added.

## U1 — capture while locked (required)

1. Roshan deliberately locks the disposable user's session manually. Do not log out yet. Confirm the selected user is the disposable account.
2. From the separate admin terminal:

   ```sh
   sudo '/Library/Application Support/FarsideUnlockPrototype/UnlockControl' capture /var/root/farside-U1-1.png
   ```

3. Success output is `FRAME_SAVED_ROOT_ONLY`. It writes a **new**, root-readable `0600` PNG; existing files/symlinks are refused. View securely from the separate administrator machine using your own trusted image-transfer workflow. For example, in the separate admin terminal, `sudo install -o YOUR_TEST_ADMIN -g staff -m 600 /var/root/farside-U1-1.png /Users/YOUR_TEST_ADMIN/U1.png`, then `scp YOUR_TEST_ADMIN@test-mac:/Users/YOUR_TEST_ADMIN/U1.png ./U1.png` to a private directory on the other computer. Replace the administrator name literally; no password is in these commands. Do not make screenshots world-readable. Inspect the image, not a blank-file-size heuristic; delete both exported and source images afterwards.
4. Capture a second new file after a visible lock-screen clock change (`/var/root/farside-U1-2.png`). Record actual displayed clock/user versus the physical test Mac.

**Pass:** both images visibly show the current locked screen, masked/no-readable-password field, correct disposable user/display, updated clock, and no unlocked desktop. **Fail/incomplete:** blank/stale frame, permission error, no GUI agent, wrong user/session, or unable to inspect. Do not enter any password until U1 passes. Remove PNGs after inspection.

## U2 — HID-tap password input (required)

1. With the disposable account still locked, Roshan physically selects that account and focuses its empty password field. Verify ABC/U.S. layout, Caps Lock off, and no held keys. The prototype never reads the field, its selection, or username. Do not type into an uncertain focus.
2. From the separate admin TTY:

   ```sh
   sudo '/Library/Application Support/FarsideUnlockPrototype/UnlockControl' type
   ```

3. Type `DISPOSABLE`, then its disposable password at the hidden prompt. No password echo should appear. The GUI agent posts ordinary HID key-down/up pairs followed by Return. It rechecks enabled state, disposable console UID and explicit locked flag before every character and Return.
4. `POSTED_NOT_VERIFIED` is **not** the pass result. Watch the test Mac and verify it unlocks to the disposable desktop. Capture now must refuse. Check terminal history and test artifacts for accidental password capture **manually, without writing the password into a search command**.

**Pass:** the right disposable session unlocks, no password appears in terminal output/logs/artifacts/another app, and the next capture/input is refused while unlocked. **Fail:** masked characters don't appear, password rejected, Return not accepted, desktop remains locked, wrong account/focus, or any cleartext spill. Stop immediately on a spill. Do not retry with a real password, brute-force, or disable Secure Event Input. Limit to three total attempts per daemon lifetime, at least 30 seconds apart, and stop sooner if macOS warns/locks the account. A daemon restart does not authorize more retries. Timeouts mean result unknown; visually inspect before any retry. The broker has single-completion watchdogs; a GUI operation that cannot complete exits only the prototype agent within 16 seconds (capture) or 11 seconds (input). No KeepAlive restarts it. Uninstall/reinstall the lab rather than retrying a timed-out operation.

Known prototype limitation: the locked-state flag is an **undocumented existing Farside observation**, not an Apple authorization contract. Missing state fails closed. A check/event-post race remains if someone unlocks/switches session at exactly that moment; disposable credentials only, nobody else touches the test Mac during the attempt. U2 alone cannot certify safe production credential handling. XPC/Foundation and CGEvent may retain internal copies despite best-effort buffer erasure; no claim of provable zero-memory persistence.

If CGEvents fail, record UID, GUI context, OS, TCC approval and generic outcome, never password/field values. Next spike is CoreHID `HIDVirtualDevice` (macOS 15+) with `com.apple.developer.hid.virtual.device` and its approved entitlement/profile; DriverKit is a separate longer fallback. Neither is implemented or accepted here. Do not ship a bypass or DEXT merely because capture passes.

## U3 — LoginWindow after logout (separate required capture gate)

1. Save/close test work. Roshan deliberately logs the **disposable** account out. This is post-logout macOS LoginWindow, not FileVault preboot. Other users must not remain foregrounded.
2. The global `/Library/LaunchAgents/...agent.plist` declares `LimitLoadToSessionType = [Aqua, LoginWindow]`. launchd loads it in the newly created LoginWindow graphical/security context; it runs as root there. The daemon remains in system and performs no GUI work.
3. Verify agent registration by requesting a new capture:

   ```sh
   sudo '/Library/Application Support/FarsideUnlockPrototype/UnlockControl' capture /var/root/farside-U3.png
   ```

4. If diagnosing the domain, identify the root `UnlockAgent` PID (`pgrep -x UnlockAgent`, then `ps -p PID -o uid=,comm=`). Query **that process's** visible domain:

   ```sh
   sudo launchctl print pid/ACTUAL_PID/com.roshan.Farside.UnlockPrototype.agent
   ```

   Do not invent `launchctl bootstrap loginwindow ...`: the installed manual documents `login/ASID`, `gui/UID` and `pid/PID`; “LoginWindow” is a plist session type. The normal test relies on global agent loading at logout. If it does not load, record failure/context; don't bootstrap into the root/system GUI namespace as a substitute.

**Pass:** a current nonblank post-logout LoginWindow image delivered by the root GUI agent, no prior user's desktop; daemon continuity confirmed. **Fail:** stale Aqua image, no agent, no TCC authorization or blank capture. U3 has **no password typing** in this phase. Sign back in manually. Fast user switching is a later separate case.

## U4 — FileVault after restart: excluded

Do not restart for this prototype. Its executable lives on the encrypted startup volume and cannot provide a pre-unlock Farside agent. Apple documents a separate SSH FileVault-unlock route on **Apple silicon with macOS 26+**, Remote Login already enabled and networking available: [Managing FileVault](https://support.apple.com/guide/security/managing-filevault-sec8447f5049/web). This is Apple's built-in route, not Farside's wake/unlock feature. Do not automate it, change FileVault, expose SSH publicly or collect recovery keys here.

## Emergency stop and clean uninstall (always, even after failure)

From the separate admin terminal:

```sh
sudo script/unlock-prototype/lab.sh disable
sudo script/unlock-prototype/lab.sh uninstall
sudo script/unlock-prototype/lab.sh verify-clean
```

Exact bootout targets used by cleanup are `system/com.roshan.Farside.UnlockPrototype.daemon`, `gui/DISPOSABLE_UID/com.roshan.Farside.UnlockPrototype.agent`, and `pid/ACTUAL_AGENT_PID/com.roshan.Farside.UnlockPrototype.agent` for any surviving LoginWindow/other-session agent. It never bootouts an entire domain. No KeepAlive is configured. It removes both global plists and the unique prototype install directory, and stops only exact-path prototype processes. Repeat uninstall after interrupted install; it is idempotent. `verify-clean` must print **PASS**; otherwise do not declare cleanup complete.

Then remove only the prototype's permission rows manually (Privacy & Security → Screen Recording and Accessibility), delete root PNGs and any transferred copies (`sudo rm -f /var/root/farside-U1-1.png /var/root/farside-U1-2.png /var/root/farside-U3.png`), remove the copied signed artifacts if desired, restore any test-only Remote Login allowance/state, and delete the disposable account through Users & Groups. Do not reset other permissions. The cleanup script does not remove users, change SSH or erase screenshots outside its install root. Registration stores only audit-session IDs in root-only `sessions.plist`, allowing exact `login/ASID/...agent` cleanup even if an agent has crashed. Cleanup enumerates GUI/login domains and verifies that **loaded jobs**, including non-running jobs, are absent; an unknown `launchctl print` format or unreadable domain fails verification.

“Guaranteed clean” means **verify before accepting**: fixed artifacts/jobs/processes absent; TCC rows, account and capture files manually removed; any interrupted/failed cleanup is an explicit failure, never silently treated as clean. No reboot or global TCC reset is required. Cleanup of loaded launchd domains is not physically verified by agents in this lane.

## Results and go/no-go

| Test | OS/build | Date | Result | Agent UID/context | Permission state / generic status | Cleanup |
|---|---|---|---|---|---|---|
| U0 refusal | 26 | | | | | |
| U1 locked frames | 26 | | | | | |
| U2 disposable unlock | 26 | | | | | |
| U3 logout capture | 26 | | | | | |
| U0 refusal | 27 | | | | | |
| U1 locked frames | 27 | | | | | |
| U2 disposable unlock | 27 | | | | | |
| U3 logout capture | 27 | | | | | |

U1/U2 passing permits integration work, not shipping. U3 is an additional gate before claiming post-logout access. Phone/security/session-transition tests and clean removal must also pass on devices before enabling any 1.0 unlock capability. All future integrated entry points use a default-off internal release gate plus owner Mac opt-in; a failed feasibility, entitlement or safety gate can never block launch. The old awake/unlocked host path remains the fallback. No automatic decision to postpone to 1.0.1 is made.

## Dated platform evidence

[DTS daemon/GUI-agent architecture](https://developer.apple.com/forums/thread/814152), rechecked 2 October 2026: SCK pre-login fix in macOS 14.4; daemon global state, GUI agent capture/input, XPC link. [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit) and [macOS 27 release notes](https://developer.apple.com/documentation/macos-release-notes/macos-27-release-notes) re-fetched that date; no login-input guarantee inferred. Installed SDK declares `NSXPCConnection.setCodeSigningRequirement` from macOS 13, so the prototype's macOS 26 deployment floor does not rely on 27-only XPC APIs. Development machine: macOS 27.0.1/26A434, Swift 6.4, SDK 27.0. macOS 26 runtime compatibility remains a required physical check.
