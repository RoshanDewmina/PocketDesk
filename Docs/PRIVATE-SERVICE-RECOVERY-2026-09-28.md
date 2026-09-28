# Private connection-service recovery — 28 September 2026

The phone displayed “Connection interrupted · retrying…” and the host exhausted its retries. Host system logs returned HTTP502 during the WebSocket handshake. No process listened on the existing proxy backend127.0.0.1:18787. Prior test-service setup had an automatic two-hour lifetime. The user explicitly approved running the connection service automatically at Mac login.

## Installed service

- Per-user launch job: `com.roshan.pocketdesk.signaling`.
- Configuration: `~/Library/LaunchAgents/com.roshan.pocketdesk.signaling.plist`.
- Bundle: `~/Library/Application Support/PocketDesk/signaling-service.js`, built from `Server/src/index.ts` using the installed Bun1.3.14.
- Runtime: `/opt/homebrew/bin/bun`; loopback127.0.0.1:18787. Existing development configuration, pairing authentication and30minute room lifetime retained.
- RunAtLoad and KeepAlive enabled,10second restart throttle, owner-only files and077 umask. No two-hour process shutdown.
- Existing Tailscale8444 `/signal` proxy unchanged. No new public endpoint, relay provider or permission grant.

The standalone bundle avoids a background service depending on access to a Documents checkout. Rebuild and deliberately redeploy this bundle when changing service source; host and phone builds do not update it automatically.

## Observed checks

Loopback health returned HTTP200 with protocol1. Trusted HTTPS1.1 WebSocket upgrade on the existing private route returned101, followed by the expected timeout for an unauthenticated probe. A curl HTTP2 upgrade probe returned502 and is not a valid WebSocket acceptance check.

A scoped SIGTERM sent to the launch job stopped it cleanly; launchd started a new process (runs2, new PID34690, prior PID34118), which again returned healthy. Host UI then showed “Your phone is controlling this Mac” and “Paired · Connected now.” This proves restored physical pairing/connectivity, not new latency or speech accuracy.

## Management

Inspect: `launchctl print gui/$(id -u)/com.roshan.pocketdesk.signaling`.

Stop and unload: `launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.roshan.pocketdesk.signaling.plist`.

Load again: `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.roshan.pocketdesk.signaling.plist`.

Unloading keeps its configuration for the next login. To disable future automatic startup, unload it and move the plist out of LaunchAgents. Do not modify the user’s other launch jobs or Tailscale routes. This service does not launch the Mac host app, wake a sleeping Mac, or provide login-screen access.

Platform reference checked: [Apple launch agent lifecycle](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html). Local launchctl state and the observed restart provide this installation’s evidence.
