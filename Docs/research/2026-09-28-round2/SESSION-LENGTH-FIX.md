# Session length fix — remote sessions no longer end at 30 minutes

29 September 2026 · Claude Code worktree branch `worktree-agent-aa03e26f1e815691c`, investigated at `pocketdesk-remote-chat` `0bd6245` and rebased onto `8c02bf0` (which includes the Mac parity merge, with the phone's 90 s session-loss reconnect window and the Mac waiting out its predecessor's connection slot, and the phone redesign; the reconnect behaviours are kept and their integration tests pass). Subordinate to PRODUCT.md; this report records a root-cause investigation, a fix and local evidence, not physical acceptance.

**Evidence level reached:** source inspection of every path that could end a session; a real Bun signaling service driven by a fake clock; the real coordinator driven by a scripted service and a manual clock; the real service with real in-process WebRTC for renewal, credential refresh, ICE restart and the legacy fallback. **Not reached:** any real iPhone or Mac session, any real TURN allocation (Cloudflare or coturn), cellular. A real 45-minute check is listed in section 6.

## 1. Symptom

Remote sessions between the owner's iPhone and Mac ended at "about 30 minutes". The precise rule is *at most* 30 minutes, because the clock does not start when the session starts: it starts when the Mac registers with the signaling service, which can be long before the phone connects. A session could therefore end after 5 minutes or after 29.

At the boundary the phone drops out of the session view, the Mac stops capturing, input held at that moment is released, and both apps show "Connection interrupted · retrying…" and rebuild the whole connection. If the retry budget holds (five attempts, 0.5 s to 8 s of backoff) the session comes back after a few seconds; if not, the user sees "Connection lost. Tap Connect to try again."

## 2. Root cause

Line numbers are from the base commit `0bd6245`.

| # | Cause | Where | Effect |
|---|---|---|---|
| 1 | The signaling service closes every host socket a fixed time after the Mac registers | `Server/src/server.ts:52` (30-minute default), `:202` (`setTimeout(() => ws.close(1001, 'room_lifetime_reached'), …)` armed once at registration), `:325-328` (closing the host deletes the room and closes the client with `host_disconnected`), `Server/src/config.ts:39` (`ROOM_LIFETIME_SECONDS`, default 1800), and `ROOM_LIFETIME_SECONDS=1800` in all three env examples (`.env.private.example:27`, `.env.standalone.example:25`, `.env.relay.example:31`) | Nothing could extend it: there was no message for renewal and the timer ignored whether both peers were connected and authorised |
| 2 | Relay credentials were issued once, at registration, and never refreshed | `Server/src/server.ts:184` (issued), `:219` (sent once); TTL 3600 s in `config.ts:35`, `turn.ts:95` (coturn) and `:137` (Cloudflare) | The service therefore forces the room to end *before* the credential does: `config.ts:41-43` and `relay-config.ts:157-160` reject a lease that is not shorter than the TTL. Raising only the room lifetime would have moved the limit to the credential: Cloudflare documents that an allocation is disconnected shortly after its credentials expire |
| 3 | The apps treat a signaling close as the end of a healthy media session | `RemoteShared/SignalingClient.swift:55` (any socket error → `close(); onClose?()`), `RemoteShared/RemoteCoordinator.swift:57` (`onClose` → `connectionLost()`), `:326-346` (`connectionLost()`), `:130-139` (`resetSession()` closes the WebRTC peer, clears `connected`, calls `onEnded`) | A direct LAN session with perfectly good video is torn down because the rendezvous socket closed |
| 4 | The consequences reach the UI and the capture pipeline | `RemotePhone/HomeView.swift:9` (session view only while `connected`), `RemotePhone/RemotePhoneApp.swift:175` and `:601`, `:803` (`onEnded` → `sessionEnded()` → `end()` clears geometry, input tokens, holds, timers), `RemoteHost/HostModel.swift:184` (`onEnded` → `endCapture()`) | The user sees the session end even though only signaling had expired |
| 5 | A live peer connection could not take new ICE servers | `RemoteShared/PeerMedia.swift:119` (servers set once in `init`, no update path) | Even a service that refreshed credentials would have had no way to hand them to a running session |

Documentation states the same design in three places: `Server/README.md` ("Runtime refresh during a session is not implemented, so `ROOM_LIFETIME_SECONDS` must remain below the credential lifetime"), the relay runbook table ("The room must end before the credential does because credentials are not refreshed mid-session. A signaling close tears the media session down") and its test 8 ("The session ends at the boundary by design").

