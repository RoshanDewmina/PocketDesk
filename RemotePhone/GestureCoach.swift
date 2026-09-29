import SwiftUI

/// First-run steps that sit above everything else: permission priming and the gesture coach.
@MainActor
final class OnboardingFlow: ObservableObject {
    enum Step: Identifiable, Equatable {
        case priming(PermissionKind)
        case coach
        var id: String {
            switch self {
            case .priming(let kind): "priming.\(kind.rawValue)"
            case .coach: "coach"
            }
        }
    }

    static let coachSeenKey = "coach.seen"
    @Published var step: Step?
    private var afterPriming: (() -> Void)?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        #if DEBUG
        if LaunchOptions.has("--ui-coach") { step = .coach }
        if LaunchOptions.has("--ui-priming-network") { step = .priming(.localNetwork) }
        if LaunchOptions.has("--ui-priming-mic") { step = .priming(.microphone) }
        if LaunchOptions.has("--ui-priming-camera") { step = .priming(.camera) }
        #endif
    }

    var coachSeen: Bool { defaults.bool(forKey: Self.coachSeenKey) }

    /// Explains Local Network once before the first connection, then runs `start`.
    func beforeConnect(_ start: @escaping () -> Void) {
        guard PermissionPrimer.needsPriming(.localNetwork, in: defaults) else { start(); return }
        afterPriming = start
        step = .priming(.localNetwork)
    }

    /// After a new pairing the Mac still has to approve; use that wait for priming and the coach.
    func afterPairing() {
        if PermissionPrimer.needsPriming(.localNetwork, in: defaults) {
            afterPriming = { [weak self] in self?.offerCoach() }
            step = .priming(.localNetwork)
        } else {
            offerCoach()
        }
    }

    /// Shown once, automatically; replayable from Home.
    func offerCoach() {
        guard !coachSeen, !LaunchOptions.suppressesOnboarding, step == nil else { return }
        step = .coach
    }

    func replayCoach() { step = .coach }

    func primingFinished() {
        step = nil
        let next = afterPriming
        afterPriming = nil
        guard let next else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { next() }
    }

    func coachFinished() {
        defaults.set(true, forKey: Self.coachSeenKey)
        step = nil
    }
}

/// Local practice pad state. Commands come from the real gesture engine; nothing is sent anywhere.
@MainActor
final class GestureCoachModel: ObservableObject {
    enum Lesson: Int, CaseIterable, Identifiable {
        case move, click, scroll, drag, zoom
        var id: Int { rawValue }

        var name: String {
            switch self {
            case .move: "Move"
            case .click: "Click"
            case .scroll: "Scroll"
            case .drag: "Drag"
            case .zoom: "Zoom"
            }
        }

        var heading: String {
            switch self {
            case .move: "Slide one finger to point."
            case .click: "Tap anywhere to click."
            case .scroll: "Two fingers to scroll."
            case .drag: "Double tap, hold, slide."
            case .zoom: "Pinch to zoom the view."
            }
        }

        var lead: String {
            switch self {
            case .move: "The pointer moves from where it is."
            case .click: "Your finger doesn’t go to the button."
            case .scroll: "One finger points, two fingers scroll."
            case .drag: "Tap once, then tap again and keep your finger down."
            case .zoom: "Pinching zooms your view of the Mac, not the Mac itself."
            }
        }

        var detail: String {
            switch self {
            case .move: "It won’t jump to your finger. Put it on the one crisp pixel. The pixel is shy, so go gently."
            case .click: "The pointer is already on it; a tap anywhere clicks right there. Try it on this pad."
            case .scroll: "Scroll to the end of the terms nobody reads."
            case .drag: "Now slide to carry the file. Lift to drop it in the folder."
            case .zoom: "Spread two fingers apart until you can read the fine print."
            }
        }

        var hint: String {
            switch self {
            case .move: "Slide anywhere on the pad. Small, slow moves are precise; quick flicks travel far."
            case .click: "Leave the pointer on Yes and tap anywhere, even far away from it."
            case .scroll: "Put two fingers down together and drag them up."
            case .drag: "Put the pointer on the file first. Then tap, tap-and-hold, and slide."
            case .zoom: "Place two fingers on the pad and move them apart."
            }
        }

        var success: (title: String, caption: String) {
            switch self {
            case .move: ("Found it.", "Move · landed")
            case .click: ("Thank you. It needed that.", "Click · landed")
            case .scroll: ("Nobody has ever read that far.", "Scroll · done")
            case .drag: ("Filed. Finally.", "Drag · dropped")
            case .zoom: ("The fine print says you’re ready.", "Zoom · readable")
            }
        }
    }

