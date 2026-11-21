import AppKit
import CullaCommands
import CullaSession

/// The grid of the current group's photos, an `NSCollectionView` so it scrolls smoothly through
/// tens of thousands of photos. It follows the session model: the photo order, decisions and
/// ratings, the selection, the thumbnail size and requests to show the focused photo. Clicks go
/// back to the model; keys never reach it (the key router takes them first).
@MainActor
final class PhotoGridController: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
    let model: SessionModel
    let scrollView = NSScrollView()
    let collectionView = PhotoCollectionView()
    private let layout = NSCollectionViewFlowLayout()

    /// The photo ids the collection view currently shows, in order: `model.gridOrder`, where a
    /// collapsed stack is its representative's id.
    private var ids: [String] = []
    private var shownOrderRevision = -1
    private var shownMarksRevision = -1
    private var shownSelection = GridSelection()
    private var shownScrollRevision = -1
    private var shownTileWidth: CGFloat = 0
    private var observation: ObservationToken?
    private var layoutWidth: CGFloat = 0
    private lazy var contextMenu = PhotoContextMenu(model: model)
    private var tiles: TileConfigurator { TileConfigurator(model: model) }

    static let spacing: CGFloat = 6
    static let inset: CGFloat = 14

    init(model: SessionModel) {
        self.model = model
        super.init()
        layout.minimumInteritemSpacing = Self.spacing
        layout.minimumLineSpacing = Self.spacing
        layout.sectionInset = NSEdgeInsets(top: Self.inset, left: Self.inset, bottom: Self.inset, right: Self.inset)
        layout.itemSize = NSSize(width: 160, height: 176)

        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = false
        collectionView.backgroundColors = [Palette.gridBackground]
        collectionView.register(PhotoTileItem.self, forItemWithIdentifier: PhotoTileItem.identifier)
        collectionView.setAccessibilityLabel(localized("grid.accessibilityLabel", default: "Photos"))
        collectionView.onClick = { [weak self] index, kind, count in self?.clicked(index, kind: kind, count: count) }
        collectionView.onContextMenu = { [weak self] index in self?.contextMenu(at: index) }
        collectionView.onBand = { [weak self] indexes, base in self?.banded(indexes, base: base) }
        collectionView.selectedIDs = { [weak self] in self?.model.selection.selected ?? [] }

        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Palette.gridBackground
        scrollView.contentView.postsFrameChangedNotifications = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(frameChanged(_:)), name: NSView.frameDidChangeNotification, object: scrollView.contentView
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrolled(_:)), name: NSView.boundsDidChangeNotification, object: scrollView.contentView
        )
        observation = observeChanges { [weak self] in self?.sync() }
    }

    // MARK: Following the model

    private func sync() {
        let orderRevision = model.orderRevision
        let marksRevision = model.marksRevision
        let selection = model.selection
        let scrollRevision = model.scrollRevision
        let tileWidth = CGFloat(model.thumbnailSize)
        let visible = model.viewMode == .grid

        if orderRevision != shownOrderRevision {
            shownOrderRevision = orderRevision
            applyOrder()
            shownSelection = selection
            shownMarksRevision = marksRevision
        }
        if marksRevision != shownMarksRevision {
            let changed = model.changedIDs(after: shownMarksRevision)
            shownMarksRevision = marksRevision
            reconfigure(changed.map(tiles(showing:)) ?? visibleIDs)
        }
        if selection != shownSelection {
            let previous = shownSelection
            shownSelection = selection
            var changed = previous.selected.symmetricDifference(selection.selected)
            if let focus = previous.focus { changed.insert(focus) }
            if let focus = selection.focus { changed.insert(focus) }
            reconfigure(changed)
        }
        if tileWidth != shownTileWidth {
            shownTileWidth = tileWidth
            updateItemSize(force: true)
        }
        if scrollRevision != shownScrollRevision, visible {
            shownScrollRevision = scrollRevision
            scrollToFocus()
        }
    }

    /// Brings the collection view in line with the model's photo order: a reload for a new
    /// group or a large change, else an animated insert and delete of the difference.
    private func applyOrder() {
        let timing = MainThreadTiming.begin("grid.applyOrder")
        defer { timing.end() }
        let newIDs = model.gridOrder.ids
        let reduceMotion = SystemAccessibility.reduceMotion
        defer { reportVisible() }
        if model.orderChange == .refill, !ids.isEmpty {
            // Analysis or tuning filled the group in: no animation, and the photo at the top of
            // the screen (or the focused one) stays exactly where it was.
            let anchor = scrollAnchor()
            ids = newIDs
            collectionView.reloadData()
            if let anchor { restore(anchor) }
            return
        }
        if model.orderChangeIsNewGroup || ids.isEmpty || abs(newIDs.count - ids.count) > 100 || newIDs.count > 20_000 {
            ids = newIDs
            collectionView.reloadData()
            return
        }
        let difference = newIDs.difference(from: ids)
        guard !difference.isEmpty else { return }
        var removed = Set<IndexPath>()
        var inserted = Set<IndexPath>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(IndexPath(item: offset, section: 0))
            case .insert(let offset, _, _): inserted.insert(IndexPath(item: offset, section: 0))
            }
        }
        ids = newIDs
        let updates = { [collectionView] in
            collectionView.deleteItems(at: removed)
            collectionView.insertItems(at: inserted)
        }
        if reduceMotion || model.activity.count(.loading) > 0 || isAutomation {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                collectionView.performBatchUpdates(updates)
            }
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                collectionView.animator().performBatchUpdates(updates)
            }
        }
        // Tiles that stayed may have changed too.
        reconfigure(visibleIDs)
    }

    /// A photo on screen and how far below the top of the visible area its tile is.
    private func scrollAnchor() -> (id: String, offset: CGFloat)? {
        let visible = collectionView.visibleRect
        var candidates: [String] = []
        if let focus = model.selection.focus { candidates.append(focus) }
        let onScreen = collectionView.indexPathsForVisibleItems().map(\.item).sorted()
        candidates += onScreen.compactMap { ids.indices.contains($0) ? ids[$0] : nil }
        for id in candidates {
            guard let index = ids.firstIndex(of: id),
                  let frame = layout.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame,
                  visible.intersects(frame)
            else { continue }
            return (id, frame.minY - visible.minY)
        }
        return nil
    }

    private func restore(_ anchor: (id: String, offset: CGFloat)) {
        collectionView.layoutSubtreeIfNeeded()
        guard let index = model.gridOrder.position(of: anchor.id), index < ids.count,
              let frame = layout.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame
        else { return }
        let visible = collectionView.visibleRect
        let maxY = max(0, collectionView.frame.height - visible.height)
        let y = min(max(0, frame.minY - anchor.offset), maxY)
        guard abs(y - visible.minY) > 0.5 else { return }
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    @objc private func scrolled(_ notification: Notification) {
        reportVisible()
    }

    /// Tells the model which photos are on screen, for analysis priority.
    private func reportVisible() {
        guard model.viewMode == .grid else { return }
        let ids = collectionView.indexPathsForVisibleItems().map(\.item).sorted().compactMap { self.ids.indices.contains($0) ? self.ids[$0] : nil }
        model.reportVisible(ids)
    }

    private var visibleIDs: Set<String> {
        Set(collectionView.indexPathsForVisibleItems().compactMap { ids.indices.contains($0.item) ? ids[$0.item] : nil })
    }

    private var isAutomation: Bool {
        #if DEBUG
        return AutomationRunner.isActive
        #else
        return false
        #endif
    }

    /// The tiles showing these photos: their own, or their collapsed stack's.
    private func tiles(showing changed: Set<String>) -> Set<String> {
        guard model.gridEntries != nil else { return changed }
        return Set(changed.compactMap { model.representative(of: $0) })
    }

    /// Redraws the visible tiles of these photos.
    private func reconfigure(_ changed: some Collection<String>) {
        let timing = MainThreadTiming.begin("grid.reconfigure")
        defer { timing.end() }
        guard !changed.isEmpty else { return }
        for id in changed {
            guard let index = model.gridOrder.position(of: id), index < ids.count, ids[index] == id,
                  let item = collectionView.item(at: IndexPath(item: index, section: 0)) as? PhotoTileItem
            else { continue }
            configure(item, at: index)
        }
    }

    private func configure(_ item: PhotoTileItem, at index: Int) {
        tiles.configure(item, id: ids[index], collapsed: model.gridEntries != nil)
    }

    // MARK: Layout

    @objc private func frameChanged(_ notification: Notification) {
        updateItemSize(force: false)
    }

    /// Sizes tiles so the columns fill the width exactly, as close to the chosen size as fits.
    func updateItemSize(force: Bool) {
        // The clip view's width: what is left once a scroller that takes space is shown.
        let width = scrollView.contentView.bounds.width
        guard width > 0, force || abs(width - layoutWidth) > 0.5 else { return }
        layoutWidth = width
        let target = CGFloat(model.thumbnailSize)
        let available = width - Self.inset * 2
        let columns = max(1, Int((available + Self.spacing) / (target + Self.spacing)))
        // Half a point spare, so rounding never pushes the last column onto the next row.
        let tileWidth = floor((available - 0.5 - CGFloat(columns - 1) * Self.spacing) / CGFloat(columns))
        let tileHeight = (tileWidth - PhotoTileView.photoInset * 2) + PhotoTileView.footerHeight + PhotoTileView.photoInset
        let size = NSSize(width: tileWidth, height: tileHeight.rounded())
        model.gridColumns = columns
        let rowHeight = size.height + Self.spacing
        model.gridRowsPerPage = max(1, Int((scrollView.contentView.bounds.height - Self.inset) / rowHeight))
        if layout.itemSize != size {
            let focusVisible = isFocusVisible
            layout.itemSize = size
            layout.invalidateLayout()
            if focusVisible { scrollToFocus() }
        }
    }

    private var isFocusVisible: Bool {
        guard let frame = focusFrame else { return false }
        return collectionView.visibleRect.intersects(frame)
    }

    private var focusFrame: NSRect? {
        guard let focus = model.selection.focus, let index = model.gridOrder.position(of: focus), index < ids.count else { return nil }
        return layout.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame
    }

    /// Scrolls just enough to show the focused photo with a little room around it.
    func scrollToFocus() {
        collectionView.layoutSubtreeIfNeeded()
        guard let frame = focusFrame else { return }
        let target = frame.insetBy(dx: 0, dy: -Self.inset)
        let visible = collectionView.visibleRect
        guard !visible.contains(target) else { return }
        var origin = visible.origin
        if target.minY < visible.minY {
            origin.y = target.minY
        } else if target.maxY > visible.maxY {
            origin.y = target.maxY - visible.height
        }
        let maxY = max(0, collectionView.frame.height - visible.height)
        origin.y = min(max(0, origin.y), maxY)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: origin.y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: Clicks

    private func clicked(_ index: Int, kind: ClickKind, count: Int) {
        guard ids.indices.contains(index) else { return }
        let id = ids[index]
        if count >= 2 {
            model.open(id)
        } else {
            model.click(id, kind: kind)
        }
    }

    private func contextMenu(at index: Int) -> NSMenu? {
        guard ids.indices.contains(index) else { return nil }
        return contextMenu.menu(for: ids[index])
    }

    /// The menu a right-click on a photo shows, for the automation harness.
    func contextMenu(for id: String) -> NSMenu? {
        contextMenu.menu(for: id)
    }

    private func banded(_ indexes: [Int], base: Set<String>) {
        model.selectBand(indexes.sorted().compactMap { ids.indices.contains($0) ? ids[$0] : nil }, base: base)
    }

    // MARK: NSCollectionViewDataSource

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        ids.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: PhotoTileItem.identifier, for: indexPath)
        if let tile = item as? PhotoTileItem, ids.indices.contains(indexPath.item) {
            configure(tile, at: indexPath.item)
        }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem, forRepresentedObjectAt indexPath: IndexPath) {
        (item as? PhotoTileItem)?.cancelLoad()
    }

    /// Visible tiles still waiting for their thumbnail, for the automation harness.
    var visibleTilesWithoutImage: Int {
        TileConfigurator.tilesWithoutImage(in: collectionView, model: model)
    }
}

