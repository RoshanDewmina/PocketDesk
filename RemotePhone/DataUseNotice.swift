import SwiftUI

/// The cellular / metered data notice is offered once per install. It never blocks or ends a session.
struct DataWarningGate {
    static let seenKey = "dataWarning.seen"
    let defaults: UserDefaults

    var seen: Bool { defaults.bool(forKey: Self.seenKey) }
    func shouldOffer(metered: Bool) -> Bool { metered && !seen }
    func markSeen() { defaults.set(true, forKey: Self.seenKey) }
}

enum StreamQualityPreference {
    static let key = "streamQuality"

    static func stored(in defaults: UserDefaults = .standard) -> StreamQuality {
        PictureModePreference.stored(in: defaults).streamQuality
    }

    static func store(_ quality: StreamQuality, in defaults: UserDefaults = .standard) {
        defaults.set(quality.rawValue, forKey: key)
        defaults.set(PictureMode(quality: quality).rawValue, forKey: PictureModePreference.key)
    }
}

enum PictureModePreference {
    static let key = "pictureMode"
    /// Internal rollback/testing switch: reads the old preset and independent motion keys.
    static let legacyKey = PictureMode.legacyKey

    static func stored(in defaults: UserDefaults = .standard) -> PictureMode {
        if !defaults.bool(forKey: legacyKey),
           let mode = defaults.string(forKey: key).flatMap(PictureMode.init(rawValue:)) { return mode }
        let old = defaults.string(forKey: StreamQualityPreference.key).flatMap(StreamQuality.init(rawValue:))
        let mode = old.map(PictureMode.init(quality:)) ?? .defaultMode
        if !defaults.bool(forKey: legacyKey) {
            // One-time nearest-mode migration. Keep the old keys for mixed-version testing.
            StreamQualityPreference.store(mode.streamQuality, in: defaults)
        }
        return mode
    }

    static func motion(for mode: PictureMode, defaults: UserDefaults = .standard) -> SmoothMotionMode {
        defaults.bool(forKey: legacyKey) ? .stored(defaults) : mode.smoothMotion
    }
}

extension PictureMode {
    /// Auto yields for typing/taps; Always adds delay to precise input as well as motion.
    var smoothMotion: SmoothMotionMode { self == .quality ? .off : .auto }
    func localizedTitle(bundle: Bundle = .main) -> String {
        CommerceLocalization.text(self == .quality ? "PICTURE_MODE_QUALITY" : "PICTURE_MODE_PERFORMANCE",
                                  title, bundle: bundle)
    }
    var localizedDescription: String {
        self == .quality
            ? CommerceLocalization.text("PICTURE_MODE_QUALITY_DETAIL", "Crisp text and full picture detail. No frame interpolation. Uses more bandwidth.")
            : CommerceLocalization.text("PICTURE_MODE_PERFORMANCE_DETAIL", "Lower resolution for responsive control. Smooth motion during scrolling and video adds about one frame of delay while active.")
    }
}

extension StreamQuality {
    var lowerDataPreset: StreamQuality? { self == .sharp ? .balanced : nil }
}

enum DataUseCopy {
    static func range(_ estimate: DataUseEstimate, locale: Locale = .current) -> (low: String, high: String) {
        (DataUseEstimate.display(estimate.lowGBPerHour, locale: locale), DataUseEstimate.display(estimate.highGBPerHour, locale: locale))
    }
    static func presetLine(_ quality: StreamQuality, _ estimate: DataUseEstimate, bundle: Bundle = .main, locale: Locale = .current) -> String {
        let value = range(estimate, locale: locale)
        return CommerceLocalization.text("DATA_USE_PRESET", "%@: about %@–%@ GB per hour", PictureMode(quality: quality).localizedTitle(bundle: bundle), value.low, value.high,
                                         bundle: bundle, locale: locale)
    }
    static func presetSpoken(_ quality: StreamQuality, _ estimate: DataUseEstimate, bundle: Bundle = .main, locale: Locale = .current) -> String {
        let value = range(estimate, locale: locale)
        return CommerceLocalization.text("DATA_USE_PRESET_SPOKEN", "%@: about %@ to %@ gigabytes per hour", PictureMode(quality: quality).localizedTitle(bundle: bundle), value.low, value.high,
                                         bundle: bundle, locale: locale)
    }
    static func note(bundle: Bundle = .main, locale: Locale = .current) -> String {
        CommerceLocalization.text("DATA_USE_NOTE", "Estimates run from a still screen to constant motion, with Mac audio while you listen. Files and guest viewers are counted separately. Experimental relay packet repair adds up to 20%%. Carrier billing adds network overhead.",
                                  bundle: bundle, locale: locale)
    }
}