    @Published private(set) var lesson: Lesson = .move
    @Published private(set) var passed = false
    @Published private(set) var finished = false
    @Published private(set) var pointer = CGPoint(x: 60, y: 300)
    @Published private(set) var target = CGPoint(x: 250, y: 120)
    @Published private(set) var targetDodged = false
    @Published private(set) var scroll: CGFloat = 0
    @Published private(set) var zoom: CGFloat = 1
    @Published private(set) var file = CGPoint(x: 90, y: 110)
    @Published private(set) var carrying = false
    @Published private(set) var ripple: (point: CGPoint, serial: Int)?
    @Published private(set) var note: String?
    @Published private(set) var showHint = false
    @Published private(set) var progress: Set<Lesson> = []

    private(set) var pad = CGSize(width: 350, height: 392)
    private var rippleSerial = 0
    private var idleTask: Task<Void, Never>?

    static let scrollLength: CGFloat = 520

    func layout(_ size: CGSize) {
        guard size.width > 40, size.height > 40, size != pad else { return }
        pad = size
        placeForLesson()
    }

    var yesButton: CGRect {
        let dialog = dialogFrame
        return CGRect(x: dialog.midX + 4, y: dialog.maxY - 48, width: dialog.width / 2 - 20, height: 34)
    }

    var noButton: CGRect {
        let dialog = dialogFrame
        return CGRect(x: dialog.minX + 16, y: dialog.maxY - 48, width: dialog.width / 2 - 20, height: 34)
    }

    var dialogFrame: CGRect {
        let width = min(300, pad.width - 44)
        return CGRect(x: (pad.width - width) / 2, y: 56, width: width, height: 128)
    }

    var folderFrame: CGRect {
        CGRect(x: pad.width - 132, y: pad.height - 150, width: 96, height: 84)
    }

    func start() {
        lesson = .move
        progress = []
        finished = false
        placeForLesson()
    }

    func skipToNext() {
        advance()
    }

    func handle(_ command: NativeGestureCommand) -> Bool {
        guard !finished else { return false }
        armIdleHint()
        switch command {
        case .move(let delta):
            movePointer(by: delta)
            return true
        case .click(let count):
            click(count: count)
            return true
        case .secondaryClick:
            flash(at: pointer)
            note = lesson == .click ? "That was a right-click: two fingers tapped. Try one." : "Two-finger tap is a right-click."
            return true
        case .scroll(let delta, _, _):
            guard lesson == .scroll, !passed else { return true }
            scroll = min(Self.scrollLength, max(0, scroll - delta.height))
            if scroll >= Self.scrollLength - 1 { pass() }
            return true
        case .dragBegan:
            if lesson == .drag, !passed, hitsFile(pointer) {
                carrying = true
                note = nil
            } else if lesson == .drag {
                note = "Put the pointer on the file first."
            }
            return true
        case .dragEnded:
            guard carrying else { return true }
            carrying = false
            if folderFrame.insetBy(dx: -18, dy: -18).contains(file) { pass() }
            else { note = "Almost. Drop it right on the folder." }
            return true
        case .zoom(let factor, _):
            guard lesson == .zoom, !passed else { return true }
            zoom = min(3, max(1, zoom * factor))
            if zoom >= 2.2 { pass() }
            return true
        case .zoomEnded:
            return true
        case .workspaceSwipe:
            note = "Three fingers switch Spaces on your Mac. Not needed here."
            return true
        case .zoomToggle, .navigate, .pan:
            return false
        }
    }

    func advance() {
        idleTask?.cancel()
        progress.insert(lesson)
        guard let next = Lesson(rawValue: lesson.rawValue + 1) else {
            finished = true
            return
        }
        lesson = next
        placeForLesson()
    }

    private func placeForLesson() {
        passed = false
        note = nil
        showHint = false
        carrying = false
        scroll = 0
        zoom = 1
        targetDodged = false
        switch lesson {
        case .move:
            pointer = CGPoint(x: pad.width * 0.2, y: pad.height * 0.78)
            target = CGPoint(x: pad.width * 0.72, y: pad.height * 0.3)
        case .click:
            pointer = CGPoint(x: yesButton.midX + 8, y: yesButton.midY - 4)
        case .scroll:
            pointer = CGPoint(x: pad.width * 0.62, y: pad.height * 0.52)
        case .drag:
            file = CGPoint(x: pad.width * 0.26, y: pad.height * 0.3)
            pointer = CGPoint(x: file.x + 6, y: file.y + 4)
        case .zoom:
            pointer = CGPoint(x: pad.width * 0.7, y: pad.height * 0.72)
        }
        armIdleHint()
    }

