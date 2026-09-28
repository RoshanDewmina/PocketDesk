import SwiftUI

enum HostMenuItem: Equatable {
    case status(String, systemImage: String)
    case note(String)
    case action(HostMenuAction)
    case separator
}

enum HostMenuAction: Equatable {
    case allowPhone, declinePhone, finishSetup, pairPhone, stopSharing, resumeSharing, tryAgain, settings, quit

    var title: String {
        switch self {
        case .allowPhone: "Allow Phone"
        case .declinePhone: "Decline"
        case .finishSetup: "Finish Setup…"
        case .pairPhone: "Pair a Phone…"
        case .stopSharing: "Stop Sharing"
        case .resumeSharing: "Resume Sharing"
        case .tryAgain: "Try Again"
        case .settings: "Settings…"
        case .quit: "Quit PocketDesk"
        }
    }
}

enum HostMenuModel {
    static func items(for state: HostViewState) -> [HostMenuItem] {
        let status = state.status
        var items: [HostMenuItem] = [.status(status.menuTitle, systemImage: statusSymbol(status))]

        switch status {
        case .controlling:
            items.append(.note("Mouse & keyboard enabled"))
        case .viewing where state.controlNeedsAccessibility:
            items.append(.note("View only · Grant access"))
        case .viewing:
            items.append(.note("View only · Control is off"))
        case .ready:
            items.append(.note("Phone can connect to this Mac"))
        case .unavailable:
            items.append(.note("Sharing needs attention"))
        case .needsScreenRecording:
            items.append(.note("Allow Screen Recording"))
        default:
            break
        }

        items.append(.separator)
        switch status {
        case .approvalRequested:
            items += [.action(.allowPhone), .action(.declinePhone), .separator]
        case .needsScreenRecording:
            items += [.action(.finishSetup), .separator]
        default:
            break
        }

        items.append(.action(.pairPhone))
        switch status {
        case .viewing, .controlling, .ready, .starting, .pairing:
            items.append(.action(.stopSharing))
        case .paused:
            items.append(.action(.resumeSharing))
        case .unavailable:
            items.append(.action(.tryAgain))
        default:
            break
        }
        items += [.separator, .action(.settings), .action(.quit)]
        return items
    }

    static func statusSymbol(_ status: HostStatus) -> String {
        switch status {
        case .viewing, .controlling, .ready: "circle.fill"
        case .needsScreenRecording, .needsPhone, .unavailable, .approvalRequested: "exclamationmark.circle"
        case .paused: "pause.circle"
        case .pairing, .starting: "circle.dotted"
        }
    }
}

struct HostMenuContent: View {
    let state: HostViewState
    let actions: HostActions

    var body: some View {
        ForEach(Array(HostMenuModel.items(for: state).enumerated()), id: \.offset) { _, item in
            switch item {
            case .status(let title, let symbol):
                Label(title, systemImage: symbol)
            case .note(let text):
                Text(text)
            case .separator:
                Divider()
            case .action(let action):
                button(for: action)
            }
        }
    }

    @ViewBuilder
    private func button(for action: HostMenuAction) -> some View {
        switch action {
        case .allowPhone: Button(action.title, action: actions.approvePhone)
        case .declinePhone: Button(action.title, action: actions.declinePhone)
        case .finishSetup: Button(action.title, action: actions.openSetup)
        case .pairPhone: Button(action.title, action: actions.pairNewPhone)
        case .stopSharing: Button(action.title, action: actions.stopSharing)
        case .resumeSharing, .tryAgain: Button(action.title, action: actions.resumeSharing)
        case .settings: Button(action.title, action: actions.openSettings).keyboardShortcut(",")
        case .quit: Button(action.title, action: actions.quit).keyboardShortcut("q")
        }
    }
}

/// Offscreen rendering of the menu for review screenshots; the live app shows a native NSMenu.
struct HostMenuPreview: View {
    let state: HostViewState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(HostMenuModel.items(for: state).enumerated()), id: \.offset) { _, item in
                switch item {
                case .status(let title, let symbol):
                    Label(title, systemImage: symbol)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14).padding(.vertical, 4)
                case .note(let text):
                    Text(text)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14).padding(.vertical, 4)
                case .separator:
                    Divider().padding(.horizontal, 14).padding(.vertical, 5)
                case .action(let action):
                    HStack {
                        Text(action.title)
                        Spacer()
                        if action == .settings { Text("⌘,").foregroundStyle(.secondary) }
                        if action == .quit { Text("⌘Q").foregroundStyle(.secondary) }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 4)
                }
            }
        }
        .font(.system(size: 13))
        .padding(.vertical, 6)
        .frame(width: 300, alignment: .leading)
    }
}