### Checked and ruled out

| Candidate | Finding |
|---|---|
| WebSocket idle timeout | `idleTimeout: 60` with `sendPings: true` on the native service; the phone's socket answers pings. Not a source of a 30-minute limit |
| Room approval | Approved rooms in `rooms.ts` have no expiry. The 300 s TTL applies only to *pending* approval requests (`readPendingRooms`) |
| App timers | Every `Task.sleep`, `Timer` and deadline in `RemoteShared/`, `RemoteHost/` and `RemotePhone/` was reviewed: pairing 120 s, response timeouts 20 s, input leases 1-2 s, background hold 25/45 s, return within 15 minutes, Pause 10 min. None is a session cap |
| Browser viewer path | Different mechanism, unchanged and intentional: the Mac gives a browser session a fixed 10 minutes (`RemoteHost/BrowserPeerController.swift:582`) and the browser service issues relay credentials once per session (`Server/src/browser/service.ts:690`, `:713`), which outlive that 10 minutes. Not part of the iPhone ↔ Mac path |
| `Server/scripts/run-bounded-standalone.sh` | A test supervisor that stops its own processes after 1800 s by default (`:12`, 60 to 3600 s allowed). It is the acceptance rig, not the product, but it will end a long device test unless it is given a longer duration |

## 3. The fix

### 3.1 Design

The room becomes a **lease** that the connected, authorised peers keep extending, and relay credentials are **refreshed before they expire and applied to the live connection**. Everything is negotiated per peer, so an older app or an older service sees exactly the messages and the lifetime it always did.

```
Mac/phone                         signaling service
   register {features:["renew.1"]}  ──▶
                                    ◀── registered {renew:{leaseSeconds:1800, renewAfterSeconds:900, credentialSeconds:3600?}}
                                    ◀── ice {servers}                       (unchanged)
   … renewAfterSeconds later …
   renew {}                         ──▶  approval re-checked, lease extended to a full lease from now,
                                         fresh credentials issued if the peer's are a third spent
                                    ◀── renewed {leaseSeconds, renewAfterSeconds, servers?, credentialSeconds?, code?}
```

- **Cadence is the service's decision.** It asks the peer to come back at half the lease, or when its credentials come due, whichever is sooner. With today's defaults (lease 1800 s, TTL 3600 s) that is renewals at 900 s and credential refreshes every 1200 s, never later than a third of the credential's life. A third leaves room for one failed round and an ICE restart before the credential the peer is using can expire.
- **Renewing extends the lease from *now*.** Either peer of an approved room may renew, so a renewing phone keeps the room alive for a Mac app that predates renewal and the reverse.
- **On the client**, `RemoteShared/SessionRenewal.swift` holds the schedule as pure state (`RenewalPlan`) and the coordinator drives it. Fresh servers are applied with `RTCPeerConnection.setConfiguration` (no effect on the media). **Only when the selected route is a relay** does the host then restart ICE, so media moves to a new allocation created with the new credentials while the old allocation keeps carrying it. On a direct route nothing restarts.
- **The fallback is untouched.** If the service stops answering, the room ends as it always did and the existing bounded reconnect takes over. Renewal never *replaces* a recovery path, it only avoids needing one.

### 3.2 Why credentials are not revoked early

The obvious design revokes the previous credential when its replacement is issued. That would cut live media: an existing TURN allocation stays bound to the username it was created with (RFC 5766 rejects refreshes from a different username) until an ICE restart creates a new one. Superseded sets are therefore left to expire on their TTL and are all revoked when the peer disconnects. With a refresh every third of the TTL, at most three sets per peer are ever live.

### 3.3 Security properties kept

| Property | How it is kept |
|---|---|
| Paired-device admission | Registration is unchanged: host token digest equals the room, client token digest equals the stored hash, room approved. `renew` is accepted only from an already-authenticated socket that is a member of its room |
| Short-lived credentials | TTL unchanged (3600 s default). Credentials are now refreshed at a third of it and every set is revoked at disconnect. A peer cannot force an earlier refresh |
| Revocation and Stop Sharing | The 1-second approval audit is untouched. Approval is also re-checked on every renewal and again after a slow issuance; a revoked room gets no new credentials and the ones just issued are revoked. Stop Sharing and every disconnect revoke all live sets immediately and end the phone session with `host_disconnected` |
| Rate limits | `renew` is subject to the per-connection message limit; refreshes count against `TURN_CREDENTIAL_ISSUES_PER_MINUTE` and the provider timeout, and a failed or refused refresh keeps the lease and returns a code instead of dropping the room |
| No lease revival | A renewal after the lease has run out is refused even when the expiry timer has not fired yet because the event loop was busy |
| Operator control | `SESSION_RENEWAL=0` restores the hard cap for every peer. `GET /ready` reports `renewal.enabled`, the lease and counters of renewals and refreshes, with no room ID or credential |
| No new trust in the service | Renewal carries no application data. The encrypted `media` signal that an ICE restart uses is the existing end-to-end protected channel |

