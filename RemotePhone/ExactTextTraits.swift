import UIKit

/// How the phone's composer treats typing. Exact is for code, shells and paths: every character
/// reaches the Mac as typed. Prose keeps the keyboard's smart typing.
enum TextEntryStyle: Equatable {
    case exact
    case prose
}

enum ExactTextTraits {
    /// Keyboard settings for a style; `secure` additionally stops iOS learning, copying or suggesting
    /// what is typed into a Mac password field.
    @MainActor
    static func apply(_ style: TextEntryStyle, secure: Bool, to view: UITextView) {
        let exact = style == .exact || secure
        view.autocapitalizationType = exact ? .none : .sentences
        view.autocorrectionType = exact ? .no : .default
        view.spellCheckingType = exact ? .no : .default
        view.smartQuotesType = exact ? .no : .default
        view.smartDashesType = exact ? .no : .default
        view.smartInsertDeleteType = exact ? .no : .default
        view.inlinePredictionType = exact ? .no : .default
        view.mathExpressionCompletionType = exact ? .no : .default
        view.writingToolsBehavior = exact ? .none : .default
        if #available(iOS 27.0, *) {
            view.grammarCheckingType = exact ? .no : .default
        }
        view.isSecureTextEntry = secure
    }
}
