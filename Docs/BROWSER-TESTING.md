# Browser feasibility checkpoint

This is the test/run companion to PRODUCT and IMPLEMENTATION-PLAN, not a second product specification. The browser client, dedicated loopback service, separate Mac browser trust, native media adapter, and generated-content harness are implemented. Real Mac permission acceptance, physical Safari/Chrome readability and input, cellular, and forced TURN remain separate tests.

## Repeatable local checks

Run from the PocketDesk repository:

```sh
./scripts/verify-remote.sh
./scripts/verify-browser.sh interactive
./scripts/verify-browser.sh view
```

The browser script needs Node, Bun, Xcode/XcodeGen, an installed Playwright package and Chromium, plus access to launch a local Mac application. If Playwright is outside normal Node resolution, set `POCKETDESK_PLAYWRIGHT` to its package directory. If its matching browser is outside the default cache, set `POCKETDESK_CHROMIUM` to the executable. No downloads or provider accounts are required when those dependencies are installed.

`verify-browser.sh` builds `PocketDeskBrowserFixture`, starts its own service on loopback port 8791, runs an isolated browser context, then stops only its own service/fixture and removes its short-lived offer. Use `POCKETDESK_BROWSER_PORT` to select another free port. `POCKETDESK_BROWSER_RECEIPTS` chooses a new, non-existing absolute result directory; by default results go under `outputs/browser-check-*`. It never uses ScreenCaptureKit or injects OS input. Its deliberate automatic enrollment approval is confined to the synthetic app, whose trust is in memory. The actual host always requires Mac approval.

The checks cover opaque enrollment, wrong peer/forged proof/replay refusal, H.264 and encrypted signaling across native Swift and WebCrypto, decoded pixel markers, committed Unicode text and IME gating, view-only crafted-input rejection, stale-video blocking, End, page hide, fresh reconnect, CSP and mobile layout. A separate browser race harness exercises late enrollment responses, Forget, pending Connect cancellation, and inert reload. Unit suites cover token/sequence/scope bounds, orientation, encryption vectors, service admission races and cancellation. These checks establish synthetic behavior, not physical performance or application-level text success.

For an interactive local preview, run `bun scripts/browser-dev.ts` and open `http://127.0.0.1:8788/probe/`. The probe uses invented code-like content and a local keyboard field. It ends automatically after the service's bounded default 30-minute lifetime; Ctrl-C stops sooner. Loading the viewer at `/` is inert. A physical phone cannot reach the Mac's loopback address.

## Physical test when Roshan returns

1. Launch the current installed **PocketDesk Host**. Follow the [Mac permission identity runbook](MAC-PERMISSION-IDENTITY.md), then verify actual runtime grants and display enumeration. On 13 September both Settings switches were on, but macOS rejected stale grants tied to an older build identity. A successful build or enabled switch is not a permission receipt.
2. Establish a private HTTPS origin reachable by the phone, with the browser service configured for that exact origin. Review the existing private proxy configuration before changing it and preserve unrelated routes. Public provider/account setup stays paused. The local service has no TURN configuration; direct local success does not establish cellular/relay access.
3. Open that trusted viewer URL in Safari on the phone. On the Mac select a display, choose view-only first, enable browser access, create the short-lived offer, paste it into the viewer, and approve the pending browser on the Mac. Native phone pairing must remain intact. Connect is a separate explicit action.
4. Inspect real small code text and punctuation in portrait and landscape, Fit, zoom/pan, then with the keyboard open. Record whether the desktop remains visible. Compare local enlargement with readability; defer crop encoding until this evidence justifies it.
5. Stop and explicitly enable a fresh interactive grant if control is needed. To upgrade a view-only enrollment, revoke browser trust on the Mac, forget that enrollment in the browser, choose the new scope and enroll again. Perform a harmless edit in a scratch code file and run its check. Confirm the text in the Mac application and resulting test output; an injection acknowledgement alone is insufficient.
6. Try click/right/double click, relative movement, two-finger scrolling, explicit modifier/key actions, Unicode and IME. Interrupt a held drag by hiding the browser, locking the phone, stopping on the Mac, and losing the network. Confirm the actual mouse button is released. Test revoke and re-enrollment without changing native pairing.
7. Record phone/browser versions, network route, real versus synthetic source, readability, approximate input-to-visible response, failures and cleanup. Keep secrets, drafts and real desktop images out of shared receipts. Cellular and forced TURN get their own later receipts after provider work resumes.

## Deployment boundary

The local service serves both viewer code and signaling. Trusted browser code can protect enrollment and media negotiation from a substituting relay, but malicious delivered JavaScript can read a pasted secret and act as the viewer. Public deployment requires an independently reviewed trusted code-delivery/origin design, HTTPS/Origin routing, operational limits, and actual cellular/TURN tests. This checkpoint does not authorize publishing a public endpoint.

## Recorded local results, 13 September 2026

- [Final native and service check](../outputs/remote-check-20260913T105750Z/): 48 native tests, 49 service tests, Mac and iOS simulator builds passed.
- [Final Chromium interactive check](../outputs/browser-check-20260913T110218Z-interactive/browser-receipt.json): 18 checks passed, including relative actions, IME/text, frozen-video release and uncertain-acknowledgement reconnect without replay. Its [lifecycle log](../outputs/browser-check-20260913T110218Z-interactive/browser-lifecycle.log) has four further probe/race checks.
- [Chromium view-only check](../outputs/browser-check-20260913T105727Z-view/browser-receipt.json): 12 checks passed, including native rejection of a crafted input packet carrying a valid decoded frame token.
- [All JavaScript suites](../outputs/browser-implementation-2026-09-13/all-js-tests.log): 61 tests, 274 assertions passed (service plus browser/fixture tests; overlaps the counts above).
- [Matching Playwright 1.63.0 / WebKit 2359](../outputs/browser-check-20260913T110307Z-view/browser-receipt.json): enrollment and auth-negative checks passed, but media timed out with ICE checking, no inbound RTP and zero frames. An earlier local browser-to-browser probe also failed. The exact cause is unproven; a headless runtime/local-network candidate restriction is a hypothesis. This is a failed compatibility test, not Safari acceptance. Do not change codecs based on it. Physical Safari and private reachability are the next evidence needed.

All generated-media offers and test processes are cleaned by the runner. The trusted-code delivery constraint remains in [the protocol](REMOTE-PROTOCOL.md).

The current signed Mac app was installed and launched successfully; [installation receipt](../outputs/host-run-20260913T110403Z/) preserves the previous copy. [Runtime permission checks](../outputs/browser-implementation-2026-09-13/installed-permission-preflight.log) on that new process still returned false for Accessibility and Screen Recording. Both scoped independent reviews approved the local synthetic checkpoint; broader physical/public gates remain open.