### 3.4 Compatibility

| Mac app | Phone app | Service | Result |
|---|---|---|---|
| new | new | new | Unlimited; relay credentials refresh; ICE restarts only on a relayed route |
| old | old | new | Exactly today's behaviour: a room per registration that ends at the lease, reconnect as before. The service sends them byte-identical `registered` and `ice` messages |
| new | new | old | The service ignores `features` and never offers renewal, so nothing is sent and the old limit applies. New apps never send `renew` unless offered |
| old | new | new | The phone's renewals keep the room alive, so a free-local session is unlimited; on a relay the old Mac's credentials still expire at their TTL and its fallback reconnect takes over. Not exercised with an old Mac build |
| new | old | new | The Mac's renewals keep the room alive; the old phone's relay credentials expire at their TTL and its fallback reconnect takes over. By code inspection an old phone answers a host-initiated ICE restart like any renegotiation, but no old phone build was available to test it |

### 3.5 What was not changed

The browser viewer path (10-minute sessions by design), the bounded standalone runner, pairing, the encrypted signaling envelope, the data-channel protocol and every UI. There is no new user-visible setting.

## 4. Files

| Area | Files |
|---|---|
| Service | `Server/src/server.ts` (clock seam, `renew.1`, lease, credential refresh, readiness counters), `Server/src/config.ts` (`SESSION_RENEWAL`, credential TTL passed through), `Server/src/turn.ts` (providers expose their TTL), `Server/src/relay-config.ts` (preflight reports the switch), `Server/.env.*.example`, `Server/README.md` |
| Apps | `RemoteShared/SessionRenewal.swift` (new: offer, schedule, scheduler and transport seams), `RemoteShared/SignalingClient.swift`, `RemoteShared/RemoteCoordinator.swift` (renewal, and the stale-signal handling of section 7), `RemoteShared/PeerMedia.swift` (`updateICEServers`, `restartICE`, renegotiation-safe candidate handling) |
| Tests | `Server/tests/session-renewal.test.ts`, `Server/tests/fake-clock.ts`, `RemoteTests/SessionRenewalTests.swift`, `RemoteTests/ScriptedSessionSupport.swift` (shared fakes: manual clock, scripted signaling, simulated service), `RemoteTests/StaleSignalTests.swift`, `RemoteTests/SessionRenewalIntegrationTests.swift`, `scripts/test-service.ts` (shortened lease and a fake relay for integration tests) |
| Docs | this report, `Docs/REMOTE-PROTOCOL.md`, relay runbook, `Docs/DEVICE-TEST-CHECKLIST.md`, `Docs/STANDALONE-NETWORK-READINESS.md`, `Docs/PRIVATE-SERVICE-RECOVERY-2026-09-28.md`, `Docs/launch/APP-REVIEW-RISKS.md`, `PRODUCT.md`, `Server/README.md` |

## 5. Tests

### 5.1 Signaling service: `bun test` in `Server/`

184 tests pass, 0 fail: the 162 that existed plus 22 in `Server/tests/session-renewal.test.ts`. The service takes an injectable clock, so the lifetimes are tested with real sockets and a fake clock (`Server/tests/fake-clock.ts`) that fires due timers in order and can also "stall" to model a blocked event loop.

