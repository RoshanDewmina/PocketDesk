# Launch measurement plan

**Source check:** Apple documentation was opened and checked on 2 October 2026. The linked pages below are the current primary-source basis for this plan; App Store Connect availability and values must be read live when reporting. This document defines measurement, not a claim that any launch target has been reached.

## What the three targets mean

| Goal | Operational definition | What can be reported now |
|---|---|---|
| At least **70% of installs produce working picture and control** | `installations with a verified first picture frame and a verified harmless control round trip ÷ eligible first-time installs`. Count each installed app/device once in a fixed install cohort, and count success only after both media and input are observed on that install. | **Not measurable with the approved sources.** App Store Connect can count downloads/installations and app opens, while the anonymous service counters below observe signaling and entitlement events. There is no shared install/session key and no app-side media-frame or control-round-trip event. Signaling readiness is not proof that picture or control worked. Do not publish a success percentage from these data. |
| At least **30% of successful users return in week 4** | `successful users from an install cohort who complete another working Farside session at least once on cohort days 22–28 ÷ successful users in that install cohort`. “Week 4” is days 22 through 28 after the install day, inclusive. “Successful” uses the verified picture-plus-control definition above. | **Not measurable with the approved sources.** The anonymous daily `{day,event,count}` counters cannot link a later event to an earlier successful user. App Store Connect retention is a useful, opt-in app-use proxy, but its cohort is app installers who have ever opened the app, not verified successful users. Its retention table reports individual day offsets such as Day 28, not the requested any-open during days 22–28. Report Day-28 retention separately and label it an app-use proxy; do not call it the 30% target. |
| **150–200 Anywhere active subscriptions by 31 December 2026** | On 31 December, count the App Store Connect **Active Paid Subscriptions** for the Anywhere subscription product/group. The target range is 150–200 active paid subscriptions. Exclude free trials. This is a subscription count, not a count of unique people or proof that each subscriber completed setup or used Anywhere. | Measurable from Apple subscription reporting once Anywhere is for sale and has subscribers. Keep Apple’s reported count and observation date as the receipt. If product/group filtering is unavailable, mark the result blocked instead of substituting all-product totals. |

## Data sources and limits

### App Store Connect

Use App Analytics for first-time downloads, total downloads, installations, sessions, active devices, and retention. Apple defines installations as completed installs and includes redownloads on the same device, installs on multiple devices sharing an Apple Account, and Family Sharing installations. Sessions count use of at least two seconds. These are useful reach and app-use signals; they do not demonstrate pairing, a live picture, or accepted control. App usage is collected only for people who opt in to share diagnostics and usage data, and Apple applies privacy availability thresholds. Therefore label App Analytics usage and retention as **opt-in observed** and retain any displayed opt-in-rate/context in the scorecard.

For the return proxy, capture the relevant matured install-cohort row and its **Day 28** cell, along with the cohort size/row context and app version filter. Day 28 is one day offset. It is not the week-four window (days 22–28), nor is it conditional on verified setup success. Do not average or relabel it to imply either condition.

For the subscription target, use the Anywhere product/group's **Active Paid Subscriptions** on 31 December. Apple defines this as currently active auto-renewable subscriptions, including paid subscriptions with introductory pricing and paid subscription offers, and excluding free trials and marketing opt-ins; activity lasts through the paid period. This is the closest directly reported measure for the stated paid-subscriber goal. Record any billing-retry/grace values separately if displayed; do not silently include trials or convert subscription count into unique-user count.

### TestFlight

During beta, TestFlight build metrics can provide installs and sessions over the last seven days, plus crashes and feedback. They help monitor beta build health and tester activity, but are tester/build scoped and do not establish App Store acquisition, a working remote-control session, week-four retention, or paid subscribers. Keep TestFlight results separate from App Analytics and production subscription results.

### Anonymous service counters

The implemented weekly endpoint reads a small D1 daily aggregate with schema `day, event, count`, and returns a Markdown scorecard for a complete Monday–Sunday UTC week:

```text
GET /v1/admin/metrics/weekly?week=YYYY-MM-DD
```

`week` is the Monday UTC date. The endpoint requires the existing admin authentication and is gated by `MEASUREMENT_ENABLED='1'`; if the setting is absent, measurement stays off. It emits only aggregate event counts, never device, user, pairing, room, transaction, or install identifiers.

The allowed events and what each can support are:

| Event | Meaning | Safe interpretation |
|---|---|---|
| `host_registered` | Successful host registrations, including reconnects | Registration activity count; not unique hosts, new pairs, or successful setups |
| `signaling_ready_free` | Signaling reached ready after client registration and peer online with local-only authorization | Signaling-ready event count; not a media frame or control success |
| `signaling_ready_anywhere` | Same signaling-ready boundary with remote/Anywhere authorization | Anywhere signaling-ready event count; not proof of paid access being exercised or of picture/control |
| `entitlement_verify_ok` | Verification response classified `entitled=true` | Positive entitlement verification response count |
| `entitlement_verify_rejected` | Verification response classified `entitled=false` or HTTP 401 | Negative entitlement response count; omit malformed input, rate limits, and service-unavailable outcomes |

