import SwiftUI

struct UsefulSessionEntry: View {
    @ObservedObject var progress: UsefulSessionProgress
    let replayCoach: () -> Void
    @State private var showing = false
    var body: some View {
        Button { showing = true } label: {
            Label(CommerceLocalization.text("SESSION_CHECK", "Session check"), systemImage: "checklist")
                .font(.body).padding(.horizontal, 12).frame(minHeight: 44)
        }
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityHint(CommerceLocalization.text("SESSION_CHECK_HINT", "Review useful-session progress, practice gestures, and get help."))
        .sheet(isPresented: $showing) {
            UsefulSessionProgressView(progress: progress) {
                showing = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { replayCoach() }
            }
        }
    }
}

struct UsefulSessionProgressView: View {
    @ObservedObject var progress: UsefulSessionProgress
    let replayCoach: () -> Void
    @Environment(\.dismiss) private var dismiss
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private func text(_ key: String, _ fallback: String) -> String { CommerceLocalization.text(key, fallback) }
    var body: some View {
        NavigationStack {
            Form {
                Section(text("FIRST_TASK", "Try one useful task")) {
                    Text(text("TASK_GUIDANCE", "Read something you need, navigate to a window, make an edit, or save a change on your Mac. Confirm only what you actually finished."))
                        .fixedSize(horizontal: false, vertical: true)
                    fact(text("USABLE_CONTENT", "Fresh picture or Couch session"), progress.evidence.admittedPicture || progress.evidence.admittedCouch)
                    fact(text("INPUT_APPLIED", "Mac confirmed applied input"), progress.evidence.appliedInput)
                    fact(text("OUTCOME_CONFIRMED", "You confirmed a task outcome"), progress.evidence.outcome != nil)
                    Text(text("TASK_FACTS_SEPARATE", "Pairing, connecting, restoring a purchase, and practicing gestures do not complete a task. A confirmed input does not prove an edit or save."))
                        .font(.footnote).foregroundStyle(.secondary)
                    ForEach(UsefulSessionEvidence.Outcome.allCases, id: \.rawValue) { outcome in
                        Button(outcomeTitle(outcome)) { progress.confirm(outcome, now: now) }
                            .frame(minHeight: 44)
                            .disabled(!progress.evidence.ready(at: now) || progress.evidence.outcome != nil
                                      || outcome != .read && !progress.evidence.appliedInput)
                    }
                    if !progress.evidence.ready(at: now) {
                        Text(text("NEED_LIVE_SESSION", "Open a fresh, authorized Mac picture or Couch session before confirming."))
                    }
                }
                Section(text("PRACTICE_HELP", "Practice and help")) {
                    Button(text("REPLAY_COACH", "Practice gestures again")) { progress.count("coachReplay"); replayCoach() }
                        .frame(minHeight: 44)
                    Text(text("PRACTICE_LOCAL", "The practice pad stays on this device. It sends nothing to your Mac."))
                    Picker(text("TASK_BLOCKER", "What got in the way?"), selection: Binding(get: { progress.blocker }, set: { progress.reportBlocker($0) })) {
                        Text(text("CHOOSE_OPTION", "Choose an option")).tag("")
                        Text(text("BLOCK_CONNECTION", "Reaching the Mac")).tag("connection")
                        Text(text("BLOCK_PICTURE", "Seeing a usable picture")).tag("picture")
                        Text(text("BLOCK_INPUT", "Controlling the Mac")).tag("input")
                        Text(text("BLOCK_TASK", "Finishing my task")).tag("task")
                        Text(text("BLOCK_NONE", "Nothing; the task worked")).tag("none")
                    }
                    Text(text("SUPPORT_GUIDE", "For help, check Mac permissions and the selected Mac, then try reconnecting. Include your app versions and the step that failed if you contact support. Keep pairing codes, remote text, and screenshots private."))
                        .fixedSize(horizontal: false, vertical: true)
                    Button(text("COPY_SUPPORT", "Copy a safe support summary")) {
                        UIPasteboard.general.string = "Farside session check: content=\(progress.evidence.readiness?.rawValue ?? "unavailable"); appliedInput=\(progress.evidence.appliedInput); confirmedOutcome=\(progress.evidence.outcome?.rawValue ?? "none"); blocker=\(progress.blocker.isEmpty ? "unanswered" : progress.blocker). No remote content or pairing credentials included."
                        progress.count("support")
                    }.frame(minHeight: 44)
                }
                Section(text("LOCAL_COUNTERS", "Optional local progress counters")) {
                    Toggle(text("COUNTERS_CONSENT", "Keep progress counts on this device"), isOn: Binding(get: { progress.consent }, set: { progress.setConsent($0) }))
                        .frame(minHeight: 44)
                    Text(text("COUNTERS_PRIVACY", "Off by default. Counts stay on this device and are never sent automatically. They contain no Mac identity, pairing credentials, app names, or remote content. Turning this off deletes saved counts. Return visits and reconnects are separate from finished tasks."))
                        .font(.footnote).fixedSize(horizontal: false, vertical: true)
                    if progress.consent {
                        Text(CommerceLocalization.text("TASK_COUNT", "Confirmed tasks: %ld", taskCount))
                    }
                }
            }
            .navigationTitle(text("SESSION_CHECK", "Session check"))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(text("DONE", "Done")) { dismiss() }.frame(minWidth: 44, minHeight: 44) } }
        }
    }
    private var taskCount: Int { UsefulSessionEvidence.Outcome.allCases.reduce(0) { $0 + (progress.counters[$1.rawValue] ?? 0) } }
    private func fact(_ title: String, _ value: Bool) -> some View {
        Label(title, systemImage: value ? "checkmark.circle.fill" : "circle")
            .accessibilityValue(value ? text("RECORDED", "Recorded") : text("NOT_YET", "Not yet"))
    }
    private func outcomeTitle(_ value: UsefulSessionEvidence.Outcome) -> String {
        switch value {
        case .read: text("CONFIRM_READ", "I read what I needed")
        case .navigate: text("CONFIRM_NAVIGATE", "I reached the window I needed")
        case .edit: text("CONFIRM_EDIT", "I finished my edit")
        case .save: text("CONFIRM_SAVE", "I saved my change")
        }
    }
}