| Behaviour | How it is tested |
|---|---|
| Original behaviour unchanged | A peer that never asks for renewal gets byte-identical `registered` and `ice`, and both sockets close at exactly 30 minutes (`room_lifetime_reached`, `host_disconnected`). This is the regression that reproduces the reported bug |
| **Long session** | Renewing peers stay connected at **30, 60 and 120 minutes** (checkpoints asserted), a renewing idle Mac stays registered for 4 hours, and a session with a relay provider is walked minute by minute for **180 minutes** asserting that both peers hold an unexpired credential at every minute, credentials were refreshed no sooner than 20 and no later than 22 minutes apart, and nothing was revoked mid-session. When renewals stop, the room ends 30 minutes later |
| At the boundary and after it | A renewal 1 ms before expiry extends the lease from that moment. A renewal after expiry is refused even though the expiry timer has not fired yet (clock stalled to the boundary); one 1 ms earlier is honoured |
| Either peer | A phone alone keeps a room alive for a Mac that never renews, for 2 hours, and the old Mac receives no message it does not know |
| Negotiation and gating | `renew` is refused unless negotiated; exact shape only; feature lists validated and unknown features ignored; `SESSION_RENEWAL=0` returns original messages and refuses `renew`; the configuration and preflight expose the switch |
| Providers misbehaving | Outage on refresh: lease kept, `code: relay_unavailable`, retry in 30 s, refresh works after recovery. Issuance limit: `rate_limited`, room kept. A second renewal while one is issuing: `renewal_pending`, nothing issued |
| Revocation and Stop Sharing | Revoking a room ends both peers immediately and the renewal that follows issues nothing; the audit alone still ends a renewing session within its interval; Stop Sharing revokes every live credential set at once and ends the phone session; credentials whose issuance finished after the peer left are revoked, not delivered |
| Observability | `/ready` reports `renewal.enabled`, the lease and counters |

**Mutation check.** Six deliberate breakages of `server.ts` were applied one at a time (no lease extension on renew, lapsed lease honoured, approval not re-checked on renew, disconnect revokes only the newest credential set, refresh moved from a third to 95% of the TTL, renewal offered to every peer): every one made between 1 and 7 of the new tests fail, and the file was restored byte for byte.

### 5.2 Apps: `RemoteCoreTests` (macOS)

| Layer | Tests | What it proves |
|---|---|---|
| `RenewalPlan` (pure, `SessionRenewalPlanTests`) | 9 | Due times, clamping of hostile intervals, retry after the 10 s response timeout with 2/4/8/16/30 s backoff, unusable replies, lease and credential expiry, wire format both ways, and a 130-minute walk in which a renewing plan never lapses while a silent one does at exactly 30 minutes |
| Coordinator with a scripted service and a **manual clock** (`CoordinatorRenewalTests`) | 9 | The real `RemoteCoordinator` for **130 simulated minutes** (host) and **125** (phone): the signaling connection is never replaced, the Mac stays registered and "Ready for your paired phone" at every minute including **30, 60 and 120**, the credential in use is unexpired at every minute, at least six refreshes happen, and no ICE restart is started without media. Also: an app that does not ask for renewal sends nothing new and ends at the lease, then the existing reconnect recovers; a service that offers nothing is never sent `renew`; a silent service is retried at 900, 910, 920, 930, 940, 956, 986 s and a late reply resets the schedule; `stop()` cancels renewal and ignores a late reply; refreshed servers without a relay are ignored and retried; a service-side refresh failure keeps the lease and old credentials and retries in 30 s; a reconnect starts renewal over without duplicate timers |
| Real service, real WebRTC (`SessionRenewalIntegrationTests`, lease cut to 3 to 8 s) | 4 | **Renewal:** a session runs 10 s (three lease periods) with 10 host renewals, 5 credential refreshes and 5 successful `setConfiguration` calls on the live connection, no drop and the same peer connection throughout, and the control channel still works. **Fallback:** apps that do not renew end at the lease and the existing reconnect restores the session with saved trust and a new peer connection. **ICE restart:** a restart on a live loopback session completes on both sides (offer and answer applied), video keeps flowing, control still works. **Relayed refresh:** with the route forced to "relay" for the test, 4 refreshes cause 4 ICE restarts, 167 frames arrive, no drop |
| Stale signaling (`StaleSignalTests`) | 10 | Section 7 |

**Whole macOS bundle.** After the rebase and every change above, one run of the entire `RemoteCoreTests` bundle: **329 tests, 3 skipped (the opt-in benchmarks), 0 failures.** That is the 297 tests on main plus these 32. It includes main's `HostRestartIntegrationTests` (phone reconnect after a Mac relaunch, the short retry window for ordinary failures, the Mac waiting out its predecessor's room), so the parity behaviours were kept. Both apps were also type-checked in full against their SDKs with `swiftc -typecheck` (the macOS Mac app, and the iPhone app against the iOS Simulator SDK): no errors. The Xcode builds used only the `RemoteCoreTests` scheme, under `lockf -k /tmp/farside-xcodebuild.lock`.

### 5.3 Compatibility with the previous service

