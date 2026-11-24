import SwiftUI

extension View {
    /// Under automation (debug builds), records `name` while this view is on screen, for the
    /// dump's `shownViews`: a script can then check what a screen shows, which SwiftUI keeps out of
    /// the accessibility tree the harness reads. Does nothing in a Release build.
    func automationMark(_ name: String) -> some View {
        #if DEBUG
        onAppear { AutomationMarks.shown.insert(name) }
            .onDisappear { AutomationMarks.shown.remove(name) }
        #else
        self
        #endif
    }
}

#if DEBUG
/// The views marked with `automationMark` that are on screen now.
@MainActor
enum AutomationMarks {
    static var shown: Set<String> = []
}
#endif
