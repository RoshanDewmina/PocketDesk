import SwiftUI

/// The Mac said its focused field takes a password (`SessionFeature.secureFocus`). While this is
/// on, the phone shows a lock, masks what is typed, and keeps no draft once the field is left.
/// The Mac reports only this boolean; nothing about the field itself crosses the wire.
struct SecureTextFocus: Equatable {
    private(set) var active = false
    /// The current draft was typed while a password field was focused.
    private(set) var draftIsSecret = false

    /// A focus reply for the probe this phone sent. Returns true when the state changed.
    @discardableResult
    mutating func reply(secure: Bool?, hostSupports: Bool) -> Bool {
        let next = hostSupports && secure == true
        guard next != active else { return false }
        active = next
        return true
    }

    mutating func draftChanged(_ draft: String) {
        if draft.isEmpty { draftIsSecret = false } else if active { draftIsSecret = true }
    }

    /// The draft to keep once the password field is left, the session ends or the app backgrounds.
    mutating func end(draft: String) -> String {
        let kept = draftIsSecret ? "" : draft
        active = false
        draftIsSecret = false
        return kept
    }

    /// Whether the draft may be written anywhere that outlives this screen (an outbox, a resume capsule).
    var draftMayPersist: Bool { !active && !draftIsSecret }
}

extension PhoneRemoteModel {
    /// Lock state for the text composer and keyboard bar.
    var passwordFieldFocused: Bool { secureTextFocus.active }

    func receiveSecureFocus(secure: Bool?) {
        var state = secureTextFocus
        let wasActive = state.active
        state.reply(secure: secure, hostSupports: hostFeatures.contains(SessionFeature.secureFocus))
        if wasActive && !state.active {
            draft = state.end(draft: draft)
        }
        secureTextFocus = state
    }

    func endSecureFocus() {
        var state = secureTextFocus
        draft = state.end(draft: draft)
        secureTextFocus = state
    }
}

/// The composer's lock while the Mac's focused field takes a password.
struct PasswordFieldLock: View {
    let visible: Bool

    var body: some View {
        if visible {
            Image(systemName: "lock.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Farside.Palette.bone)
                .padding(.trailing, 14)
                .accessibilityLabel("Password field on your Mac. Typing is hidden and not kept.")
                .accessibilityIdentifier("remote.passwordLock")
        }
    }
}
