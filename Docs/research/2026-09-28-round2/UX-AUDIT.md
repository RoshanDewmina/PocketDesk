# PocketDesk UX audit, round 2

Checked 28 September 2026. Research only: no product file was modified. PRODUCT.md still owns scope; everything here is a proposal until Roshan accepts it and it lands there.

Goal restated: an app Apple could ship, where install to first successful click is a few obvious steps, nothing needs explaining, and every failure says what happened and what to do next. Paperwash stays a light layer over native controls.

## How to read this

Evidence tags used throughout:

| Tag | Meaning |
|---|---|
| [C] | Source code inspected, path and line given (main checkout, read only) |
| [S] | Screenshot inspected (simulator or offscreen render; not a physical device) |
| [D] | Apple documentation or HIG text fetched from Apple's own site |
| [M] | Mobbin screen or flow viewed. Mobbin has no macOS catalogue, so Mac patterns use iOS analogues plus HIG |
| [W] | Web source. Vendor claims are marked (V); user reviews are single-user anecdotes from aggregator pages, not a sample |
| [E] | Arithmetic or measurement done in this audit, not on a physical device |
| [U] | Unverified. Needs a device test before anyone relies on it |

Severity: **Blocker** (a new user cannot continue or abandons), **Major** (frequent confusion or failure), **Minor** (friction), **Polish**.

Impact and effort scores in section 6 are the auditor's estimates from reading files, not from building. Effort scale: 1 = about a day, 2 = 2-3 days, 3 = about a week, 4 = about two weeks, 5 = three weeks or more.

Screenshots reviewed live in the two redesign worktrees, not in the main checkout's outputs/ directory:
`.claude/worktrees/agent-ab3a195db8d977833/outputs/phone-redesign-2026-09-28/` and `.claude/worktrees/agent-a70f056c626d35b29/outputs/mac-redesign-2026-09-28/screens/`.

## 0. Summary

**What is already right** (keep it): QR plus explicit Mac approval with no account; a menu-bar-utility host that uses a real menu, not a popover [D: HIG menu bar extras]; Liquid Glass confined to the control layer, not the content [D: HIG materials]; camera permission requested at the moment of Scan [D: HIG privacy]; permission pages that update by themselves; system gestures deferred so a swipe cannot exit by accident [D: HIG going full screen]; input shield when the scene goes inactive; acknowledged text delivery; Reduce Motion respected in viewport animation; Dynamic Type handled on the Mac card.

**The five findings that matter most**

1. **A first-time user gets no teaching moment for a non-standard input model.** The session opens full-bleed and cropped (Fill), with End, keyboard and mode hidden behind a 40 x 5 pt handle, and no coach, tip or hint anywhere in the code [C: NativeSessionView.swift:16, 331-356; no coach/TipKit matches]. HIG says custom gestures must be discoverable and taught, and hidden controls must be easy to restore [D].
2. **Errors read like logs.** The most likely first failure (Mac asleep or PocketDesk not running) shows `Connection service: host_unavailable_or_unauthorized. Check the Mac and retry.` [C: RemoteCoordinator.swift:158]. There is no troubleshooter. A Workbench App Store reviewer complains of exactly this: device shows online, no connection, "no error messages" [W].
3. **The connection is fragile in ways a user feels.** Any app switch ends the session; any network blip ejects the user from the session to Home and throws away zoom and pan [C: RemotePhoneApp.swift:371-382; HomeView.swift:9-17; RemoteCoordinator.swift:126].
4. **"It worked yesterday" failures are built in.** Open at login is off by default [C: HostModel.swift:39; S: setup-4-ready], the Home card always says "Ready to connect" whatever the Mac is doing [C: RemoteCoordinator.swift:72], and Sequoia-and-later macOS re-prompts monthly for Screen Recording for apps that bypass the system picker, which cannot be answered from a phone [W: 9to5Mac].
5. **Pairing depends on the in-app scanner only.** The QR holds a `pocketdesk:` text blob, not a link, so the iPhone Camera and Control Center scanner cannot open the app with it [C: Pairing.swift; project.yml has no URL types or associated domains] [U: exact Camera behaviour]. It is also dense: 443 characters, 83 x 83 modules [E], where a packed universal link would be about 165 characters, 55 x 55 [E].

**Journey cost today** [E, counted from code paths, not timed]: about 13 user actions across two devices, four OS-level permission dialogs (Screen Recording, Accessibility, Camera, Local Network), two System Settings toggles and one forced relaunch before the first successful click. A stopwatch run with three new users should replace this estimate (section 8).

**Top 10 of the ranked 15 (full list in section 6)**

1. Plain-language, reason-specific errors plus a "Can't connect?" troubleshooter.
2. A settle-halo that shows where the pointer stopped, at a size that survives Fit zoom.
3. Priming for Local Network (and mic/speech), and Open Settings on a denied Camera.
4. Open at login on by default; a "your Mac is ready" screen with real checks and a live thumbnail.
5. Pairing dead-ends removed: scan feedback, auto-refreshing code, a visible Copy code.
6. A 20-second, interactive, skippable gesture coach on a local practice pad, then TipKit tips.
7. Auto-reconnect on return and no ejection to Home on blips; viewport survives.
8. Camera-scannable universal-link QR, "Send to iPhone", App Store link for the phone app.
9. Discoverable dock (peek, contrast) and a compact action strip for right-click, drag, Esc, shortcuts.
10. Home presence ("online / last seen") and, later, Bonjour direct connect.

---

## 1. Friction audit of the current journey

Journey: install Mac app, permissions, pair, first connect, first task, reconnect days later, error and recovery, end session.

### Step 0. Get both apps

| ID | Finding | Evidence | Severity | Fix |
|---|---|---|---|---|
| F0.1 | Nothing on the Mac tells a new user to get the iPhone app. Pair step 1 assumes it is installed. | [C] HostSetupView.swift:243 | Major (Blocker for public users) | Add a "Get PocketDesk for iPhone" panel on the pair page: App Store QR plus a Send Link button (Share sheet: Messages, AirDrop, Mail). |
| F0.2 | The 2-minute code starts counting the moment the pair page appears, before the user has downloaded the phone app or opened it. Downloading, launching and granting camera can exceed two minutes, which lands on "Code expired". | [C] HostSetupView.swift:254-256, 305; Pairing.swift `HostPair.create` (120 s) | Major | Keep the 2-minute lifetime (it is the security bound) but auto-refresh silently while the pair page is frontmost; cancel when the window closes. No dead-end. |

### Step 1. Mac permissions

| ID | Finding | Evidence | Severity | Fix |
|---|---|---|---|---|
| F1.1 | Two permission pages before any value is shown, each text-only plus "Open System Settings". | [C] HostSetupView.swift:35-63; [S] setup-1b | Minor | Merge Screen Recording and Control into one "Allow access" page with two live checklist rows. Keep permissions before pairing because Screen Recording usually needs a relaunch, which would invalidate a live QR. |
| F1.2 | The five-step recovery paragraph ("remove it with the - button, add it again with +...") is printed by default as soon as Settings was opened. Correct only for a stale grant, alarming for everyone else. | [C] HostSetupView.swift:93-101; [S] setup-1b | Major | Show only after about 20 s without detection or after Quit and Reopen fails, behind a "Still not detected?" disclosure. |
| F1.3 | Three names for one app: "PocketDesk Host" in copy and the System Settings list, "PocketDesk" in the menu and elsewhere, "Set Up PocketDesk" as the window title. The repo also records that macOS 27 renamed the Accessibility pane. | [C] HostSetupView.swift:44, 54, 95; HostAppActivation.swift:5; Docs/MAC-PERMISSION-IDENTITY.md | Minor | One user-facing name. Avoid naming panes ("Turn on PocketDesk in the list that opens"); rely on the deep link and the system prompt. |
| F1.4 | No plan for the monthly Screen Recording re-approval. The host uses TCC capture (`CGPreflightScreenCaptureAccess`, `SCShareableContent`), not the system picker. The prompt is worded as apps that bypass the picker. On an unattended Mac it stalls capture, and the phone shows only "Screen sharing needs attention on your Mac". | [C] HostModel.swift:199, 452-462; [W] 9to5Mac Sequoia monthly prompt; [D] Persistent Content Capture entitlement (macOS 14.4, VNC apps, by request to Apple) | Major (breaks away use around day 30) | Apply now for the Persistent Content Capture entitlement (Apple review has lead time). Whether it removes the monthly prompt for a WebRTC remote-control app is not stated in the doc [U]. Interim: Mac notification when a renewal prompt is pending; a specific phone message. |
| F1.5 | Open at login is off by default, and unchecked on the "ready" page. After any restart or macOS update the Mac is unreachable until someone launches the app. | [C] HostModel.swift:39, 147; [S] setup-4-ready | Major | Default on, one plain line of consent, and say the truth about the login screen and FileVault. |
| F1.6 | The Ready page is a promise with no proof: no check has run, no phone has connected. | [S] setup-4-ready | Minor | Replace with real checks and a live thumbnail (section 2.3). |