The base-commit `Server/src/server.ts` was run unmodified against a new-style `register`: it answers with its usual `registered` and `ice` and ignores `features`. A `renew` sent to it is answered `invalid_message` and the socket is closed, which is exactly why apps only send `renew` after being offered it. A bundle of the current service (`bun build src/index.ts --target=bun`) served a real renewal exchange and `/ready` counters.

### 5.4 Limits of this evidence

Loopback WebRTC never selects a relay, so the relayed-route test forces the "relay" decision and uses a fake relay that gives credentials but no allocations. The ICE-restart mechanics, the `setConfiguration` calls and the renegotiation are real; a real TURN allocation being replaced while media flows through it has **not** been observed. Cloudflare's documentation says credentials can be refreshed on a live session with `setConfiguration` and that an allocation is disconnected shortly after its credentials expire; coturn's behaviour on expiry was not tested here.


## 6. What needs a real 45-minute device check

Everything in section 5 is source, simulation and loopback. These are the things only a real iPhone, Mac and network can settle. The step-by-step version is the "Session length" section of [DEVICE-TEST-CHECKLIST.md](../../DEVICE-TEST-CHECKLIST.md).

**Before starting**

1. Install this build on the Mac (`script/build_and_run.sh` from the integrated checkout, not from a worktree) and on the iPhone. An app built before this ignores renewal and still ends at the lease.
2. Redeploy the signaling service, because renewal only exists in the new service: the owner's private service is a bundled copy that app builds do not update, so rebuild it and restart the job (commands in [PRIVATE-SERVICE-RECOVERY-2026-09-28.md](../../PRIVATE-SERVICE-RECOVERY-2026-09-28.md); the build command was checked, the installed bundle was not touched). For the relay, redeploy per the runbook. Check `curl -s http://127.0.0.1:<port>/ready` shows `renewal.enabled: true`.
3. If the bounded runner is used, give it a duration of `3600`; its default 1800 s ends the service at 30 minutes and would fake a failure.

**The 45-minute checks**

| # | Check | Pass |
|---|---|---|
| 1 | Same Wi-Fi, direct route, 45 minutes of light use | No freeze, "Connection interrupted" banner, return to the phone's home screen, or Mac capture restart at minute 30 or at any other minute. `renewal.renewals` in `/ready` keeps growing |
| 2 | Cellular, then **Relay-only test on**, 45 minutes | Same as above, and the route still says `Relay`. With `ROOM_LIFETIME_SECONDS=300` and `TURN_CREDENTIAL_TTL_SECONDS=600`, credentials refresh every 200 s and each refresh restarts ICE on this route: note whether any refresh causes a visible hitch, how long it lasts, and whether `credentialRefreshes` matches the number of refreshes |
| 3 | Mac display asleep for part of the session | Renewal continues (the counters grow) while the display is off; this depends on the Mac's timers running with no visible window |
| 4 | Stop Sharing and revoke at the end | The phone session ends immediately (not at the next renewal), and after revocation the service reports the room gone within about a second |
| 5 | Fallback | Kill the service or toggle Airplane Mode mid-session: the existing bounded reconnect still recovers and renewal restarts after it |
| 6 | Version skew, if an older build is still around | An older phone or Mac against the new service ends at the lease and reconnects on its own, as before |
| 7 | iOS backgrounding across a renewal | Backgrounding the phone for a couple of minutes around a renewal time still returns to a working session (renewal timers do not run while suspended) |

**What could still be wrong, in order of risk**

- **A real relay allocation being replaced.** Nothing here has observed a TURN allocation created with new credentials taking over from the old one under load. If an ICE restart on a relayed route causes a visible hitch, the options are a longer credential life (fewer restarts) or restarting only as the credential nears expiry.
- **`disconnected` during a restart.** The app tolerates a passing `disconnected` for 15 s after its own restart; a real network may behave differently from loopback.
- **Older phone builds answering a restart offer.** Inferred from the code only.
- **coturn.** Cloudflare's behaviour on credential expiry is documented; coturn's was not tested.

## 7. Related fix: a late message from a previous phone session stopped the Mac listening

Requested together with this work after the Mac parity review found two known-flaky session tests, `testHostKeepsRegisteredRoomWhenPhoneLeavesOrMediaDrops` and `testGraceExpiryEndsOnlyThePhoneSessionAndCachedTrustRejoins`.

**Symptom.** The Mac occasionally ends on "Secure connection failed. Reconnect or pair again on your Mac." and stays there: its signaling socket is closed and it is no longer registered, so the phone's next attempt gets `host_unavailable_or_unauthorized`. In the app this is a Mac that stops listening until someone presses Try Again.

