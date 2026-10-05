# Supported Smart Zoom and Open app — source extraction handoff

**Disposition: source package ready for independent review and root integration; not compiled, natively tested, installed, or physically accepted.**

Both patches target combined regular checkpoint `84dc0a599d4fa5dc31af128a5c33e6494b68509f`. The isolated archive began at `e96047a9060f0ef156acd3463bcf56dc005019a2` and was rebased to the current checkpoint; the root’s DEBUG launch-orientation addition is retained. No shared combined/main/quality/beta source was edited. The source copy is `/Users/roshansilva/Developer/farside-overnight-quality-20261004/work/overnight/combined-public-zoom-source`; the separate UI proposal is in this chat’s `work/overnight/combined-public-zoom-ui/`.

## Apply boundary

1. Apply `farside-combined-public-zoom-foundation.patch` to the exact base, or review and apply its eight narrow hunks on a newer combined checkpoint. Do not replace a newer whole model/renderer file with the beta version.
2. Review/apply `farside-combined-public-zoom-ui-wiring.patch` separately. It covers only `NativeSessionView.swift` and its `NativeTrackpadSurface.swift` accessibility hint. It is a concrete UI wiring proposal, not acceptance of new native geometry; rebase those hunks over any root-owned edits.
3. Keep the editor/privacy, host authority, feedback, protocol and project files unchanged. Existing test-file memberships already cover the extraction: `project.yml:179` includes the `RemotePhoneTests` directory against the real app; `project.yml:298` includes `RemoteTests` and `RemoteShared` for `RemoteCoreTests`. No new file membership or generator change is needed.

## What was extracted

- `ViewportTransform`: local 2× anchored focus, exact ephemeral return bookmark, and interpolated camera poses. No host resize or virtual display. Letterbox/max-zoom rejection and source/canvas/inset invalidation remain explicit.
- `RemotePhoneApp`: generation-owned viewport transition; pointer-coordinate actions rejected during motion while permitted keys keep their existing sender; older completion cannot retire a newer transition. Geometry/presentation retirement and session end cancel the generation. Drawn tagged crop placement is separate from pending status-echo placement.
- `OwnedMetalVideoView`: current identity/scope/geometry/raster matching, positive original-frame presentation coverage of the complete motion path, both GPU/presentation drain edges, retained endpoint coverage, no compatibility-fallback proof, and generation-checked late callbacks. No decoder or wire change.
- Open app: existing `commandShortcut("space")` only, after current scene/control/token/freshness/hold/composition/text-delivery gates. It deliberately clears local toolbar latches after admission; hardware modifiers and Unicode draft stay owned by their existing lifetimes. It reports sender acceptance only and never types a name, presses Return, reads the clipboard, chooses an app, or opens the keyboard automatically.

## UI wiring contracts

The proposed UI adds a separately labelled “Open app…” / “Spotlight · ⌘Space” row in More, outside the eight-key grid. Its invocation checks current scene, local View, nested Settings, voice, manual editor, permission prompt, frozen-text sheet, precision overlay and motion ownership. More closes only after the sender accepts. Couch retains its previous layout. Portrait reserves 60 points for the new 48-point row plus spacing; accessibility overlay places the row inside the existing scroll area. Ordinary landscape and all accessibility layouts still require native bounds/reachability acceptance.

View receives a named Zoom in / Back to view action with hidden, accessibility-hidden max-label reservation and separate Control escape. No bookmark-driven layout branch or font-size cap is introduced. The renderer must first supply a current covering original presentation; only then does the camera sample one transform for pixels and hit mapping. Reduce Motion jumps after the same proof. A 1.5-second coverage deadline fails closed with a retry message.

