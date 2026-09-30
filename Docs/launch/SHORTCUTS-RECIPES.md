# Farside agent alerts: Shortcuts recipes

30 September 2026. Docs only: no app code, no server work, nothing ships in the binary. These are for the support page, the website and the review notes' "what alerts do" answer.

## Which iOS

**iOS 27 or later.** The Shortcuts *Notification* automation trigger is new in iOS 27.

- Apple's Shortcuts User Guide for iOS 27 lists it under event triggers. It offers two options: "App", the app the notification comes from, and "Add Filter", which filters on "the Message, Subtitle, or Title". The iOS 26 edition of the same page has no Notification trigger. Both editions were checked on 30 Sep 2026: [iOS 27](https://support.apple.com/guide/shortcuts/event-triggers-apd932ff833f/10.0/ios/27), [iOS 26](https://support.apple.com/guide/shortcuts/event-triggers-apd932ff833f/9.0/ios/26).
- The WWDC26 session [What's new in Shortcuts](https://developer.apple.com/videos/play/wwdc2026/310/) introduces the trigger with the words "In iOS 26". That session shipped with the iOS 27 SDK, and the versioned guide shows no trigger on 26. Treat the "26" as a slip, and confirm on a real iOS 27 device before publishing (see the unverified list below).

Farside itself supports iOS 26. On 26, alerts work as before and these recipes simply aren't available.

## What to match on

Every Farside agent alert has the same fixed text. It never contains an agent's or product's name, a prompt, or anything from the Mac's screen (`RemotePhone/en.lproj/Localizable.strings`, Guideline 4.5.4):

| Alert | Title | Message |
|---|---|---|
| A task needs you | **A task on your Mac needs you** | Stuck on something only a human can click. Tap to look at your Mac. |
| Reminder after Snooze | A task on your Mac needs you | Still waiting on you. |
| Settings › Send test alert | A task on your Mac needs you | This is a test. Nothing on your Mac is stuck. |

The title is a stable contract: treat a change to `AGENT_NEEDS_YOU_TITLE` as a breaking change for users' automations, and say so in release notes if it ever changes.

- **Every alert:** App = Farside, filter Title contains `needs you`.
- **Only fresh requests, not reminders or tests:** App = Farside, filter Message contains `only a human can click`.
- If **Show Previews** is set to *Never* for Farside, iOS shows the title and replaces the message with "Tap to look at your Mac." Match on the title in that case. (Whether the automation sees the real message is not documented [I].)

In each recipe, turn on **Run Immediately** in the automation's settings. Otherwise iOS asks before running it.

## Recipes

### 1. Turn on a Focus when a task needs you

Use this to silence everything else while you deal with the Mac.

1. Shortcuts › Automation › **+** › **Notification**.
2. App: **Farside**. Add Filter › Title contains `needs you`.
3. Action: **Set Focus** › choose a Focus (for example Work) › turn On, Until Turned Off.
4. Run Immediately: on.

Let Farside through that Focus: Settings › Focus › (that Focus) › Apps › add Farside. Or turn on **Break through Focus** in Farside › Alerts & Lock Screen, which uses Time Sensitive delivery.

### 2. Flash a HomeKit light

1. New Notification automation. App: **Farside**. Filter: Message contains `only a human can click`.
2. Actions:
   - **Repeat** 3 times:
     - **Control Home** › your lamp › turn On (for a colour bulb, choose a colour such as red).
     - **Wait** 1 second.
     - **Control Home** › your lamp › turn Off.
     - **Wait** 1 second.
3. Run Immediately: on.

To leave the light on instead of flashing it, use a single Control Home action or a scene ("Mac needs me"). HomeKit actions need a home hub for automations to run while the phone is locked [I].

### 3. Play a sound

1. New Notification automation. App: **Farside**. Filter: Title contains `needs you`.
2. Actions:
   - **Set Volume** 60%.
   - **Play Sound** › choose an audio file from Files.
3. Run Immediately: on.

The alert already plays the standard sound unless the phone is silenced. This recipe is for a louder or distinctive cue, for example through a HomePod ("Play Sound" on the phone; use **Set Playback Destination** first to route it).

### 4. Say it out loud

This helps with AirPods, CarPlay or a phone face-down on a desk.

1. New Notification automation. App: **Farside**. Filter: Message contains `only a human can click`.
2. Action: **Speak Text** › "A task on your Mac needs you."
3. Run Immediately: on.

## Boundaries (keep these true in copy)

- An automation reacts to the alert. It cannot approve anything or open a session. Tapping the alert still asks the person to connect, and Farside never approves an agent action.
- No Farside App Intent is involved and no server work is needed. The alert itself is the trigger.
- Don't name AI products in the recipe copy, screenshots or website examples (Guideline 4.2.7 generic mirror, 5.2 trademarks). Say "a coding agent" or "a task on your Mac".

## Unverified until tried on a device [I]

- That the trigger fires for Farside's alert on iOS 27 with Run Immediately, while the phone is locked, and under a Focus that silences Farside.
- Exact action names in the iOS 27 Shortcuts editor (Set Focus, Control Home, Play Sound, Speak Text, Set Playback Destination).
- Whether a filter sees the real message when previews are hidden.
