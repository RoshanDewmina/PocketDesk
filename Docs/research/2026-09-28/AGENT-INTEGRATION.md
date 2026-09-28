# Agent integration research and smallest useful demo

Checked 28 September 2026. Research and proposed sequence only; core remote desktop remains the priority. No chat messages were sent and no integration was deployed.

## Current code evidence

`Server/src/mcp/tools.ts` already defines request_desktop_access, session_status, stop_session and separately scoped inspect_screen. Access links contain intent identifiers; its description explicitly says that opening a link alone grants nothing. Inspection requires its own active Mac-created grant and sends image content to the model. These distinctions should remain visible in the user experience.

`Server/src/index.ts` starts createService from server.ts; current server.ts has no MCP route registration. Tests of the MCP module alone therefore do not establish a working deployed connector. The old `agent-ae8acf0d3f5df8a77` worktree contains a Runtime Codex adapter that owns a child app-server process; it is not integrated and its earlier review remains unresolved. This continuation inspected source and the installed `codex app-server --help`, not a successful runtime takeover.

## Recommended sequence

1. **Open my desktop:** authenticated chat tool returns a short-lived intent URL. The owner opens the native app or browser, authenticates normally and requests human control. Link preview, crawlers and anyone forwarding the URL receive no control authority.
2. **Agent needs me:** an adapter-owned job emits a structured waiting-for-user event. Route a notification only under the user's explicit notification preference; deduplicate and expire it. Notification text should identify the job without leaking a prompt, file contents or screen.
3. **Take over and hand back:** interrupt the cooperating runtime, wait for an acknowledged quiescent state, acquire exclusive human control, then explicitly resume after human release and fresh context. Timeout, crash or adapter mismatch must leave the runtime paused and input released.

Do not claim this can pause arbitrary existing Claude/Codex GUI chats. Do not attach an adapter to unrelated sessions merely because their IDs are discoverable. A desktop view is universally useful; managed pause/resume is limited to a runtime we own and actually verify.

## Delivery surfaces

Universal links can provide an app-or-web entry after domain association is configured. They are navigation, not authentication. Keep the browser fallback usable if a chat host cannot embed a live view. Test ChatGPT and Claude separately on the real phone; desktop connector access proves neither mobile availability nor embedded streaming. [Apple universal links](https://developer.apple.com/documentation/xcode/allowing-apps-and-websites-to-link-to-your-content).

The installed Codex CLI exposes app-server and protocol-generation commands. Before reviving the old Runtime branch, generate schemas from the exact installed version and compare initialization, thread creation, approval requests, interruption and resumed turn envelopes; then run a disposable real child process. Its fixture-only protocol assumptions cannot be accepted as proof. No provider tool capability should be inferred from this local CLI.

## Smallest honest demo

Use a disposable project owned by a managed local runtime. The agent reaches a deliberate approval checkpoint; the owner opens the access link, sees the live Mac, edits a harmless line, ends human control and explicitly resumes the agent. Show the resulting check. Include a negative test: revoke access before opening the link; the viewer must refuse control. Another test interrupts the runtime while a request is in flight; no overlapping automated input is allowed.

Suggested scope estimate: link entry and route wiring 3–5 engineer-days after security review; trustworthy managed-runtime handoff 1–3 weeks including interruption/race tests. These are engineering estimates, not measured delivery dates. Acceptance requires live integration and exclusive-authority receipts, separate from an attractive launch video.

## Differentiation hypothesis

A clear “waiting for you → human fixes the problem → job continues” loop is more specific than generic remote agent monitoring. It only becomes an advantage after users complete that task reliably. Preserve ordinary remote desktop for every other application; no AI takeover, automatic approval or access to unrelated sessions is part of this plan.
