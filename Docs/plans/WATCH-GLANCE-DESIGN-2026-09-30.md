# Watch glance — design spec

30 September 2026, revision 1. Status: **approved 30 Sep 2026 (see Decisions); Phase 1 and the session `.small` layout built on branch `farside-watch-glance` (see Amendments).** Labels: **[V]** verified in source or Apple docs today; **[I]** inferred; **[U]** unverified, needs a device.

## 1. What Roshan asked for

- "Agent needs you" alerts (D29, `PRODUCT.md:124`) on the wrist, plus Mac status: awake or online, battery, last reached.
- Tapping hands off to the iPhone. The Watch **never** approves an agent action and never controls the Mac.
- Brainstorm sizing: medium, reusing the alert and vitals data.

Why: the alert exists to reach someone who is away from the phone. A wrist tap does that better than a pocketed phone, and the Mac line answers "should I bother getting up?"

## 2. Options compared

| # | What the user sees | Code / targets | Effort | Depends on |
|---|---|---|---|---|
| A | Existing alerts forwarded to the Watch: short look, long look with Snooze / Not now | None new. Copy and category-order tweaks | 0.5–1 d | Local twin works now; remote alerts need live APNs |
| B | A, plus Live Activities in the Smart Stack with a custom `.small` layout: session (exists) and agent run (LA2). Mac line shown only while an activity runs | `.supplementalActivityFamilies([.small])` in the existing `FarsideWidgets` extension | +2–3 d | LA2 for agent glance; host presence and vitals for the Mac line |
| C | iPhone control ("Check my Mac") in Watch Control Center / Smart Stack | Control in existing extension | 2–3 d | Docs conflict (below); not recommended |
| D | Always-on Mac status complication and Smart Stack widget | **New watchOS app target + watchOS widget extension**, WatchConnectivity, signing, Watch App Store screenshots | +6–9 d | W1 host presence, B |

A full Watch app (alert inbox, history) is rejected: 12+ days for nothing A+B lacks.

