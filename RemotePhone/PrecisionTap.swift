import SwiftUI
import UIKit
import WebRTC

/// One Precision Tap: the finger moves the target at half speed for fine adjustment, and a slide far
/// from where it started, or off the canvas, arms a cancel. Canvas coordinates throughout.
struct PrecisionTap: Equatable {
    static let gain: CGFloat = 0.5
    static let cancelTravel: CGFloat = 96

    let fingerStart: CGPoint
    let anchor: CGPoint
    private(set) var finger: CGPoint
    private(set) var target: CGPoint
    private(set) var cancelArmed = false

    init?(finger: CGPoint, in viewport: ViewportTransform) {
        guard viewport.sourcePoint(fromView: finger) != nil else { return nil }
        fingerStart = finger
        anchor = finger
        self.finger = finger
        target = finger
    }

    mutating func move(to finger: CGPoint, in viewport: ViewportTransform) {
        guard finger.x.isFinite, finger.y.isFinite else { return }
        self.finger = finger
        let proposed = CGPoint(x: anchor.x + (finger.x - fingerStart.x) * Self.gain,
                               y: anchor.y + (finger.y - fingerStart.y) * Self.gain)
        let picture = viewport.contentRect.intersection(CGRect(origin: .zero, size: viewport.canvasSize))
        if !picture.isNull, picture.width > 0, picture.height > 0 {
            target = CGPoint(x: min(max(proposed.x, picture.minX), picture.maxX),
                             y: min(max(proposed.y, picture.minY), picture.maxY))
        }
        let canvas = CGRect(origin: .zero, size: viewport.canvasSize)
        cancelArmed = hypot(finger.x - fingerStart.x, finger.y - fingerStart.y) > Self.cancelTravel
            || !canvas.contains(finger)
    }

    /// The Mac display point a lift would click, or nil when lifting cancels.
    func sourceTarget(in viewport: ViewportTransform) -> CGPoint? {
        cancelArmed ? nil : viewport.sourcePoint(fromView: target)
    }
}

/// Maps a target on the Mac display into the loupe: which part of the decoded frame to show and where
/// the exact click point falls inside the circle.
struct LoupeGeometry: Equatable {
    static let diameter: CGFloat = 132
    static let magnification: CGFloat = 3

    /// The shown square as a fraction of the decoded frame (0...1 on both axes).
    let crop: CGRect
    /// The click point in loupe coordinates, 0...diameter.
    let crosshair: CGPoint
    /// Display points shown across the loupe.
    let span: CGFloat

    /// `scale` is the viewport's display-point-to-canvas scale. `region` is where the decoded frames sit on
    /// the display: a cropped capture covers only its region, whole-display capture covers `displaySize`.
    static func make(target: CGPoint, scale: CGFloat, region: CaptureRegion?, displaySize: CGSize,
                     diameter: CGFloat = diameter, magnification: CGFloat = magnification) -> LoupeGeometry? {
        let frame = region.map { $0.isWholeDisplay ? CGRect(origin: .zero, size: displaySize) : $0.rect }
            ?? CGRect(origin: .zero, size: displaySize)
        guard scale > 0, scale.isFinite, diameter > 0, magnification > 0, frame.width > 0, frame.height > 0,
              target.x.isFinite, target.y.isFinite,
              target.x >= frame.minX, target.x <= frame.maxX,
              target.y >= frame.minY, target.y <= frame.maxY else { return nil }
        let span = min(diameter / (scale * magnification), frame.width, frame.height)
        let originX = min(max(target.x - span / 2, frame.minX), frame.maxX - span)
        let originY = min(max(target.y - span / 2, frame.minY), frame.maxY - span)
        let crop = CGRect(x: (originX - frame.minX) / frame.width, y: (originY - frame.minY) / frame.height,
                          width: span / frame.width, height: span / frame.height)
        let crosshair = CGPoint(x: (target.x - originX) / span * diameter, y: (target.y - originY) / span * diameter)
        return LoupeGeometry(crop: crop, crosshair: crosshair, span: span)
    }