struct DataWarningContent: Equatable {
    let title: String
    let message: String
    let spoken: String
    let lessData: StreamQuality?

    /// `canLower` is false until the Mac has applied a preset, since only then can the phone change it.
    static func make(quality: StreamQuality, tuning: StreamTuning = .tuned, audio: Bool, canLower: Bool,
                     bundle: Bundle = .main, locale: Locale = .current) -> DataWarningContent {
        let lower = canLower ? quality.lowerDataPreset : nil
        var written: [String] = [], spoken: [String] = []
        for preset in [quality] + (lower.map { [$0] } ?? []) {
            let estimate = DataUseEstimate(preset, tuning: tuning, audio: audio, packetRepair: false)
            let value = DataUseCopy.range(estimate, locale: locale)
            written.append(CommerceLocalization.text("DATA_WARNING_RATE", "%@ uses about %@–%@ GB per hour.", PictureMode(quality: preset).localizedTitle(bundle: bundle), value.low, value.high,
                                                     bundle: bundle, locale: locale))
            spoken.append(DataUseCopy.presetSpoken(preset, estimate, bundle: bundle, locale: locale) + ".")
        }
        let extra = CommerceLocalization.text("DATA_WARNING_EXTRA", "Files and guest viewers are extra. Your session keeps running.", bundle: bundle, locale: locale)
        let title = CommerceLocalization.text("DATA_WARNING_TITLE", "On cellular or metered data", bundle: bundle, locale: locale)
        return DataWarningContent(title: title, message: (written + [extra]).joined(separator: " "),
                                  spoken: (spoken + [extra]).joined(separator: " "), lessData: lower)
    }
}

/// A plate above the session or Home, not a modal: everything behind it stays usable.
struct DataWarningCard: View {
    let content: DataWarningContent
    var useLessData: () -> Void
    var keep: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize && FarsideAccessibilityLayout.enabled {
                ViewThatFits(in: .vertical) {
                    cardContents
                    // In short landscape space, even the actions need to scroll inside the plate.
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) { notice; actionButtons }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
            } else {
                cardContents
            }
        }
        .padding(16)
        .farsidePlate(Farside.Radius.card, fill: Farside.Palette.panel.opacity(0.97), stroke: Farside.Palette.line2)
        // Use the short landscape window's width before spending its limited height on wrapping.
        .frame(maxWidth: dynamicTypeSize.isAccessibilitySize && verticalSizeClass == .compact
            && FarsideAccessibilityLayout.enabled ? .infinity : 420)
        .padding(.horizontal, 16)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("remote.dataWarning")
        .onAppear { AccessibilityNotification.Announcement("\(content.title). \(content.spoken)").post() }
    }

    private var cardContents: some View {
        VStack(alignment: .leading, spacing: 12) {
            // At the largest text sizes the message scrolls and the buttons stack, so both stay on screen.
            ViewThatFits(in: .vertical) {
                notice
                ScrollView { notice.frame(maxWidth: .infinity, alignment: .leading) }.scrollBounceBehavior(.basedOnSize)
            }
            actionButtons
        }
    }

    private var actionButtons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { buttons }
            VStack(spacing: 10) { buttons }
        }
    }

    private var notice: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Farside.Palette.ash)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(content.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Farside.Palette.bone)
                    .accessibilityAddTraits(.isHeader)
                Text(content.message)
                    .font(.footnote)
                    .foregroundStyle(Farside.Palette.ash)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(content.spoken)
            }
        }
    }

    @ViewBuilder private var buttons: some View {
        if let lower = content.lessData {
            Button(CommerceLocalization.text("DATA_WARNING_LESS", "Use less data"), action: useLessData)
                .buttonStyle(FarsidePrimaryButtonStyle(height: 40))
                .accessibilityHint(CommerceLocalization.text("DATA_WARNING_LESS_HINT", "Switches the picture to %@.",
                                                            PictureMode(quality: lower).localizedTitle()))
                .accessibilityIdentifier("remote.dataWarning.less")
        }
        Button(CommerceLocalization.text("DATA_WARNING_KEEP", "Keep"), action: keep)
            .buttonStyle(FarsideSecondaryButtonStyle(height: 40))
            .accessibilityHint(CommerceLocalization.text("DATA_WARNING_KEEP_HINT", "Keeps the current picture quality. This notice won’t appear again."))
            .accessibilityIdentifier("remote.dataWarning.keep")
    }
}