Cancellation is wired into existing gesture cancellation, geometry/inset replacement, scene/privacy/disconnect, source identity/scope change, manual pan/pinch/minimap/slider, Fit/Fill, resume, Window Workspace and saved-task-view restoration. Keyboard focus reveal/pointer following and locked mouse cannot modify coordinates during the generation. The reading lens is closed at start, and active frozen-text/precision/editor UI prevents start. Manual keyboard defaults, draft ownership and the new public Window Workspace remain intact.

## Protected-source verification

An archive comparison checked all 1299 files and found exactly the eight foundation files changed. All recorded protected checks pass. In particular, the current renderer `presentedReceipt` body—including original receipt IDs, decode-to-present feedback, and `textSnapshotPresented`—and the complete glass-lens/Metal shader string are byte-identical. Model phone-load sample ingestion, current cancel/release ownership, legacy frame-placement policy and `commandShortcut` body are byte-identical. `CommittedTextField`, `SecureTextFocus`, their tests, `ControlProtocol`, `VideoPresentationAdmission` and `project.yml` are unchanged.

The added lines contain no `FarsideBeta`, `FARSIDE_WORKSPACE_BETA`, `VirtualDisplay`, `VideoPresentedSource`, `rotationSourcePresented`, `NSClassFromString` or `dlsym`. This proves the extraction does not import those features; it does not certify the entire existing Debug host tree as private-API-free. The prior integration audit’s existing DEBUG prototype/scanner caveat remains relevant to the final build route.

Both patches passed source-only applicability checks (foundation reverse against its candidate; UI forward against the exact isolated base UI). No Swift parse, compiler, XcodeGen, native test, simulator, device, build, install, network, or power action was run by this author.

## Semantic risks and native gates

1. **Renderer ownership policy changes even before first zoom.** Every submission, including redraws, now retains both completion edges. This is required to drain pre-existing flights safely when a later transition begins. Current default shader/backing/drawable choices are unchanged, but the old `phoneUnfencedDrawableDisabled` rollback no longer disables this presentation tracking. The renamed test now strictly requires redraw tracking in both optional backing modes. This is correctness policy, not a measured speed improvement.
2. **Positive receipts are mandatory.** Simulator and receipt-free compatibility fallback cannot establish live Smart Zoom coverage; the feature times out truthfully. Older hosts without matching region/scope metadata may likewise be unable to start. Unit tests inject the real receipt closure but do not prove physical Core Animation presentation. The placement test calls `frameDrawn`; its name’s “Presents” suffix must not be mistaken for a physical presentation assertion.
3. **UI and newer-feature interactions need a combined build.** Test same-frame mapping, repeated return, interrupting manual camera edits, source/rotation/inset changes, Window Workspace/task-view restore, frozen text, lens, keyboard Hide/reopen and privacy/end. Preserve current metadata ownership and OCR/lens behavior.
4. **Actual touch bounds remain ≥44.** Inspect native ordinary/AXXXXL portrait/landscape More and View captures; assert individual Open app, Settings, Done, Control, Fit/Fill and Zoom/Back bounds/hittability, reachability, scroll containment and unchanged default manual keyboard. Do not infer these from source frames or from old beta screenshots.

## Focused test selectors and sensitivity

Run existing classes through their real native targets, preserving all prior tests. The extraction adds 21 cases and renames/strengthens one existing presentation-tracking case (22 listed selectors):