### Step 2. Pair

| ID | Finding | Evidence | Severity | Fix |
|---|---|---|---|---|
| F2.1 | The QR encodes `pocketdesk:` plus base64 text, not a URL. The Camera app and Control Center scanner cannot open PocketDesk from it. Most people will try the Camera first. | [C] Pairing.swift (`code()`); project.yml (no URL types, no associated domains) [U] | Major | Universal-link QR (section 2.5, option A). |
| F2.2 | QR is dense: 443 characters, 83 x 83 modules at correction level M, drawn at about 168 pt on the Mac page. Glare on a glossy laptop screen makes this the type of code that scans on the fifth try. | [E] CoreImage measurement; [C] HostStyle.swift:144-152 (level M); [S] setup-3 | Minor | Pack fields in binary, drop defaults: about 165 characters, 55 x 55 modules [E]. |
| F2.3 | Scanning a wrong or expired code does nothing: no message, no haptic. The scanner silently ignores anything `PairInvitation.parse` rejects, and parse rejects expired codes. | [C] ScannerView.swift:43 | Major | Inline chip under the viewfinder: "That code has expired. Choose New Code on your Mac." / "That isn't a PocketDesk code." plus an error haptic. |
| F2.4 | The paste help says "click Copy pairing code" but that command exists only as a right-click on the QR. | [C] PairingSheet.swift:134 vs HostSetupView.swift:285-288 | Major (paste path) | Visible "Copy code" and "Send to iPhone" buttons beside the QR. |
| F2.5 | Camera denied: only "Paste Code Instead". No Open Settings. HIG Writing: give a direct link, do not describe where a setting is. | [C] PairingSheet.swift:71-87; [D] HIG Writing | Minor | Add Open Settings. |
| F2.6 | The iOS Local Network alert fires on the first connection to a Mac on the same Wi-Fi, mid "Connecting...", unprimed. Denial is not detected, so LAN connection quietly fails or falls to a relay that is not deployed yet. | [C] project.yml:97 (usage string only; no Bonjour entry, no handling); [D] TN3179 (alert on first local network operation, may deny before the user answers) | Major | Single-button pre-alert screen (section 2.2) and a denied state with Open Settings. |
| F2.7 | Approval names no one: "A phone scanned your code." No device model, no comparison code. Two people in a cafe cannot tell which phone is asking. | [C] HostSetupView.swift:313-320; Docs/HOST-REDESIGN-RECEIPT (device name not stored) | Minor | Send model name in the handshake plus a short comparison derived from the handshake transcript. PRODUCT already asks for a comparison-code evaluation and security review. |
| F2.8 | The phone has 60 s to be approved; on expiry the user sees the generic timeout copy. | [C] RemoteCoordinator.swift:188, 277 | Minor | Specific copy: "Nobody approved this iPhone on the Mac in time. Try again and choose Allow." |

### Step 3. First connect

| ID | Finding | Evidence | Severity | Fix |
|---|---|---|---|---|
| F3.1 | The session opens straight into full-bleed Fill (cropped), status bar and home indicator hidden, dock collapsed to a 40 x 5 pt white capsule with a shadow. End, keyboard and mode are invisible; on a white Mac window the handle nearly disappears. | [C] NativeSessionView.swift:16, 59-61, 331-356; [S] session-fill-hidden | Blocker (first session) | Peek the dock for the first three sessions; glass capsule handle for contrast; overview flash at connect (section 3.1). |
| F3.2 | No first-run teaching for relative-trackpad input, three-finger workspace gestures, the double-tap-handle shortcut or hold-to-drag. The only text is in Controls > Gestures, three taps away. | [C] no coach or TipKit; NativeSessionView.swift:768-776 | Blocker | Gesture coach (section 2.4). |
| F3.3 | Most likely first-connect failure shows a raw server code and the word "service". | [C] RemoteCoordinator.swift:158, 277 | Major | Error rewrite table below. |
| F3.4 | Connect-time status strings run "Connecting securely...", "Authenticating your Mac...", "Connecting live desktop..." with no progress meaning and, on unknown raw states, are shown verbatim in caution colour. | [C] RemoteCoordinator.swift:101, 148, 224; HomeView.swift:169-184 | Minor | Three named steps with a bounded indicator, as Sonos and Apple Home do [M]. |

### Step 4. First task (point, click, scroll, type)

