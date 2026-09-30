> Researched 29 Sep 2026 · Decision: Buffer Essentials via its API.

# Farside social posting: what can be automated per platform (checked 2026-09-29)

**Bottom line:** Don't use Codex computer-use "to be safe". It is the riskiest option. X's own guidelines say browser automation gets an account permanently suspended [12]. Instagram's terms forbid accessing it "in an automated way without our express permission" [44]. The official APIs, and schedulers built on them, are the permitted route.

## Per-platform table

Setup times are my estimates, not documented figures.

| Platform | Can he post programmatically to his own new account today? | What's needed | Blockers / gotchas | Setup |
|---|---|---|---|---|
| **Instagram** | **Yes** | A Creator or Business account. A Meta app using Instagram Login, which needs no Facebook Page [3]. Permissions `instagram_business_basic` and `instagram_business_content_publish` [1]. Standard Access is enough for your own account, with no App Review or business verification [4][5]. | The API has no scheduling parameter; the scheduler has to call `media_publish` at the right time. Media must be at a public URL (Reels can also use `rupload`). Unpublished containers expire after 24 h. Limit is 100 API posts per rolling 24 h [1]. Carousels hold up to 10 items and can mix images and video [1]. Captions: 2,200 characters, 30 hashtags, 20 @tags. Reels support `cover_url`, `thumb_offset` and `audio_name`. Images must be JPEG [2]. | ~1–2 h |
| **Threads** | **Yes** | A Meta app with the Threads use case. Add yourself as a Threads Tester; testers need no App Review. Permissions `threads_basic` and `threads_content_publish` [8]. | 250 posts and 1,000 replies per 24 h. Text up to 500 characters. Video up to 5 min / 1 GB [7]. No more than 5 links per post. Carousels take 2–20 items, mixed allowed [6]. Tokens last 1 h and can be swapped for 60-day tokens that refresh [8]. No native scheduling is documented. | ~1 h |
| **X** | **Yes, paid** | Pay-per-use credits bought in the developer console. There are no subscriptions and no free tier [9]. Video uploads in chunks (INIT/APPEND/FINALIZE/STATUS) [11]. | $0.015 per post; **$0.20 per post containing a URL**, effective 2026-04-20 [9][10]. Since 2026-02-23 the API only allows a reply if the original author @mentioned or quoted you [10]. Whether replying to your own thread counts is not addressed (unverified). | ~1 h |
| **TikTok** | **Not publicly with his own app** | Content Posting API with the `video.publish` scope, plus a creator-info query before each post [14]. | Until an app passes TikTok's audit, everything it posts is private [14], and only to private accounts [15]. The guidelines list "a utility tool to help upload contents to the account(s) you or your team manages" as **not acceptable** [17], so an audit for a personal tool is unlikely. The draft/inbox upload route allows at most 5 pending shares per 24 h, and you finish the post in the app [16]. A search snippet of [17] says about 15 posts per creator per day, shared across all tools (not directly verified). | Via Buffer: ~15 min |
| **YouTube Shorts** | **Private-only with his own project** | `videos.insert` with the `youtube.upload` scope. `status.publishAt` schedules [18]. Vertical or square videos up to 3 min count as Shorts automatically [20]. | Uploads from unverified projects created after 28 Jul 2020 are private until the project passes an audit [18]. Default limit is 100 `videos.insert` calls per day [19]. In OAuth "Testing" mode, refresh tokens expire after 7 days [21]. | Via Buffer: ~15 min |

## Schedulers

**Buffer**
- **Channels:** Instagram, Threads, TikTok, X, YouTube and others [23].
- **Pricing:** Free covers 3 channels with 10 scheduled posts each. Essentials is $5 per channel per month and Team is $10; both have a 14-day trial [23].
- **API:** A GraphQL API on every plan, including Free [24]. `createPost` with `mode: customScheduled` and `dueAt` schedules posts [26]. Rolling limits are 100 requests per 15 min and 250 per 24 h on Free/Essentials [25].
- **API limits:** Media goes in as public URLs only, with no direct upload. Custom video thumbnails can't be set through the API [24].
- **Instagram:** Automatic publishing needs a Business or Creator account. **Carousels are images only (no mixed media)**, max 10. Reels can run 3 s to 15 min. Music, stickers, collabs and topics switch the post to "Notify Me" (finish it yourself in the app) [27].
- **TikTok:** Publishes automatically. Videos 3 s to 10 min, or up to 10 images [28].
- **YouTube:** Shorts up to 3 min publish automatically, but YouTube's music library isn't available (from a search snippet of [29]).