/// The collection view, taking clicks itself so selection follows the model rather than the
/// collection view's own rules. A drag that starts between tiles draws a rubber band and selects
/// the tiles it touches (with Shift or Command, added to the selection).
final class PhotoCollectionView: NSCollectionView {
    var onClick: ((Int, ClickKind, Int) -> Void)?
    var onContextMenu: ((Int) -> NSMenu?)?
    var onBand: (([Int], Set<String>) -> Void)?
    var selectedIDs: (() -> Set<String>)?
    var allowsRubberBand = true

    private var bandStart: NSPoint?
    private var bandBase: Set<String> = []
    private var bandLayer: CAShapeLayer?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        window?.makeFirstResponder(self)
        let flags = event.modifierFlags
        guard let indexPath = indexPathForItem(at: point) else {
            guard allowsRubberBand else { return }
            bandStart = point
            bandBase = flags.contains(.shift) || flags.contains(.command) ? (selectedIDs?() ?? []) : []
            return
        }
        bandStart = nil
        let kind: ClickKind = flags.contains(.shift) ? .extend : flags.contains(.command) ? .toggle : .plain
        onClick?(indexPath.item, kind, event.clickCount)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = bandStart else { return }
        autoscroll(with: event)
        let point = convert(event.locationInWindow, from: nil)
        let rect = NSRect(
            x: min(start.x, point.x), y: min(start.y, point.y),
            width: abs(point.x - start.x), height: abs(point.y - start.y)
        )
        showBand(rect)
        let attributes = collectionViewLayout?.layoutAttributesForElements(in: rect) ?? []
        let indexes = attributes.compactMap { $0.representedElementCategory == .item && $0.frame.intersects(rect) ? $0.indexPath?.item : nil }
        onBand?(indexes, bandBase)
    }

    override func mouseUp(with event: NSEvent) {
        bandStart = nil
        bandLayer?.removeFromSuperlayer()
        bandLayer = nil
    }

    private func showBand(_ rect: NSRect) {
        if bandLayer == nil, let layer {
            let band = CAShapeLayer()
            band.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
            band.strokeColor = NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor
            band.lineWidth = 1
            band.zPosition = 1000
            band.actions = ["path": NSNull(), "position": NSNull(), "bounds": NSNull()]
            layer.addSublayer(band)
            bandLayer = band
        }
        bandLayer?.frame = bounds
        bandLayer?.path = CGPath(rect: rect.insetBy(dx: 0.5, dy: 0.5), transform: nil)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let indexPath = indexPathForItem(at: point) else { return nil }
        return onContextMenu?(indexPath.item)
    }

    override var acceptsFirstResponder: Bool { true }
}
