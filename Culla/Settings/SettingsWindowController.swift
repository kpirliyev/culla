import AppKit
import CullaCommands
import SwiftUI

/// The Settings window (⌘,): a standard Mac settings window with a toolbar of panes. Each pane
/// is SwiftUI; the window resizes to the pane's height as panes change.
///
/// Every control writes `AppSettings` at once, and the app follows each change without a
/// restart (`AppSettings.changed`).
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    let model: SettingsModel
    private let tabs = SettingsTabViewController()
    private var keyMonitor: Any?
    private var recordingObservation: ObservationToken?

    static let width: CGFloat = 660

    init(app: AppModel) {
        model = SettingsModel(app: app)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 480),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .preference
        window.title = localized("settings.window.title", default: "Settings")
        window.identifier = NSUserInterfaceItemIdentifier("settings")
        super.init(window: window)
        window.delegate = self
        tabs.tabStyle = .toolbar
        tabs.onSelect = { [weak self] pane in self?.selected(pane) }
        for pane in SettingsPane.allCases {
            let hosting = NSHostingController(rootView: SettingsPaneView(pane: pane, model: model))
            hosting.sizingOptions = [.preferredContentSize]
            let item = NSTabViewItem(viewController: hosting)
            item.label = pane.title
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
            item.identifier = pane.rawValue
            tabs.addTabViewItem(item)
        }
        window.contentViewController = tabs
        window.center()
        recordingObservation = observeChanges { [weak self] in self?.followRecording() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var isShown: Bool { window?.isVisible == true }

    /// Shows the window on a pane, or on the pane it was last on.
    func show(pane: SettingsPane? = nil, activate: Bool = true) {
        let timing = MainThreadTiming.begin("settings.show")
        defer { timing.end() }
        if let pane { select(pane) } else { selected(model.pane) }
        model.takeBaseline()
        if activate {
            showWindow(nil)
            window?.makeKeyAndOrderFront(nil)
        } else {
            // Automation: shown, but never taking the focus from what the person is doing.
            window?.orderFront(nil)
        }
        if model.pane == .performance { Task { await model.app.measureCache() } }
    }

    func select(_ pane: SettingsPane) {
        guard let index = SettingsPane.allCases.firstIndex(of: pane) else { return }
        if tabs.selectedTabViewItemIndex != index {
            tabs.selectedTabViewItemIndex = index
        } else {
            selected(pane)
        }
    }

    private func selected(_ pane: SettingsPane) {
        let timing = MainThreadTiming.begin("settings.selected")
        defer { timing.end() }
        model.cancelRecording()
        model.pane = pane
        window?.title = pane.title
        fitWindow(animate: window?.isVisible == true)
        if pane == .performance { Task { await model.app.measureCache() } }
    }

    /// The tallest a pane is shown before it scrolls: it must fit a 13-inch laptop's screen
    /// (about 800 points under the menu bar with the Dock shown) with the toolbar above it.
    static let maximumPaneHeight: CGFloat = 620

    /// The tallest pane this window's screen leaves room for.
    private func paneHeightLimit() -> CGFloat {
        guard let window, let screen = window.screen ?? NSScreen.main else { return Self.maximumPaneHeight }
        let chrome = window.frame.height - window.contentLayoutRect.height
        return min(Self.maximumPaneHeight, screen.visibleFrame.height - chrome - 24)
    }

    /// Sizes the window to the pane's content, keeping its top edge where it is. A pane taller
    /// than the screen allows is shown at the limit and scrolls.
    func fitWindow(animate: Bool) {
        let timing = MainThreadTiming.begin("settings.fitWindow")
        defer { timing.end() }
        guard let window, let view = tabs.tabViewItems[tabs.selectedTabViewItemIndex].viewController?.view else { return }
        let pane = model.pane
        let limit = paneHeightLimit()
        var height: CGFloat
        if model.scrollingPanes.contains(pane) {
            height = limit
            if model.scrollingHeight != limit { model.scrollingHeight = limit }
        } else {
            let measure = MainThreadTiming.begin("settings.measurePane")
            view.layoutSubtreeIfNeeded()
            height = max(200, view.fittingSize.height)
            measure.end()
            if height > limit, pane != .keys {
                model.scrollingHeight = limit
                model.scrollingPanes.insert(pane)
                height = limit
            }
        }
        let contentRect = NSRect(origin: .zero, size: NSSize(width: Self.width, height: height))
        var frame = window.frameRect(forContentRect: contentRect)
        frame.origin.x = window.frame.minX
        frame.origin.y = window.frame.maxY - frame.height
        if let screen = window.screen, frame.minY < screen.visibleFrame.minY {
            frame.origin.y = screen.visibleFrame.minY
        }
        let resize = MainThreadTiming.begin("settings.setFrame")
        window.setFrame(frame, display: true, animate: animate && !SystemAccessibility.reduceMotion)
        resize.end()
    }

    // MARK: Key recording

    /// While a key is recorded, key presses in this window go to the recorder, not the menus.
    private func followRecording() {
        if model.recording != nil, keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                // By position on layouts such as Russian, as the key router reads keys: a key
                // recorded as "з" on the P key is stored and shown as P.
                let chord = KeyRouter.chord(for: event)
                let windowNumber = event.windowNumber
                let consumed = MainActor.assumeIsolated { () -> Bool in
                    guard let self, self.window?.windowNumber == windowNumber, self.model.recording != nil else { return false }
                    if let chord {
                        self.model.record(chord)
                    }
                    return true
                }
                return consumed ? nil : event
            }
        } else if model.recording == nil, let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    func windowWillClose(_ notification: Notification) {
        model.cancelRecording()
    }
}

/// Reports which pane the toolbar selected.
final class SettingsTabViewController: NSTabViewController {
    var onSelect: ((SettingsPane) -> Void)?

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        if let name = tabViewItem?.identifier as? String, let pane = SettingsPane(rawValue: name) {
            onSelect?(pane)
        }
    }
}
