import AppKit
import CullaCommands
import CullaCore
import CullaSession

/// The strip of thumbnails under the loupe: the current group in capture order, the focused photo
/// kept in the middle where possible. Cells are the grid's tiles at a small size, so decisions,
/// ratings and the focus read the same at a glance. An `NSCollectionView`, so it stays smooth
/// with tens of thousands of photos: only the visible cells exist.
@MainActor
final class FilmstripController: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
    let model: SessionModel
    let scrollView = NSScrollView()
    let collectionView = PhotoCollectionView()
    private let layout = NSCollectionViewFlowLayout()
    private var ids: [String] = []
    private var shownOrderRevision = -1
    private var shownMarksRevision = -1
    private var shownSelection = GridSelection()
    private var shownFocus: String?
    private var observation: ObservationToken?
    private lazy var contextMenu = PhotoContextMenu(model: model)

    static let tileWidth: CGFloat = 84
    static let spacing: CGFloat = 4
    static let verticalInset: CGFloat = 5
    static var tileHeight: CGFloat {
        (tileWidth - PhotoTileView.photoInset * 2) + PhotoTileView.footerHeight + PhotoTileView.photoInset
    }
    /// The strip's height: a row of tiles and its margins.
    static var height: CGFloat { tileHeight + verticalInset * 2 }

    /// False while the loupe is hidden: the strip then follows changes but does not scroll.
    var isActive = false {
        didSet { if isActive, !oldValue { centreFocus(animated: false) } }
    }

    init(model: SessionModel) {
        self.model = model
        super.init()
        layout.scrollDirection = .horizontal
        layout.itemSize = NSSize(width: Self.tileWidth, height: Self.tileHeight)
        layout.minimumInteritemSpacing = Self.spacing
        layout.minimumLineSpacing = Self.spacing
        layout.sectionInset = NSEdgeInsets(top: Self.verticalInset, left: 10, bottom: Self.verticalInset, right: 10)

        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = false
        collectionView.backgroundColors = [Palette.panelBackground]
        collectionView.register(PhotoTileItem.self, forItemWithIdentifier: PhotoTileItem.identifier)
        collectionView.setAccessibilityLabel(localized("Filmstrip"))
        collectionView.allowsRubberBand = false
        collectionView.onClick = { [weak self] index, kind, _ in self?.clicked(index, kind: kind) }
        collectionView.onContextMenu = { [weak self] index in
            guard let self, self.ids.indices.contains(index) else { return nil }
            return self.contextMenu.menu(for: self.ids[index])
        }

        scrollView.documentView = collectionView
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScrollElasticity = .none
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Palette.panelBackground
        observation = observeChanges { [weak self] in self?.sync() }
    }

    // MARK: Following the model

    private func sync() {
        let timing = MainThreadTiming.begin("filmstrip.sync")
        defer { timing.end() }
        let orderRevision = model.orderRevision
        let marksRevision = model.marksRevision
        let selection = model.selection
        _ = model.scrollRevision

        if orderRevision != shownOrderRevision {
            shownOrderRevision = orderRevision
            shownMarksRevision = marksRevision
            shownSelection = selection
            ids = model.order.ids
            collectionView.reloadData()
            shownFocus = nil
        }
        if marksRevision != shownMarksRevision {
            let changed = model.changedIDs(after: shownMarksRevision)
            shownMarksRevision = marksRevision
            reconfigure(changed ?? visibleIDs)
        }
        if selection != shownSelection {
            var changed = shownSelection.selected.symmetricDifference(selection.selected)
            if let focus = shownSelection.focus { changed.insert(focus) }
            if let focus = selection.focus { changed.insert(focus) }
            shownSelection = selection
            reconfigure(changed)
        }
        if selection.focus != shownFocus {
            let isStep = shownFocus != nil
            shownFocus = selection.focus
            if isActive { centreFocus(animated: isStep) }
        }
    }

    private var visibleIDs: Set<String> {
        Set(collectionView.indexPathsForVisibleItems().compactMap { ids.indices.contains($0.item) ? ids[$0.item] : nil })
    }

    private func reconfigure(_ changed: some Collection<String>) {
        let tiles = TileConfigurator(model: model)
        for id in changed {
            guard let index = model.order.position(of: id), index < ids.count, ids[index] == id,
                  let item = collectionView.item(at: IndexPath(item: index, section: 0)) as? PhotoTileItem
            else { continue }
            tiles.configure(item, id: id)
        }
    }

    private var laidOutWidth: CGFloat = 0

    /// Called when the strip may have changed size: keeps the focused photo in the middle.
    func stripDidLayout() {
        let width = scrollView.contentView.bounds.width
        guard isActive, abs(width - laidOutWidth) > 0.5 else { return }
        laidOutWidth = width
        centreFocus(animated: false)
    }

    /// Scrolls so the focused photo sits in the middle of the strip, or as near as the ends allow.
    func centreFocus(animated: Bool) {
        guard let focus = model.selection.focus, let index = model.order.position(of: focus), index < ids.count else { return }
        collectionView.layoutSubtreeIfNeeded()
        guard let frame = layout.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame else { return }
        let clip = scrollView.contentView
        let width = clip.bounds.width
        let maxX = max(0, collectionView.frame.width - width)
        let x = min(max(0, frame.midX - width / 2), maxX).rounded()
        guard abs(clip.bounds.origin.x - x) > 0.5 else { return }
        let reduceMotion = SystemAccessibility.reduceMotion
        // A short glide for one step; a jump for anything far, so holding an arrow key keeps up.
        if animated, !reduceMotion, !isAutomation, abs(clip.bounds.origin.x - x) < width {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                context.allowsImplicitAnimation = true
                clip.animator().setBoundsOrigin(NSPoint(x: x, y: 0))
            }
        } else {
            clip.scroll(to: NSPoint(x: x, y: 0))
        }
        scrollView.reflectScrolledClipView(clip)
    }

    private var isAutomation: Bool {
        #if DEBUG
        return AutomationRunner.isActive
        #else
        return false
        #endif
    }

    private func clicked(_ index: Int, kind: ClickKind) {
        guard ids.indices.contains(index) else { return }
        model.click(ids[index], kind: kind)
    }

    /// A click on a cell, for the automation harness: the same path a mouse click takes.
    func click(_ id: String) -> Bool {
        guard let index = ids.firstIndex(of: id) else { return false }
        clicked(index, kind: .plain)
        return true
    }

    func contextMenu(for id: String) -> NSMenu? {
        contextMenu.menu(for: id)
    }

    /// Visible cells still waiting for their thumbnail, for the automation harness.
    var visibleTilesWithoutImage: Int {
        TileConfigurator.tilesWithoutImage(in: collectionView, model: model)
    }

    /// The photos of the cells on screen, in order, for the automation dump.
    var visibleRange: [String] {
        collectionView.indexPathsForVisibleItems().map(\.item).sorted().compactMap { ids.indices.contains($0) ? ids[$0] : nil }
    }

    // MARK: NSCollectionViewDataSource

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        ids.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: PhotoTileItem.identifier, for: indexPath)
        if let tile = item as? PhotoTileItem, ids.indices.contains(indexPath.item) {
            TileConfigurator(model: model).configure(tile, id: ids[indexPath.item])
        }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem, forRepresentedObjectAt indexPath: IndexPath) {
        (item as? PhotoTileItem)?.cancelLoad()
    }
}
