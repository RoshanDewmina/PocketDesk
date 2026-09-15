# PocketDesk MVP device test checklist

Use this checklist to decide whether the private feasibility MVP works for one useful task. It records physical evidence; a successful build, installed app, signature, or permission switch is not a substitute.

The current local baseline is **33 native tests and 33 service tests passing**. Those checks do not replace the physical route and control gates below.

## Before leaving the Mac

1. Run the read-only local check from the repository root:

   ```sh
   scripts/preflight-remote.sh
   ```

   Resolve `BLOCKED` local checks. `UNKNOWN` permission and device results are expected until the live steps below. The command does not read private environment files or test a provider.
2. Open `/Applications/PocketDesk Host.app`. In the host, choose one existing display. At the actual prompt, grant and then verify Screen & System Audio Recording and Accessibility with the host's own permission/display check. Do not treat System Settings toggles alone as proof.
3. Open [`scripts/physical-acceptance.html`](../scripts/physical-acceptance.html) on the Mac. Keep its live clock, editable text field, and drag target visible. This is the common fixture for every route.
4. Pair the phone, approve the pairing on the Mac, enable control, and confirm the phone shows the changing clock. If it cannot, stop and record the exact host status rather than retrying blindly.

## Local baseline

With the iPhone and Mac on the same Wi-Fi:

1. Read the advancing clock for at least 20 seconds. A frozen initial image fails this gate.
2. Tap into the fixture's text field from the phone, make a short distinctive edit, and verify the exact edit is visible on the Mac.
3. Start a deliberate drag of the fixture target. While the pointer is held, interrupt the phone path by backgrounding PocketDesk or briefly disabling Wi-Fi. Verify the Mac releases the held input and that no unwanted drop/click is left behind. Reconnect and confirm no prior action is replayed.
4. Capture the displayed route and whether the task was comfortable enough to read, edit, and recover. Local success is a baseline only; it is not away-use or relay proof.

## Built-in remote path: cellular, then forced relay

This is the MVP acceptance path. The signaling and relay service is PocketDesk's built-in test stack; do not replace it with Tailscale for these two gates.

1. Prepare the private service setup outside the repository using [`Server/.env.standalone.example`](../Server/.env.standalone.example), [`Server/Caddyfile.standalone.example`](../Server/Caddyfile.standalone.example), and the bounded runner at [`Server/scripts/run-bounded-standalone.sh`](../Server/scripts/run-bounded-standalone.sh). Run the real provider/WSS checks only when the required account access is deliberately available; [`Server/scripts/readiness.ts`](../Server/scripts/readiness.ts) makes credential requests.
2. Before starting the service, use the read-only deployment inventory without exposing values:

   ```sh
   scripts/preflight-remote.sh --standalone \
     --service-env /absolute/private/path/pocketdesk.env \
     --caddy-config /absolute/private/path/Caddyfile
   ```

   A named tunnel also needs `--tunnel-config`; a Quick Tunnel does not. The preflight checks only that a selected private path is a regular owner-only file and never reads its contents.
3. Move the iPhone to cellular and turn Wi-Fi off. With **Relay-only test** off, pair/connect and repeat the clock, edit, and interrupted-drag task. Record the route diagnostic. A successful cellular session can still be direct ICE.
4. Turn **Relay-only test** on, reconnect from a fresh session, and require the route diagnostic to say `Relay`. Repeat the same clock, edit, and interrupted-drag task. A changing clock plus the reflected edit plus safe input release are all required. WSS authentication or returned ICE servers alone do not prove media crossed a relay.
5. Stop the bounded runner when finished. Preserve redacted timestamps, route labels, observed behavior, and any necessary Mac intervention. Never retain pairing codes, tokens, or provider credentials in the receipt.

## Temporary Tailscale path

Tailscale is useful only as a private debugging route while the built-in service is unavailable. Its endpoint and successful session may help isolate pairing, capture, or input problems, but they do not establish PocketDesk’s standalone cellular or forced-relay behavior. A private WSS signaling check also does not prove a phone media/control session. Keep the temporary listener bounded and remove only the test processes it owns. Repeat the two built-in remote gates above before calling the MVP validated.

## Pass record

Mark each item with an observed result and a timestamp:

| Route | Clock changes | Exact edit reflected | Interrupted drag safely released | Route shown | Result |
| --- | --- | --- | --- | --- | --- |
| Local Wi-Fi |  |  |  | Local/direct |  |
| Cellular |  |  |  | Record actual route |  |
| Cellular relay-only |  |  |  | Must say `Relay` |  |

The feasibility MVP remains unvalidated until all three rows pass on physical devices. Record a concise continue, change, or stop recommendation after the test.
