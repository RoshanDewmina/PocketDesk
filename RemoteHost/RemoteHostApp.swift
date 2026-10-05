import SwiftUI
import AppKit

@main
struct RemoteHostApp: App {
    @NSApplicationDelegateAdaptor(RemoteHostAppDelegate.self) private var appDelegate
    @StateObject private var model: RemoteHostModel

    init() {
        #if DEBUG
        if PortraitPrototypeOptions.requested(CommandLine.arguments) {
            exit(VirtualDisplayPortraitPrototype.run(arguments: CommandLine.arguments))
        }
        if CommandLine.arguments.contains(VirtualDisplaySpike.launchArgument) { VirtualDisplaySpike.run(); exit(0) }
        #endif
        HostFonts.registerBundledFonts()
        CrashDiagnostics.shared.start()
        let model = RemoteHostModel()
        _model = StateObject(wrappedValue: model)
        appDelegate.configure(cleanup: { model.stopForTermination() }, prepare: model.prepareForTermination)
        appDelegate.onLaunch = { launchedAsLoginItem in
            HostAppActivation.shared.start()
            if model.presentsSetupAtLaunch && !Self.e2eActive { HostAppActivation.shared.bringForward() }
            else if model.presentsConsentAtLaunch(launchedAsLoginItem: launchedAsLoginItem) && !Self.e2eActive {
                DispatchQueue.main.async { HostAppActivation.shared.showSetupOrSettings(needsSetup: true) }
            }
            // With the icon hidden, a launch from Finder or Spotlight would otherwise show nothing.
            else if !model.menuBarIconShown && !launchedAsLoginItem && !Self.e2eActive {
                DispatchQueue.main.async { HostAppActivation.shared.showSetupOrSettings(needsSetup: false) }
            }
        }
        appDelegate.onReopen = {
            let destination = HostMenuBarIconPolicy.reopenDestination(needsSetup: model.needsSetup || model.consentPending,
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

        // Removing the icon (Command-drag or System Settings → Menu Bar) only hides it: the app delegate
        // declines to quit after the last window closes, so the app, and sharing, keep running.
        // Settings → Show in menu bar restores it.
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
        var actions = HostActions.live(model, finishSetup: {
            model.finishFirst60Setup()
            dismissWindow(id: HostWindowID.setup)
        })
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
            removePairedDevice: model.removePairedDevice,
            removeServerRoom: model.removeServerRoom,
            stopSharing: model.stopSharing,
            pauseSharing: { model.pauseSharing() },
            resumeSharing: model.resumeSharing,
            setAllowControl: model.setControl,
            setKeepAwake: model.setKeepAwake,
            setChimeOnConnect: model.setChimeOnConnect,
            setLocalOnly: model.setLocalOnly,
            setAllowSystemAudio: model.setAllowSystemAudio,
            setOpenAtLogin: model.setOpenAtLogin,
            confirmBackgroundChoices: { model.confirmBackgroundChoices(openAtLogin: $0, keepAwake: $1) },
            setAutomaticRecovery: model.setAutomaticRecovery,
            openLoginItems: model.openLoginItems,
            setPrivacyCurtain: model.setPrivacyCurtain,
            setAllowBigText: model.setAllowBigText,
            restoreNormalSize: model.restoreNormalSize,
            setAwayMode: model.setAwayMode,
            coverNow: model.coverNow,
            dismissLockWarning: model.dismissLockWarning,
            openLockScreenSettings: model.openLockScreenSettings,
            setAgentAlerts: model.setAgentAlerts,
            setCompletedAlerts: model.setCompletedAlerts,
            setFailedAlerts: model.setFailedAlerts,
            copyAgentHookSetup: model.copyAgentHookSetup,
            resetAgentAlertLink: model.resetAgentAlertLink,
            copyDiagnostics: model.copyDiagnostics,
            deleteDiagnosticReport: model.deleteDiagnosticReport,
            setCompatibilityVideoEncoder: model.setCompatibilityVideoEncoder,
            setNewestFrameWins: model.setNewestFrameWins,
            selectDisplay: model.selectDisplay,
            refreshCaptureScopes: model.refreshCaptureScopes,
            createGuestLink: model.createGuestLink,
            copyGuestLink: model.copyGuestLink,
            approveGuest: model.approveGuest,
            revokeGuest: model.revokeGuest,
            selectCaptureScope: model.selectCaptureScope,
            setMenuBarIconShown: model.setMenuBarIconShown,
            openSetup: openSetup,
            openSettings: openSettings,
            quit: {
                NSApplication.shared.terminate(nil)
            }
        )
    }
}
