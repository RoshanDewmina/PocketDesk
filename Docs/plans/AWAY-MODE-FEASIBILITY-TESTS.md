# Away mode — feasibility tests S1 and S2 (for Roshan)

30 September 2026. Spec: `Docs/plans/AWAY-MODE-DESIGN-2026-09-30.md` (§3, §8 and the Decisions section).
Only you run these. They idle or lock the Mac, so no agent may run them; agents only type-check the scripts.

## Why

Away mode ships in 1.0 only if **S1a and S2 pass by about 10 October** (decision A1). If either fails,
or there is no time to run them, 1.0 keeps the fallback: the "needs your Mac awake and unlocked" copy and
the "your Mac locked while sharing" warning, and Away mode moves to 1.1.

- **S1** asks: while Farside holds the same two power assertions Away mode holds when armed, does macOS
  still lock the Mac when nobody touches it?
- **S2** asks: when Farside posts the system Lock Screen shortcut (Control-Command-Q), does the Mac lock,
  and does macOS report it locked within 2 seconds?

## Before you start

1. Pick a quiet time. S1 needs about 30 minutes per run with nobody touching the Mac.
2. Save your work and close anything that would mind the Mac locking.
3. Write down your current settings in **System Settings → Lock Screen** so you can put them back:
   - "Start Screen Saver when inactive": ______
   - "Turn display off on battery when inactive": ______
   - "Turn display off on power adapter when inactive": ______
   - "Require password after screen saver begins or display is turned off": ______
4. Plug the Mac into power.
5. Quit Farside's host (menu bar icon → Quit) so it does not hold its own assertions during the test.
   Also quit anything else that keeps the Mac awake (Amphetamine, `caffeinate`, a playing video).
   Optional check: `pmset -g assertions` should show no other app preventing display sleep.
6. Keep your phone away from the Mac and do not connect to it with Farside.
7. Run every command from the repository root in Terminal (or your usual terminal app). The first run
   takes a few seconds to compile. Each script waits for you to type a word; nothing happens until you do.

## S1a — required

**Settings:** screen saver **Never**, display off (on power adapter) **2 minutes**, require password **Immediately**.

```sh
swift script/away-feasibility/away-hold-and-watch.swift --minutes 30
```

Type `HOLD`, press Return, and walk away. Do not touch the keyboard, mouse or trackpad for 30 minutes.
When you come back, read the last lines (the Mac may be locked; unlock it as usual first).

- **Pass:** `S1 RESULT: NOT LOCKED during 30 min`.
- **Fail:** `S1 RESULT: LOCKED after X s (screensaver=…)`.
- `S1 RESULT: INCOMPLETE …` means it was stopped early (Control-C or terminated); run it again.

## S1b — informs the A4 copy, not a blocker

Same as S1a, but set the screen saver to **2 minutes** (display off 2 minutes, password Immediately).

```sh
swift script/away-feasibility/away-hold-and-watch.swift --minutes 30
```

Record LOCKED or NOT LOCKED and whether `screensaver=true` appears in any line.
Expected: the screen saver starts and the Mac locks. Away mode then detects it and explains it at the Mac
with a link to Lock Screen settings (decision A4). That is the planned behaviour, not a failure.

## S1c — record only

S1b settings, plus a periodic "someone is active" declaration every 60 seconds:

```sh
swift script/away-feasibility/away-hold-and-watch.swift --minutes 30 --declare-activity-every 60
```

Record the result. Option B (declaring activity to hold off the screen saver) was not chosen; this run is
only so we know.

## S2 — required

1. Give your terminal app Accessibility for this test: **System Settings → Privacy & Security →
   Accessibility**, add Terminal (or iTerm, Ghostty, whichever you run the command in). Without it
   macOS drops the shortcut; the script says so and exits without posting anything.
2. Run:

   ```sh
   swift script/away-feasibility/away-lock-probe.swift
   ```

3. Type `LOCK` and press Return. Keep your hands off the keyboard and trackpad during the 5-second
   countdown. The Mac should lock.
4. Unlock it with your password as usual and read the result in the terminal.

- **Pass:** `S2 RESULT: LOCKED in X ms` with X under 2000.
- **Fail:** `S2 RESULT: NOT LOCKED within 2 s`. (If the Mac visibly locked a little later, note that too.)

Afterwards, remove your terminal's Accessibility grant if you added it only for this test.

## Afterwards

Put your Lock Screen settings back to what you wrote down above, and relaunch Farside if you use it.

## Results

Each run writes a log to `~/Library/Logs/Farside/` (`away-s1-<date-time>.log`, `away-s2-<date-time>.log`);
the path is printed at the end. The first line of each log includes the macOS version.

| Test | macOS | Date | Result | Log file | Notes |
|---|---|---|---|---|---|
| S1a | 26 | | | | |
| S1a | 27 | | | | |
| S1b | 26 | | | | |
| S1b | 27 | | | | |
| S1c | 26 | | | | |
| S1c | 27 | | | | |
| S2 | 26 | | | | |
| S2 | 27 | | | | |

## Go / no-go

- **S1a and S2 both pass on macOS 26 and 27** → set `AwayModeGate.releaseDefault = true` in
  `RemoteHost/HostAwayEnvironment.swift` (one line), then run S3–S6 below with the real app.
- **Otherwise** → leave it `false`. 1.0 ships the fallback copy and lock warning; Away mode moves to 1.1.

S1b and S1c never block the release; they decide the wording Away mode shows when the screen saver is on.

## Trying the real app before flipping the gate

To see Away mode in a build where the gate is still off:

```sh
defaults write com.roshan.PocketDesk.RemoteHost FarsideAwayModePreview -bool YES
```

Relaunch Farside. To hide it again:

```sh
defaults delete com.roshan.PocketDesk.RemoteHost FarsideAwayModePreview
```

## Later physical checks with the real app (S3–S6)

From spec §8. Run these with Away mode on, sharing on, on power, in the same quiet conditions.

- **S3 — local touch to lock.** Wait until the screen is covered (2 minutes without use), then touch the
  trackpad once. Measure the time from the touch to the lock screen. Note whether that one touch or
  keystroke reached the Mac underneath (the design expects the first event to land).
- **S4 — crash while covered.** With the screen covered, from another Mac or over SSH run
  `kill -9 <Farside host pid>`. Count the seconds the desktop is visible before the relaunched host
  locks the Mac. Needs **"Restart Farside if it quits"** turned on in Farside's settings.
- **S5 — power and lid.** Unplug power with no phone connected: Away mode should end, and the Mac lock,
  after 5 minutes. Separately, close the lid and note what happens.
- **S6 — real use.** Arm Away mode, leave for 2 hours, then connect from the phone on cellular. Use the
  Mac, then tap **End and lock Mac** and confirm the Mac is locked when you get back.

## Safety

- The scripts change no settings, never ask for, type or store a password, and post no events except
  S2's single Control-Command-Q.
- S1 holds its two power assertions only while it runs. It releases them when it finishes, on Control-C
  and when terminated; if it is killed outright, macOS drops them when the process exits.
- Both scripts refuse to start unless you type the word yourself in a terminal, so nothing can start
  them by piping input.
