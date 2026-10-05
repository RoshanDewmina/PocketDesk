# Feature 5 PNG clipboard verification

Source checkpoint ff70473 (053f125 implementation, 7760478 receipt/allocation tests, ff70473 raw PNG IHDR bounds). Branch codex/ten-clipboard; isolated base cbe9ce5 plus authorized root common capability commits 79d684f/32bbd45 (local aliases 39a1177/0fdc2da). Generated project remains excluded; root owns canonical project integration.

## Implemented slice

Explicit system Paste control/provider image send to Mac and explicit Get Mac image to phone. PNG transaction on isolated FRC1 bulk namespace sharing transport/governor; SHA/integrity receipt followed by separate actual clipboard commit receipt. One job per endpoint, 20 s uncertain-delivery deadline; 8 MiB encoded, 16M pixels, <=64 MiB decoded raster, RGB/Gray and <=8-bit source restriction, single image only. Orientation normalized; raster re-encoding omits source property dictionaries; alpha retained. Rich data is held in memory and never saved to user files.

Phone never automatically reads image content. User-selected provider file representation is read with an 8 MiB+1 bound. All pasteboard item type metadata is unioned before representations are read. Mac pasteboard lazy reads and writes run on the existing serial clipboard queue; private/password manager/transient/auto-generated markers refuse before representation read. Secure-focus metadata is checked before admitting read/write and again on the serial queue immediately before the effect, with unknown focus refused.

Negotiated mode uses one monotonic Mac source clock for every automatic text chunk and explicit image barrier. Beginning explicit image jobs retires prior text assemblies/read leases/outboxes. Resume samples a fresh change-count baseline, suppresses echo; the phone rejects seen and previously unseen older source revisions. A canceled transaction with an issued revision also preserves that fence. Only new wire-session retirement resets the phone watermark.

Owner control, full display Picture, current epoch, permissions, sharing/connection, foreground/privacy/password/PiP, Away, lock/asleep and Low Data gates apply. Authority loss closes transaction admission; late verified data cannot write. Existing legacy text/picker behavior remains for old peers.

## Checks

- First mac core run: 44 tests passed, `core-first.log`; PNG normalizing/rotation/alpha/high-depth refusal, malformed protocol, namespace isolation, explicit push/pull integrity/commit, cancellation/source replacement/unsolicited offers, host text service + text assembler.
- Final exact ff70473 source core run: **57/57 passed**, `core-preflight.log`; includes raw PNG IHDR preflight before any ImageIO call, malformed/oversized/deep image refusal, premature receipts/retired callbacks, additional lazy privacy union, queued secure-effect/lease, revision/outbox retirement and workspace capability tests. Earlier `core-final.log` was 54/56 passing because a header-only test tried to query ImageIO dimensions; that fixture assertion was replaced with direct bounded preflight, with no oversized decode.
- Host build at 053f125 + tests: **passed**, `host-final.log`. Redundant author host refresh was canceled while still queued (no xcodebuild child had started), per parent request; parent final native script at f964c45 includes ff70473 and covers exact integrated Host Debug + Release. This record does not claim those parent checks have passed.
- Phone app/test build-for-testing at ff70473: **passed**, `phone-final.log`, generic iOS Simulator arm64 and x86_64. Compiled phone ordering tests cover partial/unseen delayed old text, missing revision, fresh newer text, suppressed echo and cancellation/session retirement.

## Actual limits

PNG-only first slice; attributed runs/HTML/RTFD intentionally deferred per parent handoff. OS provider/pasteboard materialization can allocate outside our own bounded encoded/raster buffers; Raw PNG signature/IHDR limits are checked before any ImageIO source/properties call, including incoming verification. Explicit selected other raster formats use ImageIO metadata checks before thumbnail decoding; OS metadata/provider allocation remains outside the accepted final raster budget. No automatic cloud downloads or provider service changes. A queued PNG write may retain its bounded payload behind a hung OS pasteboard provider after lease retirement; retirement prevents the effect, but this implementation does not guarantee immediate purge of queued closure data or a total process-memory cap. No installed app changes, author simulator launch/device install, physical two-device clipboard acceptance, paste-privacy prompt exercise, network loss acceptance or memory benchmark. Real Paste/provider compatibility and UI accessibility remain physical/integrated acceptance checks.

## API freshness

Apple official Markdown documentation checked 2026-10-05: [UIPasteControl](https://developer.apple.com/documentation/uikit/uipastecontrol) (iOS 16+, explicit tap supplies paste contents) and [NSItemProvider.loadFileRepresentation](https://developer.apple.com/documentation/foundation/nsitemprovider/loadfilerepresentation(fortypeidentifier:completionhandler:)) (system temp copy removed after callback; normalization completes inside callback). Local SDK UIKit headers also checked. Web extraction did not read Markdown; direct official-document reads were saved in this work folder.
