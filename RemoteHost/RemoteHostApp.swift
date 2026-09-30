import SwiftUI
import AppKit

@main
struct RemoteHostApp: App {
    @NSApplicationDelegateAdaptor(RemoteHostAppDelegate.self) private var appDelegate
    @StateObject private var model: RemoteHostModel

    init() {
        #if DEBUG
        if CommandLine.arguments.contains(VirtualDisplaySpike.launchArgument) { VirtualDisplaySpike.run(); exit(0) }
        #endif
        HostFonts.registerBundledFonts()
        let model = RemoteHostModel()
        _model = StateObject(wrappedValue: model)
        appDelegate.configure { model.stopForTermination() }
        appDelegate.onLaunch = { launchedAsLoginItem in
            HostAppActivation.shared.start()
            if model.presentsSetupAtLaunch && !Self.e2eActive { HostAppActivation.shared.bringForward() }
            // With the icon hidden, a launch from Finder or Spotlight would otherwise show nothing.
            else if !model.menuBarIconShown && !launchedAsLoginItem && !Self.e2eActive {
                DispatchQueue.main.async { HostAppActivation.shared.showSetupOrSettings(needsSetup: false) }
            }
        }
        appDelegate.onReopen = {
            let destination = HostMenuBarIconPolicy.reopenDestination(needsSetup: model.needsSetup,
                                                                      iconShown: model.menuBarIconShown)
            HostAppActivation.shared.showSetupOrSettings(needsSetup: destination == .setup)
        }
    }

    var body: some Scene {
        Window(HostWindowID.setupTitle, id: HostWindowID.setup) {
            HostSetupContainer(model: model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(model.presentsSetupAtLaunch && !Self.e2eActive ? .presented : .suppressed)
        .restorationBehavior(.disabled)

        Settings {
            HostSettingsContainer(model: model)
        }
        .windowResizability(.contentSize)
        .commands { CommandGroup(after: .appInfo) { HostUpdateButton() } }

        // Removing the icon (Command-drag or System Settings → Menu Bar) only hides it: the Setup and
        // Settings scenes keep the app, and sharing, running. Settings → Show in menu bar restores it.
        MenuBarExtra(isInserted: Binding(get: { model.menuBarIconShown }, set: model.setMenuBarIconShown)) {
            HostPopoverContainer(model: model)
        } label: {
            HostMenuBarLabel(glyph: model.menuGlyph, state: HostMarkState(status: model.status), title: model.status.title)
        }
        .menuBarExtraStyle(.window)
    }

    /// The E2E harness host never presents setup or takes focus from the Farside Test Pad.
    private static var e2eActive: Bool {
        #if DEBUG
        HostE2E.active != nil
        #else
        false
        #endif
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

private struct HostPopoverContainer: View {
    @ObservedObject var model: RemoteHostModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HostPopoverView(state: model.viewState, actions: HostActions.live(
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
        ), activity: model.activity)
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
            skipPairing: model.deferPairing,
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
            removeServerRoom: model.removeServerRoom,
            stopSharing: model.stopSharing,
            pauseSharing: { model.pauseSharing() },
            resumeSharing: model.resumeSharing,
            setAllowControl: model.setControl,
            setKeepAwake: model.setKeepAwake,
            setChimeOnConnect: model.setChimeOnConnect,
            setAllowSystemAudio: model.setAllowSystemAudio,
            setAllowFileTransfer: model.setAllowFileTransfer,
            setOpenAtLogin: model.setOpenAtLogin,
            setAutomaticRecovery: model.setAutomaticRecovery,
            openLoginItems: model.openLoginItems,
            setPrivacyCurtain: model.setPrivacyCurtain,
            setAgentAlerts: model.setAgentAlerts,
            copyAgentHookSetup: model.copyAgentHookSetup,
            resetAgentAlertLink: model.resetAgentAlertLink,
            copyDiagnostics: model.copyDiagnostics,
            setNewestFrameWins: model.setNewestFrameWins,
            selectDisplay: model.selectDisplay,
            setMenuBarIconShown: model.setMenuBarIconShown,
            openSetup: openSetup,
            openSettings: openSettings,
            quit: {
                model.stop()
                NSApplication.shared.terminate(nil)
            }
        )
    }
}