**Postiz** (open-source, self-hostable)
- **Maturity:** AGPL-3.0, 36.5k stars, v2.24.0 released 2026-09-22, 247 open issues/PRs, last push today [38].
- **Platforms:** Supports 34, including Instagram (via a Facebook Business Page or standalone), Threads, X, TikTok and YouTube [30][32].
- **Own apps required:** Self-hosters must **register their own developer app on each platform** [30].
- **TikTok on self-host:** Needs an HTTPS redirect URL and publicly reachable media on a verified domain. It stays private-only until the app is audited [31].
- **Docker:** Needs Postgres 14+, Redis 6+ and Temporal (required since v2.12.0). Minimum 2 vCPU / 2 GB RAM; 4 vCPU / 8 GB recommended [34].
- **Programmatic access:** A public API (create-post capped at 90/h on self-host, adjustable via `API_LIMIT`), a CLI, and an MCP server at `/mcp` [35][36].
- **Postiz Cloud:** From $29/mo for 5 channels, with API and MCP included [37]. I couldn't confirm whether its TikTok app is audited.

**Other options**
- **Publer:** CSV bulk upload of up to 500 posts on the Professional plan (from $5 per account). The API is Business plan only (from $10) and covers Threads, TikTok, Instagram, YouTube and X [39][40][41].
- **Metricool:** CSV import with Instagram post/reel/story types, Threads, TikTok and YouTube. Which plan includes it is unverified (from a search snippet of [42]).
- **Typefully:** API covers X and Threads but not Instagram or TikTok, so it only fits part of the kit (from a search snippet of [43]).
- **Later:** not verified.

## Platform rules on automation

- **X:** "Use only the official X API. No scraping, browser automation, or unofficial methods. Violations result in permanent suspension." [12] Auto-likes, bulk follow/unfollow and unsolicited replies are prohibited. Automated accounts posting scheduled content are marked as allowed. Automated accounts must turn on the "Automated" label. My reading is that a founder scheduling his own posts isn't a bot, but that is an interpretation.
- **Meta (Instagram and Threads):** The terms forbid "creating accounts or accessing or collecting information in an automated way without our express permission" [44]. The publishing API is that permission.
- **TikTok:** The terms ban automated bots and scraping [45]. The Community Guidelines reportedly ban "automation to register or operate accounts in bulk" and bot-driven engagement. That page is JS-rendered and I only saw it through secondary sources, so treat it as unverified [46].
- **New accounts:** I found no official statement about new accounts specifically. Everything above makes UI bots the unsanctioned path.

## Creating the accounts programmatically

No platform offers an official way to do this.
- **YouTube:** the channels resource supports only `list` and `update`; there is no insert [22].
- **Instagram:** the terms explicitly bar automated account creation [44].
- **TikTok:** bans automated bulk registration (secondary sources only).
- **X:** I found no account-creation endpoint in the API docs. That is an absence I observed, not a stated policy.

## Recommendations

**(A) Fastest reliable path this week: Buffer Essentials.**
- Connect 4 channels ($20/mo), or 5 with YouTube ($25/mo). The 14-day trial covers the launch calendar [23].
- Put the MP4s and images somewhere with public URLs, such as R2 or S3, then have a short script send the 14-day calendar through Buffer's API [24][26].
- This means no developer apps, no X API bill, and TikTok and Shorts go out **public** (Buffer auto-publishes).
- Caveats: carousels must be images only, and Reel covers have to be set in Buffer's web UI [24][27].

**(B) Most programmable path: self-hosted Postiz on the PC, run as a hybrid.**
- Run Postiz under WSL2 Docker and expose it with a public HTTPS tunnel (Postiz needs an HTTPS callback URL and publicly reachable media) [30][31].
- Register his own apps for:
  - **Meta:** Instagram Login + Threads, Standard Access, no review needed.
  - **X:** pay-per-use credits. Postiz can strip links from X posts (`STRIP_LINKS_FROM_X_POSTS`) to avoid the $0.20 rate [33].