    private func movePointer(by delta: CGSize) {
        let next = CGPoint(x: min(pad.width - 2, max(2, pointer.x + delta.width)),
                           y: min(pad.height - 2, max(2, pointer.y + delta.height)))
        if carrying {
            file.x += next.x - pointer.x
            file.y += next.y - pointer.y
        }
        pointer = next
        guard lesson == .move, !passed else { return }
        if hypot(pointer.x - target.x, pointer.y - target.y) < 16 {
            if !targetDodged {
                targetDodged = true
                target = CGPoint(x: pad.width * 0.34, y: pad.height * 0.22)
                note = "It’s shy the first time. Try again."
            } else {
                pass()
            }
        }
    }

    private func click(count: Int) {
        flash(at: pointer)
        switch lesson {
        case .click where !passed:
            if yesButton.insetBy(dx: -6, dy: -6).contains(pointer) { pass() }
            else if noButton.insetBy(dx: -6, dy: -6).contains(pointer) { note = "It asked nicely. Try Yes." }
            else { note = "The click lands where the pointer is. Put it back on Yes." }
        case .drag where !passed:
            note = count == 2 ? "Double-click opens things. For a drag, keep the second tap down." : "Now tap again and hold."
        default:
            break
        }
    }

    private func pass() {
        guard !passed else { return }
        passed = true
        note = nil
        showHint = false
        idleTask?.cancel()
        flash(at: lesson == .drag ? file : pointer)
    }

    private func flash(at point: CGPoint) {
        rippleSerial &+= 1
        ripple = (point, rippleSerial)
    }

    private func hitsFile(_ point: CGPoint) -> Bool {
        CGRect(x: file.x - 34, y: file.y - 34, width: 68, height: 80).contains(point)
    }

    private func armIdleHint() {
        idleTask?.cancel()
        showHint = false
        let current = lesson
        idleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, let self, self.lesson == current, !self.passed else { return }
            self.showHint = true
        }
    }
}