Counts are event totals. Reconnects can increase them, and there is no first-pair, first-session, unique-install, or cohort deduplication. The ratios `signaling_ready_free ÷ host_registered`, `signaling_ready_anywhere ÷ host_registered`, or `entitlement_verify_ok ÷ (entitlement_verify_ok + entitlement_verify_rejected)` are not conversion or success rates because their events are not guaranteed to describe the same users, installations, or attempts. Use the raw counts as operational trends only; report missing/zero denominators as `N/A`.

Record the backend hostname/environment with each scorecard and never combine test/staging and production totals. Accepted Sandbox/Xcode transactions or configured developer relay passes can enter these authorization counts; the current production config accepts Sandbox. No purchase-environment dimension is stored. Only Apple’s production paid-subscription report answers the subscriber target.

The current telemetry does not observe local-LAN versus relay routing. In particular, signaling readiness must not be described as proof of a media path, and no local-LAN success rate can be derived from these events.

## Weekly review (under five minutes)

Open **App Store Connect → Analytics → Farside**. Use **Acquisition** for First Time Downloads/Total Downloads, **Engagement → App Usage** for Installations/Sessions/Active Devices/Crashes, and **Engagement → App Retention** for the dated install-cohort grid. These are dashboard metrics, not a custom setup funnel. In **Sales and Trends → Subscriptions**, choose the Anywhere subscription group/products and read **Active Paid Subscriptions**; do not substitute Active Subscriptions (which can include trials). During beta, use **Apps → Farside → TestFlight → iOS → selected build** for build installs, sessions and crashes, and the feedback sections for voluntary tester reports. Apple may change labels; the cited help pages govern metric definitions. No portal was accessed in this lane.

After approved deployment/enablement, the default GET selects the previous complete UTC week. An existing admin token is required; keep it out of terminal tracing and screenshots. With `FARSIDE_ADMIN_TOKEN` set privately:

```sh
printf 'Authorization: Bearer %s\n' "$FARSIDE_ADMIN_TOKEN" | curl --silent --show-error --fail --header @- \
  'https://signal.getfarside.com/v1/admin/metrics/weekly'
```

Append `?week=2026-10-05` to select an older complete Monday week within the 90-day retention window. This is a read-only request. Never issue a deploy, migration or secret command during the weekly review.

1. Request the last complete Monday–Sunday UTC scorecard from the authenticated read-only endpoint. If measurement is disabled or the endpoint is unavailable, record `BLOCKED` and do not enable it as part of the weekly review.
2. In App Store Connect, capture the same completed week’s first-time downloads, total downloads, installations, sessions, and active devices. Note platform/app-version filters and usage opt-in context; leave hidden or unavailable values blank with the reason.
3. Capture a matured App Analytics retention cohort’s Day-28 value as the separately labeled app-use proxy. Do not use an immature cohort or treat the value as the week-four successful-user KPI.
4. Capture the Anywhere Active Paid Subscriptions count and observation date when available. Before 31 December this is a trend; on 31 December it is the target check.
5. Paste values into the scorecard below, mark each target `MET`, `NOT MET`, or `NOT MEASURABLE`, and save the dated scorecard with its source/export receipt. Do not fill unavailable data with estimates.

The endpoint emits the service part as Markdown, so normal weekly entry is a copy/paste plus the App Store Connect values. No individual-level export or analytics SDK is part of this workflow.

## Weekly scorecard

Copy one block per review. Use a week starting Monday UTC and record the actual date/time the Apple values were read.

```markdown
## Week of YYYY-MM-DD (Monday UTC)

Reviewed at: YYYY-MM-DD HH:MM UTC
Backend hostname/environment: 
ASC app/platform/version filters: 
ASC usage opt-in context: 
Evidence receipt/path: 

### Acquisition and app use (App Store Connect)

| Metric | Value | Availability / notes |
|---|---:|---|
| First-time downloads | | |
| Total downloads | | Includes first-time downloads and redownloads |
| Installations | | Includes redownloads and installs on multiple devices |
| Sessions | | At least two seconds; opted-in usage only |
| Active devices | | Opted-in usage only |
| Day-28 retention, matured cohort | | Proxy only; not successful-user week-4 retention |

### Anonymous service events (complete week, UTC)

| Event | Count | Interpretation |
|---|---:|---|
| host_registered | | Includes reconnects |
| signaling_ready_free | | Signaling readiness only |
| signaling_ready_anywhere | | Signaling readiness only |
| entitlement_verify_ok | | `entitled=true` response |
| entitlement_verify_rejected | | `entitled=false` or HTTP 401 |

### Outcomes

| Goal | Target | Result | Status |
|---|---|---|---|
| Installs with working picture + control | ≥70% | NOT MEASURABLE from approved sources | NOT MEASURABLE |
| Successful users returning in week 4 (days 22–28) | ≥30% | NOT MEASURABLE from approved sources | NOT MEASURABLE |
| Anywhere active paid subscriptions at 2026-12-31 | 150–200 | | PENDING |

Decision / next action: 
```

