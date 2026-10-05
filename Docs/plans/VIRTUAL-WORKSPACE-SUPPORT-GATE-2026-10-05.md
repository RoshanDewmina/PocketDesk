# Virtual workspace support gate — 5 October 2026

Status: unresolved supported-provider prerequisite; this feature is not implemented for production. The owner requested implementation of all ten, but the reviewed plan requires a supported distributable route before a production virtual display.

Checked Xcode 27.0 SDK public CoreGraphics and DriverKit headers for `CGVirtualDisplay`, `IOUserFramebuffer`, `IOUserGraphics` and `IODisplay`: no creation/provider declaration matched. This bounded search result does not prove that no supported route can exist. Apple’s current DriverKit overview and creation guide describe driver infrastructure without establishing display creation support for this app. Duet and Astropad product documentation supplies no verified distributable integration contract or license for a Farside-created display.

Existing `VirtualDisplaySpike` and `VirtualDisplayPortraitPrototype` remain `#if DEBUG` experiments. Their private class names must not appear in a Release executable. `script/check-virtual-display-release.sh` checks this exclusion. Passing proves only exclusion of those names, not App Review approval, provider support, or headless functionality.

Reopen implementation after obtaining documented Apple creation support or a supported provider contract specifying API, lifecycle, licensing/distribution, signing, macOS compatibility, raster/logical scale, and cleanup ownership. Do not replace that prerequisite with a fake success or a private production API. Cropping a physical desktop is not a virtual display. Features 2 and 6 improve the current display independently.

Sources checked today:

- [DriverKit](https://developer.apple.com/documentation/driverkit)
- [Creating a Driver Using the DriverKit SDK](https://developer.apple.com/documentation/driverkit/creating-a-driver-using-the-driverkit-sdk)
- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [Duet help](https://www.duetdisplay.com/help)
- [Luna Display](https://astropad.com/product/lunadisplay/)

SDK query receipt: task scratch `work/virtual-display-public-sdk-search.txt` (no matching lines). No vendor contact, entitlement request, purchase, or display creation occurred.
