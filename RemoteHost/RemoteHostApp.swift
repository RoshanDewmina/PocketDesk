import SwiftUI
import AppKit

@main
struct RemoteHostApp: App {
    @NSApplicationDelegateAdaptor(RemoteHostAppDelegate.self) private var appDelegate
    @StateObject private var model: RemoteHostModel

    init() {
        let model = RemoteHostModel()
        _model = StateObject(wrappedValue: model)
        appDelegate.configure { model.stopForTermination() }
        appDelegate.onLaunch = {
            HostAppActivation.shared.start()
            if model.needsSetup { HostAppActivation.shared.bringForward() }
        }
        appDelegate.onReopen = {
            HostAppActivation.shared.showSetupOrSettings(needsSetup: model.needsSetup)
        }
    }

    var body: some Scene {
        Window(HostWindowID.setupTitle, id: HostWindowID.setup) {
            HostSetupContainer(model: model)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(model.needsSetup ? .presented : .suppressed)
        .restorationBehavior(.disabled)

        Settings {
            HostSettingsContainer(model: model)
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            HostMenuContainer(model: model)
        } label: {
            Image(systemName: model.status.menuBarSymbol)
                .accessibilityLabel("PocketDesk, \(model.status.title)")
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct HostSetupContainer: View {
    @ObservedObject var model: RemoteHostModel
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        var actions = HostActions.live(model, finishSetup: { dismissWindow(id: HostWindowID.setup) })
        actions.cancelPairing = {
            model.cancelPairing()
            dismissWindow(id: HostWindowID.setup)
        }
        return HostSetupView(state: model.viewState, actions: actions)
    }
}

private struct HostSettingsContainer: View {
    @ObservedObject var model: RemoteHostModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HostSettingsView(state: model.viewState, actions: HostActions.live(model, openSetup: {
            HostAppActivation.shared.bringForward()
            openWindow(id: HostWindowID.setup)
        }))
    }
}

private struct HostMenuContainer: View {
    @ObservedObject var model: RemoteHostModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HostMenuContent(state: model.viewState, actions: HostActions.live(
            model,
            openSetup: showSetup,
            openSettings: {
                HostAppActivation.shared.bringForward()
                openSettings()
            },
            pairNewPhone: {
                model.requestPairing()
                showSetup()
            }
        ))
    }

    private func showSetup() {
        HostAppActivation.shared.bringForward()
        openWindow(id: HostWindowID.setup)
    }
}

extension HostActions {
    static func live(
        _ model: RemoteHostModel,
        finishSetup: @escaping () -> Void = {},
        openSetup: @escaping () -> Void = {},
        openSettings: @escaping () -> Void = {},
        pairNewPhone: (() -> Void)? = nil
    ) -> Self {
        HostActions(
            openSystemSettings: model.openSystemSettings,
            relaunch: model.relaunch,
            skipAccessibility: model.skipAccessibility,
            beginPairing: model.beginPairing,
            setServiceAddress: model.setServiceAddress,
            approvePhone: model.approvePhone,
            declinePhone: model.declinePhone,
            copyPairingCode: model.copyPairingCode,
            cancelPairing: model.cancelPairing,
            finishSetup: finishSetup,
            pairNewPhone: pairNewPhone ?? {
                model.requestPairing()
                openSetup()
            },
            removePhone: model.revoke,
            stopSharing: model.stopSharing,
            resumeSharing: model.resumeSharing,
            setAllowControl: model.setControl,
            setKeepAwake: model.setKeepAwake,
            setOpenAtLogin: model.setOpenAtLogin,
            selectDisplay: model.selectDisplay,
            openSetup: openSetup,
            openSettings: openSettings,
            quit: {
                model.stop()
                NSApplication.shared.terminate(nil)
            }
        )
    }
}