    /// Where the loupe's centre sits: above the finger, or below it near the top, inside `safe`.
    static func placement(finger: CGPoint, safe: CGRect, diameter: CGFloat = diameter) -> CGPoint {
        let lift = diameter / 2 + 56
        var y = finger.y - lift
        if y - diameter / 2 < safe.minY + 8 { y = finger.y + lift }
        let x = min(max(finger.x, safe.minX + diameter / 2 + 8), safe.maxX - diameter / 2 - 8)
        return CGPoint(x: x, y: min(max(y, safe.minY + diameter / 2), safe.maxY - diameter / 2))
    }

    /// Integer pixel crop inside a buffer's own crop, on even offsets so 4:2:0 chroma stays aligned.
    static func pixelCrop(_ crop: CGRect, baseX: Int, baseY: Int, baseWidth: Int, baseHeight: Int)
        -> (x: Int, y: Int, width: Int, height: Int)? {
        guard baseWidth >= 2, baseHeight >= 2 else { return nil }
        func even(_ value: CGFloat) -> Int { Int(value / 2) * 2 }
        let x = even(crop.minX * CGFloat(baseWidth)), y = even(crop.minY * CGFloat(baseHeight))
        let width = max(2, even(crop.width * CGFloat(baseWidth))), height = max(2, even(crop.height * CGFloat(baseHeight)))
        guard x >= 0, y >= 0 else { return nil }
        return (baseX + min(x, baseWidth - 2), baseY + min(y, baseHeight - 2),
                min(width, baseWidth - min(x, baseWidth - 2)), min(height, baseHeight - min(y, baseHeight - 2)))
    }
}

/// Owns the live Precision Tap for the session view and turns a lift into one ordinary click.
@MainActor
final class PrecisionTapController: ObservableObject {
    @Published private(set) var tap: PrecisionTap?
    @Published private(set) var sequence: UInt64 = 0
    private var lastSent: CGPoint?

    func handle(_ phase: PrecisionPhase, finger: CGPoint, viewport: ViewportTransform, model: PhoneRemoteModel) -> Bool {
        switch phase {
        case .began:
            guard model.canControl, let started = PrecisionTap(finger: finger, in: viewport) else { return false }
            tap = started
            lastSent = nil
            sequence &+= 1
            UIAccessibility.post(notification: .announcement,
                                 argument: "Precision Tap. Lift to click, slide away to cancel.")
            return true
        case .moved:
            guard var current = tap else { return false }
            current.move(to: finger, in: viewport)
            tap = current
            if let source = current.sourceTarget(in: viewport), source != lastSent, model.pointTo(source) {
                lastSent = source
            }
            return true
        case .ended:
            guard var current = tap else { return false }
            current.move(to: finger, in: viewport)
            tap = nil
            guard let source = current.sourceTarget(in: viewport), model.pointTo(source) else { return false }
            return model.gesture(.click(count: 1))
        case .cancelled:
            tap = nil
            return true
        }
    }

    #if DEBUG
    /// Offline screenshots: a loupe over a small dock target, with no Mac to click.
    func previewForTesting(viewport: ViewportTransform) {
        let source = CGPoint(x: viewport.sourceSize.width * 0.5, y: viewport.sourceSize.height * 0.93)
        tap = PrecisionTap(finger: viewport.viewPoint(fromSource: source), in: viewport)
        sequence &+= 1
    }
    #endif
}

/// The loupe is an owned derivative with the same current authenticated admission,
/// global terminal invalidation and expiry as the main surface. It never owns timing.
struct LoupeVideo: View {
    let track: RTCVideoTrack
    let crop: CGRect
    let admission: VideoPresentationAdmission
    var body: some View {
        RemoteVideoSurface(track: track, fillsFrame: true, smoothMotion: .off, primary: false,
            admission: admission, sourceCrop: crop, onFrame: {})
    }
}

