import Foundation

/// Where a tap on the Home Screen Connect widget goes. Compiled into the app and the widget
/// extension; the app routes it through `FarsideRoute.openMac`, which asks before connecting.
enum ConnectWidgetLink {
    static let kind = "FarsideConnect"
    static let url = URL(string: "farside://open")!
}
