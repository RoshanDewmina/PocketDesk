import SwiftUI

/// The Mac said its focused field takes a password (`SessionFeature.secureFocus`). While this is
/// on, the phone shows a lock, masks what is typed, and keeps no draft once the field is left.
/// The Mac reports only this boolean; nothing about the field itself crosses the wire.
struct SecureTextFocus: Equatable {
    private(set) var active = false
    /// The current draft was typed while a password field was focused.
    private(set) var draftIsSecret = false
    /// Local-only retirement identity for deferred editor publications. Never crosses the wire.
    private(set) var draftPublicationLifetime = UUID()

    /// A focus reply for the probe this phone sent. Returns true when the state changed.
    @discardableResult
    mutating func reply(secure: Bool?, hostSupports: Bool) -> Bool {
        let next = hostSupports && secure == true
        guard next != active else { return false }
        draftPublicationLifetime = UUID()
        active = next
        return true
    }

    mutating func draftChanged(_ draft: String) {
        if draft.isEmpty { draftIsSecret = false } else if active { draftIsSecret = true }
    }

    /// The draft to keep once the password field is left, the session ends or the app backgrounds.
    mutating func end(draft: String) -> String {
        draftPublicationLifetime = UUID()
        let kept = draftIsSecret ? "" : draft
        active = false
        draftIsSecret = false
        return kept
    }

    /// Whether the draft may be written anywhere that outlives this screen (an outbox, a resume capsule).
    var draftMayPersist: Bool { !active && !draftIsSecret }
}

extension PhoneRemoteModel: DraftPublicationOwner {
    var draftPublicationIdentity: DraftPublicationIdentity {
        DraftPublicationIdentity(session: connection.presentationSessionID,
                                 privacy: secureTextFocus.draftPublicationLifetime)
    }
    /// Lock state for the text composer and keyboard bar.
    var passwordFieldFocused: Bool { secureTextFocus.active }

    func receiveSecureFocus(secure: Bool?) {
        var state = secureTextFocus
        let wasActive = state.active
        let changed = state.reply(secure: secure, hostSupports: hostFeatures.contains(SessionFeature.secureFocus))
        if wasActive && !state.active {
            draft = state.end(draft: draft)
        }
        if state.active { FrozenTextController.cancelActive() }
        secureTextFocus = state
        // The owner retires composition even if its UIKit editor has already disappeared.
        // A repeated focus reply belongs to the same context and must leave current IME alone.
        if changed, isComposingText { isComposingText = false }
    }

    func endSecureFocus() {
        var state = secureTextFocus
        draft = state.end(draft: draft)
        secureTextFocus = state
        if isComposingText { isComposingText = false }
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
