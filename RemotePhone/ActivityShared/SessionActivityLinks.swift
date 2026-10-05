import Foundation

/// Where a tap on the Live Activity goes. Compiled into the app and the widget extension; the app
/// routes the same URL through `FarsideRoute`.
enum SessionActivityLinks {
    static let session = URL(string: "\(FarsideBeta.urlScheme)://session")!
}
