# Phone-sized virtual display — 2 October 2026

This is the engineering record for the default-off B8 experiment authorized in PRODUCT. It is not physical acceptance or distribution approval. Lane receipts live in `~/Documents/Codex/2026-10-01/perf-push/b8-vdisplay/`; the checkout is `~/Developer/farside-b8-vdisplay`, branch `claude/b8-vdisplay`.

## Geometry and capture

The phone advertises its actual streamed canvas points, current display scale and maximum refresh rate only after the host advertises `display.virtual.1`. Invalid or unrepresentable canvases explicitly withdraw the viewport. Ordinary peers omit all new metadata.

The requested backing raster is canvas points × phone scale. Mac HiDPI is 2×: an iPhone 17 portrait canvas of 402×874 points at 3× requests 1206×2622 pixels and a 603×1311-point Mac workspace. Landscape swaps the axes. The iPad Air 5 reference is 820×1180 points at 2×, or 1640×2360 pixels. Fractional points are accepted only if both backing axes are exact even integers. Odd rasters, invalid dimensions, excessive area and insufficient negotiated codec budgets fall back; no rounding or stretching is hidden.

The retained, runtime-audited private CGVirtualDisplay is an extended non-main, non-mirrored display. Mode/filter/backing geometry must all agree. A 120 Hz request may retry at 60 Hz. Private API availability, timing and macOS 26 compatibility are not guaranteed by Apple documentation.

The existing ScreenCaptureKit/HEVC route receives the exact raster. Virtual capture ignores preset-size caps, viewport crop and ladder size reductions while retaining receiver budget checks and rate adaptation. Sender degradation preserves resolution in Quality and Performance. Input uses the same SCK logical display geometry; normalized taps map through the exact backing/phone ratio. No ViewportCapture or zoom implementation file was changed.

## Window ownership and restoration

The chosen first A/B scope is the frontmost application's current-Space standard windows, at most eight. It does not make the virtual display main, mirror a physical display, switch Spaces, or automatically follow every app/new window. Mac fullscreen, minimized/off-Space, ambiguous identity and Mac Stage Manager cases are unsupported. Phone/iPad window size changes remain independent of Mac Stage Manager.

Atomic originals are persisted before display creation, because WindowServer creation can itself reflow windows. Targets are persisted before any AX frame write; actual applied frames are persisted afterward. Staggered placement avoids coincident frames. App-enforced overlap or minimum-size refusal rolls back. Live bindings require the same process launch, AX membership and public CG window ID; cold recovery requires a unique current AX/CG frame match, with optional identifier. No title matching or private AX window ID is used.

Restoration precedes display removal. Closed windows and exited/replaced process launches retire their records without touching replacements. Off-Space or inaccessible/ambiguous survivors keep their journal and block another virtual transition. Unknown GUI inventory cannot establish closure. Physical user moves are respected. Failed cleanup retries after unlock/permission availability; quit refuses success while owned resources remain. A crash drops process-owned display objects and relaunch retries the persisted journal, even if the switch is now off. Exact arbitrary Spaces restoration is not a supported public AX operation and is not claimed.

Unexpected disconnect retains the existing 20-second grace, including a disconnect during an awaited resize. Deliberate end, background, Couch, scope/display selection and quit retire immediately. Captured input is fenced during every transition. Late owned removal notifications are ignored only for two seconds and only while the protected physical topology still matches; physical hot-plug/mode/main/mirror changes remain foreign.

## Other features

Big Text is not advertised or accepted while the virtual route is offered/owned. A completed normal-path fallback restores its established behavior. Couch stays on physical screens. The existing opt-in sharing curtain excludes the owned virtual screen and can cover physical screens while capture continues. No physical display mode, main-display or mirror write is introduced. The phone restores its prior Fit/Fill mode and does not persist the virtual route's temporary Fill choice.

## Verification and limits

At this source checkpoint, compilation, tests and granted harness measurements are pending. The lane notes are the receipt authority. The tests cover geometry/mode ownership, prepared/atomic journal recovery, failures and ambiguity, codec admission, optional wire fields and sender policy; async host lifecycle and actual AX/SPI behavior still require execution/acceptance.

The isolated Debug harness dispatches before HostModel creation. Its runner refuses installed/Release paths, requires the exact quiet grant, pins only its own child processes and uses a bounded strict window guard instead of the historical displaystate restoration utility. The guard snapshots before creation and restores/verifies surviving windows and all preexisting display topology afterward. Cleanup remains callable after grant withdrawal; withdrawal or unverified restoration fails the receipt. No permissions are prompted or reset.

Capture callback rate, changing-content rate, encoder/network delivery and phone presentation are separate measurements. The harness must not label SCK callbacks as delivered phone fps. The connection survives a resize, but the existing phone geometry epoch retires live presentation, so rotation can briefly blank. Seamless rotation/no black flash is not implemented in this candidate. A safe future frozen frame requires separate bounded authority and actual tagged presentation receipts; retaining the old live admission is unsafe. Rotation gap and a recorded physical handoff remain acceptance gates. App following, true 3× Mac logical scaling, arbitrary Spaces recovery and private-SPI distribution remain limits of this first A/B candidate.

## Orchestrator A/B

After integration, successful builds/tests/review and acceptance of the granted harness receipts, update the host only from the integrated main checkout through its normal identity-preserving installer. This lane never installs.

Enable, then restart the integrated host:

```sh
defaults write com.roshan.PocketDesk.RemoteHost farsideVirtualDisplayEnabled -bool YES
```

Return to baseline, then restart:

```sh
defaults write com.roshan.PocketDesk.RemoteHost farsideVirtualDisplayEnabled -bool NO
```

Compare the same normal app and text in portrait/landscape and iPad window sizes. Pass requires exact reported backing pixels, aligned taps, unchanged physical display mode/main/mirror state, clean end/drop/Couch restoration, and an acceptable measured rotation gap. Check crash/relaunch recovery in a separate approved physical window. A candidate with missing receipts is not ready for this A/B.
