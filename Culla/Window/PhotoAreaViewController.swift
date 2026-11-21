import AppKit
import CullaSession
import SwiftUI

/// The middle of the shoot window: the group's header bar, the grid or the loupe, the empty-group
/// message, notes such as "3 new photos" or the summary when analysis ends, and the tuning panel
/// as a popover from the header.
///
/// The loupe and the empty-group message are made the first time they are needed, so opening a
/// shoot in the grid builds only the grid.
@MainActor
final class PhotoAreaViewController: NSViewController, NSPopoverDelegate {
    let model: SessionModel
    let grid: PhotoGridController
    private(set) var loupe: LoupeViewController?
    private(set) var stackReview: StackReviewController?
    private(set) var duplicateReview: DuplicateReviewController?
    private(set) var compare: CompareController?
    private var emptyHost: NSHostingView<EmptyGroupView>?
    private var bannerHost: NSHostingView<PhotoAreaBanner>!
    /// Notices that stay until dealt with, docked under the header so they never cover a photo.
    private(set) var noticeHost: NSHostingView<NoticeBarView>!
    private var observation: ObservationToken?
    private var bannerBottom: NSLayoutConstraint!
    private(set) var headerHost: NSHostingView<GroupHeaderView>!
    private(set) var tuningPopover: NSPopover?
    private var tuningObservation: ObservationToken?
    /// The header's slider button, in the header's coordinates with the origin top left.
    private var tuningButtonFrame: CGRect?

