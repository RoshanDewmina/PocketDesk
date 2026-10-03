import SwiftUI
import WidgetKit

@main
struct FarsideWidgetsBundle: WidgetBundle {
    var body: some Widget {
        SessionLiveActivity()
        ConnectWidget()
        ConnectControl()
    }
}
