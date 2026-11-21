import AppKit
import CullaCommands
import SwiftUI

/// The shoot: sidebar on the left, the photo area in the middle, the inspector on the right
/// (hidden until asked for), and the status bar along the bottom.
@MainActor
final class ShootViewController: NSViewController {
    let app: AppModel
    let model: SessionModel
    private let split = ShootSplitViewController()
    let photoArea: PhotoAreaViewController
    private var sidebarItem: NSSplitViewItem!
    private var inspectorItem: NSSplitViewItem!
    private var observation: ObservationToken?
    private var inspector: LazyViewController?
    private var confirmationObservation: ObservationToken?
    /// The ⇧X confirmation on screen, if any.
    private(set) var confirmation: NSAlert?
    private var shownRequest: UUID?
    /// What the confirmation on screen asks for.
    private enum ConfirmationKind { case bulkReject, undoApply }
    private var confirmationKind = ConfirmationKind.bulkReject
    /// Review and Apply, over the sidebar, the photo area and the inspector.
    private(set) var applyHost: NSHostingView<ApplyScreenView>?
    private var applyObservation: ObservationToken?

    static let statusBarHeight: CGFloat = 28

    init(app: AppModel, model: SessionModel) {
        self.app = app
        self.model = model
        photoArea = PhotoAreaViewController(model: model)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView(frame: NSRect(origin: .zero, size: MainWindowController.defaultSize))
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let sidebar = NSHostingController(rootView: SidebarView(model: model))
        sidebar.sizingOptions = []
        // The split view takes the sidebar's first width from its frame, which spares a layout
        // pass that setting the divider's position would force.
        // Never narrower than its longest group name needs in the language of the interface.
        let needed = SidebarView.naturalWidth(photoCount: model.session.count(of: .allPhotos).total).clamped(to: 200...360)
        sidebar.view.frame.size.width = max(CGFloat(app.settings.sidebarWidth ?? 220), needed).clamped(to: 200...360)
        sidebarItem = NSSplitViewItem(viewController: sidebar)
        sidebarItem.minimumThickness = needed
        sidebarItem.maximumThickness = 360
        sidebarItem.canCollapse = false
        sidebarItem.holdingPriority = .init(260)

        let content = NSSplitViewItem(viewController: photoArea)
        // 340 leaves room at the 900-point minimum window for a sidebar sized to Russian or
        // Turkmen group names beside the inspector.
        content.minimumThickness = 340

        // The inspector is hidden by default; its view is made the first time it is shown.
        let model = model
        let inspector = LazyViewController(width: CGFloat(app.settings.inspectorWidth ?? 300).clamped(to: 280...380)) {
            let host = NSHostingView(rootView: InspectorView(model: model))
            host.sizingOptions = []
            return host
        }
        self.inspector = inspector
        if model.inspectorVisible { inspector.materialize() }
        inspectorItem = NSSplitViewItem(viewController: inspector)
        inspectorItem.minimumThickness = 280
        inspectorItem.maximumThickness = 380
        inspectorItem.canCollapse = true
        inspectorItem.holdingPriority = .init(259)
        inspectorItem.isCollapsed = !model.inspectorVisible

        split.splitView.dividerStyle = .thin
        split.onResize = { [weak self] in self?.rememberWidths() }
        split.splitView.isVertical = true
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(content)
        split.addSplitViewItem(inspectorItem)
        addChild(split)

        let status = NSHostingView(rootView: StatusBarView(model: model))
        status.sizingOptions = []

        let splitView = split.view
        splitView.translatesAutoresizingMaskIntoConstraints = false
        status.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(splitView)
        view.addSubview(status)
        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: view.topAnchor),
            splitView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: status.topAnchor),
            status.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            status.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            status.heightAnchor.constraint(equalToConstant: Self.statusBarHeight),
        ])

        observation = observeChanges { [weak self] in self?.updateInspector() }
        confirmationObservation = observeChanges { [weak self] in
            let request = self?.model.bulkRejectRequest
            let undoRequest = self?.model.undoApplyRequest
            DispatchQueue.main.async {
                if let undoRequest {
                    self?.showUndoApplyConfirmation(undoRequest)
                } else {
                    self?.showConfirmation(request)
                }
            }
        }
        applyObservation = observeChanges { [weak self] in
            let open = self?.model.apply.isOpen ?? false
            DispatchQueue.main.async { self?.showApplyScreen(open) }
        }
    }

    // MARK: Review and Apply

    /// Shows the screen over the shoot while it is open. The views under it are hidden, so
    /// nothing behind it draws or takes clicks.
    private func showApplyScreen(_ open: Bool) {
        let timing = MainThreadTiming.begin("showApplyScreen")
        defer { timing.end() }
        if open, applyHost == nil {
            let host = NSHostingView(rootView: ApplyScreenView(model: model))
            host.sizingOptions = []
            host.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(host)
            NSLayoutConstraint.activate([
                host.topAnchor.constraint(equalTo: view.topAnchor),
                host.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                host.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -Self.statusBarHeight),
            ])
            applyHost = host
        }
        applyHost?.isHidden = !open
        split.view.isHidden = open
        if !open, let host = applyHost {
            // Made again next time: a hidden screen would still follow every change of the session.
            host.removeFromSuperview()
            applyHost = nil
        }
        if !open, let window = view.window {
            // Back to the grid's keyboard focus.
            if model.viewMode == .grid { window.makeFirstResponder(photoArea.grid.collectionView) }
        }
    }

    // MARK: Undo Apply confirmation

    private func showUndoApplyConfirmation(_ request: UndoApplyRequest) {
        guard request.id != shownRequest, let window = view.window, window.attachedSheet == nil else { return }
        shownRequest = request.id
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = request.question
        alert.informativeText = request.detail
        alert.addButton(withTitle: localized("button.undoApply", default: "Undo Apply"))
        alert.addButton(withTitle: localized("Cancel"))
        confirmation = alert
        confirmationKind = .undoApply
        let model = model
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                self?.confirmation = nil
                if response == .alertFirstButtonReturn {
                    model.confirmUndoApply()
                } else {
                    model.cancelUndoApply()
                }
            }
        }
    }

    // MARK: ⇧X confirmation

    /// One confirmation that states the count and the group: "Reject 12 photos that are
    /// certainly blurry?" Return confirms, Escape cancels.
    private func showConfirmation(_ request: BulkRejectRequest?) {
        guard let request else {
            if confirmationKind == .bulkReject, let confirmation, let window = view.window, window.attachedSheet === confirmation.window {
                window.endSheet(confirmation.window, returnCode: .cancel)
            }
            return
        }
        guard request.id != shownRequest, let window = view.window else { return }
        shownRequest = request.id
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = request.question
        let groupTitle = request.group.title
        alert.informativeText = localized("Only undecided photos flagged Certain in \(groupTitle) are rejected. Nothing is moved until you apply.")
            + " " + KeyText.undoSentence(.takesItBackInOneStep, in: app.settings.keyBindings)
        alert.addButton(withTitle: request.buttonTitle)
        alert.addButton(withTitle: localized("Cancel"))
        confirmation = alert
        confirmationKind = .bulkReject
        let model = model
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                self?.confirmation = nil
                if response == .alertFirstButtonReturn {
                    model.confirmBulkReject()
                } else {
                    model.cancelBulkReject()
                }
            }
        }
    }

    /// Answers the confirmation as a click on one of its buttons would, for the automation harness.
    func answerConfirmation(confirm: Bool) -> Bool {
        guard let confirmation, let window = view.window else { return false }
        window.endSheet(confirmation.window, returnCode: confirm ? .alertFirstButtonReturn : .alertSecondButtonReturn)
        return true
    }

    // MARK: Widths

    /// The sidebar's and the inspector's widths on screen (the inspector's 0 while hidden).
    var splitWidths: [String: Double] {
        ["sidebar": Double(sidebarItem.viewController.view.frame.width),
         "inspector": inspectorItem.isCollapsed ? 0 : Double(inspectorItem.viewController.view.frame.width)]
    }

    /// Remembers the sidebar and inspector widths as they are dragged, for the next shoot.
    private func rememberWidths() {
        guard view.window != nil, split.splitView.inLiveResize || NSEvent.pressedMouseButtons != 0 else { return }
        let sidebarWidth = Double(sidebarItem.viewController.view.frame.width)
        if sidebarWidth >= 200, abs(sidebarWidth - (app.settings.sidebarWidth ?? 0)) >= 1 { app.settings.sidebarWidth = sidebarWidth }
        if !inspectorItem.isCollapsed {
            let width = Double(inspectorItem.viewController.view.frame.width)
            if width >= 280, abs(width - (app.settings.inspectorWidth ?? 0)) >= 1 { app.settings.inspectorWidth = width }
        }
    }

    private func updateInspector() {
        let hidden = !model.inspectorVisible
        guard inspectorItem.isCollapsed != hidden else { return }
        if !hidden { inspector?.materialize() }
        if SystemAccessibility.reduceMotion || app.environment.isAutomation {
            inspectorItem.isCollapsed = hidden
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.allowsImplicitAnimation = true
                inspectorItem.animator().isCollapsed = hidden
            }
        }
    }
}

/// The shoot's split view, reporting when its dividers move (it is the split view's delegate).
final class ShootSplitViewController: NSSplitViewController {
    var onResize: (() -> Void)?

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        onResize?()
    }
}

/// A view controller whose content is made the first time it is needed.
@MainActor
final class LazyViewController: NSViewController {
    private var make: (() -> NSView)?
    private let width: CGFloat

    init(width: CGFloat = 300, make: @escaping () -> NSView) {
        self.make = make
        self.width = width
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 600))
    }

    func materialize() {
        guard let make else { return }
        self.make = nil
        let content = make()
        content.frame = view.bounds
        content.autoresizingMask = [.width, .height]
        view.addSubview(content)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
