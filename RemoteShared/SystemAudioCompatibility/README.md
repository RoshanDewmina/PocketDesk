# Public WebRTC audio-device compatibility header

`RTCAudioDevice.h` is an **unmodified** copy of the public header in the iOS arm64 slice of the project's pinned stasel/WebRTC **153.0.0** XCFramework. It repairs a packaging omission: the macOS factory publishes `initWithEncoderFactory:decoderFactory:audioDevice:` and contains the Objective-C audio-device implementation, but the macOS slice omits the matching protocol header. No binary, private symbol, runtime swizzle or dependency version is changed.

- Package revision: `4266157cd08f92115de885ab12d87196a8db87e1`.
- Artifact: `https://github.com/stasel/WebRTC/releases/download/153.0.0/WebRTC-M153.xcframework.zip`.
- Declared SwiftPM checksum: `3e3a8946f27510133e3feed04d05fa23505bbe366e977620503bfc7986c2b78f`.
- Exact public header SHA-256: `8b4bdd60ab38c0a092da4b1ad6064946a77b0ffe95c2e116a1643c8d8ca3d83d`.
- Inspected cached macOS universal framework binary SHA-256: `0ceab88884a7f4f0657dcd8c8db14e74ff9f101e385a7806113b517c6f71cce7`.

The archive checksum above is the package manifest's declared provenance; this work used SwiftPM's existing cached extraction and did not independently redownload/hash the original archive. `SystemAudioDeviceTests.testPinnedMacFactoryActuallyInitializesInjectedDevice` confirms actual runtime initialization against that macOS binary. `SystemAudioTransportTests` exercises synthetic fixture PCM over real loopback Opus RTP, with custom devices on both sides and no microphone/speaker hardware. Neither is evidence of real ScreenCaptureKit or phone playback acceptance.

The original copyright and BSD license reference remain in the header. The full distribution notice is `Docs/WebRTC-distribution-license.md`. Recheck the public header, ABI and tests when changing the pinned dependency; prefer removing this compatibility copy if upstream publishes the macOS header.