/// The magnified circle over the session. The ember dot is the exact point a lift clicks.
struct PrecisionLoupeOverlay: View {
    @ObservedObject var controller: PrecisionTapController
    @ObservedObject var model: PhoneRemoteModel
    let viewport: ViewportTransform
    let track: RTCVideoTrack?
    let offline: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let tap = controller.tap, let source = viewport.sourcePoint(fromView: tap.target),
               let geometry = LoupeGeometry.make(target: source, scale: viewport.scale, region: model.placementRegion,
                                                 displaySize: viewport.sourceSize) {
                loupe(geometry, source: source, cancelling: tap.cancelArmed)
                    .position(LoupeGeometry.placement(finger: tap.finger, safe: viewport.safeRect))
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(reduceMotion ? .easeInOut(duration: 0.14) : Farside.Motion.easeOut(Farside.Motion.micro),
                   value: controller.tap == nil)
        .allowsHitTesting(false)
        .sensoryFeedback(trigger: controller.sequence) { _, _ in model.hapticsEnabled ? .impact(weight: .medium) : nil }
        .sensoryFeedback(trigger: controller.tap?.cancelArmed) { old, new in
            model.hapticsEnabled && old != nil && new != nil ? .selection : nil
        }
        #if DEBUG
        .task(id: viewport.canvasSize) {
            guard offline, LaunchOptions.has("--ui-precision-preview"), controller.tap == nil,
                  viewport.canvasSize.width > 0, viewport.scale > 0 else { return }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            controller.previewForTesting(viewport: viewport)
        }
        #endif
    }

    private func loupe(_ geometry: LoupeGeometry, source: CGPoint, cancelling: Bool) -> some View {
        let diameter = LoupeGeometry.diameter
        return ZStack(alignment: .topLeading) {
            Farside.Palette.void2
            if let track, !model.contentConcealed, let admission = model.inlinePresentationAdmission {
                LoupeVideo(track: track, crop: geometry.crop, admission: admission)
                    .frame(width: diameter, height: diameter)
            } else if offline {
                let zoom = diameter / geometry.span
                let origin = CGPoint(x: source.x - geometry.crosshair.x / zoom, y: source.y - geometry.crosshair.y / zoom)
                DesktopPreview(size: viewport.sourceSize)
                    .scaleEffect(zoom, anchor: .topLeading)
                    .offset(x: -origin.x * zoom, y: -origin.y * zoom)
                    .frame(width: diameter, height: diameter, alignment: .topLeading)
            }
            crosshair.position(geometry.crosshair)
        }
        .frame(width: diameter, height: diameter)
        .clipShape(.circle)
        .overlay { Circle().strokeBorder(Farside.Palette.bone.opacity(0.9), lineWidth: 2) }
        .overlay { Circle().strokeBorder(Farside.Palette.void.opacity(0.7), lineWidth: 1).padding(2) }
        .opacity(cancelling ? 0.45 : 1)
        .overlay(alignment: .bottom) {
            if cancelling {
                Text("Release to cancel")
                    .font(Farside.Typeface.caption(.caption))
                    .foregroundStyle(Farside.Palette.bone)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Farside.Palette.void, in: .capsule)
                    .offset(y: 28)
            }
        }
        .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(cancelling ? "Precision Tap, release to cancel" : "Precision Tap, release to click")
        .accessibilityIdentifier("remote.precisionLoupe")
    }

    private var crosshair: some View {
        ZStack {
            Rectangle().fill(Farside.Palette.bone).frame(width: 22, height: 1.5)
            Rectangle().fill(Farside.Palette.bone).frame(width: 1.5, height: 22)
            Circle().fill(Farside.Palette.ember).frame(width: 6, height: 6)
                .overlay { Circle().strokeBorder(Farside.Palette.void, lineWidth: 1) }
        }
        .shadow(color: .black.opacity(0.6), radius: 1)
    }
}

struct PrecisionTapSettingsSection: View {
    let directTouch: Bool
    @AppStorage(PrecisionTapTrigger.key) private var trigger: PrecisionTapTrigger = .off

    var body: some View {
        Section {
            Picker("Precision Tap", selection: $trigger) {
                Text("Off").tag(PrecisionTapTrigger.off)
                Text("Touch and hold").tag(PrecisionTapTrigger.hold)
                Text("Every tap").tag(PrecisionTapTrigger.always)
            }
            .foregroundStyle(Farside.Palette.bone)
            .accessibilityIdentifier("remote.precisionTap")
            .listRowBackground(Farside.Palette.panel)
        } header: {
            Text("Precision Tap")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Farside.Palette.ash)
                .textCase(nil)
        } footer: {
            Text(directTouch
                 ? "A magnifier shows the exact point under your finger. Slide to fine-tune at half speed, lift to click, or slide away to cancel. Touch and hold still drags if you move first."
                 : "Precision Tap works with Direct touch, where your finger covers what you tap.")
                .foregroundStyle(Farside.Palette.ash)
        }
    }
}