    init(model: SessionModel) {
        self.model = model
        grid = PhotoGridController(model: model)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.wantsLayer = true
        view.layer?.backgroundColor = Palette.gridBackground.cgColor
        self.view = view
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let model = model
        headerHost = NSHostingView(rootView: GroupHeaderView(
            model: model,
            toggleTuning: { model.toggleTuningPanel() },
            tuningButtonMoved: { [weak self] frame in self?.tuningButtonFrame = frame }
        ))
        headerHost.sizingOptions = []
        headerHost.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(headerHost)
        NSLayoutConstraint.activate([
            headerHost.topAnchor.constraint(equalTo: view.topAnchor),
            headerHost.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerHost.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            headerHost.heightAnchor.constraint(equalToConstant: GroupHeaderView.height),
        ])
        noticeHost = NSHostingView(rootView: NoticeBarView(model: model, width: noticeWidth))
        noticeHost.sizingOptions = [.intrinsicContentSize]
        noticeHost.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(noticeHost)
        NSLayoutConstraint.activate([
            noticeHost.topAnchor.constraint(equalTo: headerHost.bottomAnchor),
            noticeHost.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            noticeHost.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        bannerHost = NSHostingView(rootView: PhotoAreaBanner(model: model))
        bannerHost.sizingOptions = [.intrinsicContentSize]
        fill(with: grid.scrollView)
        bannerHost.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bannerHost)
        bannerBottom = bannerHost.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -14)
        NSLayoutConstraint.activate([
            bannerBottom,
            bannerHost.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            bannerHost.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -28),
        ])
        observation = observeChanges { [weak self] in self?.update() }
        tuningObservation = observeChanges { [weak self] in self?.updateTuningPanel() }
    }

    // MARK: Tuning panel

    /// Shows the tuning panel while the model says it is open, anchored to the header's slider
    /// button at its trailing end.
    private func updateTuningPanel() {
        let group = model.tuningPanelGroup
        DispatchQueue.main.async { [weak self] in self?.showTuningPanel(for: group) }
    }

    private func showTuningPanel(for group: GroupID?) {
        guard let group else {
            if let popover = tuningPopover {
                tuningPopover = nil
                popover.performClose(nil)
            }
            return
        }
        if let popover = tuningPopover {
            (popover.contentViewController as? NSHostingController<TuningPanel>)?.rootView = TuningPanel(model: model, group: group)
            return
        }
        guard view.window != nil else { return }
        let popover = NSPopover()
        let host = NSHostingController(rootView: TuningPanel(model: model, group: group))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.delegate = self
        // Transient for a person; held open for automation, which never activates the app.
        popover.behavior = isAutomation ? .applicationDefined : .transient
        popover.animates = !SystemAccessibility.reduceMotion && !isAutomation
        tuningPopover = popover
        var anchor = tuningButtonFrame ?? NSRect(x: 160, y: 4, width: 24, height: headerHost.bounds.height - 8)
        if !headerHost.isFlipped { anchor.origin.y = headerHost.bounds.height - anchor.maxY }
        popover.show(relativeTo: anchor, of: headerHost, preferredEdge: .maxY)
    }

    func popoverDidClose(_ notification: Notification) {
        guard (notification.object as? NSPopover) === tuningPopover || tuningPopover == nil else { return }
        tuningPopover = nil
        if model.tuningPanelGroup != nil { model.closeTuningPanel() }
    }

    private var isAutomation: Bool {
        #if DEBUG
        return AutomationRunner.isActive
        #else
        return false
        #endif
    }

    /// Adds a view filling the area, below the banner.
    private func fill(with subview: NSView) {
        subview.translatesAutoresizingMaskIntoConstraints = false
        if let bannerHost, bannerHost.superview === view {
            view.addSubview(subview, positioned: .below, relativeTo: bannerHost)
        } else {
            view.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            subview.topAnchor.constraint(equalTo: noticeHost.bottomAnchor),
            subview.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            subview.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            subview.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private var noticeHeight: CGFloat = 0
    private let noticeWidth = NoticeBarWidth()

    override func viewDidLayout() {
        super.viewDidLayout()
        if abs(noticeWidth.value - view.bounds.width) > 0.5 { noticeWidth.value = view.bounds.width }
        // A notice docked above the photos pushes them down: the focused tile stays in view.
        if let height = noticeHost?.frame.height, abs(height - noticeHeight) > 0.5 {
            noticeHeight = height
            if model.viewMode == .grid { DispatchQueue.main.async { [weak self] in self?.grid.scrollToFocus() } }
        }
        grid.updateItemSize(force: false)
    }

    private func update() {
        let mode = model.viewMode
        let isEmpty = model.order.isEmpty && mode != .compare
        grid.scrollView.isHidden = mode != .grid || isEmpty
        loupe?.view.isHidden = mode != .loupe || isEmpty
        stackReview?.view.isHidden = mode != .stackReview || isEmpty
        duplicateReview?.view.isHidden = mode != .duplicateReview || isEmpty
        compare?.view.isHidden = mode != .compare
        emptyHost?.isHidden = !isEmpty
        // A shoot that cannot be reached is dimmed; its decisions stay.
        let alpha: CGFloat = model.folderMissing ? 0.35 : 1
        for content in [grid.scrollView, loupe?.view, stackReview?.view, duplicateReview?.view, compare?.view] {
            if let content, content.alphaValue != alpha { content.alphaValue = alpha }
        }
        // Notes sit above the filmstrip in the loupe and in stack review.
        switch mode {
        case .loupe where !isEmpty: bannerBottom.constant = -(FilmstripController.height + 14)
        case .stackReview where !isEmpty: bannerBottom.constant = -((stackReview?.bottomHeight ?? StackFilmstripView.height) + 14)
        case .duplicateReview where !isEmpty: bannerBottom.constant = -(DuplicateReviewController.cardHeight + 14)
        default: bannerBottom.constant = -14
        }
        _ = model.group
        if missingView(mode: mode, isEmpty: isEmpty) {
            // Made outside this observation, so it does not also follow everything they read.
            DispatchQueue.main.async { [weak self] in self?.makeMissingViews() }
        }
        if mode == .grid, !isEmpty {
            view.window?.makeFirstResponder(grid.collectionView)
            grid.scrollToFocus()
        }
    }

    private func missingView(mode: ViewMode, isEmpty: Bool) -> Bool {
        if isEmpty { return emptyHost == nil }
        switch mode {
        case .grid: return false
        case .loupe: return loupe == nil
        case .stackReview: return stackReview == nil
        case .duplicateReview: return duplicateReview == nil
        case .compare: return compare == nil
        }
    }

    private func makeMissingViews() {
        let mode = model.viewMode
        let isEmpty = model.order.isEmpty && mode != .compare
        if mode == .loupe, !isEmpty, loupe == nil {
            let controller = LoupeViewController(model: model)
            addChild(controller)
            fill(with: controller.view)
            loupe = controller
        }
        if mode == .stackReview, !isEmpty, stackReview == nil {
            let controller = StackReviewController(model: model)
            controller.onBottomHeightChange = { [weak self] height in
                guard let self, self.model.viewMode == .stackReview else { return }
                let constant = -(height + 14)
                if abs(self.bannerBottom.constant - constant) > 0.5 { self.bannerBottom.constant = constant }
            }
            addChild(controller)
            fill(with: controller.view)
            stackReview = controller
        }
        if mode == .duplicateReview, !isEmpty, duplicateReview == nil {
            let controller = DuplicateReviewController(model: model)
            addChild(controller)
            fill(with: controller.view)
            duplicateReview = controller
        }
        if mode == .compare, compare == nil {
            let controller = CompareController(model: model)
            addChild(controller)
            fill(with: controller.view)
            compare = controller
        }
        stackReview?.view.isHidden = mode != .stackReview || isEmpty
        duplicateReview?.view.isHidden = mode != .duplicateReview || isEmpty
        compare?.view.isHidden = mode != .compare
        if isEmpty, emptyHost == nil {
            let host = NSHostingView(rootView: EmptyGroupView(model: model))
            host.sizingOptions = []
            fill(with: host)
            emptyHost = host
        }
        loupe?.view.isHidden = mode != .loupe || isEmpty
        emptyHost?.isHidden = !isEmpty
    }
}