| ID | Finding | Evidence | Severity | Fix |
|---|---|---|---|---|
| F4.1 | The pointer is hard to find. Roshan reported this on the physical phone. The locator ring is off (`showsRing = false`). In portrait at Fit the desktop is about 0.27x, so a 17 pt arrow renders near 5 pt [E: 1470 pt desktop on 402 pt iPhone 17, illustrative, matches PRODUCT's 0.27x]. | [C] PointerLocator.swift:54-56, 64; PRODUCT.md backlog row 1 | Blocker for precision tasks | Settle-halo (section 3.4). |
| F4.2 | New users tap where they want the click; the relative model does nothing visible. There is no on-canvas hint. Xbox's remote prints "Swipe to navigate. Tap to select." on its touch surface [M]. | [C] NativeTrackpadSurface.swift; [M] Xbox | Major | Ghost hint inside the surface for the first three sessions. |
| F4.3 | Right-click, drag, Esc and shortcuts are three steps deep: reveal dock, open Controls, tap a tile. | [C] NativeSessionView.swift:277-290, 711-736 | Major | Compact action strip (section 3.1). |
| F4.4 | Typing is compose-then-Send with delivery states, unlike every other keyboard on the phone. The two-row bar plus the system keyboard takes roughly half of portrait height and roughly three quarters of landscape height [E: typical iOS keyboard heights, not measured]. | [C] NativeSessionView.swift:376-456 | Major | Live typing mode; single-row bar in landscape (section 3.2). |
| F4.5 | The keyboard opens automatically only after a click that the host probe reports as editable; it never closes itself when focus leaves the field; the manual path is the hidden handle double-tap or two taps through the dock. | [C] NativeSessionView.swift:78-84, 331-356 | Minor | Auto-dismiss on positive focus loss; keyboard button in the peek state. |
| F4.6 | Every accepted click plays a heavy impact at full intensity. HIG: avoid overuse, prefer short unobtrusive haptics, make them optional. The toggle exists. Roshan asked for stronger haptics. | [C] RemotePhoneApp.swift:122, 226; [D] HIG haptics | Polish | Keep the current strength as "Strong"; add Light and Off; do not change Roshan's default without asking. |
| F4.7 | Fill crops the Mac screen and nothing says so. First view looks like part of the Mac is missing. | [C] ViewportPreference default; PRODUCT 28 Sep Fill decision | Minor | Zoom badge says "Part of your Mac's screen"; noninteractive mini indicator during pan and zoom (PHONE-UX.md). |

### Step 5. Reconnect days later

| ID | Finding | Evidence | Severity | Fix |
|---|---|---|---|---|
| F5.1 | Home shows "Ready to connect" whether the Mac is on, asleep or gone. It is a stored string, not a check. Apple Home marks devices "Not Responding"; Chime shows "Last seen 15 hours ago" [M]. | [C] RemoteCoordinator.swift:72; HomeView.swift:169-172 | Major | Presence from the connection service (section 2.5, option C). |
| F5.2 | Switching to any other app ends the session. Only `.inactive` (Control Center, banners) survives. On return: a dead-end "Session ended" screen, one tap, then a full handshake. HIG multitasking: let people continue as if they never left. | [C] RemotePhoneApp.swift:359-382; HomeView.swift:300-344; [D] HIG multitasking | Major | Auto-reconnect on return; optional Face ID gate. |
| F5.3 | A network blip tears down the session view. `resetSession` clears `remoteVideo` and `connected`, so the router shows Home; when retry succeeds a new session view is built with fresh `@State`, and zoom and pan are lost. | [C] HomeView.swift:9-17; RemoteCoordinator.swift:126, 314-328 | Major | Keep the session view mounted with a "Reconnecting..." pill over the dimmed last frame; persist viewport across reconnects. |
| F5.4 | Restart, display sleep, FileVault at the login window, Sequoia renewal prompt: all look the same from the phone. Workbench documents the same limits ("cannot wake a sleeping Mac", FileVault blocks after reboot) [W]. | [C] RemoteCoordinator.swift:277; [W] Astropad help | Major | Say which, when known (host reason codes); otherwise say "Your Mac may be asleep, restarting or waiting at the login window". |
| F5.5 | Every launch needs a tap on Connect. | [C] HomeView.swift:255-260 | Minor | Optional "Connect when I open PocketDesk" with a 1.5 s cancellable state; default on when exactly one Mac is paired. |

### Step 6. Error and recovery

| ID | Finding | Evidence | Severity | Fix |
|---|---|---|---|---|
| F6.1 | Error copy is written for developers (table below). | [C] see table | Major | Rewrites below. HIG Writing: avoid blame, say what to do; HIG Alerts: avoid titles like "Error". |
| F6.2 | No troubleshooting path. More > Connection Details shows monospaced route diagnostics. | [C] HomeView.swift:270-298 | Major | "Can't connect?" sheet: five-line checklist, Try Again, Send Diagnostics. Hue, Oura, Alexa, IKEA all do this [M]. |
| F6.3 | "View only" and "Input paused" do not say who can fix them. | [C] NativeSessionView.swift:358-365 | Minor | "Mouse and keyboard are off on your Mac" / "Reconnecting the picture. Controls are paused." |
| F6.4 | No retry counter, though the coordinator retries up to five times with backoff. | [C] RemoteCoordinator.swift:34, 309-328 | Polish | "Reconnecting... (2 of 5)" with Cancel. |

**Error copy rewrites** (writing rule: what happened, why if known, one action; no codes, no "service"; no "oops")

| Where | Now | Proposed |
|---|---|---|
| RemoteCoordinator.swift:277 | Connection timed out. Check that the Mac is awake and the service is reachable. | Couldn't reach MacBook Air. It may be asleep, offline, or PocketDesk isn't running. [Try Again] [Can't connect?] |
| :158-164 | Connection service: host_unavailable_or_unauthorized. Check the Mac and retry. | MacBook Air isn't available right now. Check that it's awake and that PocketDesk is in its menu bar. |
| :158-164 (`already_connected`) | Connection service: already_connected... | PocketDesk is still closing your last session. Try again in a few seconds. |
| :168 | Secure connection failed. Reconnect or pair again on your Mac. | Couldn't verify this Mac. Try again. If it keeps happening, pair again. |
| :250 | Invalid control message. Session ended safely. | The connection glitched, so PocketDesk ended the session to keep your Mac safe. Reconnect. |
| :322 | Connection interrupted - retrying... | Reconnecting... (2 of 5) [Cancel] |
| :228 | Relay-only test requires a configured TURN service. | Hide in release builds. |
| HomeView.swift:316 | PocketDesk hides your Mac's screen and ends the session when it moves to the background. | You left PocketDesk, so your Mac's screen is hidden. [Reconnect to MacBook Air] |
| NativeSessionView.swift:164 | Waiting for a fresh picture / Screen sharing needs attention on your Mac | Waiting for your Mac's screen... / Your Mac stopped sharing its screen. Screen Recording may need to be renewed. Open PocketDesk on your Mac. (needs a host reason code) |
| :361 | Input paused | Reconnecting the picture. Controls are paused. |
| RemotePhoneApp.swift:82 | Picture quality needs the updated Mac companion. | Update PocketDesk on your Mac to change picture quality. |
| RemotePhoneApp.swift:172-173 | Text is limited to 4,096 UTF-8 bytes / 1,024 UTF-16 units. | That's too long to send at once. Send it in two parts. |
| Pairing.swift `invalidPairing` | ...Open Pair Phone on your Mac. | ...Choose Pair a Phone in the PocketDesk menu on your Mac. (match the real menu title) |

### Step 7. End session

| ID | Finding | Evidence | Severity | Fix |
|---|---|---|---|---|
| F7.1 | End is only in the expanded dock. Deliberate and safe, but nothing else can end a session quickly. | [C] NativeSessionView.swift:264-275 | Polish | Optional Live Activity ("Controlling MacBook Air", End) [U: eligibility and lifetime]. |
| F7.2 | A host-side Stop Sharing and a network drop look alike on the phone. | [C] RemotePhoneApp.swift end() | Polish | Host sends a reason; phone says "MacBook Air stopped sharing." |

---

## 2. First run and onboarding

### 2.1 Target flow

Principle from HIG: teach through interactivity, keep it brief and optional, never show it twice, keep it findable later; ask for permission in context [D: Onboarding, Privacy].

| Now (about 13 actions) | Target (about 9 actions, coach inside the wait) |
|---|---|
| Launch, Open System Settings, toggle, Quit and Reopen, Open System Settings, toggle, phone: open, Scan, Allow camera, aim, Mac: Allow, Local Network Allow, Done | Launch, Allow access (one page, two rows), phone: Camera scan or Camera app link, Mac: Allow (names the phone), Local Network (primed), coach runs during the first connection, Done |

Ideas that shorten the path: one merged permission page; QR that the Camera app can open; auto-refreshing code; the coach filling the "Approve on your Mac" wait instead of a spinner (Sonos also uses the connecting wait for a friendly status [M]).

### 2.2 Permission priming

HIG rules for a pre-alert screen: one button, titled "Continue" or "Next", no cancel or close, never an image of the system alert, never annotate the alert [D: Privacy > Pre-alert screens]. Ask in context when the feature is used.

| Permission | When | Prime? | Copy draft |
|---|---|---|---|
| Camera (phone) | Tap Scan | No screen needed: context is obvious and the purpose string is good. Add Open Settings on denial. | Purpose string exists: "Scan the pairing code shown on your Mac." |
| Local Network (phone) | First Connect | Yes. A single-screen pre-alert. | Title: Connect faster at home. Body: When your iPhone and Mac share Wi-Fi, PocketDesk connects directly. iOS will ask to find devices on your local network. Choose Allow. Button: Continue. Denied: banner "Local network is off. PocketDesk will use the internet instead, which can be slower." [Open Settings]. Reword the usage string, which today promises "Discover". |
| Microphone and Speech (phone) | Tap mic | Prime once ("Two quick permissions: microphone and speech recognition. Speech stays on this iPhone.") | Continue |
| Screen Recording (Mac) | Setup | System alert via `CGRequestScreenCaptureAccess`, plus one line of what it enables | "PocketDesk streams this Mac's screen to your iPhone." Keep, add a small picture of the switch. |
| Accessibility (Mac) | Setup | Same, plus honest skip | "So your iPhone can click and type. You can skip and use view only." |
| Notifications | Never at launch | Only when a feature needs them (for example "agent needs you") | n/a |

Mobbin references: [Edits, three-line "how you'll use this" priming](https://mobbin.com/screens/4bce154c-bc90-4b02-87ab-02dc3b0fe523); [Family, tap-to-enable rows with reasons](https://mobbin.com/screens/fc99942c-5d52-40b7-9037-665288964a78); [Lapse, "Why do you need this"](https://mobbin.com/screens/7e43fdbb-28e7-4e71-8a1b-5341de2be89a); [Alexa permission priming inside setup](https://mobbin.com/flows/5dc6e5b3-7f1e-463a-8aa6-669f1ee007fd).

### 2.3 "Your Mac is ready" confirmation

Replace the static Ready page with proof.

Mac page contents:
- A live thumbnail of the shared display captured now, captioned "This is what your iPhone will see." It proves Screen Recording works, catches the "toggle on but stale grant" case, and is the most satisfying confirmation available.
- Real checklist, each row green only if actually checked: Screen Recording, Mouse and keyboard (or "View only"), Connection reachable, iPhone paired, Opens at login (on by default).
- One sentence on limits: "Your Mac needs to be awake. After a restart, log in once."
- Menu bar location shown as a picture with the icon circled (the HIG says people, not apps, choose to keep a menu bar extra; showing where it lives is the discoverable part) [D].

After the first real connection, both devices confirm together: Mac menu shows "Roshan's iPhone is viewing"; the phone shows a short "Connected to MacBook Air" check and hands off to the coach. Alexa's success screen pairs "set up and ready" with the first thing to do next [M: [Alexa first-light success](https://mobbin.com/screens/257edb9d-995b-4c40-9087-3ec9be08a8a9)]; Hue and Withings do the same [M: [Hue flow](https://mobbin.com/flows/8d39b393-01f5-43dd-a59f-f9d6eb1b3a9b), [Withings](https://mobbin.com/screens/b5de7829-f383-4d7b-97d7-38c685afc7a9)].

### 2.4 Gesture coach that teaches in 20 seconds

Requirements traced to HIG: interactive not a carousel, brief, skippable, not repeated, findable later, context tips instead of one long flow, a non-gesture way for every action [D: Onboarding, Gestures, Accessibility].

**Format.** A full-screen practice pad shown after the first fresh frame, or during the first "Approve on your Mac" wait. It is a miniature desktop with three targets and a scroll list, driven by the real `NativeGestureEngine` (RemoteShared, UIKit-free) with a stub command sink, so nothing is sent to the Mac. This is the safe place to try each action, per HIG.

| Beat | Prompt (one line) | Success signal | Time |
|---|---|---|---|
| 1 Move | Slide one finger anywhere. The pointer moves, it doesn't jump to your finger. | Engine emits enough `move` distance | 4 s |
| 2 Click | Tap to click where the pointer is. | `click(count: 1)` on a target | 4 s |
| 3 Scroll | Two fingers to scroll. | `scroll` on the list | 4 s |
| 4 Zoom | Pinch to zoom the view. | `zoom` past threshold | 4 s |
| 5 Controls | Swipe up on the handle for controls. Double-tap it to type. | Handle swipe on the pad | 4 s |

Each success plays a selection haptic and a check and auto-advances; idle for 6 s shows a hint variant. Right-click, hold-to-drag and three-finger workspace swipes are not taught here; they arrive later as TipKit tips (below). A visible Skip is always on screen. Completion is stored once; replay lives in Controls > Gestures and Home > More > How to use PocketDesk.

**Then context tips.** Use TipKit (iOS 17+, target is iOS 26): attach a tip to the dock handle after a session where the keyboard was never used; a tip on first Fit; a tip for two-finger tap after several clicks. Apple's own guidance: use tips sparingly, for unused features, not to guide people through the app [D: TipKit].

**Accessibility.** With VoiceOver on, skip the pad and present a single screen listing the actions available from the trackpad element's actions rotor (they already exist: Right-click, Double-click, Zoom view) and the Controls sheet [C: NativeTrackpadSurface.swift:52-57, 71-77]. Reduce Motion: static illustrations, no animated ghost hand. Test at the largest Dynamic Type size.

**Mobbin references** (structure, not styling): [Telegram's icon-plus-one-line gesture cheat sheet](https://mobbin.com/screens/44cc1608-a319-4252-961b-26ee9db04dfa); [Polarsteps three-gesture card](https://mobbin.com/screens/705552aa-40c7-4c47-b67d-292ca45ad647); [Suno inline hint with Got it](https://mobbin.com/screens/df1739c2-14b9-4376-bd91-db5691eb1593); [Uber Eats swipe hint](https://mobbin.com/screens/caaeaafa-eb83-4580-be9e-aaee2f9e0183); [Xbox "Swipe to navigate. Tap to select." label on the surface](https://mobbin.com/screens/f29dc23d-69a0-4f4f-8914-fc4f6e2a4806).

### 2.5 Zero-config pairing: what is feasible

Checked against Apple documentation. The security floor stays: QR-level trust with explicit Mac approval, no PocketDesk account.

| Option | Experience | Feasibility on public API | Security notes | Effort | Verdict |
|---|---|---|---|---|---|
| **A. Universal-link QR** | Scan with the Camera app or Control Center; iOS offers to open PocketDesk (or the App Store page if not installed) | Universal links need an associated domain, an AASA file and the entitlement; nothing in the project today [D: supporting associated domains; C: project.yml] [U: exact Camera banner behaviour, test on device] | Put the payload in the URL fragment so it is not sent to a server. If the app is missing the link opens in Safari, so the one-time secret can land in history: keep the 2-minute, one-time bound. Longer term, a short code with a PAKE handshake would remove the secret from the QR entirely (needs review). | 3 | **Do now.** Packs to about 55 x 55 modules [E]. |
| **B. Send to iPhone** | Button on the Mac sends the same link via Share sheet, AirDrop, Messages or Universal Clipboard | AppKit sharing services | Same as A | 1-2 | **Do now**, with A. Makes the QR optional and fixes the invisible "Copy code". |
| **C. Presence plus Bonjour on the LAN** | Home shows "MacBook Air, nearby" or "last seen 3 h ago"; direct connect without the service on the same Wi-Fi | Bonjour needs `NSBonjourServices` and the Local Network alert; WebRTC LAN candidates already need that permission, so it is the same alert [D: TN3179]. The connection service already tells the phone when the host is online (`peer.online`) [C: RemoteCoordinator.swift:144-152]. | Advertise only an unlinkable rotating identifier. Client-isolated Wi-Fi (campus, cafe) blocks mDNS: keep the service path. | 3 | **Next.** Presence first, Bonjour second. |
| **D. Unpaired "Nearby Macs" list** | Roku-style "Available on this network" list [M: [Roku](https://mobbin.com/screens/078311ac-cb2b-4d3c-9863-0a43aef1d089)] | Bonjour; needs the Local Network alert before any pairing | Needs a comparison code or PAKE to resist a LAN attacker; fails on isolated networks | 4 | Not now. Secondary path after C. |
| **E. Same Apple Account (CloudKit private database)** | Phone signed in to the same iCloud account sees "MacBook Air" with no scan. Matches Universal Control and Sidecar, which both require the same Apple Account with two-factor authentication [D: Apple support]. | `CKRecord.encryptedValues` (iOS 15 / macOS 12) is public; needs iCloud entitlements, push and a Developer ID provisioning profile on the Mac [U] | Apple's doc: with Advanced Data Protection the keys are available only to the owner; without it that is not end-to-end. So carry only public data (Mac card, public key, endpoint) in CloudKit and run a device-side key exchange; never store session keys there. Keep Mac-side approval for the first connection per device; an Apple Account compromise must not equal silent access. | 5 | **North star.** Build after A-C if pairing drop-off data justifies it. No PocketDesk account needed. |
| **F. Handoff (`NSUserActivity`)** | While the pair window is open, the iPhone app switcher offers "Continue" for PocketDesk | Public API, same Apple Account and Bluetooth proximity; activity type in Info.plist; `userInfo` accepts plain types [D] | Payload travels over Apple's channel; keep it a locator, not a secret [U: size limits] | 2-4 | Optional experiment; flaky by nature. |
| G. Wi-Fi Aware, DeviceDiscoveryUI, AccessorySetupKit | Apple's own proximity pairing UI | **Not available for a native macOS host**: Wi-Fi Aware and DeviceDiscoveryUI list iOS, iPadOS, Mac Catalyst (and tvOS for DeviceDiscoveryUI); AccessorySetupKit is iOS and iPadOS only and for hardware accessories [D] | n/a | n/a | **Rule out.** |
| H. App Clip | Scan and connect without installing | App Clips cannot perform local network operations [D: TN3179] and the WebRTC binary is large [U] | n/a | n/a | **Rule out.** |
| I. Bluetooth LE, NFC, UWB | Proximity pairing | Macs have no NFC reader or UWB; BLE adds a permission on both sides | n/a | n/a | Not recommended. |
| J. Short numeric code | "Try numeric code instead?" [M: [Alexa scan screen](https://mobbin.com/screens/d4db8f8f-f2b6-4852-8adf-bf2c7fb6fe7b), [Hue setup code](https://mobbin.com/flows/8d39b393-01f5-43dd-a59f-f9d6eb1b3a9b)] | Requires a PAKE (for example SPAKE2) through the service so a short code is safe | Online guessing limited by rate limit and 2-minute life; needs security review before public release | 4 | Replaces today's paste-a-blob fallback when the security work is done. |

Recommendation: A and B in the next sprint, C after that, E as the "just works" target for the following release, with the QR kept as the fallback for shared or work Macs on different accounts.

---

## 3. In-session recommendations

### 3.1 Dock and controls

Today: collapsed handle; expanded dock is status pill, End, four icon buttons (Keyboard, Fit/Fill, Control/View, Controls), Mic or Release [C: NativeSessionView.swift:229-329].

- **Make the handle findable.** For the first three sessions, show the dock open for about two seconds, then collapse (skip if Reduce Motion is on: leave it open until first touch). Replace the plain white capsule with a small glass capsule so it is visible on both white and black desktops. Keep the double-tap-to-type shortcut but also put a Keyboard button in the peek state. HIG: keep essential controls easy to reveal, restore hidden chrome with a familiar gesture [D: going full screen].
- **Compact action strip** (in the PRODUCT backlog as "Next"): Right-click, Drag, Esc, Cmd, Tab, Undo, Refresh screen. Sidecar's sidebar is the reference. These are the actions that are three steps deep now (F4.3).
- **Dock alignment setting** (Left, Center, Right) for left-handed and one-handed use. End currently sits at the far left, which is also the hardest place for a right thumb: keep it there for accident safety but let people move the whole dock.
- **Refresh screen** action: requests a fresh keyframe or restarts capture. It is the stock remedy for black or stuck pictures (RustDesk and Workbench reviewers hit both) [W].
- **Fit or Fill by orientation:** default Fill in portrait for reading, Fit in landscape where the 16:10 desktop matches the phone's aspect; remember the user's choice per orientation.
- **Route badge in Controls:** "Direct, Wi-Fi" or "Relayed". It explains lag without a support call and reuses the existing diagnostics string.

Mobbin: [Google TV remote with a Swipe control / D-pad control choice](https://mobbin.com/screens/7088a28e-ebad-46ed-9caa-ef55e6054924); [Roku remote grouping keyboard, mic, back, home](https://mobbin.com/screens/551701e2-93f4-463f-b977-1cb250f5c2cb); [SmartThings touchpad remote](https://mobbin.com/screens/54345414-2c0d-4376-8335-7a65a69df97f); [Canva presentation remote with QR and copy link](https://mobbin.com/screens/968be409-0199-4ec1-80a0-9f82cef1e896).

### 3.2 Keyboard

- **Live typing mode.** Today's compose-then-Send model protects IME and emoji but feels unlike every other app. Make "type directly" the default for plain text (each committed character sent immediately, with the existing request-ID acknowledgement) and use compose for dictation, emoji and CJK composition. PRODUCT open decision 3 already lists this comparison; run it in the coach study.
- **Auto-open and auto-close.** Keep the click-probe auto-open. Add auto-dismiss when the host reports focus left an editable field (debounced), so the keyboard does not linger over content. Terminals and canvas apps will not report; manual stays.
- **Landscape.** One row: keys scroll inside the field row; drop the caption line. Two rows plus the system keyboard leaves about a quarter of landscape height for the desktop [E].
- **Dictation** exists (mic). Prime speech and mic once (section 2.2).

### 3.3 Dynamic zoom

Follows PHONE-UX.md (staged, manual wins, no surprise motion). Additions from this audit:

1. **Now:** zoom badge wording ("Part of your Mac's screen"), noninteractive mini indicator while panning, Fit or Fill by orientation.
2. **Keyboard-aware framing:** when the keyboard opens, keep the pointer or focused region inside the shrunken safe area, restore the prior viewport when it closes (Maps-style). The safe-inset plumbing exists (`applyGeometry`).
3. **Caret-follow:** the host may send the focused element's bounded rectangle (accessibility frame), never text. The phone transforms it, eases in, pauses while the user drags, and uses hysteresis near edges. If Reduce Motion is on, cross-fade or jump. If accessibility data is unavailable (terminals, canvas editors), do nothing and leave manual zoom intact [PHONE-UX.md].
4. **Tap-to-fit window** only as an explicit mode, because an ordinary tap already means click.

Effort is high because it needs a host-side accessibility query and cross-app compatibility testing; ship steps 1 and 2 first.

### 3.4 Pointer

Recommendation: a **settle-halo**. Accuracy matters more than always-on visibility, because a ring drawn while the finger moves can sit a few frames away from the captured cursor (the freshness window is 250 ms) and read as a second pointer [C: PointerLocator.swift; PRODUCT 28 Sep]. Instead:

- When motion stops (finger lifts or pauses), fade in a soft halo at the authoritative position once it is fresh, hold about a second, fade out.
- Halo diameter is fixed in screen points (for example 28 pt) so it survives Fit zoom, with high-contrast edge for both light and dark desktops.
- Setting: Pointer highlight Off, When it stops (default), Always; Pointer size Small, Medium, Large (macOS has the same idea in Accessibility).
- Reduce Motion: no pulse, fade only.
- A replacement phone-drawn pointer stays the later step, as CURSOR-RESEARCH concluded; it needs `showsCursor` off on new hosts and an old-client fallback, so it is a bigger project.

### 3.5 One-tap reconnect and blips

- On return from background within about 10 minutes: reconnect automatically into a "Reconnecting to MacBook Air..." state with the screen still shielded until the first fresh frame; optional Face ID gate in Settings for people who want it. iOS gives a backgrounded app little guaranteed network time, so this is reconnect, not a kept-alive socket [D: HIG multitasking; NETWORK-AND-SESSION.md].
- During in-session drops: keep the session view mounted, dim the last frame, show a glass pill "Reconnecting... (2 of 5)" with Cancel; keep viewport, mode and draft.
- After five failures: one sheet, "Can't connect?" with the checklist (F6.2).
- Mobbin: [Google TV "Connected, Living Room TV" header](https://mobbin.com/screens/7088a28e-ebad-46ed-9caa-ef55e6054924); [Google TV connect flow](https://mobbin.com/flows/f4a1c6f0-b7ae-427b-a896-b4f3c2535f41); [Sonos add-speaker flow](https://mobbin.com/flows/8887a914-022d-483e-a280-e306103609a5).

### 3.6 Plain-language in-session states

Use the rewrite table above. Add a specific host reason code so the phone can say why sharing stopped (permission renewal, display removed, Stop Sharing, Mac sleeping). Where only someone at the Mac can fix it, say so; do not offer a Retry that cannot work. HIG: display errors near the problem, avoid blame, say what to do; use passive status, not alerts, for connection problems (Mail's indicator is the HIG example) [D: Writing, Alerts, Feedback].

### 3.7 Accessibility

| Area | Finding | Evidence | Fix |
|---|---|---|---|
| VoiceOver: pointer control | The trackpad view is a `.button` element, so VoiceOver intercepts one-finger touches; a VoiceOver user cannot move the pointer with a drag. | [C] NativeTrackpadSurface.swift:51 [U: confirm on device] | Add `allowsDirectInteraction` to the trackpad element so touches pass through when VoiceOver is on [D: UIAccessibilityTraits.allowsDirectInteraction, "views the user interacts with directly"]. Add adjustable actions to nudge the pointer by 10 or 50 pt. Keep the existing Right-click and Double-click actions. |
| VoiceOver: dock | Handle, buttons, End, Release, Mic have labels, hints and actions. | [C] NativeSessionView.swift:264-356 | Keep. Add the new action strip labels. |
| Dynamic Type | "End" is `.body` text in a fixed 52 pt slot and will clip at large sizes. Dock icons are fixed 48-52 pt (fine as icons). Home card adapts. HIG asks for at least 200% text. | [C] NativeSessionView.swift:33, 264-275; HomeView.swift:207-238; [D] HIG accessibility | Use an X icon with a text label in a `ViewThatFits`, or `@ScaledMetric`. Test the coach and Controls sheet at the top size. |
| Reduce Motion | Viewport animations are gated on it. Auto-follow easing, coach, halo and dock peek must be too. HIG: tighten springs, replace movement with fades. | [C] NativeSessionView.swift:29, 885, 925 | Coach and halo need static variants. |
| Reduce Transparency, Increase Contrast | White handle at 92% opacity with a shadow on top of an arbitrary Mac screen. | [C] NativeSessionView.swift:331-343 | Glass capsule handle with a system contrast fallback. |
| Time-boxed UI | Zoom badge (0.9 s), "Click sent" (0.6 s), drag hold expires at 10 s. HIG: avoid auto-dismissing UI for people who need more time. | [C] NativeSessionView.swift:109-119; RemotePhoneApp.swift:329 | Non-critical, keep; make the hold limit a visible countdown on the Release button. |
| Gesture alternatives | Click, right-click, double-click, drag and workspace actions exist as buttons in Controls. | [C] NativeSessionView.swift:711-794 | Good; surface via the action strip. |
| Haptics | Toggle exists; heavy full intensity. | [C] RemotePhoneApp.swift:114-116, 226 | Off, Light, Strong. |
| Left-handed and one-handed | Relative trackpad works anywhere on the glass. Dock is fixed center; End far left. | [C] NativeSessionView.swift:229-248 | Dock alignment setting; mirror End and Mic. |
| Switch Control, Voice Control, Full Keyboard Access | Standard buttons with labels; not tested. | [U] | Add to the acceptance list. |

### 3.8 iPad and landscape

- **Hardware keyboard and pointer are missing.** No `pressesBegan`, `UIKeyCommand`, hover or pointer handling anywhere in the phone code; the input view accepts only `.direct` touches [C: NativeTrackpadSurface.swift:91; grep]. On an iPad with a Magic Keyboard, shortcuts, arrows and the trackpad do nothing. For the "university assignments" scenario this is table stakes. Plan per APPLE-INTERACTION-RESEARCH.md: key-down and key-up mapping with modifier release on disconnect, deduplicated against the text path (RustDesk reviewers report duplicated keys; a Jump thread reports stuck Cmd) [W]; indirect pointer through a pan recogniser with scroll types enabled; optional pointer lock.
- **Multitasking risk [U]:** the app shields the picture whenever the scene is `.inactive` [C: RemotePhoneApp.swift:359-370]. In Split View or Stage Manager an unfocused window may report inactive, which would black out the desktop each time the user taps the reference app next to it. Test on an iPad before promising side-by-side use. HIG: every app needs to work well with multitasking [D].
- **Direct-touch option first on iPad:** relative input is slower on a large glass; Workbench defaults to direct touch; macOS 27 adds touch to Sidecar [W]. Offer an explicit Direct mode with a small magnifier for precise targets (PRODUCT: optional after relative input is proven).
- **iPad layout:** use the size class; a two-column Home (Macs, details) is optional polish. The dock max width (560) and keyboard bar (640) already suit a wide window.
- **Landscape iPhone:** single-row keyboard bar (3.2), Fit default (3.1), preserve the focal anchor through rotation (PHONE-UX.md), controls sheet already uses a large detent when compact.

---

## 4. Mac companion simplification

| Element | Action | Reason |
|---|---|---|
| Four setup pages (Screen, Control, Phone, Ready) | Merge to three: **Allow access** (two live rows), **Pair**, **Ready** | Fewer page turns; keep permissions before pairing because of relaunch |
| Recovery paragraph on permission pages | Hide behind "Still not detected?" after about 20 s | F1.2 |
| "PocketDesk Host" naming | One name, "PocketDesk" everywhere | F1.3 |
| Pair page | Auto-refreshing code; visible Copy code and Send to iPhone; small App Store QR | F0.1, F0.2, F2.4 |
| Ready page | Live thumbnail plus real checklist plus limits sentence; Open at login on by default | F1.5, F1.6 |
| Conditional "service address" step | Remove from shipped builds (it exists only for the development build) | PRODUCT: not a customer experience |
| Menu bar | See spec below | HIG: a menu, not a popover [D] |
| Settings: Phone row | Rename "Your iPhone" to the real device name; list up to N devices with last seen and Remove (Telegram and Chime patterns [M: [Telegram devices](https://mobbin.com/screens/d5905262-96e9-4793-b9c9-7d55b06c1379), [Chime My devices](https://mobbin.com/screens/b19183d6-a104-447d-b598-8bfed52ec096)]) | Today "Pair New Phone" replaces the only phone, so an iPhone and an iPad cannot both work |
| Settings: "Keep this Mac awake while sharing" | Keep; reword as "Keep this Mac awake while PocketDesk is on"; footer states real limits (lid closed, restart, login screen) | "While sharing" is ambiguous; PRODUCT wants honesty |
| Settings: add | Help and Diagnostics row (Run checks, Copy diagnostics), version and update status | Workbench offers diagnostic reports [W]; Grab-style "we found issues" list [M: [Grab Driver diagnostics](https://mobbin.com/screens/f21cc30a-b0e8-4c8e-9de8-3a829706255c)] |
| Notification on connect | Optional, on by default: "Roshan's iPhone connected to this Mac." | Awareness without a persistent indicator; macOS already shows its own capture indicator |
| Dock icon | Keep: appears only while a window is open | Already right [C: HostAppActivation.swift] |
| "Approve" surface | Keep in the setup window; name the phone model and add the comparison code | F2.7. Apple's Screen Sharing invitation in Messages is answered with an explicit "Control my screen" option and Accept [W: Apple Messages support]; consider a similar view-only or control choice on Allow |

**What the menu bar should show** (a native menu, at most six rows):

```
[state icon]  MacBook Air is ready                 (line 1: state, in words)
              Roshan's iPhone is controlling · 12 min · Wi-Fi direct   (only when live)
--------------------------------------------------
Allow iPhone... / Decline          (only while an approval is pending)
Stop Sharing  /  Resume Sharing    (one primary action for the current state)
Pair Another Device...             (secondary)
--------------------------------------------------
Settings...                        Cmd-,
Quit PocketDesk                    Cmd-Q
```

- Icon states (one SF Symbol each, template-rendered): ready, viewing, controlling, paused, attention (with a badge).
- The attention row names the exact fix ("Turn on Accessibility for PocketDesk...") instead of the current "View only · Grant access" note [C: HostMenuContent.swift:36-37].
- Do not rely on the icon staying visible; the system may hide it. HIG suggests a Dock menu as a second entry point [D]; add a Dock menu with Stop Sharing.
- Give people the choice to keep the menu bar icon during setup [D].

---

## 5. What users complain about in competitors, and how PocketDesk avoids it

Evidence quality: App Store text and aggregator review pages (single reviewers), Astropad's own release notes and help index, one press review. Web search surfaced no indexed Reddit threads to quote, so none are claimed. Vendor material is marked (V).

| # | Complaint | Source | How PocketDesk avoids it | Status |
|---|---|---|---|---|
| 1 | Device shows online, connection never starts, no error explains why (Workbench) | [W] Workbench App Store review; Astropad help lists "connection keeps dropping", "won't connect on 5G", "Mac not showing in list" | Reason-coded errors, "Can't connect?" checklist, presence on Home, Send Diagnostics | Not built |
| 2 | Copy and paste freezes the app (Workbench) | [W] App Store review; 1.3 notes fix clipboard sync | Ship explicit one-shot paste via `UIPasteControl` with size limits and timeouts; no background sync (PHONE-UX.md) | Not built |
| 3 | Screen sometimes fails to render; typing sometimes lost (Workbench) | [W] MacStories review | Existing freshness gating and acknowledged text delivery; add Refresh screen and host watchdog | Partly built |
| 4 | Unexpected logouts, account and 2FA friction (Workbench 1.3.1 fixes "unexpected logouts") | [W] App Store what's new; BENCHMARK doc | No account; trust stored in Keychain; test that pairing survives app updates and reinstall paths | Design advantage; test needed |
| 5 | Paywall surprises: features locked after buying (Jump), no real free trial and a forced subscription upgrade (Screens 5), free tier 30 min/day (Workbench) | [W] justuseapp review pages; App Store | Free on your own network; if remote is paid, show the paywall only at the moment someone leaves Wi-Fi, say why (relay costs), real introductory offer, never remove a shipped feature | Business decision open |
| 6 | Router, UPnP, double-NAT, "works on same Wi-Fi only" (Screens 5, Jump) | [W] justuseapp reviews | Own relay before charging; automatic fallback; never ask for ports; show Direct or Relayed | Relay not deployed |
| 7 | Cannot reach a sleeping Mac; FileVault blocks after reboot (Jump; Workbench help) | [W] reviews; Astropad help | Say so plainly; Open at login on; keep-awake option; do not recommend disabling FileVault | Copy and defaults |
| 8 | Black screen and unstable connections (RustDesk) | [W] justuseapp reviews | Refresh screen, reconnect-in-place, clear "waiting for picture" state | Not built |
| 9 | Pointer mapping wrong when the remote desktop is zoomed or cropped (Jump); two-finger gestures move the canvas instead of scrolling; double-click flaky (RustDesk) | [W] App Store and review pages | Relative pointer avoids absolute mapping errors; the gesture engine has single-owner arbitration and reads the host's double-click interval | Built; physical test pending |
| 10 | Keyboard: arrows dead, duplicate keys with Bluetooth keyboards (RustDesk); stuck Cmd or Caps (Jump support thread); iOS steals Cmd-Tab (Workbench) | [W] reviews; Jump support; Astropad help | Sticky modifier row exists; hardware keyboard adapter with release on disconnect and dedupe (section 3.8); document iOS-reserved shortcuts | iPad gap |
| 11 | Settings reset after reconnect, saved connections lost after updates, repeated password prompts (RustDesk) | [W] reviews | Persist viewport, sensitivity, haptics (partly done); upgrade-path test for Keychain trust | Partly built |
| 12 | No indicator that the screen is exposed to the room (Jump) | [W] review | Shield on inactive, Mac menu bar state, connect notification, always-reachable End | Mostly built |
| 13 | Resolution: Fluid without Retina (Jump); "why does my Mac look different" (Workbench help) | [W] review; help index | Sharper (2560 px cap) plus one plain sentence explaining Fill versus Fit and resolution | Built; copy needed |
| 14 | Users keep a backup remote app because the primary one is unreliable (MacStories on Workbench) | [W] MacStories | Do not claim reliability; measure and publish (BENCHMARK doc) | Ongoing |

---

## 6. Ranked top 15 (impact x effort)

Score = Impact x (6 - Effort). Impact 1-5, effort as defined at the top. Ties are broken by impact.

| Rank | Item | Fixes | I | E | Score | References |
|---|---|---|---|---|---|---|
| 1 | Plain-language errors plus a "Can't connect?" troubleshooter | F3.3, F5.4, F6.1-F6.4, F2.8 | 5 | 1 | 25 | [D: HIG Writing](https://developer.apple.com/design/human-interface-guidelines/writing), [Alerts](https://developer.apple.com/design/human-interface-guidelines/alerts), [Feedback](https://developer.apple.com/design/human-interface-guidelines/feedback). [M: Hue No Bridge found](https://mobbin.com/screens/33c875bb-1b3c-4e08-8457-64e04e1ba387), [Oura](https://mobbin.com/screens/f529277c-9371-4aec-8380-225d82941229), [Alexa](https://mobbin.com/screens/8c847f57-62d6-4d6b-b4ba-06ed4c89cd6f), [IKEA](https://mobbin.com/screens/079812f3-6162-489c-99c8-13a83f50accc), [Waymo offline](https://mobbin.com/screens/66ee96c8-a0e3-401b-a8d2-d7c80dbdaae7) |
| 2 | Pointer settle-halo, fixed size, with highlight and size settings | F4.1 | 5 | 2 | 20 | [D: HIG Motion](https://developer.apple.com/design/human-interface-guidelines/motion), [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility). [M: Xbox surface label](https://mobbin.com/screens/f29dc23d-69a0-4f4f-8914-fc4f6e2a4806) |
| 3 | Priming: Local Network (and mic/speech), Open Settings on denied camera, reworded usage string | F2.5, F2.6 | 4 | 1 | 20 | [D: HIG Privacy](https://developer.apple.com/design/human-interface-guidelines/privacy), [TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy). [M: Edits](https://mobbin.com/screens/4bce154c-bc90-4b02-87ab-02dc3b0fe523), [Family](https://mobbin.com/screens/fc99942c-5d52-40b7-9037-665288964a78) |
| 4 | Open at login default on; Ready page with live thumbnail and real checks; one app name | F1.3, F1.5, F1.6 | 4 | 2 | 16 | [D: HIG Onboarding](https://developer.apple.com/design/human-interface-guidelines/onboarding), [menu bar](https://developer.apple.com/design/human-interface-guidelines/the-menu-bar), [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice). [M: Alexa success](https://mobbin.com/screens/257edb9d-995b-4c40-9087-3ec9be08a8a9), [Withings](https://mobbin.com/screens/b5de7829-f383-4d7b-97d7-38c685afc7a9) |
| 5 | Pairing dead ends: scan feedback, auto-refreshing code, visible Copy code, merged permission page, hidden recovery paragraph | F0.2, F1.1, F1.2, F2.3, F2.4 | 4 | 2 | 16 | [M: Alexa QR scan with numeric fallback](https://mobbin.com/screens/d4db8f8f-f2b6-4852-8adf-bf2c7fb6fe7b), [Apple Home Add Accessory](https://mobbin.com/screens/e25145c0-7af1-4c26-9103-fd71e6566afd), [Telegram Link Desktop](https://mobbin.com/screens/d5905262-96e9-4793-b9c9-7d55b06c1379), [Octopus add device](https://mobbin.com/flows/1defac27-6b72-49b5-8ce0-f29228c1875b) |
| 6 | Interactive 20-second gesture coach on a practice pad; TipKit follow-ups; replay | F3.2, F4.2 | 5 | 3 | 15 | [D: HIG Onboarding](https://developer.apple.com/design/human-interface-guidelines/onboarding), [Gestures](https://developer.apple.com/design/human-interface-guidelines/gestures), [TipKit](https://developer.apple.com/documentation/tipkit). [M: Telegram](https://mobbin.com/screens/44cc1608-a319-4252-961b-26ee9db04dfa), [Polarsteps](https://mobbin.com/screens/705552aa-40c7-4c47-b67d-292ca45ad647), [Suno](https://mobbin.com/screens/df1739c2-14b9-4376-bd91-db5691eb1593) |
| 7 | Auto-reconnect on return; keep the session view through blips; persist viewport; Reconnecting pill | F5.2, F5.3, F6.4 | 5 | 3 | 15 | [D: HIG Multitasking](https://developer.apple.com/design/human-interface-guidelines/multitasking), [Going full screen](https://developer.apple.com/design/human-interface-guidelines/going-full-screen). [M: Google TV connect](https://mobbin.com/flows/f4a1c6f0-b7ae-427b-a896-b4f3c2535f41), [Sonos](https://mobbin.com/flows/8887a914-022d-483e-a280-e306103609a5) |
| 8 | Universal-link QR (Camera-scannable, smaller), Send to iPhone, App Store link for the phone app | F0.1, F2.1, F2.2 | 5 | 3 | 15 | [D: Supporting associated domains](https://developer.apple.com/documentation/xcode/supporting-associated-domains). [M: Canva remote QR plus copy link](https://mobbin.com/screens/968be409-0199-4ec1-80a0-9f82cef1e896), [Telegram Link Desktop](https://mobbin.com/screens/d5905262-96e9-4793-b9c9-7d55b06c1379) |
| 9 | Discoverable dock (peek, glass handle) plus compact action strip; Refresh screen; dock alignment | F3.1, F4.3, F4.5 | 4 | 3 | 12 | [D: HIG Going full screen](https://developer.apple.com/design/human-interface-guidelines/going-full-screen). [M: Google TV](https://mobbin.com/screens/7088a28e-ebad-46ed-9caa-ef55e6054924), [Roku](https://mobbin.com/screens/551701e2-93f4-463f-b977-1cb250f5c2cb), [SmartThings](https://mobbin.com/screens/54345414-2c0d-4376-8335-7a65a69df97f) |
| 10 | Home presence ("online, last seen"), then Bonjour direct connect | F5.1, F5.5 | 4 | 3 | 12 | [D: TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy). [M: Chime last seen](https://mobbin.com/screens/b19183d6-a104-447d-b598-8bfed52ec096), [Roku available on this network](https://mobbin.com/screens/078311ac-cb2b-4d3c-9863-0a43aef1d089), [Apple Home No Remote Access banner](https://mobbin.com/screens/0cce7995-97ac-4a4b-b60d-8ef61e3b7ea5) |
| 11 | Typing: live mode, auto-dismiss on focus loss, single-row landscape bar | F4.4, F4.5 | 4 | 3 | 12 | [D: HIG Keyboards](https://developer.apple.com/design/human-interface-guidelines/keyboards). [M: Roku keyboard access](https://mobbin.com/screens/551701e2-93f4-463f-b977-1cb250f5c2cb) |
| 12 | Screen Recording monthly re-approval: apply for Persistent Content Capture now; interim notification and phone message | F1.4 | 4 | 3 | 12 | [D: Persistent Content Capture entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.persistent-content-capture), [SCContentSharingPicker](https://developer.apple.com/documentation/screencapturekit/sccontentsharingpicker). [W: 9to5Mac](https://9to5mac.com/2024/08/14/macos-sequoia-screen-recording-prompt-monthly/) |
| 13 | Accessibility pass: VoiceOver direct interaction and pointer nudge actions, Dynamic Type on End, contrast on handle, haptic levels | 3.7 | 3 | 2 | 12 | [D: HIG Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility), [allowsDirectInteraction](https://developer.apple.com/documentation/uikit/uiaccessibilitytraits/allowsdirectinteraction), [Playing haptics](https://developer.apple.com/design/human-interface-guidelines/playing-haptics) |
| 14 | Dynamic zoom: zoom badge and mini indicator now; keyboard-aware framing; caret-follow later | F4.7, 3.3 | 4 | 4 | 8 | [D: HIG Motion](https://developer.apple.com/design/human-interface-guidelines/motion). PHONE-UX.md staged plan |
| 15 | iPad hardware keyboard and pointer; verify multitasking shield; optional Direct touch | 3.8 | 4 | 4 | 8 | [D: HIG Multitasking](https://developer.apple.com/design/human-interface-guidelines/multitasking), [Keyboards](https://developer.apple.com/design/human-interface-guidelines/keyboards). [W: Workbench input help](https://support.astropad.com/en/articles/14025802-mouse-keyboard-and-input-in-workbench) |

Just outside the list: multi-device management (iPhone plus iPad, score 6), Live Activity with End (6), and the **north star**, same-Apple-Account pairing (option E, score 5 because of effort, but the biggest "just works" step available).

**Suggested sequencing**

- Start now, in parallel with everything: the Persistent Content Capture entitlement request (Apple's lead time is outside our control) and the associated domain plus AASA for the universal link.
- Sprint 1 (about a week): ranks 1, 3, 4, 5 and the halo (rank 2). All mostly copy, defaults and small views.
- Sprint 2: ranks 6, 7, 8 (coach, reconnect, universal link).
- Sprint 3: ranks 9, 10, 11, 12, 13.
- After that: 14, 15, then decide on option E from measured pairing drop-off.

**Decisions Roshan should make**: whether to keep Fill as the first-view default (it is his earlier choice; the audit only adds explanation); keep the heavy haptic as the default (his request; the audit only adds levels); compose versus live typing default; whether a one-time paywall moment is acceptable for remote access.

---

## 7. Reference index

**Apple HIG** (text read from Apple's HIG data endpoint on 28 Sep 2026): [Onboarding](https://developer.apple.com/design/human-interface-guidelines/onboarding), [Privacy](https://developer.apple.com/design/human-interface-guidelines/privacy), [Gestures](https://developer.apple.com/design/human-interface-guidelines/gestures), [Playing haptics](https://developer.apple.com/design/human-interface-guidelines/playing-haptics), [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility), [Motion](https://developer.apple.com/design/human-interface-guidelines/motion), [Materials (Liquid Glass)](https://developer.apple.com/design/human-interface-guidelines/materials), [Keyboards](https://developer.apple.com/design/human-interface-guidelines/keyboards), [Multitasking](https://developer.apple.com/design/human-interface-guidelines/multitasking), [Going full screen](https://developer.apple.com/design/human-interface-guidelines/going-full-screen), [The menu bar (menu bar extras)](https://developer.apple.com/design/human-interface-guidelines/the-menu-bar), [Alerts](https://developer.apple.com/design/human-interface-guidelines/alerts), [Feedback](https://developer.apple.com/design/human-interface-guidelines/feedback), [Writing](https://developer.apple.com/design/human-interface-guidelines/writing).

**Apple documentation:** [TN3179 local network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy); [Persistent Content Capture](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.persistent-content-capture); [SCContentSharingPicker](https://developer.apple.com/documentation/screencapturekit/sccontentsharingpicker); [CKRecord.encryptedValues](https://developer.apple.com/documentation/cloudkit/ckrecord/encryptedvalues); [Wi-Fi Aware](https://developer.apple.com/documentation/wifiaware); [DeviceDiscoveryUI](https://developer.apple.com/documentation/devicediscoveryui); [AccessorySetupKit](https://developer.apple.com/documentation/accessorysetupkit); [Supporting associated domains](https://developer.apple.com/documentation/xcode/supporting-associated-domains); [TipKit](https://developer.apple.com/documentation/tipkit); [NSUserActivity.userInfo](https://developer.apple.com/documentation/foundation/nsuseractivity/userinfo); [allowsDirectInteraction](https://developer.apple.com/documentation/uikit/uiaccessibilitytraits/allowsdirectinteraction). Apple support: [Universal Control](https://support.apple.com/en-us/102459), [Sidecar](https://support.apple.com/en-us/102597), [Screen Sharing in Messages](https://support.apple.com/guide/messages/share-screens-icht11883/mac).

**Mobbin** (screens and flows viewed; iOS only): pairing and add-device: [Alexa scan QR flow](https://mobbin.com/flows/5dc6e5b3-7f1e-463a-8aa6-669f1ee007fd), [Apple Home Add Accessory](https://mobbin.com/screens/e25145c0-7af1-4c26-9103-fd71e6566afd), [Dyson add product](https://mobbin.com/flows/ba6475d7-af6b-4dc7-8438-1cc0680cd37d), [Octopus add device](https://mobbin.com/flows/1defac27-6b72-49b5-8ce0-f29228c1875b), [Hue add device](https://mobbin.com/flows/8d39b393-01f5-43dd-a59f-f9d6eb1b3a9b), [Sonos add speaker](https://mobbin.com/flows/8887a914-022d-483e-a280-e306103609a5), [Google TV connect](https://mobbin.com/flows/f4a1c6f0-b7ae-427b-a896-b4f3c2535f41). Remote controls: [Google TV](https://mobbin.com/screens/7088a28e-ebad-46ed-9caa-ef55e6054924), [SmartThings](https://mobbin.com/screens/54345414-2c0d-4376-8335-7a65a69df97f), [Roku](https://mobbin.com/screens/551701e2-93f4-463f-b977-1cb250f5c2cb), [Xbox](https://mobbin.com/screens/f29dc23d-69a0-4f4f-8914-fc4f6e2a4806), [Canva](https://mobbin.com/screens/968be409-0199-4ec1-80a0-9f82cef1e896), [ChatGPT connections to a Mac](https://mobbin.com/screens/e3212fcd-5143-412d-bbb2-27aeea9184e8). Permission priming: [Edits](https://mobbin.com/screens/4bce154c-bc90-4b02-87ab-02dc3b0fe523), [Family](https://mobbin.com/screens/fc99942c-5d52-40b7-9037-665288964a78), [Lapse](https://mobbin.com/screens/7e43fdbb-28e7-4e71-8a1b-5341de2be89a), [Turo](https://mobbin.com/screens/64b7b165-5876-45f1-ba60-02a665c1f123). Gesture coaching: [Telegram](https://mobbin.com/screens/44cc1608-a319-4252-961b-26ee9db04dfa), [Polarsteps](https://mobbin.com/screens/705552aa-40c7-4c47-b67d-292ca45ad647), [Suno](https://mobbin.com/screens/df1739c2-14b9-4376-bd91-db5691eb1593), [Reddit](https://mobbin.com/screens/3df8b28b-9ede-49e9-ac59-8e7805aa5e50), [TikTok](https://mobbin.com/screens/70fe8052-9db7-4321-9c6d-51d70e362c2e). Errors and empty states: [Waymo](https://mobbin.com/screens/66ee96c8-a0e3-401b-a8d2-d7c80dbdaae7), [GoPay](https://mobbin.com/screens/95483b32-a4d7-4025-b6e7-64220245eff5), [Noom](https://mobbin.com/screens/2419210e-0800-41b0-b0ce-d45c385858cc), [Hatch](https://mobbin.com/screens/50415435-978b-4734-88ab-16fa725bc82a), [Grab diagnostics](https://mobbin.com/screens/f21cc30a-b0e8-4c8e-9de8-3a829706255c), [Eight Sleep](https://mobbin.com/screens/bb976239-e92e-4ab6-bc78-d1e5a7e57607). Devices and status: [Chime My devices](https://mobbin.com/screens/b19183d6-a104-447d-b598-8bfed52ec096), [Roku connect](https://mobbin.com/screens/078311ac-cb2b-4d3c-9863-0a43aef1d089), [Xbox device](https://mobbin.com/screens/635edb13-a99a-4990-9f5b-7f19afe118f0), [Telegram devices](https://mobbin.com/screens/d5905262-96e9-4793-b9c9-7d55b06c1379), [Apple Home No Remote Access](https://mobbin.com/screens/0cce7995-97ac-4a4b-b60d-8ef61e3b7ea5).

**Competitor and platform sources:** [Astropad Workbench App Store](https://apps.apple.com/us/app/astropad-workbench/id6758788573); [Workbench 1.3 notes](https://astropad.com/blog/workbench-1-3/) (V); [Workbench help index](https://support.astropad.com/en/collections/18710933-workbench); [Workbench iPhone setup](https://support.astropad.com/en/articles/14025859-setting-up-workbench-on-your-ipad-iphone); [Workbench input](https://support.astropad.com/en/articles/14025802-mouse-keyboard-and-input-in-workbench); [Workbench remote access setup](https://support.astropad.com/en/articles/14010461-setting-up-your-mac-for-remote-access); [MacStories on Workbench](https://www.macstories.net/reviews/astropad-workbench-rethinks-remote-mac-control-for-ai-agents/); [Jump Desktop reviews (aggregator)](https://justuseapp.com/en/app/364876095/jump-desktop-rdp-vnc-fluid/reviews); [Screens 5 reviews (aggregator)](https://justuseapp.com/en/app/1663047912/screens-5-vnc-remote-desktop/reviews); [RustDesk iOS reviews (aggregator)](https://justuseapp.com/en/app/1581225015/rustdesk-remote-desktop/reviews); [Remote Mac Desktop Control App Store](https://apps.apple.com/us/app/remote-mac-desktop-control/id6790186904); [9to5Mac on Sequoia's monthly prompt](https://9to5mac.com/2024/08/14/macos-sequoia-screen-recording-prompt-monthly/).

---

## 8. Verification plan and limits

**Not verified in this audit**
- No physical-device behaviour. Every gesture, haptic, keyboard and multitasking statement is from code or docs. [U] items above need a device.
- Camera-app and Control Center handling of a universal-link QR. Apple's docs establish universal links; the exact banner behaviour was not confirmed here.
- Whether the Persistent Content Capture entitlement removes the monthly Screen Recording prompt for this app type. The doc gives its purpose and the request form, not that outcome.
- The iPad `.inactive` behaviour in Split View and Stage Manager.
- VoiceOver interception of the trackpad element.
- Competitor apps were not run hands-on. Their complaints come from reviews and vendor pages; treat them as directions to test, not as statistics.
- Reddit: web search returned no indexed threads; none are cited.
- Mobbin has no macOS catalogue, so the Mac recommendations rest on iOS analogues, Apple's HIG and Apple's own Mac features.

**Measure before and after each sprint** (three participants who have never seen the app, per PHONE-UX.md's proposed sample; qualitative, not population evidence)
1. Time from launching the Mac app to first successful click on the phone; number of taps and of OS dialogs.
2. Pairing drop-off: code expired, wrong code scanned, camera denied, Local Network denied.
3. Time to find the pointer after the first move; time to open the keyboard; time to right-click without help.
4. After returning from another app for 30 s: time back at the desktop with the previous zoom.
5. Error comprehension: show three failure screens and ask "what would you do now?".
6. VoiceOver run of pairing, connect and a click; largest Dynamic Type run of Home, Pair, coach and Controls.
