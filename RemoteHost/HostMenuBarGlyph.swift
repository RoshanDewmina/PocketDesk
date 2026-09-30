import AppKit
import Combine
import SwiftUI

/// One frame of the live menu-bar mark (D39): the same dot glyph, with a brightness wave that runs
/// from the tip down the pointer when a phone connects, an ember halo that breathes while it is
/// connected, and a small ring on each tap from the phone. Idle, paused and attention never animate.
struct HostMarkFrame: Equatable {
    /// Ember halo opacity around the tip.
    var halo: CGFloat = 0.35
    /// The arrival wave's position, 0 at the tip to 1 past the last dot; nil when not arriving.
    var wave: CGFloat?
    /// A tap ring's age, 0…1; nil when there is none.
    var flash: CGFloat?

    static let rest = HostMarkFrame()

    static let breathPeriod: TimeInterval = 2.8
    static let waveDuration: TimeInterval = 0.5
    static let flashDuration: TimeInterval = 0.28

    /// Extra radius for dot `order` of `count` while the arrival wave passes it.
    func swell(at order: Int, of count: Int) -> CGFloat {
        guard let wave, count > 1 else { return 0 }
        let distance = (CGFloat(order) / CGFloat(count - 1) - wave) / 0.18
        return 0.45 * exp(-distance * distance)
    }

    /// The frame at `now`, quantized so an unchanged frame never redraws the status item.
    static func at(_ now: Date, liveSince: Date?, flashAt: Date?) -> HostMarkFrame {
        var frame = HostMarkFrame()
        let breath = 0.5 + 0.5 * sin(now.timeIntervalSinceReferenceDate * 2 * .pi / breathPeriod)
        frame.halo = ((0.18 + 0.3 * CGFloat(breath)) * 16).rounded() / 16
        if let liveSince {
            let age = now.timeIntervalSince(liveSince)
            if age >= 0 && age < waveDuration { frame.wave = (CGFloat(age / waveDuration) * 1.3 * 10).rounded() / 10 }
        }
        if let flashAt {
            let age = now.timeIntervalSince(flashAt)
            if age >= 0 && age < flashDuration { frame.flash = (CGFloat(age / flashDuration) * 6).rounded() / 6 }
        }
        return frame
    }
}

/// Drives the live mark at 12 frames a second, only while a phone is connected and only when
/// Reduce Motion is off. Everything else is the still mark.
@MainActor
final class HostMenuBarGlyph: ObservableObject {
    @Published private(set) var frame = HostMarkFrame.rest

    private var state: HostMarkState = .idle
    private var liveSince: Date?
    private var flashAt: Date?
    private var timer: Timer?
    private var taps: AnyCancellable?

    init(activity: HostActivityFeed) {
        taps = activity.$tapSerial.dropFirst().sink { [weak self] _ in
            Task { @MainActor in self?.tapped() }
        }
    }

    func update(_ next: HostMarkState) {
        guard next != state else { return }
        let arriving = next == .live && state != .live
        state = next
        if arriving {
            liveSince = Date()
            start()
        } else if next != .live {
            stop()
        }
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func tapped() {
        guard state == .live else { return }
        flashAt = Date()
    }

    private func start() {
        guard !reduceMotion else { frame = .rest; return }
        if timer == nil {
            let timer = Timer(timeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        tick()
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        liveSince = nil
        flashAt = nil
        if frame != .rest { frame = .rest }
    }

    private func tick() {
        guard state == .live, !reduceMotion else { stop(); return }
        let next = HostMarkFrame.at(Date(), liveSince: liveSince, flashAt: flashAt)
        if next != frame { frame = next }
    }
}

/// The menu-bar label: the Farside mark for the current state, animated by `HostMenuBarGlyph`.
struct HostMenuBarLabel: View {
    @ObservedObject var glyph: HostMenuBarGlyph
    let state: HostMarkState
    let title: String

    var body: some View {
        Image(nsImage: HostMenuBarIcon.image(for: state, accessibilityDescription: "Farside, \(title)", frame: glyph.frame))
            .accessibilityLabel("Farside, \(title)")
            .onAppear { glyph.update(state) }
            .onChange(of: state) { _, next in glyph.update(next) }
    }
}