## Cost

Use the **existing D1 `DB` binding**, with no new product or dependency. Root/dev and staging already name D1 databases in `Backend/wrangler.jsonc`; production still has a placeholder database ID. The config does not identify the account's actual billing plan; no billing portal was accessed. Both D1 and Analytics Engine have Free allowances. D1 was selected because it stores only daily totals, reuses the existing database/admin authentication, and avoids event timestamps, another binding and query credentials.

Expected incremental cost is **about $0 at launch volumes, conditional on shared account quota headroom**. [D1 pricing](https://developers.cloudflare.com/d1/platform/pricing/) checked 2026-10-02 includes 100,000 written rows/day, 5 million read rows/day and 5 GB storage on Free; Paid includes 50 million writes/month and 25 billion reads/month. Illustrative load: 10,000 counted events/day, budgeted conservatively at two written rows/event, uses 20,000 writes/day. These are planning assumptions, not measured traffic. The five-event table retains at most 91 UTC day buckets (455 rows including the cutoff day) plus an indexed weekly read of at most 35 rows. Cleanup runs on the existing daily cron. Existing entitlement, room and push traffic shares the quotas; exceeding Free quota can interrupt their D1 queries, so inspect account usage before enabling. Do not upgrade as part of this work. [Analytics Engine pricing](https://developers.cloudflare.com/analytics/analytics-engine/pricing/) was also checked; its published Free allowances and currently unbilled usage do not require a new paid plan.

## Implementation and privacy decision

Only `(UTC day, fixed event name, integer count)` is added to `daily_metrics`. No room/install/device/transaction identifier, IP, exact event time, payload, user history or join key is stored there. The SQL event whitelist and schema test enforce that boundary. This does not change the existing operational/security stores or provider logs; it is not a claim that those already contain no identifiers. Do not join the daily totals to those stores or log new event context.

Writes are atomic and scheduled with `waitUntil` after successful registration/result handling. Failures produce a fixed warning without exception details and cannot deny access; totals may undercount. There is no automatic retry/deduplication. Zero means zero recorded events, not proven zero usage. Record the enablement date, disabled periods, outages and deployment version manually; no stored per-day coverage status exists. Queries return 503 when disabled or storage is unavailable, and reject partial/current weeks, invalid dates and dates outside retention. Older weeks disappear from the service after cleanup; save aggregate scorecards if needed.

Measurement is **off by default** (`MEASUREMENT_ENABLED` absent or not exactly `1`). No environment config enables it. The orchestrator must review this lane, apply migration `0007_daily_metrics.sql` before enabling in the intended environment, and handle the production binding placeholder separately. No deployment or remote query occurred here.

Roshan must approve the precise disclosure and label treatment drafted in the lane NOTES before enablement. The existing website says “no crash-reporting or analytics service”; even identifier-free backend product counters need an explicit clarification. Website/privacy drafts, manifests and portal labels were left untouched.

For actual setup failures during TestFlight, use voluntary feedback: ask the tester to state whether a picture appeared and whether a harmless pointer/key action worked, and optionally share existing local Copy Diagnostics. Nothing is uploaded automatically by Farside. This is a biased support sample, not an all-install setup-success percentage; no new app event or UI is added.

## Apple primary sources checked 2026-10-02

- [App Analytics](https://developer.apple.com/app-store-connect/analytics/) — downloads, retention context, and privacy/data-availability caveats.
- [App usage](https://developer.apple.com/help/app-store-connect-analytics/engagement/app-usage/) — definitions of installations, sessions, active devices, and opt-in usage data.
- [App retention](https://developer.apple.com/help/app-store-connect-analytics/engagement/app-retention) — cohort rows, day-offset cells, and denominator behavior.
- [TestFlight build status and metrics](https://developer.apple.com/help/app-store-connect/test-a-beta-version/view-build-status-and-metrics/) — build installs and sessions across testers during the last seven days.
- [Subscriptions in App Analytics](https://developer.apple.com/help/app-store-connect-analytics/monetization/subscriptions) — paid plans, active plans, trials, and subscription lifecycle metrics.
- [View subscription data](https://developer.apple.com/help/app-store-connect/measure-app-performance/view-subscription-data) — definition of active paid subscriptions and where to view the count.
- [Protecting user privacy in report data](https://developer.apple.com/documentation/analytics-reports/privacy) — opt-in and minimum-contributor privacy protections in usage reports.
