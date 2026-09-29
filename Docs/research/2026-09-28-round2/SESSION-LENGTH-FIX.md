# Session length fix — remote sessions no longer end at 30 minutes

29 September 2026 · Claude Code worktree branch `worktree-agent-aa03e26f1e815691c`, based on `pocketdesk-remote-chat` at `0bd6245`. Subordinate to PRODUCT.md; this report records a root-cause investigation, a fix and local evidence, not physical acceptance.

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
| old | new | new | The phone's renewals keep the room alive, so a free-local session is unlimited; on a relay the old Mac's credentials still expire at their TTL and its fallback reconnect takes over |
| new | old | new | The Mac's renewals keep the room alive; the old phone's relay credentials expire at their TTL and its fallback reconnect takes over. An old phone answers a host-initiated ICE restart like any renegotiation |

### 3.5 What was not changed

The browser viewer path (10-minute sessions by design), the bounded standalone runner, pairing, the encrypted signaling envelope, the data-channel protocol and every UI. There is no new user-visible setting.

## 4. Files

| Area | Files |
|---|---|
| Service | `Server/src/server.ts` (clock seam, `renew.1`, lease, credential refresh, readiness counters), `Server/src/config.ts` (`SESSION_RENEWAL`, credential TTL passed through), `Server/src/turn.ts` (providers expose their TTL), `Server/src/relay-config.ts` (preflight reports the switch), `Server/.env.*.example`, `Server/README.md` |
| Apps | `RemoteShared/SessionRenewal.swift` (new: offer, schedule, scheduler and transport seams), `RemoteShared/SignalingClient.swift`, `RemoteShared/RemoteCoordinator.swift`, `RemoteShared/PeerMedia.swift` (`updateICEServers`, `restartICE`, renegotiation-safe candidate handling) |
| Tests | `Server/tests/session-renewal.test.ts`, `Server/tests/fake-clock.ts`, `RemoteTests/SessionRenewalTests.swift`, `RemoteTests/SessionRenewalIntegrationTests.swift`, `scripts/test-service.ts` |
| Docs | this report, `Docs/REMOTE-PROTOCOL.md`, relay runbook, `Docs/DEVICE-TEST-CHECKLIST.md`, `Docs/launch/APP-REVIEW-RISKS.md`, `PRODUCT.md` |

## 5. Tests

RESULTS_PLACEHOLDER

## 6. What needs a real 45-minute device check

RESULTS_PLACEHOLDER_DEVICE
