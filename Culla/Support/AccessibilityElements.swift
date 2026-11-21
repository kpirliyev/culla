import AppKit

/// An accessibility element for something drawn rather than made of views, such as a face-strip
/// cell: VoiceOver finds it by its frame, reads its label, and presses it like a button.
final class DrawnAccessibilityElement: NSAccessibilityElement {
    private weak var view: NSView?
    private let rect: @MainActor @Sendable () -> CGRect
    private let press: (@MainActor @Sendable () -> Void)?

    /// `rect` is in the view's own coordinates; it is asked again whenever VoiceOver needs it.
    init(in view: NSView, role: NSAccessibility.Role, label: String, help: String? = nil, selected: Bool = false,
         rect: @escaping @MainActor @Sendable () -> CGRect, press: (@MainActor @Sendable () -> Void)?) {
        self.view = view
        self.rect = rect
        self.press = press
        super.init()
        setAccessibilityRole(role)
        setAccessibilityLabel(label)
        setAccessibilityHelp(help)
        setAccessibilitySelected(selected)
        setAccessibilityParent(view)
    }

    override func accessibilityFrame() -> NSRect {
        let view = self.view
        let rect = self.rect
        return MainActor.assumeIsolated {
            guard let view, view.window != nil else { return .zero }
            return NSAccessibility.screenRect(fromView: view, rect: rect())
        }
    }

    override func accessibilityPerformPress() -> Bool {
        guard let press = self.press else { return false }
        MainActor.assumeIsolated { press() }
        return true
    }

    override func isAccessibilityElement() -> Bool { true }
}