Facts behind the table:
- Notifications from an iOS app, local or remote, go to the Watch when the iPhone is locked or its screen is off and the Watch is on the wrist and unlocked. Otherwise they go to the iPhone [V, [notification forwarding](https://developer.apple.com/documentation/watchos-apps/taking-advantage-of-notification-forwarding)]. The iPhone app's notification categories supply the Watch action buttons [V, HIG Notifications › watchOS].
- iPhone Live Activities appear at the top of the Watch Smart Stack automatically. By default they combine the compact leading and trailing views. `ActivityFamily.small` opts in to a custom Watch layout [V, [ActivityFamily](https://developer.apple.com/documentation/widgetkit/activityfamily), HIG Live Activities › watchOS]. With no Watch app, a tap opens a full-screen view with a button to open the app on iPhone [V, HIG; [Launching your app from a Live Activity](https://developer.apple.com/documentation/activitykit/launching-your-app-from-a-live-activity)]. The same `.small` layout is used in CarPlay, where buttons are deactivated [V].
- iPhone system widgets never appear on the Watch. "To offer watch complications and watchOS widgets, create a watchOS app" [V, [WidgetKit strategy](https://developer.apple.com/documentation/widgetkit/developing-a-widgetkit-strategy)]. **So an always-visible Mac status requires option D.**
- On controls, Apple's docs conflict. The WidgetKit strategy page says controls from a paired iPhone appear on the Watch, but the Controls page of the HIG says "Not supported in watchOS" [V, both]. Option C is out until a device settles it.

**Recommendation: A now, B next, D only if Roshan wants status on the wrist when no session or agent run is active (Q2).** A+B adds no targets, entitlements or App Store assets, and matches the "medium" sizing.

## 3. UX (recommended A + B)

Reach style (`PRODUCT.md:127`, `RemoteShared/FarsideTheme.swift:7-17`): `void` background, `bone` primary text and `ash` secondary text in SF Pro, times in SF Mono. **No ember**: needs-you is not contact (`design/FARSIDE-DESIGN-SYSTEM.md:29`). Watch faces may tint or invert colour, so meaning is carried by words and glyphs, never colour (HIG Widgets [V]).

**Notification (A).**
- Short look: app icon plus the title `Claude Code needs you` (or `An agent needs you` when the name is off; `Backend/src/push.ts:143`). The title is agent kind only, as the HIG asks for short looks [V].
- Long look: title, body, then **Snooze 15 min**, **Not now** and the system Dismiss.
- Change the body at `RemotePhone/Localizable.strings:5` from "…Tap to look at your Mac." to **"Stuck on something only a human can click. Open Farside on your iPhone to look."** On the wrist, "Tap" leads nowhere. The phone reads fine either way.
- Double Tap (Series 9 / Ultra 2) runs the first nondestructive action [V, watchOS updates]. That is Snooze, because of the order `[snooze, notNow]` at `RemotePhone/SystemIntegrations/AgentNotifications.swift:74`. Keep this order and lock it with a test, so an accidental pinch only snoozes.
- Not now declines: the agent is told the human declined (`AgentAlertCenter.swift:305-311`). This is not approval and does not touch the Mac, so it may stay on the wrist. An iPhone app cannot hide an action per device [I].

**Smart Stack `.small` layouts (B).** Size: 152×69.5 pt (40 mm) to 191×81.5 pt (49 mm) [V, HIG]. No buttons (CarPlay would disable them anyway, and the Watch never acts). Three lines at most:

| Activity / phase | Line 1 (bone, semibold) | Line 2 (ash, mono) | Line 3 (ash, only with presence data) |
|---|---|---|---|
| Session live | `Live · Your Mac` | elapsed `12:04` (`Text(timerInterval:)`) | `End it on your iPhone.` |
| Session paused | `Paused` | `Lets go in 0:42` | — |
| Agent needs_you | `Claude Code needs you` | `Waiting 2:14` | `Your Mac · seen 1 min ago · 64%` |
| Agent working | `Agent at work` | `12 min · nothing needs you` | Mac line |
| Agent human_active | `You have the wheel` | `On your iPhone` | — |
| Agent expired | `Request expired` | `Nothing was sent to your Mac.` | — |
| Stale (any) | unchanged | unchanged | `Not seen since 11:42` |

Leading glyph: `FarsideMarkGlyph` (`FarsideWidgets/SessionLiveActivity.swift:32`) in bone. Needs-you adds a hollow ring. There is no pulse on Always-On or with Reduce Motion (`isLuminanceReduced` is already used at `:251`).

**Tap.** The system full-screen view appears, then **Open on iPhone**. That opens the existing universal link (`widgetURL`, `SessionLiveActivity.swift:18,42`) to the session or the `HelpRequestSheet`. Connecting stays a separate choice on the phone.

## 4. Data flow, freshness, privacy

- **Alerts.** The server's APNs push (`push.ts:141-158`: loc keys, allow-listed agent name, `hid`, pairing identity) reaches the iPhone, which forwards it. The local twin raised during a backgrounded session (`AgentAlertCenter.swift:344-360`) forwards too [V, forwarding table].
- **Live Activity state.** Live Activities have no network [V], so Mac fields must arrive in content-state. Add optional plain fields to LA2's state (wire rules as `FarsideSessionAttributes.swift:6-9`): `macState` (`awake`|`asleep`|`notSeen`), `macSeenUnix`, `batteryPercent?`, `power?` (names match `MAC-VITALS-DESIGN-2026-09-30.md`). Push at priority 5 only on a state change or a 20 %/10 % battery crossing; `staleDate = macSeenUnix + 10 min`.
- **Honesty** (as `MacStatusService.swift:5-7`, `SYSTEM-INTEGRATIONS.md:151`): never "Awake" without "seen … ago"; `isStale` shows "Not seen since HH:MM"; "Asleep" only if the host announced it. The host observes `willSleep` (`RemoteHost/HostModel.swift:333`) but reports nothing to the service today [V: no presence in `Backend/src`]. No battery → omit it, never "0 %".
- **Last reached** is phone-local in `UserDefaults.standard` (`PairedMacs.swift:38-41`, `HomeView.swift:92`), and there is no App Group [V: `RemotePhone/Farside.entitlements`], so no extension can read it. B uses the service's "seen" time; D would send the phone's value over WatchConnectivity.
- **Privacy.** A watch face is as public as a Lock Screen: no prompt text, file names, screen content or latency, and the Mac name only if "Show Mac name on Lock Screen" is on (`AgentNotifications.swift:40-44`). Keep `privacySensitive()` (`SessionLiveActivity.swift:127`) and the hidden-preview placeholder (`AgentNotifications.swift:61`) [I on Watch]. D puts no pairing credentials on the Watch.

## 5. Dependencies and order

1. **APNs live** for remote alerts. Provider credentials are absent (`Docs/launch/CURRENT-REVIEW-PACKET.md:39`) and Debug push is off (`project.yml:98-104`). A's copy and ordering can land first.
2. **Session `.small`**: only the existing activity (`FarsideWidgetsBundle.swift:7`); this is LA3 (`SYSTEM-INTEGRATIONS.md:30`).
3. **Agent glance**: LA2 (8–12 d, 1.1); no `FarsideAgentAttributes` in source [V].
4. **Mac line**: host presence and sleep/wake reporting (W1/E7, 5–7 d) plus Mac Vitals (`Docs/plans/MAC-VITALS-DESIGN-2026-09-30.md`, draft) for battery. Its vitals reach the phone only during a session; getting them out of session depends on its service question (Q3). The host reads no battery today [V: no IOPS use in `RemoteHost`/`RemoteShared`].
5. **D**: all of the above, Watch targets, App Store Connect Watch screenshots and review [I].

## 6. Edge cases

| Case | Behaviour |
|---|---|
| iPhone unlocked, or Watch off the wrist | Alert on the phone only [V] |
| Session app in the foreground | In-app banner, no notification (`AgentAlertCenter.swift:268-275`), so nothing on the Watch |
| iPad-only alert address | No Watch: a Watch pairs with an iPhone [I] |
| Ended activity | Stays in the Smart Stack up to 4 h [V]. Set a dismissal: session 2 min, agent per the LA2 table |
| Host silent / lost end push | `isStale` wording, never "Awake" |
| Pairing replaced | Old alert opens but cannot snooze or report (`AgentAlertCenter.swift:282-288`) |
| Two agents | One activity that ticks between them (LA2 rule) |
| Desktop Mac, no battery | Omit battery |
| Focus / Time Sensitive | Assumed to mirror the iPhone [U]; spike S-NOTIF-1/2 (`SYSTEM-INTEGRATIONS.md:748-749`) |

## 7. Testing

- **Automated.** Snapshots of the `.small` views at all five Watch sizes; copy per phase; stale never renders "Awake"; nil battery omitted; old state payloads still decode with the new optional fields; Snooze is the first action.
- **Simulator.** Paired iPhone + Apple Watch simulators (Xcode 27). Whether they forward notifications or Live Activities is **[U]**, so results are indicative only. Never run them during shared-Mac builds.
- **Physical.** **Watch availability is unknown; without one, all wrist behaviour stays unverified.** Check: locked phone with the Watch worn (test alert, then a real push); unlocked phone; Work Focus with and without Time Sensitive; hidden previews; Double Tap snoozes; Not now reaches the service; Smart Stack tap → Open on iPhone → sheet; cutting the host's network makes the line stale.
- **Test alert delay.** "Send test alert" fires after 1 s (`AgentAlertCenter.swift:255`), too soon to lock the phone. Add a 10 s variant labelled `Send test alert in 10 s — lock your iPhone to see it on your Watch.`

## 8. Size and order

- **Phase 1 (A):** 0.5–1 d. Body copy, order test, 10 s test alert, Watch check. Can ship with D29 in 1.0 once APNs is live.
- **Phase 2 (B):** 2–3 d. Session `.small` (1–1.5 d) now; agent `.small` (1 d) with LA2 in 1.1; Mac line (0.5 d) once presence and vitals exist.
- **Phase 3 (D):** 6–9 d plus store assets, and only on a yes to Q2. Not a 3 November gate.

## 9. Open questions for Roshan

1. **Do you own an Apple Watch paired to your test iPhone?** (a) Yes, Series 9 / Ultra 2 or later on watchOS 26+. (b) Yes, older. (c) No. *Recommendation: if (c), build only A+B (no Watch code) and mark wrist behaviour unverified until one is borrowed.*
2. **Mac status on the wrist when no session or agent run is active?** (a) No: status only inside Live Activities (A+B). (b) Yes: add a minimal Watch app with one complication and Smart Stack widget (D, +6–9 d, after W1). (c) Alerts only, no Mac line. *Recommendation: (a).*
3. **An End session button in the Watch session layout?** (a) No buttons on the wrist. (b) End only, as a kill switch. *Recommendation: (a). It keeps the "never controls" rule, and CarPlay shares the layout.*
4. **Timing?** (a) Phase 1 with the D29 beta in 1.0, Phase 2 in 1.1. (b) Everything in 1.1. (c) Everything before launch. *Recommendation: (a).*

## Decisions — 30 September 2026

Roshan approved this design and every recommended answer to the open questions above ("Sounds good … go ahead"). Implementation is authorized on a feature branch; no install, merge into `pocketdesk-remote-chat`, deployment or submission without his separate go-ahead.
Watch ownership (question 1) was not answered: treat as "no Watch available", build the no-Watch-app options, and mark all on-wrist behaviour unverified.

## Amendments — 30 September 2026 (implementation)

Made while planning the build (`Docs/plans/WATCH-GLANCE-IMPLEMENTATION-PLAN-2026-09-30.md`). They change wording and layout detail only; the approved scope and every answer above stand.

1. **Session stale in `.small`.** The session activity carries no Mac seen time, so the stale row's line 3 cannot exist for it. A stale session shows `Session ended?` / `Check your iPhone.`, matching the Lock Screen's existing "Session ended?", and never a live title or a running clock.
2. **Session phases the §3 table omits** get short copy: reconnecting `Reconnecting` / `Hold on.`; ended by the person `Session ended` / `Mac handed back.`; timeout `Farside let go` / `You were away.`; stopped at the Mac `Sharing stopped` / `Stopped at the Mac.`; error `Session ended` / `Nothing left open.`; paused with no time left `Paused` / `Lets go soon.`. The sample preview's line 3 is `Sample · preview`.
3. **Mac line wording.** `Mac · seen 11:41 · 64%`, not `Your Mac · seen 1 min ago · 64%`. A Live Activity redraws only on an update, and LA2 updates only on a state change, so "1 min ago" would freeze and become false; an absolute time never does, and matches `Not seen since 11:42`. "Mac" rather than the Mac label keeps the line inside 40 mm and matches the Mac vitals spec's `Mac · …` lines. Asleep reads `Mac · asleep since 11:40`, with no battery. Times use the locale's hour format (24-hour where the locale uses it) with a narrow am/pm marker in 12-hour locales, so en_US reads `Mac · seen 12:59 p · 100%` (ICU puts a narrow no-break space, U+202F, before the marker): the default `12:59 PM` pushes that line past the 40 mm width at the 0.85× minimum.
4. **Times** use SF Pro with monospaced digits, as the existing `SessionClock` does, not SF Mono: SF Mono's `Lets go in 0:42` does not fit 40 mm.
5. **No pulse at all** in `.small`. §3 already forbids it on Always-On and with Reduce Motion; none is simpler and loses nothing on a glance.
6. **Fit findings for LA2** (not built here): at 40 mm, `Claude Code needs you` does not fit the title width even at the 0.7× minimum (`An agent needs you` does), and `12 min · nothing needs you` and `Nothing was sent to your Mac.` do not fit one line at any allowed scale. LA2 must shorten them or let its title wrap; the layout's fit tests are the check to use.
7. **Mac presence fields** are modelled now as `MacPresence` (every field optional; an unknown state decodes as not seen, because a state that fails to decode silently stops a Live Activity updating) so LA2 can carry them. No existing activity carries them, so nothing shows a Mac line yet.
8. **Dismissal.** The existing ended-session dismissal (6 s after End, 90 s otherwise, `RemotePhone/ActivityShared/EndSessionIntent.swift:39-41`) is already shorter than the 2 min in §6, so it stays.
9. **An opted-in Mac name can overflow the title.** When the person chose to show their Mac's name, `Live · <macLabel>` can exceed the 40 mm title width. It scales down to the 0.7× minimum and then truncates with an ellipsis; that is accepted, because the name is the person's own choice and the detail and note lines still say what matters.
10. **The Mac's name on the wrist is redactable.** The Lock Screen only shows an opted-in Mac name in its `privacySensitive` line, never in the title. The Watch keeps that: the title is `Live`, and ` · <macLabel>` is drawn as a separate `privacySensitive` suffix (`WatchGlance.sensitiveTitleSuffix`), so it is redacted wherever the Lock Screen's line would be.
11. **Presence decoding is tolerant per field.** A `MacPresence` field of the wrong type (a string seen time, a fractional battery) decodes as absent instead of failing the whole Live Activity state.
