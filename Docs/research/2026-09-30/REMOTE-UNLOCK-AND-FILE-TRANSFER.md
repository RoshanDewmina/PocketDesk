# Remote unlock / wake feasibility and file-transfer design

30 September 2026. Advisory research for Farside (iPhone/iPad app + Apple-silicon Mac menu-bar companion, macOS 26+/iOS 26+). Research only: no code, settings, builds, installs or browsers on the Mac. Sources: repository inspection, primary Apple documentation (web, Apple doc JSON, the local `apple_ssh_and_filevault(7)` man page and the macOS 27 SDK `IOPMLib.h` header), vendor help centres, and a few clearly marked secondary sources. All web sources accessed 2026-09-30. Subordinate to `PRODUCT.md`; nothing here is a product decision.

**Evidence tags.** **[R]** repository fact from source inspection (not proof of installed or physical behaviour). **[V]** verified in a primary source (Apple, standards body, or the vendor's own documentation about its own product). **[V2]** secondary source (forum, press, community, security benchmark), reported but not independently confirmed. **[I]** my inference or design proposal; test before relying on it.

---

## 0. Summary

| Question | Short answer | 1.0 (submit 2026-11-03)? |
|---|---|---|
| Wake a sleeping Mac from away | Not with Farside's architecture. A sleeping Mac drops Farside's outbound signaling socket; Wake for network access needs a waker on the Mac's LAN; lid-closed MacBooks sleep unless in closed-display mode. | **No feature.** Honest copy + setup warnings. |
| Unlock an ordinary locked screen | No documented public API. Farside tears sharing down on lock by design. Typing the password through a remote session is unreliable on macOS (lock-screen input evidence below) and needs sharing to survive lock. | **No.** Post-launch spike. |
| GUI login after logout | Needs a pre-login LaunchAgent (LoginWindow session) + daemon installed system-wide, as Parsec's separate installer does. | **No.** Later, if ever. |
| FileVault unlock after restart | Apple-documented on Apple silicon + macOS 26: SSH password unlock when Remote Login is on and a network connection is available. Reached over LAN/VPN only (Farside's relay isn't running pre-boot); afterwards the Mac is reportedly at the login window, where Farside's user-session host isn't running. | **Docs-only help article at most.** |
| **Hidden 1.0 risk** | Farside ends sharing on screen lock [R], and macOS locks when the display sleeps if "Require password after screen saver begins or display is turned off" is short (reported default "Immediately" [V2]). An unattended Mac may therefore become unreachable soon after its display sleeps. This matters more for the paid away-from-home promise than any unlock feature. | **Yes: needs a decision and physical test before launch.** |
| File transfer | Competitors with it: Apple Screen Sharing (Mac↔Mac), Screens 5.6 (iPhone/iPad↔Mac), RustDesk, Chrome Remote Desktop web. Without it: Jump Fluid (text clipboard only), Parsec, Astropad Workbench. Smallest useful v1 is one file per transfer each way over a new `file` data channel on the existing DTLS-encrypted peer connection. | **Recommend 1.1.** Phone→Mac only could fit 1.0 if launch blockers clear by about 14 Oct. See §B8. |

---

# PART A: Remote wake / unlock / login / FileVault

## A0. What Farside does today [R]

- `RemoteHost/HostKeepAwake.swift`: while sharing (and "keep awake" on), the host holds `PreventUserIdleSystemSleep`. It holds `PreventUserIdleDisplaySleep` only while a phone is connected (`HostPowerPolicy.assertions`). `HostDisplayWake` declares remote user activity to light the display on connect.
- `HostSleepPolicy.response(to:)`: `systemWillSleep`, `sessionResigned` (fast user switch) and `screenLocked` all return `.tearDown`. Display sleep alone keeps sharing registered.
- `HostModel.handleAvailability` (`RemoteHost/HostModel.swift:1759`) suspends auto-start and tears down with "This Mac is locked. Sharing resumes when it's unlocked." Lock is detected with the undocumented `com.apple.screenIsLocked` distributed notification plus `CGSessionCopyCurrentDictionary()["CGSSessionScreenIsLocked"]` (`HostScreenLock`).
- Launch at login and a crash watchdog exist (PRODUCT, 29 Sep). Both need a logged-in GUI session.
- PRODUCT line 15 records a physical run in which the phone's Connect failed while the Mac was locked, and "the native UI tool confirmed the lock and could not unlock it."
- PRODUCT F10/F11/B20 and the "later" list: locked/sleeping/restarted behaviour, FileVault/login-window unlock, wake-on-LAN and closed-lid guarantees are separate decisions. There is "no remote TCC repair or login/FileVault unlock promise."

Apple's header documents that the idle-system-sleep assertion Farside uses **does not stop lid-close sleep**: "The system may still sleep for lid close, Apple menu, low battery, or other sleep reasons. This assertion has no effect if the system is in Dark Wake." **[V]** (`IOPMLib.h`, macOS 27.0 SDK, `kIOPMAssertPreventUserIdleSystemSleep`).

### A0.1 The display-sleep → auto-lock interaction (highest-priority finding)

- The Lock Screen setting "Require password after screen saver begins or display is turned off" takes a time interval **[V]** ([Apple: Require a password after waking your Mac](https://support.apple.com/guide/mac-help/require-a-password-after-waking-your-mac-mchlp2270/mac)). Apple's page does not state the default. CIS benchmark audit items report "Immediately" as the Sequoia default **[V2]** ([Tenable/CIS macOS 15](https://www.tenable.com/audits/items/CIS_Apple_macOS_15.0_Sequoia_v1.1.0_L1.audit:9bf02f1ea590a3a597a77b5c806d8d53)).
- Farside lets the display sleep when no phone is connected [R] and tears down on lock [R]. **[I]** Under common settings, an unattended Mac will probably lock soon after its display sleeps, and Farside will then stop listening. A phone connecting later would get "locked," not a session. Wake-on-connect does not help, because sharing is already torn down.
- Workarounds each weaken something **[I]**. (a) The user sets the lock delay to Never or a long delay. (b) Farside holds the display awake whenever sharing is on. The Mac then sits unlocked and lit, and the privacy curtain is "not an input block." (c) Keep the host registered while locked and support unlock (§A2), which is a large piece of work.
- **Action before launch:** physically test on macOS 26 and 27 with default Lock Screen settings: leave, let the display sleep, then connect from cellular. Decide what 1.0 promises and what setup tells the user. This is a launch-messaging and support-load issue, not an unlock feature.

## A1. Waking a sleeping Mac

**Verified facts**
- "Wake for network access" lets the Mac "wake briefly so users can access shared services." Laptops set it in Battery › Options (pop-up); desktops toggle it. Separately, "Prevent automatic sleeping on power adapter when the display is off" (laptops) / "…when the display is off" (desktops) **[V]** ([Apple: Set sleep and wake settings, macOS 26](https://support.apple.com/guide/mac-help/set-sleep-and-wake-settings-mchle41a6ccd/26/mac/26)).
- A sleeping Mac with sharing wakes "when a user at another computer accesses the shared resources" and requires "an Apple wireless device that supports 802.11n" (the Bonjour Sleep Proxy) **[V]** ([Apple: Share your Mac resources when it's in sleep](https://support.apple.com/guide/mac-help/share-your-mac-resources-when-its-in-sleep-mh27905/mac)).
- Apple Remote Desktop's Wake needs hardware that supports `wakeonlan` and Wake for network access, and it "can't wake computers on a different subnet" unless a Bonjour sleep proxy runs there **[V]** ([Apple Remote Desktop guide](https://support.apple.com/guide/remote-desktop/sleep-shut-down-log-out-or-restart-a-computer-apd5535ee19/mac)).
- On iOS, sending IP broadcast or multicast (a classic WoL magic packet) requires the Apple-approved `com.apple.developer.networking.multicast` entitlement **[V]** ([Apple entitlement docs](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.multicast)).
- Lid closed: Apple's IOPM header (above) says lid close can still sleep the system **[V]**. Closed-display mode needs an external display, power, and an external keyboard/mouse. The Apple article did not load, so this rests on multiple consistent secondary reports **[V2]** ([Macworld](https://www.macworld.com/article/673295/how-to-use-macbook-with-lid-closed-stop-closed-mac-sleeping.html)). Edovia says a plugged-in laptop "can be in clamshell mode and it will still respond to connection requests," and that the Mac must be on power to wake for connections **[V]** ([Edovia: wake for connections](https://help.edovia.com/en/screens-4/how-to/wake-for-connections-mac)).
- WoL-triggered wakes can be *dark wakes* lasting about 30–60 s that repeated packets don't extend **[V2]** ([Apple Developer Forums 771999, Jan 2025](https://developer.apple.com/forums/thread/771999)). Laptop WoL reliability complaints are longstanding **[V2]** ([forum 656687](https://developer.apple.com/forums/thread/656687)).

**Feasibility for Farside [I]**
- Farside reaches the Mac through an outbound WSS registration plus WebRTC. A sleeping Mac holds no socket, and nothing on the internet can wake it. Wake for network access responds to LAN or sleep-proxy traffic for *Bonjour-advertised services*, not to Farside's relay.
- A phone on the *same LAN* could try a unicast wake or a Bonjour connect to a Farside-advertised service. Broadcast WoL needs the multicast entitlement (an Apple application). After waking, the Farside host must fully resume, re-register and survive dark wake. That is not guaranteed.
- Waking from away needs another always-on device on the Mac's LAN: a sleep-proxy Apple device, a router with WoL, or another computer. Jump Desktop's WoL is also LAN-originated [V2 snippet].
- **App Review/notarization:** no special issue for WoL. The multicast entitlement needs Apple approval, which is launch risk.
- **Honest 1.0 promise:** "Farside needs your Mac on, awake and signed in. The display can sleep. A MacBook with its lid closed sleeps unless it's plugged into power with an external display (closed-display mode)." Farside keeps idle sleep off while sharing, which already exists. Add Mac-setup warnings when on battery or when the lid-closed limitation applies.
- **Later (difficulty 3–4, value 2–3):** a same-LAN "Wake my Mac" button, Bonjour-advertised host service, and a separate full-wake test on each Mac class.

## A2. Unlocking an ordinary locked screen of a logged-in user

**Verified facts**
- There is no public API for a third-party app to unlock the macOS lock screen. None was found in Apple documentation; absence is by design **[I]**, so treat any claim otherwise as needing proof.
- Farside's own physical record shows the tool could not unlock the Mac [R, PRODUCT line 15].
- Other remote tools have trouble typing into the macOS lock-screen password field. In RustDesk on macOS 15.4.1, "typing any character (other than return) has no effect." The workaround was to unlock with VNC (Apple Screen Sharing) **[V2]** ([rustdesk#11802, May 2025](https://github.com/rustdesk/rustdesk/issues/11802)). RustDesk also shows the Mac "offline" once it locks **[V2]** ([discussion 7565](https://github.com/rustdesk/rustdesk/discussions/7565)). A LaunchAgent developer found mouse injection works but keyboard events can't be posted at LoginWindow (Intel; Apple silicon worked for them). Apple did not reply **[V2]** ([forum 724740, Feb 2023](https://developer.apple.com/forums/thread/724740)).
- Loginwindow enables Secure Event Input while the lock screen is up. Community reports describe it leaking system-wide **[V2]** ([claude-code#81585](https://github.com/anthropics/claude-code/issues/81585), [codex#40235](https://github.com/openai/codex/issues/40235)).
- Apple Screen Sharing is a system service. Screens 5 builds on it ("We recommend using Screen Sharing") **[V]** ([Edovia prepare Mac](https://help.edovia.com/en/screens-5/getting-started/prepare-mac-for-screen-sharing)). After an SSH FileVault unlock, Screen Sharing can connect before GUI login **[V2]** ([Jeff Geerling](https://www.jeffgeerling.com/blog/2025/you-can-finally-manage-macs-filevault-remotely-tahoe/)). **[I]** Apple's own server handles the lock screen and login window. Third-party user-session apps are the ones that struggle.

**"Unlock by typing the password through the remote session": what it would take and why it's risky [I]**
1. **Keep sharing alive while locked.** Today Farside deliberately tears down. It would need to keep the peer connection, capture what ScreenCaptureKit returns while locked (untested: blank, the lock screen, or an error) and accept input only for the unlock field. This reverses a deliberate privacy decision (the curtain lifts on lock; `PrivacyCurtain.swift`).
2. **Inject the password into loginwindow.** A `CGEvent`/Accessibility path from the user session is unreliable per the evidence above, and there is no documented guarantee. It could break in any macOS update.
3. **Password exposure.** The Mac login password is the FileVault/keychain secret. It would be typed on the phone, travel the E2E channel and be injected as synthetic keystrokes. Mitigations: an iOS secure text field (system keyboard, no autocorrect learning), never logged, no automatic retry, and Face ID before sending. Any "remember my Mac password" option multiplies the risk; it would need biometry-bound, this-device-only Keychain storage. A stolen, unlocked, paired phone becomes a Mac unlocker.
4. **Physical-presence exposure.** Someone in front of the Mac sees it unlock. The curtain would have to engage *before* unlock and block local input. Farside's curtain is "not an input block" today.
5. **App Review/notarization.** The Mac host is Developer ID (D30). Notarization does not review behaviour, but `com.apple.screenIsLocked`/`CGSSessionScreenIsLocked` are undocumented. On iOS, a password-entry UI is acceptable if framed as the user controlling their own Mac. Expect reviewer questions if it's marketed as "unlock."

**Safer later alternative [I, difficulty 4–5]:** Farside tunnels to Apple's own Screen Sharing. The host is still running while the Mac is locked, because locking doesn't quit apps. With the user's opt-in to Screen Sharing, the host proxies `127.0.0.1:5900` over a Farside data channel, and the phone runs a minimal RFB client just for unlocking. Apple's server then handles the lock screen. Costs: implementing RFB plus Apple authentication, the user enabling Screen Sharing (which exposes port 5900 on the LAN; recommend "Only these users"), and review of a second protocol path.

**1.0:** no unlock. Copy: "If your Mac locks, Farside pauses until it's unlocked at the Mac." Pair this with the §A0.1 decision.

## A3. GUI login after logout (or after a restart without FileVault)

**Verified facts**
- Apple DTS: a daemon handles networking. A **LaunchAgent** handles GUI work (capture/input), configured with `LimitLoadToSessionType` = `Aqua` + `LoginWindow`, installed in `/Library/LaunchAgents`. `LimitLoadToSession` is ignored for daemons. ScreenCaptureKit works pre-login on macOS 14.4+ **[V]** ([Apple Developer Forums 814152, Jan 2026](https://developer.apple.com/forums/thread/814152)).
- Parsec's login-screen access needs a *different installer* (it installs `/Library/LaunchAgents/com.parsec.app.plist`), a wired Ethernet connection, and FileVault disabled **[V; vendor page via search snippet, direct fetch returned 403]** ([Parsec: Access Login Screen on macOS](https://support.parsec.app/hc/en-us/articles/32381618319124-Access-Login-Screen-on-macOS)).
- Jump Desktop says Fluid supports "logging into a machine after restart (with no users logged in)" **[V; vendor page via search snippet, 403 on fetch]** ([Jump: Fluid Remote Desktop](https://support.jumpdesktop.com/hc/en-us/articles/216423983-General-Fluid-Remote-Desktop)).
- Community threads report that on Apple silicon, Chrome Remote Desktop shows the Mac offline until a user logs in **[V2]** ([Google community thread](https://support.google.com/chrome/thread/199134730)).
- Automatic login is unavailable when FileVault is on **[V]** ([Apple 102316, 19 May 2026](https://support.apple.com/en-us/102316)). Astropad tells Workbench users to enable Auto Login and **disable FileVault** for reliable remote access **[V]** ([Astropad: Setting up your Mac](https://support.astropad.com/en/articles/14010461-setting-up-your-mac-for-remote-access), [Mac mini guide](https://support.astropad.com/en/articles/14062891-using-workbench-with-your-mac-mini)).

**What Farside would need [I, difficulty 5]:** a system-wide privileged install (a LaunchDaemon for signaling/WebRTC, a LoginWindow-session LaunchAgent for capture/input, and XPC between them) with admin approval. TCC grants would have to work in the LoginWindow context (unverified). Keyboard injection at loginwindow would need physical proof. Pairing keys would have to be readable pre-login, and today they sit in the user's Keychain (so that part of the design changes). That triples the security review surface. Farside should not tell users to disable FileVault (PRODUCT: "never silently weaken device security").

**1.0:** no. Launch-at-login covers "restart with auto-login"; say that auto-login is unavailable with FileVault.

## A4. FileVault unlock after restart (Apple silicon + macOS 26+)

**Verified facts (primary)**
- Apple Platform Security, *Managing FileVault* (page dated 28 Jan 2026): on a **Mac with Apple silicon** and **macOS 26 or later**, "FileVault can be unlocked over SSH after a restart if Remote Login is turned on and a network connection is available." **[V]** ([Apple](https://support.apple.com/guide/security/managing-filevault-sec8447f5049/web))
- *What's new for enterprise in macOS Tahoe 26* (page dated 27 Jul 2026) repeats this and points to the man page **[V]** ([Apple 124963](https://support.apple.com/en-us/124963)).
- `man apple_ssh_and_filevault` (read locally, macOS 27.0.1): OpenSSH's configuration lives on the locked data volume, so normal auth methods and shell are unavailable. With Remote Login enabled, **password authentication** still works and unlocks the data volume. It "does not immediately permit an SSH session": macOS disconnects briefly while it mounts the data volume and starts dependent services, and then "SSH (and other enabled services) are fully available." It first appeared in macOS 26 **[V]**.

**Reported details (secondary)**
- Pre-boot SSH initially worked only over **Ethernet**; Wi-Fi reportedly works from macOS 26.5 **[V2]** ([Geerling](https://www.jeffgeerling.com/blog/2025/you-can-finally-manage-macs-filevault-remotely-tahoe/)). This matters for Roshan's M4 MacBook Air, which is Wi-Fi-only without an adapter. Needs a physical test on 26.x/27.
- Geerling reports an **administrator** password; Der Flounder reports "an account authorized to unlock FileVault" **[V2]** ([Der Flounder, 11 Oct 2025](https://derflounder.wordpress.com/2025/10/11/unlocking-filevault-via-ssh-on-macos-tahoe/)). SSH keys are not usable pre-unlock (keys live on the locked volume) **[I, consistent with the man page]**.
- After the unlock, **no GUI login occurs**; Screen Sharing/SSH then work at the login window **[V2]** (Der Flounder; Geerling).

**Implications for Farside [I]**
- The Farside host is a user-session app. After an SSH FileVault unlock the Mac sits at the login window, so Farside is still not running (§A3). FileVault recovery with Farside alone is therefore incomplete: the user would still need Apple Screen Sharing, or a pre-login agent, to reach the desktop.
- Reachability: the pre-boot Mac runs only sshd, and there's no Farside relay. The phone must reach port 22 directly: same LAN, or the user's own VPN/Tailscale subnet router (as in [this demo](https://www.youtube.com/watch?v=833pTn_3HYI) [V2]). Port-forwarding SSH to the internet with password auth is dangerous, and Farside should say so.
- Security: Remote Login exposes sshd with password auth on every interface. Recommend "Allow access for: Only these users," LAN-only, and strong passwords. The password typed is the FileVault/login password.
- App Store: an iOS app embedding an SSH client just for this is acceptable (many exist) **[I]**, but it's a new product surface. A docs-only path (the user runs any SSH app, e.g. `ssh user@mac.local`) costs nothing.
- **1.0:** at most a help article: "If your Mac restarts with FileVault on: (1) enable Remote Login beforehand; (2) from the same network, SSH in with your Mac password to unlock the disk; (3) log in at the Mac, or with Screen Sharing, so Farside starts." Everything in it is an Apple feature, and Farside claims nothing it doesn't do.
- **Later (difficulty 3 for an in-app SSH unlock button, LAN only; 5 for complete login):** only if user research shows restarts are a real away-from-home failure.

## A5. Competitor comparison (availability)

| Product | Wake | Locked screen | Login window / after restart | FileVault | Evidence |
|---|---|---|---|---|---|
| Apple Screen Sharing / ARD | ARD "Wake" (WoL; same subnet unless sleep proxy) | Yes (system service) | Yes; works after an SSH FileVault unlock | Via SSH unlock (macOS 26, Apple silicon) | [V] ARD guide; [V2] Geerling |
| Screens 5 (Edovia) | Tells users to set Wake for network access = Always and stay on power; clamshell OK when plugged in | Inherits Apple Screen Sharing | Inherits Apple Screen Sharing | "FileVault can prevent connections" | [V] Edovia |
| Jump Desktop (Fluid) | WoL "for automatic connections" (8.2.21); Privacy Mode locks the Mac after the session | Not documented in pages fetched | Fluid: login after restart supported | Not found | [V] release notes; [V snippet] support |
| Parsec | Not documented | Not documented | Separate login-screen installer (`/Library/LaunchAgents`), **Ethernet required** | **Must be disabled** | [V snippet] Parsec |
| Chrome Remote Desktop | Not documented | Not documented | Community: Apple silicon Mac offline until user login | Not documented | [V2] |
| Astropad Workbench | Prevents sleep automatically | Not documented | Recommends **Auto Login** | Recommends **disabling FileVault** | [V] Astropad help |
| Farside today | Prevents idle sleep while sharing | Tears down on lock | Launch at login (needs GUI login) | No | [R] |

Takeaway [I]: only the Apple-service-based tools (Screen Sharing, Screens) and privileged-install tools (Jump, Parsec) handle lock/login. Astropad Workbench, the closest architectural peer, doesn't: it tells users to weaken FileVault. Farside can differentiate honestly by being *clear* ("works while signed in and unlocked") and not telling users to disable FileVault.

---

# PART B: File transfer

## B1. What competitors offer

| Product | Phone/iPad → Mac | Mac → phone/iPad | Mechanism / notes | Evidence |
|---|---|---|---|---|
| Apple Screen Sharing | n/a (no iOS client) | n/a | Mac↔Mac: drag files into the window; shared clipboard | [V] [Apple](https://support.apple.com/guide/mac-help/share-the-screen-of-another-mac-mh14066/mac) |
| **Screens 5.6** | Drag from Files/Numbers/other apps onto the remote screen; multiple files; Mac 10.10+ | Drag a file on the Mac, Screens shows a drop target, release to download; Mac **14+**; lands in **Files › On My iPhone › Screens › Downloads** | Keep the app open or transfers may be interrupted; resumes on return; large transfers slightly slow the UI; SSH-tunnelled transfers slower | [V] [Edovia iPhone](https://help.edovia.com/en/screens-5/features/file-transfers-iphone), [iPad](https://help.edovia.com/en/screens-5/features/file-transfers-ipad) |
| Jump Desktop | RDP only (copy/paste files, folder sharing) | RDP only | **Fluid (its Mac protocol) = text-only clipboard**; users asking for built-in transfers | [V snippet] Jump support/community; [V] 7.1 notes |
| Chrome Remote Desktop | Web client "Upload file" | Web client "Download file" | Side panel in the desktop browser; iOS app docs don't mention transfer | [V2] guides; [V] Google iOS help (absence) |
| Parsec | None built-in | None | Clipboard only; use cloud storage | [V2] |
| Astropad Workbench | None found | None found | MacStories (5 May 2026): Screen Sharing "supports Finder-to-Finder file transfers, which Workbench doesn't" | [V2] [MacStories](https://www.macstories.net/reviews/astropad-workbench-rethinks-remote-mac-control-for-ai-agents/) |
| RustDesk iOS | Yes | Yes | File-transfer mode | [V2] (`Docs/COMPETITOR-LANDSCAPE-2026-09-28.md`) |

Screens is the direct benchmark: drag/drop both ways, a Files-app folder, and resume on return. Workbench and Jump Fluid lack it, so a small, reliable v1 is a real differentiator against the closest competitor.

## B2. What Farside already has to build on [R]

- `RemoteShared/ClipboardTransfer.swift`: an explicit, user-initiated text transfer. 256 KiB cap, 4 KiB chunks (base64 in JSON under the 16 KiB packet limit), a SHA-256 digest, in-order reassembly that discards the whole transfer on any gap, a 5 s reassembly timeout, and pacing by `bufferedAmount` (high water 16 KiB, 2 frames per 10 ms ≈ 800 KiB/s ceiling) "so input stays responsive." Status codes travel as strings. It honours nspasteboard.org concealed/transient markers.
- `RemoteHost/HostClipboard.swift`: explicit phone requests only, no observation and no content logging. Pasteboard I/O runs off the main thread. Generation counters drop late results. The host authorizes with `clipboard.receive(frame, allowed: current && !phonePause.isPaused && controlEffective)` (`HostModel.swift:1659`) and resets on session end (`:1194`, `:1325`, `:1728`).
- `RemoteShared/PeerMedia.swift`: the host creates **one** ordered, reliable data channel `"control"` (`:256`). `sendControl` refuses messages above 16384 bytes or when `bufferedAmount ≥ 64 KiB` (`:505`). Receive rejects non-binary or >16 KiB messages by failing the session (`:733`). The phone's `didOpen` **closes any channel not labelled `control`** (`:710`), so a file channel needs a small routing change there.
- `RemoteShared/ControlProtocol.swift`: `RemoteAction` has optional extension fields (`clipboard: ClipboardFrame?`, …) validated in `SessionContinuity.swift`. Capabilities are negotiated with `SessionFeature` strings (`clipboard.text.1`, …), and older peers end the session on unknown actions, so a new `file.1` feature must gate everything.
- Phone continuity: backgrounding pauses capture and releases input; iOS gives about 25 s; the Mac holds the session 45 s; reconnect within 15 min (PRODUCT, 28 Sep).
- Transport security: signaling payloads are CryptoKit AES-GCM with a per-pair key. The SDP with DTLS fingerprints is authenticated end to end (`REMOTE-PROTOCOL.md`). So any data channel on this peer connection is DTLS-encrypted between the two paired devices, and TURN relays only see ciphertext **[V for DTLS on data channels: [MDN](https://developer.mozilla.org/en-US/docs/Web/API/WebRTC_API/Using_data_channels); [R] for fingerprint binding]**.
- No App Group, share extension, `UIFileSharingEnabled` or document types exist on the phone today [R: `project.yml`, `RemotePhone/Info.plist`]. The only extension is `FarsideWidgets`.

## B3. Smallest useful v1 (proposal) [I]

**Principles:** one file per transfer, user-initiated from the phone, only while the session is authorized for control (the same predicate as clipboard), a visible result on both devices, nothing partial ever surfaced as a finished file, no content logging, and no execution of received files.

### Phone → Mac ("Send to Mac")
1. In the session controls: **Send file…** → SwiftUI `.fileImporter` (Files, iCloud Drive, third-party providers). Add **Send photo/video…** via `PhotosPicker`. Both are out-of-process pickers with no Photos permission, which App Review 5.1.1 prefers ("use the out-of-process picker or a share sheet") **[V]** ([guidelines](https://developer.apple.com/app-store/review/guidelines/)).
2. The phone sends an **offer** (name, size, UTType, SHA-256 when cheap) on the control channel. The Mac replies `accept` or a refusal code (`tooLarge`, `notAllowed`, `busy`, `diskFull`, `denied`).
3. Bytes stream on a new `file` data channel. The Mac writes `~/Downloads/Farside/<name>.farside-partial`, verifies the digest, then renames to a de-duplicated final name ("report 2.pdf").
4. **Visible result:** a Mac notification ("Received report.pdf from Roshan's iPhone" + Reveal), with optional *Reveal in Finder on the streamed display* so the user sees it land. The phone shows a toast: "Saved to Downloads › Farside on MacBook Air."

### Mac → phone ("Get file from Mac")
1. Phone button **Get file from Mac…** The Mac brings up an `NSOpenPanel` on the streamed display, and the user picks the file remotely with Farside's own controls. This needs **no Apple Events/Finder automation permission**: reading Finder's selection would need `NSAppleEventsUsageDescription`, the hardened-runtime Apple Events entitlement and a TCC prompt that probably has to be approved at the Mac [I]. Alternative for later: drag a file onto the Farside menu-bar item. The host uses SwiftUI `MenuBarExtra` (`RemoteHostApp.swift:41`), where drop support is uncertain, so treat it as phase 3.
2. The phone checks its **own** free space locally and accepts or refuses. It never sends the number (see §B6).
3. The phone writes to `tmp/…partial`, verifies, then moves to `Documents/From Mac/` and shows **Share / Save to Files / Open in…** (`UIActivityViewController` / `fileExporter`). With `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`, the folder also appears in Files › On My iPhone › Farside, the same pattern Screens uses **[V keys: [UIFileSharingEnabled](https://developer.apple.com/documentation/bundleresources/information-property-list/uifilesharingenabled), [LSSupportsOpeningDocumentsInPlace](https://developer.apple.com/documentation/bundleresources/information-property-list/lssupportsopeningdocumentsinplace); Files visibility of the pair: [I] + Screens precedent]**.

### Limits (v1)
- **Hard cap 1 GiB per file** (a constant, easily raised). Warn above 100 MB when the route is Relay ("This will use your internet connection and may take a while").
- **Foreground-only:** keep the idle timer off during a transfer. If the app backgrounds, the transfer fails cleanly after the existing continuity window with "Transfer stopped when Farside left the screen. Send again." Screens gives similar advice.
- One transfer at a time per direction. Cancel on either side. The session end, a phone pause or a loss of control authority cancels the transfer and deletes the partial file.
- No folders (the user can zip first), no multi-select, no resume in v1.

## B4. Protocol sketch (for review before any code) [I]

- **Capability:** the host adds `file.1` to `capture.features`. The phone uses file actions only after seeing it (the existing pattern).
- **Control messages** travel on `control` as `RemoteAction(action: "file", file: FileFrame)`, validated like `ClipboardFrame`: `offer{transfer, direction, name, bytes, uttype?, digest}`, `accept{transfer, offset:0}`, `result{transfer, status}`, `cancel{transfer}`, `progress{transfer, bytes}` (receiver to sender, ≤ 4 Hz, drives the UI on both sides). Transfer IDs reuse `ClipboardTransferID` rules. Names are at most 255 UTF-8 bytes and sanitized by the receiver (below).
- **Bulk data** travels on a second ordered, reliable channel `file`, created by the host alongside `control` at connection. Channels added after the SCTP association exists need no SDP renegotiation, but creating it up front avoids races. Frames are binary: `magic 'FSF1' | transfer id (16 B) | offset (UInt64 BE) | payload`. No JSON or base64, which saves the 33 % overhead the clipboard pays.
- **Chunk size 64 KiB** (payload about 64 KiB − 28 B). If an SDP has no `max-message-size`, 64 KB is assumed; larger messages cause head-of-line blocking **[V]** (MDN; RFC 8841). The receiver's existing 16 KiB receive guard applies only to `control`.
- **Flow control:** the sender fills while `file.bufferedAmount < 1 MiB` and resumes on `dataChannel(_:didChangeBufferedAmount:)` (present in the bundled WebRTC ObjC headers [R]). On a Relay route, the sender also caps its rate to a share of the ladder's `availableKbps` so video and input keep priority. Measure this physically; separate SCTP streams still share one congestion controller and path [I].
- **Integrity:** streaming SHA-256 (CryptoKit `SHA256` incremental) on both sides. The receiver renames only when the digest matches; otherwise it deletes and reports `invalid`.
- **Authorization:** the host reuses `current && !phonePause.isPaused && controlEffective`. View-only sessions get `notAllowed` both ways. A Mac-side **"Allow file transfer"** toggle in Settings (default: see Questions). Mac→phone always needs a Mac-side pick in *that* session, so the phone can't pull an arbitrary path. The phone can already drive the Mac UI, so the real boundary is control authority itself; state that honestly.
- **Mac write safety:** strip `/`, `:`, NUL, control and bidi-override characters (e.g., U+202E extension spoofing), leading dots and `..`; cap the length; never follow symlinks (`O_NOFOLLOW`/create-exclusive); never overwrite. Set **quarantine** on each received file (`URLResourceValues.quarantineProperties`) so Gatekeeper checks received apps and scripts, and never auto-open. `LSFileQuarantineEnabled` quarantines *every* file the app creates **[V]** ([Apple](https://developer.apple.com/documentation/bundleresources/information-property-list/lsfilequarantineenabled)), which is broader than needed.
- **TCC on the Mac:** the non-sandboxed host writing into `~/Downloads` triggers the Files & Folders consent ("Some apps … can access files and folders in your Desktop, Downloads, and Documents folders," managed in Privacy & Security › Files & Folders) **[V]** ([Apple](https://support.apple.com/guide/mac-help/control-access-to-files-and-folders-on-mac-mchld5a35146/mac)). Request it during Mac setup, at the Mac, with a test write. Don't rely on approving a TCC prompt remotely; PRODUCT already rules out "remote TCC repair." If access is denied, report `denied` and offer "choose another folder" at the Mac.

## B5. Encryption, relay cost and free/paid routing

- **Encryption [V/R]:** all bytes ride the existing peer connection's DTLS, keyed by fingerprints inside Farside's authenticated, E2E-encrypted signaling. The relay (Cloudflare TURN) forwards ciphertext and cannot read files. No extra application-layer encryption is needed for v1 [I]. The service never stores file bytes.
- **Cloudflare pricing [V]:** "The first 1,000 GB each month is free. SFU and TURN share this allowance," then **$0.05 per GB of egress**, where TURN bills "outbound from Cloudflare to the TURN client" ([Realtime pricing, updated 22 Sep 2026](https://developers.cloudflare.com/realtime/pricing/); [TURN, updated 25 Sep 2026](https://developers.cloudflare.com/realtime/turn/)).
- **Cost model [I]:** a relayed 1 GB file costs about 1 GB of egress, and up to about 2 GB if both peers sit behind relay allocations. Verify with Cloudflare analytics during testing. That's $0.05–$0.10 per GB beyond the free tier, roughly the same as 15–30 minutes of relayed video at the 5 Mbps restart floor (`StreamTuning.restartFloorKbps`). Direct routes cost nothing.
- **D28 fit:** free tier = same LAN = direct, so file transfer costs Farside nothing for free users. Relayed transfers happen only for paid, entitled rooms. Suggest a soft fair-use cap on *relayed file bytes* (e.g., 20 GB/month per subscription; product decision) reported by the host from route stats. No new server component is needed, just a counter if metering is wanted.

## B6. Privacy manifest, App Store privacy label, App Review

- **Phone `PrivacyInfo.xcprivacy`** (today: UserDefaults CA92.1, SystemBootTime 35F9.1/8FFB.1 [R]):
  - `NSPrivacyAccessedAPICategoryFileTimestamp`: **3B52.1** ("timestamps, size or other metadata of files or directories that the user specifically granted access to such as using a document picker") for reading the picked file's size, and **C617.1** (files inside the app container) for staging and inbox management **[V]** ([Apple approved reasons](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitypereasons)).
  - `NSPrivacyAccessedAPICategoryDiskSpace`: **E174.1** ("check whether there is sufficient disk space to write files … The app must behave differently … observable to users"). It carries the rule "**may not be sent off-device**", with an exception "to avoid downloading files from a server when disk space is insufficient" **[V]**. Design consequence [I]: the phone checks space locally and sends only a refusal code (`diskFull`), never the free-space value. Whether a refusal code counts as "derived information" is a judgment call; the E174.1 exception supports it. Keep the Mac's free space off the wire too; a Mac-side refusal is sufficient.
- **Mac host:** a Developer ID app (D30). App Store privacy-manifest enforcement applies to App Store submissions [I]. Mirror the entries for hygiene (the repo already maintains one).
- **Privacy "nutrition" label [I]:** Apple defines *collect* as "transmitting data off the device in a way that allows you and/or your third-party partners to access it for a period longer than what is necessary to service the transmitted request in real time" **[V]** ([App privacy details](https://developer.apple.com/app-store/app-privacy-details/)). E2E-encrypted peer-to-peer bytes that the relay can't read and nobody stores are arguably not "collected." Record the reasoning in the launch review packet. If any server-side metering of *bytes* is added, that is usage data, not content.
- **App Review:** Farside is a generic mirror of the user's Mac, so the 4.2.7 constraints aimed at "mirror of specific software" don't bite. File transfer adds no special rule. Per 2.5.2 ("may not … download, install, or execute code which introduces or changes features"), the phone must only store and share received files and never interpret or execute them **[V]** (guidelines). Mention file transfer and Files-app visibility in the review notes, with steps for the demo Mac.

## B7. Resumability and progress UI

- **v1:** no resume. Clean failure, partial deleted, one-tap **Send again**. Progress: a determinate bar with bytes and time remaining in a small capsule above the session toolbar (phone) and a menu-bar badge or notification (Mac). Include a route hint ("Local" / "Internet"), since relayed transfers are slower.
- **v2 resume [I]:** keep `.farside-partial` plus a sidecar `{transfer, name, bytes, digest, receivedOffset}`. The data channel is ordered and reliable, so the received data is always a contiguous prefix and `accept{offset}` suffices. Within the existing 15-minute reconnect window, the sender re-offers the same transfer ID and the receiver answers with its offset. The final whole-file digest still gates the rename. Expire partials after 24 h.
- **v2 background (iOS 26) [V API / I fit]:** `BGContinuedProcessingTask` "starts in the foreground," must be started "in response to someone's action," shows progress in a system Live Activity the user can cancel, and "can also use the network" in the background. The system may terminate tasks that show little progress **[V]** ([Apple: BGContinuedProcessingTask](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtask), [Performing long-running tasks](https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados)). It needs a "transfer-only" background state that keeps the peer connection but not video. Farside currently pauses capture on background, so the design must confirm the host keeps the channel open past its 45 s hold during an active transfer. `beginBackgroundTask` alone gives only a short extension (a 5 s `applicationDidEnterBackground` budget, then extra time) **[V]** ([Apple](https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time)).

## B8. Phased implementation plan (difficulty 1–5; estimates are inferences)

| Phase | Scope | Files (existing → change; new) | Difficulty | Rough effort |
|---|---|---|---|---|
| **0. Contract** | Freeze `file.1`, frames, limits, statuses, authorization, sanitizer rules; product decisions (Questions) | `Docs/REMOTE-PROTOCOL.md` (new section); `PRODUCT.md` (decision row) | 1 | 0.5 day |
| **1. Shared core** | `FileFrame` validation, binary chunk codec, streaming digest, sender/receiver state machines, filename sanitizer, limits; unit tests modelled on `ClipboardTransferTests` | **new** `RemoteShared/FileTransfer.swift`; `RemoteShared/ControlProtocol.swift` (`file: FileFrame?`); `RemoteShared/SessionContinuity.swift` (`SessionFeature.fileTransfer = "file.1"`, validation); `RemoteShared/PeerMedia.swift` (create/accept `file` channel at `:256`/`:710`, `sendFile(_:)`, buffered-amount callbacks, route bulk frames); **new** `RemoteTests/FileTransferTests.swift` | 3 | 2–3 days |
| **2. Phone → Mac** | `.fileImporter` + `PhotosPicker`, offer/stream/progress/cancel; Mac receive to `~/Downloads/Farside`, quarantine, notification, reveal; setup-time Downloads consent; Mac "Allow file transfer" toggle | **new** `RemotePhone/PhoneFileTransfer.swift` (mirrors `PhoneClipboard.swift`); `RemotePhone/NativeSessionView.swift` (menu + progress capsule); `RemotePhone/RemotePhoneApp.swift` (wire like `clipboard` at `:101`/`:551`); **new** `RemoteHost/HostFileReceiver.swift` (mirrors `HostClipboard.swift`); `RemoteHost/HostModel.swift` (wire like clipboard at `:131`, `:288–292`, `:1657–1659`, resets `:1194/:1325/:1728`); `RemoteHost/HostSettingsView.swift`, `RemoteHost/HostSetupView.swift` | 3 | 2–3 days + physical tests |
| **3. Mac → phone** | Phone "Get file from Mac…" → host `NSOpenPanel` on the streamed display → send; phone inbox + share/save; Files visibility keys; privacy manifest | `RemoteHost/HostModel.swift`, **new** `RemoteHost/HostFileSender.swift`; `RemotePhone/PhoneFileTransfer.swift`; `RemotePhone/Info.plist` (`UIFileSharingEnabled`, `LSSupportsOpeningDocumentsInPlace`); `RemotePhone/PrivacyInfo.xcprivacy` (FileTimestamp 3B52.1/C617.1, DiskSpace E174.1); `RemoteHost/PrivacyInfo.xcprivacy` (mirror) | 3 | 2 days + physical tests |
| **4. Polish (1.1+)** | Resume; `BGContinuedProcessingTask`; share-sheet entry (document types "Open in Farside", or a share extension staging into an App Group "outbox" the app sends on next connect; needs App Group capability and a new target in `project.yml`); Finder Share extension or menu-bar drop; multi-file/folders; relayed-bytes fair-use counter | as named + `project.yml` | 4 | 1–2 weeks |

**Verification per phase:** unit tests (framing, sanitizer, digest mismatch, cancel/reset mid-transfer, unknown-feature peers); an E2E stub-host run (`E2EStubHost`); a physical LAN test with 1 MB, 100 MB and 1 GiB files, measuring input-to-visible latency *during* transfer; a physical forced-relay test (`POCKETDESK_TEST_FORCE_RELAY`) checking cost against Cloudflare analytics; background and lock-phone behaviour; Downloads TCC denied path.

**1.0 recommendation [I]:** launch blockers remain open (`.11` Remove Phone `-25244` failure, pending physical acceptance of pairing/input/performance, purchases disabled, external gates; PRODUCT lines 3–5), and submission is five weeks away. **Ship file transfer in 1.1.** If blockers close by about 14 Oct, Phases 0–2 (phone→Mac only, about 5 days + tests) are self-contained behind `file.1`, and older peers are unaffected, so they could ride 1.0 as a "beta" like D29. Don't start Phase 3 before submission.

---

## C. Questions for Roshan

1. **Away-use promise (A0.1):** with default Lock Screen settings, the Mac probably locks after display sleep and Farside stops. Should 1.0 (a) tell users to lengthen or disable the lock delay, (b) add an opt-in "keep display on while sharing" (the Mac stays unlocked and lit; the curtain doesn't block local input), or (c) accept "Mac must be unlocked" and plan a lock-screen story for 1.1? A physical default-settings test should come first.
2. **FileVault help article:** OK to publish Apple's SSH-unlock procedure as an advanced help page (LAN/VPN only, no Farside code, no claim that Farside then starts before login)?
3. **File transfer timing:** 1.1 (recommended), or phone→Mac only as a 1.0 beta if blockers clear by about 14 Oct?
4. **Defaults:** Mac "Allow file transfer" on or off by default? Receive folder fixed at `~/Downloads/Farside`, or user-chosen at setup? Is a 1 GiB v1 cap acceptable?
5. **Relay fair use:** meter or cap relayed file bytes per paid subscription (e.g., 20 GB/month), or leave uncapped until usage data exists?
6. **Unlock ambition:** is locked-screen access important enough to fund a post-launch spike (keep-alive-while-locked + injection test, or the Apple Screen Sharing tunnel), knowing it partly reverses the "curtain lifts on lock" privacy stance?

## D. Sources (all accessed 2026-09-30; page dates where shown)

Apple (primary)
- Apple Platform Security, *Managing FileVault* (28 Jan 2026): https://support.apple.com/guide/security/managing-filevault-sec8447f5049/web
- *What's new for enterprise in macOS Tahoe 26* (27 Jul 2026): https://support.apple.com/en-us/124963
- `man 7 apple_ssh_and_filevault` (dated 1 Jul 2025; read locally on macOS 27.0.1 build 26A434)
- `IOPMLib.h`, macOS 27.0 SDK: `kIOPMAssertPreventUserIdleSystemSleep` discussion
- Set sleep and wake settings (macOS 26): https://support.apple.com/guide/mac-help/set-sleep-and-wake-settings-mchle41a6ccd/26/mac/26
- Share your Mac resources when it's in sleep: https://support.apple.com/guide/mac-help/share-your-mac-resources-when-its-in-sleep-mh27905/mac
- Remote Desktop: sleep, shut down, log out or restart: https://support.apple.com/guide/remote-desktop/sleep-shut-down-log-out-or-restart-a-computer-apd5535ee19/mac
- Require a password after waking your Mac: https://support.apple.com/guide/mac-help/require-a-password-after-waking-your-mac-mchlp2270/mac
- Automatic login (19 May 2026): https://support.apple.com/en-us/102316
- Control access to files and folders: https://support.apple.com/guide/mac-help/control-access-to-files-and-folders-on-mac-mchld5a35146/mac
- Share the screen of another Mac: https://support.apple.com/guide/mac-help/share-the-screen-of-another-mac-mh14066/mac
- Developer Forums 814152 (DTS, Jan 2026): https://developer.apple.com/forums/thread/814152
- App Review Guidelines (4.2.7, 2.5.2, 5.1.1): https://developer.apple.com/app-store/review/guidelines/
- App privacy details: https://developer.apple.com/app-store/app-privacy-details/
- Required-reason API approved reasons: https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitypereasons
- Multicast entitlement: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.multicast
- TN3179 Local network privacy: https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy
- Persistent Content Capture entitlement: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.persistent-content-capture
- UIFileSharingEnabled / LSSupportsOpeningDocumentsInPlace / LSFileQuarantineEnabled: https://developer.apple.com/documentation/bundleresources/information-property-list/
- BGContinuedProcessingTask; Performing long-running tasks; Extending background execution time: https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtask, https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados, https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time

Standards / platform
- MDN, Using WebRTC data channels (message size, DTLS): https://developer.mozilla.org/en-US/docs/Web/API/WebRTC_API/Using_data_channels
- Cloudflare Realtime pricing (22 Sep 2026): https://developers.cloudflare.com/realtime/pricing/ ; TURN (25 Sep 2026): https://developers.cloudflare.com/realtime/turn/

Vendors (primary for their own products)
- Edovia Screens 5 file transfers (iPhone/iPad): https://help.edovia.com/en/screens-5/features/file-transfers-iphone, https://help.edovia.com/en/screens-5/features/file-transfers-ipad ; wake: https://help.edovia.com/en/screens-4/how-to/wake-for-connections-mac ; prepare Mac: https://help.edovia.com/en/screens-5/getting-started/prepare-mac-for-screen-sharing
- Jump Desktop 8.2.21 notes: https://jumpdesktop.com/redir/new_mac_inapp/index-80221.html ; Fluid/File support pages (search snippets; 403 on fetch): https://support.jumpdesktop.com/hc/en-us/articles/216423983-General-Fluid-Remote-Desktop
- Parsec, Access Login Screen on macOS (search snippet; 403 on fetch): https://support.parsec.app/hc/en-us/articles/32381618319124-Access-Login-Screen-on-macOS
- Astropad help: https://support.astropad.com/en/articles/14010461-setting-up-your-mac-for-remote-access, https://support.astropad.com/en/articles/14062891-using-workbench-with-your-mac-mini
- Google Chrome Remote Desktop help (iOS/desktop): https://support.google.com/chrome/answer/1649523

Secondary
- Der Flounder (11 Oct 2025): https://derflounder.wordpress.com/2025/10/11/unlocking-filevault-via-ssh-on-macos-tahoe/
- Jeff Geerling (2025, updated re 26.5 Wi-Fi): https://www.jeffgeerling.com/blog/2025/you-can-finally-manage-macs-filevault-remotely-tahoe/
- MacStories Workbench review (5 May 2026): https://www.macstories.net/reviews/astropad-workbench-rethinks-remote-mac-control-for-ai-agents/
- RustDesk #11802, discussion 7565; Apple Developer Forums 724740, 656687, 771999; Google community thread 199134730; CIS/Tenable macOS 15 audit item; Macworld clamshell guide (URLs inline above).