- Drive it from agents through the Postiz API or MCP [35][36].
- **Keep TikTok, and YouTube until its audit is done, on Buffer or Postiz Cloud.** Self-built apps for those two post privately only [14][18].

## What must stay manual

- Creating every account, including email/phone verification and 2FA.
- Switching Instagram to a Creator or Business account.
- The first OAuth "connect" click for each channel.
- Registering developer apps and buying X credits.
- Posts that use licensed music, stickers or collabs (Buffer switches these to "Notify Me") [27].
- **All replies and engagement.** X blocks unsummoned API replies [10], and automated likes or follows are prohibited on X [12]; TikTok's guidelines reportedly ban bot-driven engagement too (unverified).
- Reconnecting channels when tokens expire (Threads 60 days; Google "Testing" mode every 7 days) [8][21].

## Sources

1. https://developers.facebook.com/docs/instagram-platform/content-publishing
2. https://developers.facebook.com/docs/instagram-platform/instagram-graph-api/reference/ig-user/media
3. https://developers.facebook.com/docs/instagram-platform/instagram-api-with-instagram-login
4. https://developers.facebook.com/docs/instagram-platform/overview/
5. https://developers.facebook.com/docs/graph-api/overview/access-levels
6. https://developers.facebook.com/docs/threads/posts
7. https://developers.facebook.com/docs/threads/overview
8. https://developers.facebook.com/docs/threads/get-started
9. https://docs.x.com/x-api/getting-started/pricing
10. https://docs.x.com/changelog (secondary coverage: https://techcrunch.com/2026/04/22/x-makes-it-more-expensive-to-post-links-through-its-api/)
11. https://docs.x.com/x-api/media/quickstart/media-upload-chunked
12. https://docs.x.com/developer-guidelines (help.x.com automation rules page returned 403)
13. (unused)
14. https://developers.tiktok.com/docs/en/content-posting-api-get-started
15. https://developers.tiktok.com/docs/en/content-posting-api-reference-direct-post
16. https://developers.tiktok.com/docs/en/content-posting-api-reference-upload-video
17. https://developers.tiktok.com/docs/en/content-sharing-guidelines
18. https://developers.google.com/youtube/v3/docs/videos/insert
19. https://developers.google.com/youtube/v3/determine_quota_cost
20. https://support.google.com/youtube/answer/15424877
21. https://developers.google.com/identity/protocols/oauth2
22. https://developers.google.com/youtube/v3/docs/channels
23. https://buffer.com/pricing
24. https://support.buffer.com/en-us/articles/what-is-buffers-api-GtIYIQilz5
25. https://developers.buffer.com/guides/api-limits.html
26. https://developers.buffer.com/examples/
27. https://support.buffer.com/en-us/articles/scheduling-instagram-posts-reels-stories-and-notifications-3XA98S9Q5p
28. https://support.buffer.com/en-us/articles/using-tiktok-with-buffer-oGEroY9Of2
29. https://support.buffer.com/article/562-using-youtube-shorts-with-buffer (search snippet)
30. https://docs.postiz.com/self-host/providers/overview.md
31. https://docs.postiz.com/self-host/providers/tiktok.md
32. https://docs.postiz.com/self-host/providers/instagram.md
33. https://docs.postiz.com/self-host/providers/x-twitter.md
34. https://docs.postiz.com/self-host/installation/system-requirements.md
35. https://docs.postiz.com/public-api/introduction.md
36. https://docs.postiz.com/mcp/introduction.md
37. https://docs.postiz.com/cloud/plans.md
38. https://github.com/gitroomhq/postiz-app (GitHub API queried 2026-09-29)
39. https://publer.com/help/en/article/how-to-schedule-in-bulk-16hbbj4/
40. https://publer.com/help/en/article/what-are-publers-plans-and-pricing-15h4yqh/
41. https://publer.com/docs
42. https://metricool.com/import-csv-for-scheduling/ (search snippet)
43. https://support.typefully.com/en/articles/8718287-typefully-api (search snippet)
44. https://www.facebook.com/help/581066165581870 (Instagram Terms of Use)
45. https://www.tiktok.com/legal/page/us/terms-of-service/en
46. https://www.tiktok.com/community-guidelines (not directly readable)
