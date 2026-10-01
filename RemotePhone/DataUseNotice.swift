import SwiftUI

/// The cellular / metered data notice is offered once per install. It never blocks or ends a session.
struct DataWarningGate {
    static let seenKey = "dataWarning.seen"
    let defaults: UserDefaults

    var seen: Bool { defaults.bool(forKey: Self.seenKey) }
    func shouldOffer(metered: Bool) -> Bool { metered && !seen }
    func markSeen() { defaults.set(true, forKey: Self.seenKey) }
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
        return CommerceLocalization.text("DATA_USE_PRESET", "%@: about %@–%@ GB per hour", quality.title, value.low, value.high,
                                         bundle: bundle, locale: locale)
    }
    static func presetSpoken(_ quality: StreamQuality, _ estimate: DataUseEstimate, bundle: Bundle = .main, locale: Locale = .current) -> String {
        let value = range(estimate, locale: locale)
        return CommerceLocalization.text("DATA_USE_PRESET_SPOKEN", "%@: about %@ to %@ gigabytes per hour", quality.title, value.low, value.high,
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

    static func make(quality: StreamQuality, audio: Bool, bundle: Bundle = .main, locale: Locale = .current) -> DataWarningContent {
        let estimate = DataUseEstimate(quality, audio: audio, packetRepair: false)
        let value = DataUseCopy.range(estimate, locale: locale)
        let lower = quality.lowerDataPreset
        var message = CommerceLocalization.text("DATA_WARNING_BODY", "%@ uses about %@–%@ GB per hour. Files and guest viewers are extra. Your session keeps running.",
                                                quality.title, value.low, value.high, bundle: bundle, locale: locale)
        var spoken = DataUseCopy.presetSpoken(quality, estimate, bundle: bundle, locale: locale)
        if let lower {
            let lowerEstimate = DataUseEstimate(lower, audio: audio, packetRepair: false)
            let lowerValue = DataUseCopy.range(lowerEstimate, locale: locale)
            message += " " + CommerceLocalization.text("DATA_WARNING_LOWER", "%@ uses about %@–%@ GB per hour.", lower.title, lowerValue.low, lowerValue.high,
                                                       bundle: bundle, locale: locale)
            spoken += ". " + DataUseCopy.presetSpoken(lower, lowerEstimate, bundle: bundle, locale: locale)
        }
        let title = CommerceLocalization.text("DATA_WARNING_TITLE", "On cellular or metered data", bundle: bundle, locale: locale)
        return DataWarningContent(title: title, message: message, spoken: spoken, lessData: lower)
    }
}

/// A plate above the session or Home, not a modal: everything behind it stays usable.
struct DataWarningCard: View {
    let content: DataWarningContent
    var useLessData: () -> Void
    var keep: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                        .font(Farside.Typeface.caption(.footnote))
                        .foregroundStyle(Farside.Palette.ash)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(content.spoken)
                }
            }
            HStack(spacing: 10) {
                if let lower = content.lessData {
                    Button(CommerceLocalization.text("DATA_WARNING_LESS", "Use less data"), action: useLessData)
                        .buttonStyle(FarsidePrimaryButtonStyle(height: 40))
                        .accessibilityHint(CommerceLocalization.text("DATA_WARNING_LESS_HINT", "Switches the picture to %@.", lower.title))
                        .accessibilityIdentifier("remote.dataWarning.less")
                }
                Button(CommerceLocalization.text("DATA_WARNING_KEEP", "Keep"), action: keep)
                    .buttonStyle(FarsideSecondaryButtonStyle(height: 40))
                    .accessibilityHint(CommerceLocalization.text("DATA_WARNING_KEEP_HINT", "Keeps the current picture quality. This notice won’t appear again."))
                    .accessibilityIdentifier("remote.dataWarning.keep")
            }
        }
        .padding(16)
        .farsidePlate(Farside.Radius.card, fill: Farside.Palette.panel.opacity(0.97), stroke: Farside.Palette.line2)
        .frame(maxWidth: 420)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("remote.dataWarning")
        .onAppear { AccessibilityNotification.Announcement("\(content.title). \(content.spoken)").post() }
    }
}