/// Five short lessons on a local practice pad: move, click, scroll, drag, zoom.
struct GestureCoachView: View {
    let onFinish: () -> Void
    @StateObject private var coach = GestureCoachModel()
    @AppStorage("pointerSensitivity") private var sensitivity = 1.0
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        Group {
            if voiceOver {
                GestureSummaryView(onFinish: onFinish)
            } else if coach.finished {
                completion
            } else {
                lessonLayout
            }
        }
        .background(FarsideBackground())
        .onAppear {
            coach.start()
            #if DEBUG
            for _ in 0..<(LaunchOptions.value("--ui-coach-lesson=").flatMap(Int.init) ?? 0) { coach.advance() }
            #endif
        }
        .sensoryFeedback(.selection, trigger: coach.passed, condition: { _, passed in passed })
        .sensoryFeedback(.impact(weight: .heavy), trigger: coach.ripple?.serial)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("coach")
    }

    // MARK: Layout

    @ViewBuilder private var lessonLayout: some View {
        if verticalSizeClass == .compact || horizontalSizeClass == .regular {
            HStack(alignment: .top, spacing: Farside.Space.l) {
                VStack(alignment: .leading, spacing: Farside.Space.m) {
                    topBar
                    instructions
                    Spacer(minLength: 0)
                    footer
                }
                .frame(maxWidth: 380)
                pad.frame(maxWidth: 620, maxHeight: 560)
            }
            .padding(Farside.Space.l)
        } else {
            VStack(alignment: .leading, spacing: Farside.Space.m) {
                topBar
                FarsideHeading(coach.lesson.heading, size: 30)
                pad
                paragraph
                Spacer(minLength: 0)
                footer
            }
            .padding(.horizontal, Farside.Space.l)
            .padding(.top, Farside.Space.xs)
            .padding(.bottom, Farside.Space.s)
        }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: Farside.Space.m) {
            FarsideHeading(coach.lesson.heading, size: 30)
            paragraph
        }
    }

    private var topBar: some View {
        VStack(alignment: .leading, spacing: Farside.Space.s) {
            HStack {
                Text("Lesson \(coach.lesson.rawValue + 1) of 5 · \(coach.lesson.name)")
                    .farsideCaption()
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Skip", action: onFinish)
                    .buttonStyle(FarsideSecondaryButtonStyle(height: 36, fullWidth: false))
                    .accessibilityHint("Closes the lessons. You can replay them from Home.")
            }
            HStack(spacing: 6) {
                ForEach(GestureCoachModel.Lesson.allCases) { lesson in
                    Circle()
                        .fill(dotColor(lesson))
                        .frame(width: 7, height: 7)
                        .shadow(color: lesson == coach.lesson ? Farside.Palette.ember : .clear, radius: 4)
                }
            }
            .accessibilityHidden(true)
        }
    }

    private func dotColor(_ lesson: GestureCoachModel.Lesson) -> Color {
        if lesson == coach.lesson { return Farside.Palette.ember }
        return coach.progress.contains(lesson) ? Farside.Palette.bone : Farside.Palette.dim
    }

    private var paragraph: some View {
        VStack(alignment: .leading, spacing: Farside.Space.xs) {
            let lead = Text(coach.lesson.lead).foregroundStyle(Farside.Palette.bone).fontWeight(.medium)
            Text("\(lead) \(coach.lesson.detail)")
                .font(.body)
                .foregroundStyle(Farside.Palette.ash)
                .fixedSize(horizontal: false, vertical: true)
            if let note = coach.note ?? (coach.showHint ? coach.lesson.hint : nil) {
                Text(note)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Farside.Palette.bone)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .farsidePlate(Farside.Radius.control, fill: Farside.Palette.panel2)
                    .transition(.opacity)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .animation(reduceMotion ? nil : Farside.Motion.easeOut(), value: coach.note)
        .animation(reduceMotion ? nil : Farside.Motion.easeOut(), value: coach.showHint)
    }

    private var footer: some View {
        HStack(alignment: .center) {
            Text("Practice only · nothing reaches your Mac").farsideCaption()
            Spacer(minLength: Farside.Space.s)
            if coach.passed {
                Button(coach.lesson == .zoom ? "Finish" : "Next") { advance() }
                    .buttonStyle(FarsidePrimaryButtonStyle(height: 40))
                    .frame(width: 108)
                    .accessibilityIdentifier("coach.next")
            } else {
                Text("\(coach.lesson.rawValue + 1)/5").farsideCaption(Farside.Palette.bone)
            }
        }
    }

    private func advance() {
        withAnimation(reduceMotion ? nil : Farside.Motion.easeOut()) { coach.advance() }
    }

    // MARK: Pad

    private var pad: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                FarsideHalftone(style: HalftoneStyle(cell: 7, dust: 0.03), animated: false) { layers, _ in
                    let s = layers.size
                    FarsideArt.radial(layers.bone, at: CGPoint(x: s.width * 0.5, y: s.height * 0.42),
                                      radius: max(s.width, s.height) * 0.6, from: 0.13, to: 0)
                }
                lessonContent
                PointerGlyphView(shape: coach.carrying ? .closedHand : .arrow, arrowHeight: 30)
                    .position(PointerGlyphMetrics.cached(shape: coach.carrying ? .closedHand : .arrow, arrowHeight: 30)
                        .center(forHotSpotAt: coach.pointer))
                    .allowsHitTesting(false)
                if let ripple = coach.ripple {
                    ContactRipple(serial: ripple.serial)
                        .position(ripple.point)
                        .allowsHitTesting(false)
                }
                if coach.passed {
                    successCard.transition(reduceMotion ? AnyTransition.opacity : AnyTransition(.blurReplace).combined(with: .scale(scale: 0.9)))
                }
                NativeTrackpadSurface(enabled: !coach.passed, panMode: false, revision: UInt64(coach.lesson.rawValue),
                                      sensitivity: CGFloat(sensitivity), pointerScale: 1, doubleClickInterval: 0.5,
                                      onCommand: coach.handle, onPointerMotionEnded: {})
                    .accessibilityHidden(true)
            }
            .onAppear { coach.layout(proxy.size) }
            .onChange(of: proxy.size) { _, size in coach.layout(size) }
        }
        .frame(minHeight: 300)
        .clipShape(.rect(cornerRadius: 30, style: .continuous))
        .background(Color.black, in: .rect(cornerRadius: 30, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).strokeBorder(Farside.Palette.line, lineWidth: 1))
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.45, dampingFraction: 0.68), value: coach.passed)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("coach.pad")
    }

    @ViewBuilder private var lessonContent: some View {
        switch coach.lesson {
        case .move: moveContent
        case .click: clickContent
        case .scroll: scrollContent
        case .drag: dragContent
        case .zoom: zoomContent
        }
    }

    private var moveContent: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Farside.Palette.bone)
                .frame(width: 12, height: 12)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Farside.Palette.line2, lineWidth: 1).frame(width: 34, height: 34))
                .position(coach.target)
                .animation(reduceMotion ? nil : Farside.Motion.easeOut(0.5), value: coach.target)
            Text(coach.targetDodged ? "It moved. Of course it did" : "The crisp one")
                .farsideCaption()
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Color.black)
                .position(x: coach.target.x, y: coach.target.y + 34)
        }
    }

    private var clickContent: some View {
        let dialog = coach.dialogFrame
        return ZStack(alignment: .topLeading) {
            VStack(spacing: 6) {
                Text("Are you sure you’re sure?")
                    .font(.headline)
                    .foregroundStyle(Color(white: 0.07))
                Text("This dialog has been open since 2019.")
                    .font(.footnote)
                    .foregroundStyle(Color(white: 0.33))
                Spacer(minLength: 0)
            }
            .padding(.top, 16)
            .frame(width: dialog.width, height: dialog.height)
            .background(Color(white: 0.925), in: .rect(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.6), radius: 24, y: 12)
            .position(x: dialog.midX, y: dialog.midY)
            dialogButton("No", frame: coach.noButton, primary: false)
            dialogButton("Yes, I’m sure", frame: coach.yesButton, primary: true)
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Farside.Palette.ember, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .frame(width: coach.yesButton.width + 14, height: coach.yesButton.height + 14)
                .position(x: coach.yesButton.midX, y: coach.yesButton.midY)
            Text("Pointer’s already here")
                .farsideCaption(Farside.Palette.ember)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Color.black)
                .position(x: coach.yesButton.midX, y: coach.yesButton.maxY + 20)
            TapGhost()
                .position(x: coach.pad.width * 0.26, y: coach.pad.height * 0.76)
            Text("Tap down here")
                .farsideCaption()
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Color.black)
                .position(x: coach.pad.width * 0.26, y: coach.pad.height * 0.76 + 50)
        }
    }

    private func dialogButton(_ title: String, frame: CGRect, primary: Bool) -> some View {
        Text(title)
            .font(.footnote.weight(.medium))
            .foregroundStyle(primary ? .white : Color(white: 0.1))
            .frame(width: frame.width, height: frame.height)
            .background(primary ? Color(white: 0.07) : Color(white: 0.85), in: .rect(cornerRadius: 9, style: .continuous))
            .position(x: frame.midX, y: frame.midY)
    }

    private var scrollContent: some View {
        let window = CGRect(x: 26, y: 30, width: coach.pad.width - 52, height: coach.pad.height - 60)
        return ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Terms nobody read · v47")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(white: 0.1))
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                    .background(Color(white: 0.86))
                ZStack(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(0..<34, id: \.self) { line in
                            Capsule().fill(Color(white: 0.8))
                                .frame(width: (window.width - 40) * CGFloat([0.92, 0.84, 0.95, 0.7, 0.88, 0.62][line % 6]), height: 7)
                        }
                        Text("You reached the end. Nobody has ever reached the end.")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color(white: 0.1))
                            .padding(.top, 6)
                    }
                    .padding(14)
                    .offset(y: -coach.scroll)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
            }
            .frame(width: window.width, height: window.height)
            .background(Color(white: 0.96), in: .rect(cornerRadius: 14, style: .continuous))
            .clipShape(.rect(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.5), radius: 18, y: 10)
            .position(x: window.midX, y: window.midY)
            Capsule().fill(Color(white: 0.55))
                .frame(width: 4, height: 60)
                .position(x: window.maxX - 8, y: window.minY + 60 + (window.height - 120) * coach.scroll / GestureCoachModel.scrollLength)
        }
    }

    private var dragContent: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 54))
                    .foregroundStyle(Color(red: 0.36, green: 0.62, blue: 0.94))
                Text("Definitely final")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Farside.Palette.bone)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Color.black)
            }
            .frame(width: coach.folderFrame.width, height: coach.folderFrame.height)
            .position(x: coach.folderFrame.midX, y: coach.folderFrame.midY)
            VStack(spacing: 6) {
                Image(systemName: "doc.richtext.fill")
                    .font(.system(size: 42))
                    .foregroundStyle(Farside.Palette.bone)
                Text("final_final_v2.key")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Farside.Palette.bone)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(coach.carrying ? Farside.Palette.panel2 : Color.black)
            }
            .scaleEffect(coach.carrying ? 1.06 : 1)
            .opacity(coach.passed ? 0 : 1)
            .position(coach.file)
        }
    }

    private var zoomContent: some View {
        VStack(spacing: 10) {
            Text("Fine print")
                .farsideCaption()
            Text("By reading this you agree that you now know how to zoom. That’s it. That’s the fine print.")
                .font(.system(size: 5 * coach.zoom, weight: .medium))
                .foregroundStyle(Farside.Palette.bone)
                .multilineTextAlignment(.center)
                .frame(width: min(coach.pad.width - 40, 90 * coach.zoom))
                .padding(10)
                .background(Farside.Palette.panel, in: .rect(cornerRadius: 10))
        }
        .position(x: coach.pad.width / 2, y: coach.pad.height * 0.42)
    }

    private var successCard: some View {
        VStack(spacing: 8) {
            Text(coach.lesson.success.title)
                .font(.custom(Farside.Typeface.serifItalic, size: 30, relativeTo: .title))
                .foregroundStyle(Farside.Palette.bone)
                .multilineTextAlignment(.center)
            Text(coach.lesson.success.caption).farsideCaption()
        }
        .padding(.horizontal, 22).padding(.vertical, 18)
        .background(Color.black.opacity(0.9), in: .rect(cornerRadius: Farside.Radius.card, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var completion: some View {
        VStack(alignment: .leading, spacing: Farside.Space.m) {
            Spacer(minLength: 0)
            FarsideHalftone(style: HalftoneStyle(cell: 5), scene: FarsideArt.reach(gap: 0, contact: 1))
                .frame(height: 220)
                .padding(.horizontal, -Farside.Space.l)
            FarsideHeading("You’re ready.", accent: "ready", size: 34)
            Text("Slide to point, tap to click, two fingers to scroll, double tap and hold to drag, pinch to zoom. Swipe up on the handle for everything else.")
                .font(.body)
                .foregroundStyle(Farside.Palette.ash)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Done", action: onFinish)
                .buttonStyle(FarsidePrimaryButtonStyle(height: 60))
                .accessibilityIdentifier("coach.done")
        }
        .padding(Farside.Space.l)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
    }
}

/// VoiceOver version of the coach: the same actions as a list, with where to find each one.
private struct GestureSummaryView: View {
    let onFinish: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Farside.Space.m) {
                FarsideHeading("How to steer.", accent: "steer", size: 30)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.0).font(.headline).foregroundStyle(Farside.Palette.bone)
                        Text(row.1).font(.body).foregroundStyle(Farside.Palette.ash)
                    }
                    .padding(Farside.Space.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .farsidePlate()
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(Farside.Space.l)
        }
        .safeAreaInset(edge: .bottom) {
            Button("Done", action: onFinish)
                .buttonStyle(FarsidePrimaryButtonStyle())
                .padding(.horizontal, Farside.Space.l)
        }
    }

    private var rows: [(String, String)] {
        [("Click", "Double-tap the desktop. The click lands where the Mac pointer is."),
         ("Right-click and double-click", "On the desktop, swipe up or down to choose an action, then double-tap."),
         ("Controls", "Open the controls handle at the bottom for the keyboard, voice, clipboard, Fit and View modes."),
         ("Drag and workspaces", "Use Controls for Drag, Mission Control and switching Spaces.")]
    }
}

/// A dotted tap target that breathes, showing where a thumb can tap.
private struct TapGhost: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pressed = false

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let pitch: CGFloat = 6
            for y in stride(from: pitch / 2, to: size.height, by: pitch) {
                for x in stride(from: pitch / 2, to: size.width, by: pitch) {
                    let distance = hypot(x - center.x, y - center.y)
                    guard distance < size.width * 0.46 else { continue }
                    context.fill(Path(ellipseIn: CGRect(x: x - 1.4, y: y - 1.4, width: 2.8, height: 2.8)),
                                 with: .color(Farside.Palette.bone.opacity(0.85)))
                }
            }
        }
        .frame(width: 64, height: 64)
        .scaleEffect(pressed ? 0.82 : 1)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) { pressed = true }
        }
        .accessibilityHidden(true)
    }
}