- `RemotePhoneTests/OpenAppPhoneTests/testOpenAppRechecksControlFreshnessAndSceneAtInvocation`
- `RemotePhoneTests/OpenAppPhoneTests/testOpenAppRefusesCompositionAndPendingCommittedText`
- `RemotePhoneTests/OpenAppPhoneTests/testOpenAppRefusesHeldMouseWithoutReleasingIt`
- `RemotePhoneTests/OpenAppPhoneTests/testOpenAppRefusesPendingVoiceCommitWithoutChangingDraft`
- `RemotePhoneTests/OpenAppPhoneTests/testOpenAppRejectsMissingAndExpiredNativeTokens`
- `RemotePhoneTests/OpenAppPhoneTests/testOpenAppRejectsRetiredGeometryUntilCurrentAdmission`
- `RemotePhoneTests/OpenAppPhoneTests/testOpenAppRejectsScopedViewAndPendingLock`
- `RemotePhoneTests/OpenAppPhoneTests/testOpenAppRequiresNewSessionAdmissionAfterEnd`
- `RemotePhoneTests/OpenAppPhoneTests/testOpenAppSenderRefusalDoesNotRetryOrCommitDraft`
- `RemotePhoneTests/OpenAppPhoneTests/testOpenAppSendsExactlyCurrentCommandSpaceAndKeepsDraftLocal`
- `RemotePhoneTests/SessionLifecycleTests/testGeometryAndEndRetireViewportTransitionBeforeLateCompletion`
- `RemotePhoneTests/SessionLifecycleTests/testViewportTransitionRejectsPointerInputKeepsKeysAndIgnoresOldCompletion`
- `RemotePhoneTests/SessionLifecycleTests/testVoiceBlockedSmartZoomStartAndCancelledTaskCleanupCannotOrphanOrReplaceFence`
- `RemotePhoneTests/OwnedVideoLifecycleTests/testRetainedEndpointSurvivesUnchangedPoseAndRetiresForEveryManualPoseFamily`
- `RemotePhoneTests/OwnedVideoLifecycleTests/testSmartZoomMotionDrainsOldCropFlightsThenRejectsLateNarrowPresentationAndRetainsSafeEndpoint`
- `RemotePhoneTests/OwnedVideoLifecycleTests/testSmartZoomTracksEveryRedrawPresentationWithLegacyFenceSwitch`
- `RemotePhoneTests/ViewportCaptureTests/testSmartZoomWideningKeepsActualCroppedPixelsPlacedUntilMatchingWholeSourcePresents`
- `RemoteCoreTests/ViewportTransformTests/testSmartZoomCameraSamplesRoundTripAndKeepsEndpointFramingDuringInterruptibleReturn`
- `RemoteCoreTests/ViewportTransformTests/testSmartZoomFocusDoublesPortraitFitWithoutForcingDeepFillCrop`
- `RemoteCoreTests/ViewportTransformTests/testSmartZoomFocusRejectsLetterboxAndBoundsCornersAndMaximumZoom`
- `RemoteCoreTests/ViewportTransformTests/testSmartZoomFocusReturnIsExactAfterManualPanAndPinchForFitAndPannedFill`
- `RemoteCoreTests/ViewportTransformTests/testSmartZoomReturnInvalidatesOnSourceRotationOrKeyboardGeometryReplacement`

After positives, isolated negative copies should prove: (a) Command Space changed to Tab fails the exact packet-key assertion; (b) removing both held-input guards fails the real private-hold test without releasing the hold; (c) removing generation comparison fails the older-completion test; (d) admitting coverage after only one old flight edge fails both GPU-first/presented-first permutations; (e) treating draw/submission or a stale receipt as readiness fails the renderer test; (f) replacing drawn crop placement with the pending status echo fails the old-cropped-pixels case. Restore source and rebuild affected positives. Build failure/zero tests/timeout is not a meaningful negative.

Root owns independent source review, final UI adaptation, native compilation/tests, signed combined regular builds, privacy/private-API scanner checks and installation. Owner manual testing remains parked. Beta removal remains after verified regular replacement and truthful restoration, as separately authorized.

## Exact hashes

Full before/after hashes and check names are in `farside-combined-public-zoom-source-manifest.json`. Patch hashes:

- `farside-combined-public-zoom-foundation.patch`: `6dba1810c04982c338cc3c74366e23435440ba44cff6e64a1270012fc13e9639`
- `farside-combined-public-zoom-ui-wiring.patch`: `58a4fbcd10cd420823cbd20a5a957ab85e1319adbb28b6bfc0ab280dc0d45964`