**Measured before the fix** (this tree with the renewal code, without the stale-signal change): the room test failed 1 of 12 isolated runs; the whole `SessionIntegrationTests` class had 3 failing runs out of 10 (the room test once, the grace-expiry test twice). The failing room-test receipt shows the Mac's status history ending `… "connected", "Ready for your paired phone", "Secure connection failed. Reconnect or pair again on your Mac."`.

**Root cause.** `RemoteCoordinator.receive` decrypts every `signal` and hands it to `receiveProtected`, which is written for the *current* handshake: a `request` is valid only when the Mac has none, a `proof` only for the current request and session, and everything else only through the `SessionReplayGuard` for the current request and session. A message that does not fit throws `RemoteError.stale`, and `receive` had a single `catch` for every error that called `fail(...)`. `fail` sets `stopped`, closes the socket and clears the registration. But messages that do not fit the current session are normal: when the Mac resets a phone session (the phone left, media dropped, the Mac dropped it), that phone's trailing ICE candidates and acknowledgements are still in flight, a phone that has not noticed yet keeps sending, and the service answers a signal for a departed peer with a non-closing `peer_unavailable`. Whether one lands after the reset is a matter of milliseconds, which is why the tests were load-sensitive. The request, session and sequence IDs were there and were checked; the bug was what happened when the check failed. A stalled handshake had the same shape: its 20 s timeout called `fail`.

**Fix** (`RemoteShared/RemoteCoordinator.swift`):

- A message that cannot be attributed to the current pairing, session or handshake (sealed with another key or malformed, no session in progress, wrong request or session, replayed sequence, a second `request` while one is active) is **dropped and counted** (`staleMessagesIgnored`), so a replay is still never acted on, and it can neither disturb an active handshake nor stop an idle Mac.
- The service's non-closing `peer_unavailable` is treated the same way. Every other service error, including `room_not_approved`, still ends the connection.
- On a registered Mac, an *authenticated, current* message that breaks the protocol ends only that phone's session (`peerDisconnected()`), and a phone handshake that stalls ends only that attempt. A Mac that never reached the service still reports the timeout as a failure.
- A phone still fails closed on a protocol violation from the Mac, unchanged.
- The handshake timeout is injectable (`handshakeTimeoutNanoseconds`) so this can be tested in milliseconds.

**Tests** (`RemoteTests/StaleSignalTests.swift`, 10, deterministic): a late message from the previous phone session after a reset, a late message during the next handshake (which still completes), a replayed or competing request during an active handshake (nothing is sent, nothing is reset), a message sealed with another key or not decodable, the service's `peer_unavailable` versus a real error, a malformed authenticated message and an unknown message kind (session ends, Mac keeps listening and serves the next phone), a stale challenge and stale media on the phone, a phone that still fails closed, a stalled phone handshake, and a Mac that never registered. Each plays the phone or the Mac with correctly sealed messages, so the race the integration tests hit once in a dozen runs is hit every time.

**Evidence that this is the cause and that it is fixed.**

| Check | Before the fix | After the fix |
|---|---|---|
| The deterministic stale-signal tests that apply to the old code (8, behaviour only) | **7 fail, every time** (30 failed assertions: the Mac ends on "Secure connection failed…" and is no longer registered); the 8th, "a phone still fails closed", passes because that behaviour is unchanged | all pass |
| Room test, 20 isolated runs | 1 failure in 12 | **20 of 20 pass** |
| Grace-expiry test, 20 isolated runs | (failed in whole-class runs) | **20 of 20 pass** |
| Whole `SessionIntegrationTests` class, 10 runs | 7 clean, 3 failed (room ×1, grace-expiry ×2) | **10 of 10 clean** |
| Both flaky tests under identical 8-process parallel load, 4 workers × 8 runs each | 2 failures in 64 (one each) | **0 in 64** |

The "before" runs use the same source with only the coordinator reverted to the commit before the fix. The random-race numbers are small samples and are weak proof on their own; the deterministic result is the strong one, because it removes the timing.


## 8. Follow-ups, not done

- Show renewal counters in Copy Diagnostics (`HostDiagnostics.swift` is in a file other agents are editing).
- A per-session or per-plan cap on total relay time is an operator policy the service could enforce on renewal; nothing needs it yet.
- The browser viewer path keeps its 10-minute admission; if it ever needs long sessions it needs the same renewal.
- `relay_unavailable` at registration still stops a Mac; a bounded retry would fit the same "keep listening" principle.
