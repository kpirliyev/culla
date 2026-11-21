import AppKit
import CullaCommands

/// The one window: the welcome view until a shoot is open, then the shoot with its top bar.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    let app: AppModel
    private let root: RootViewController
    private let topBar: ShootTopBar
    /// Empty: it only makes the title bar as tall as the top bar (see `showShootChrome`).
    private let chromeToolbar: NSToolbar
    private var screenObservation: ObservationToken?
    private var titleObservation: ObservationToken?

    static let defaultSize = NSSize(width: 1280, height: 800)

    init(app: AppModel) {
        self.app = app
        topBar = ShootTopBar(app: app)
        root = RootViewController(app: app, topBar: topBar)
        chromeToolbar = NSToolbar(identifier: "ShootChrome")
        chromeToolbar.displayMode = .iconOnly
        chromeToolbar.allowsUserCustomization = false
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Culla"
        window.minSize = NSSize(width: 900, height: 560)
        window.backgroundColor = Palette.windowBackground
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenPrimary)
        // With Full Keyboard Access, Tab reaches the top bar's controls through the key view
        // loop, as it is the app's own view and not an NSToolbar (Control-F5 finds only that).
        window.autorecalculatesKeyViewLoop = true
        window.contentViewController = root
        window.setContentSize(Self.defaultSize)
        super.init(window: window)
        window.delegate = self
        app.window = window
        if !app.environment.isAutomation {
            window.setFrameAutosaveName("MainWindow")
            if !window.setFrameUsingName("MainWindow") { window.center() }
        } else {
            window.center()
        }

        screenObservation = observeChanges { [weak self] in self?.screenChanged() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The shoot view, when a shoot is open.
    var shootController: ShootViewController? { root.shootController }

    /// Shows the window behind every other window without activating the app, for automation.
    func showInBackground() {
        window?.orderBack(nil)
    }

    /// Puts the shoot's chrome up, or takes it down for the welcome view. The shoot draws its own
    /// flat top bar (`ShootTopBar`) under a transparent title bar, because from macOS 26 the system
    /// draws every toolbar item in a glass capsule. The window keeps an empty toolbar only so the
    /// title bar is as tall as the bar and the window buttons sit centred on it; with no items
    /// there is nothing for the system to draw.
    private func showShootChrome(_ show: Bool, in window: NSWindow) {
        let timing = MainThreadTiming.begin("window.showShootChrome")
        defer { timing.end() }
        guard show != window.styleMask.contains(.fullSizeContentView) else { return }
        // Keep the window's frame: the taller title bar would otherwise make it taller.
        let frame = window.frame
        if show {
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.titlebarSeparatorStyle = .none
            window.toolbar = chromeToolbar
            window.toolbarStyle = .unifiedCompact
        } else {
            window.toolbar = nil
            window.styleMask.remove(.fullSizeContentView)
            window.titlebarAppearsTransparent = false
            window.titleVisibility = .visible
            window.titlebarSeparatorStyle = .automatic
        }
        window.setFrame(frame, display: true)
        root.setTopBarShown(show)
    }

    /// Lays out the top bar while the welcome view waits for a folder, so showing it when a shoot
    /// starts opening is quick.
    func prewarmTopBar() {
        let timing = MainThreadTiming.begin("window.prewarmTopBar")
        defer { timing.end() }
        topBar.view.layoutSubtreeIfNeeded()
    }

    private func screenChanged() {
        let timing = MainThreadTiming.begin("window.screenChanged")
        defer { timing.end() }
        guard let window else { return }
        switch app.screen {
        case .welcome:
            showShootChrome(false, in: window)
            window.title = "Culla"
            window.subtitle = ""
            titleObservation = nil
        case .loading(let info):
            // The top bar goes up while the shoot loads, so it is not laid out in the moment the
            // shoot appears.
            showShootChrome(true, in: window)
            window.title = info.name
            window.subtitle = ""
            titleObservation = nil
        case .shoot(let session):
            showShootChrome(true, in: window)
            // The title is hidden (the top bar shows the name and the count), but the Window
            // menu, Mission Control and VoiceOver still read it.
            titleObservation = observeChanges { [weak window, weak session] in
                guard let window, let session else { return }
                window.title = session.name
                window.subtitle = Formatting.photos(session.session.count)
                window.representedURL = nil
            }
        }
    }
}
