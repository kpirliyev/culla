import AppKit
import SwiftUI

/// Holds what the window shows (welcome, loading or the shoot) and accepts a folder dropped
/// anywhere on the window. While a shoot loads or is open, the top bar runs along the top, in
/// the title bar's place, and the rest sits under it.
@MainActor
final class RootViewController: NSViewController {
    private let app: AppModel
    private let topBar: ShootTopBar
    /// Below the top bar: the welcome, loading or shoot view.
    private let content = NSView()
    private var topBarShown = false
    private var current: NSViewController?
    private var currentSession: ObjectIdentifier?
    private var currentKind = ""
    private var preparingSession: ObjectIdentifier?
    private var observation: ObservationToken?

    init(app: AppModel, topBar: ShootTopBar) {
        self.app = app
        self.topBar = topBar
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let view = FolderDropView(frame: NSRect(origin: .zero, size: MainWindowController.defaultSize))
        view.onDrop = { [weak self] url in self?.app.openFolder(at: url) }
        view.onTargetChange = { [weak self] targeted in self?.app.isDropTargeted = targeted }
        content.frame = view.bounds
        content.autoresizesSubviews = true
        view.addSubview(content)
        topBar.view.isHidden = true
        view.addSubview(topBar.view)
        self.view = view
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observation = observeChanges { [weak self] in self?.update() }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        layoutTopBar()
    }

    /// Shows the top bar (a shoot loading or open) or takes it away (the welcome view).
    func setTopBarShown(_ shown: Bool) {
        topBarShown = shown
        topBar.view.isHidden = !shown
        layoutTopBar()
    }

    /// The bar is as tall as the window's title bar, so the window buttons sit centred on it, and
    /// its content starts after them. In full screen, where the title bar slides in only on
    /// demand, it keeps its own height and starts at the margin.
    private func layoutTopBar() {
        let bounds = view.bounds
        var height: CGFloat = 0
        if topBarShown {
            height = TopBarStyle.fallbackHeight
            var leading = TopBarStyle.sideMargin
            if let window = view.window, !window.styleMask.contains(.fullScreen) {
                let titleBar = window.frame.height - window.contentLayoutRect.height
                if titleBar >= TopBarStyle.controlHeight + 4 { height = titleBar.rounded() }
                if let zoom = window.standardWindowButton(.zoomButton), !zoom.isHidden, zoom.window != nil {
                    leading = (zoom.convert(zoom.bounds, to: view).maxX + TopBarStyle.afterTrafficLights).rounded()
                }
            }
            topBar.setLeadingInset(leading)
        }
        let barFrame = NSRect(x: 0, y: bounds.height - height, width: bounds.width, height: height)
        if topBar.view.frame != barFrame { topBar.view.frame = barFrame }
        let contentFrame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - height)
        if content.frame != contentFrame { content.frame = contentFrame }
    }

    private func update() {
        let timing = MainThreadTiming.begin("root.update")
        defer { timing.end() }
        switch app.screen {
        case .welcome:
            show(kind: "welcome") {
                Self.host(WelcomeView(app: self.app))
            }
        case .loading:
            show(kind: "loading") {
                Self.host(LoadingView(app: self.app))
            }
        case .shoot(let session):
            let id = ObjectIdentifier(session)
            if currentKind == "shoot", currentSession == id { return }
            guard preparingSession != id else { return }
            // In two steps, each its own turn of the main thread, so neither stalls it for long:
            // first the shoot's views are made, while the loading view still shows; then they
            // are put in the window and laid out.
            preparingSession = id
            DispatchQueue.main.async { [weak self, weak session] in
                guard let self, let session, self.preparingSession == id else { return }
                let timing = MainThreadTiming.begin("open.makeShootViews")
                let controller = ShootViewController(app: self.app, model: session)
                _ = controller.view
                timing.end()
                DispatchQueue.main.async { [weak self, weak session] in
                    guard let self, let session, self.preparingSession == id,
                          case .shoot(let current) = self.app.screen, current === session
                    else { return }
                    self.preparingSession = nil
                    self.currentSession = id
                    let timing = MainThreadTiming.begin("open.showShootViews")
                    self.show(kind: "shoot", force: true) { controller }
                    self.view.layoutSubtreeIfNeeded()
                    timing.end()
                }
            }
        }
    }

    private static func host<Content: View>(_ view: Content) -> NSViewController {
        let host = NSHostingController(rootView: view)
        host.sizingOptions = []
        return host
    }

    private func show(kind: String, force: Bool = false, make: () -> NSViewController) {
        guard force || kind != currentKind else { return }
        currentKind = kind
        if kind != "shoot" { preparingSession = nil }
        if kind != "shoot" { currentSession = nil }
        let controller = make()
        if let current {
            current.view.removeFromSuperview()
            current.removeFromParent()
        }
        addChild(controller)
        controller.view.frame = content.bounds
        controller.view.autoresizingMask = [.width, .height]
        content.addSubview(controller.view)
        current = controller
    }

    /// The shoot view, when a shoot is open, for the automation harness.
    var shootController: ShootViewController? { current as? ShootViewController }
}

/// Accepts a folder dragged onto the window. The drag grants the sandbox access to it.
final class FolderDropView: NSView {
    var onDrop: ((URL) -> Void)?
    var onTargetChange: ((Bool) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func folder(in info: any NSDraggingInfo) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
              let url = urls.first
        else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return url
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard folder(in: sender) != nil else { return [] }
        onTargetChange?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        folder(in: sender) != nil ? .copy : []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onTargetChange?(false)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        onTargetChange?(false)
        guard let url = folder(in: sender) else { return false }
        onDrop?(url)
        return true
    }
}
