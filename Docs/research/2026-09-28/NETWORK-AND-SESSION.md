# Network and session research

Checked 28 September 2026. Proposed engineering work; no service was purchased or deployed. Subordinate to PRODUCT.md.

## Recommendation

Keep WebRTC and finish owned signaling plus short-lived TURN admission before trying QUIC. A faster codec cannot remove an extra relay hop or make an unreachable Mac reachable. First compare direct LAN, direct internet and forced relay with the same frame source, resolution and device. Report selected ICE candidate pair, RTT, loss, throughput, decode cadence and physical click-to-visible change separately.

Cloudflare documents TURN at US$0.05 per billed GB after 1,000 GB/month, charging server-to-client traffic including TURN overhead. Verify account terms before purchase. [Cloudflare TURN FAQ](https://developers.cloudflare.com/realtime/turn/faq/), [product pricing](https://www.cloudflare.com/en-gb/developer-platform/products/cloudflare-realtime/).

### Explicit planning model

Assume 8 Mb/s video, 20 hours per user/month, 30% of sessions relayed, 10% transport overhead and decimal GB. Estimated billed GB/user = 8 / 8 × 3600 × 20 / 1000 × 0.30 × 1.10 = 23.76. This is our scenario, not observed usage or a quote.

| Active users | Estimated billed GB/month | TURN cost/month after allowance |
|---:|---:|---:|
| 50 | 1,188 | $9.40 |
| 500 | 11,880 | $544.00 |
| 5,000 | 118,800 | $5,890.00 |

At 100% relay the same model uses 79.2 GB/user: costs become $148, $1,930 and $19,750. Signaling, storage, monitoring, taxes, support and payment fees are excluded. Video bitrate and session length dominate economics; an annual unlimited promise needs usage evidence first. TURN avoids owning global relay operations but does not remove our authentication/revocation responsibility.

## Session lifecycle

Treat foreground inactive, background, disconnect and host sleep as separate events. For Control Center: shield sensitive content and cancel held input, retain authenticated transport briefly, then require fresh healthy capture before accepting input again. A backgrounded app is not guaranteed indefinite networking. No fake audio or VoIP background entitlement should keep a remote-desktop socket alive.

PiP is a separate view-only experiment. Apple documents AVPictureInPictureController and custom video-call content, but that does not establish eligibility or reliable remote-desktop background behavior. Its call-style PiP window does not receive custom touch events. Test genuine supported content/rendering and app-review suitability before scheduling it as a quick feature. [Apple PiP guidance](https://developer.apple.com/documentation/avkit/adopting-picture-in-picture-for-video-calls).

## Implementation sequence and gates

1. Mount existing authenticated service routes only after current MCP/service security review; keep links as locators, never credentials.
2. Mint credentials server-side after authenticated admission, with short expiry, revocation and per-owner limits; secrets never enter the app bundle.
3. Test Wi-Fi/cellular transition, expired credentials, revoked owner, UDP blocked/TURN TCP-TLS, reconnect and rate limits. Stop capture and release held keys on loss of authority.
4. Measure forced relay across at least two actual networks. Same-host loopback and Tailscale are not this gate.
5. Evaluate QUIC only if data identifies transport as the bottleneck. It still needs loss recovery, congestion control, NAT traversal and relaying; protocol replacement is a multiweek project estimate, not a shortcut.

Awake/unlocked remains the supported initial host state. Sleep, lock, login and FileVault recovery are not promised. Public deployment/account activation stays outside the current local continuation.
