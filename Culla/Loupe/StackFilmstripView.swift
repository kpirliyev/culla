import AppKit
import CullaCommands
import CullaCore
import CullaSession

/// The frames of the stack in review, one tile per column of the face strip above, so a column
/// of faces sits over its frame. Each tile is the grid's tile at a small size: the star on the
/// pick, the reason badges and Culla's notes ("softer than the pick"), the decision, and the
/// focus ring on the current frame. Stacks are short, so the tiles are plain views.
@MainActor
final class StackFilmstripView: NSView {
    static let tileHeight: CGFloat = 80
    static let height: CGFloat = tileHeight + 12

    let scrollView = NSScrollView()
    private let document = FlippedView()
    private var tiles: [PhotoTileView] = []
    private var loads: [Task<Void, Never>] = []
    private(set) var ids: [String] = []
    private let legend = NSTextField(labelWithString: "")
    private let title = NSTextField(labelWithString: localized("filmstrip.frames", default: "Frames"))
    var onClick: ((String) -> Void)?
    var onScroll: ((CGFloat) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Palette.panelBackground.cgColor
        scrollView.documentView = document
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .none
        scrollView.contentView.postsBoundsChangedNotifications = true
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        legend.font = .systemFont(ofSize: 10)
        legend.textColor = .tertiaryLabelColor
        legend.maximumNumberOfLines = 2
        legend.stringValue = localized("★ best pick\n▢ current frame")
        for view in [scrollView, title, legend] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            legend.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            legend.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            legend.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.leadingAnchor, constant: -4),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: FaceStripView.labelWidth),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled(_:)), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(localized("Frames of the stack"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Shows the frames. Tiles of frames that stay are only reconfigured, so nothing flashes.
    func show(_ contents: [TileContent], model: SessionModel) {
        let newIDs = contents.map(\.id)
        if newIDs != ids {
            for task in loads { task.cancel() }
            loads = []
        }
        while tiles.count < contents.count {
            let tile = PhotoTileView(frame: .zero)
            document.addSubview(tile)
            tiles.append(tile)
        }
        let width = FaceStripView.columnWidth
        for (index, tile) in tiles.enumerated() {
            guard index < contents.count else {
                tile.isHidden = true
                tile.content = nil
                continue
            }
            let content = contents[index]
            tile.isHidden = false
            tile.frame = CGRect(x: FaceStripView.gridInset + CGFloat(index) * width + 2, y: 6, width: width - 4, height: Self.tileHeight)
            if tile.content?.id != content.id || !tile.hasImage {
                if tile.content?.id != content.id { tile.setImage(nil) }
                load(tile, id: content.id, model: model)
            }
            tile.content = content
            let id = content.id
            tile.accessibilityPress = { [weak self] in self?.onClick?(id) }
        }
        ids = newIDs
        document.frame.size = NSSize(width: FaceStripView.gridInset * 2 + CGFloat(contents.count) * width, height: Self.height)
    }

    private func load(_ tile: PhotoTileView, id: String, model: SessionModel) {
        guard let photo = model.state.photo(id), !photo.isUnreadable else { return }
        if let image = model.thumbnails.cachedThumbnail(for: photo.file) {
            tile.setImage(image)
            return
        }
        let thumbnails = model.thumbnails
        let activity = model.activity
        activity.begin(.thumbnail)
        loads.append(Task { [weak tile, weak model] in
            defer { activity.end(.thumbnail) }
            do {
                let image = try await thumbnails.thumbnail(for: photo.file)
                guard !Task.isCancelled, let tile, tile.content?.id == id else { return }
                tile.setImage(image)
            } catch is CancellationError {
                return
            } catch {
                // As in the grid: a disconnected folder waits for its return, a bad file is marked.
                guard !Task.isCancelled else { return }
                model?.thumbnailFailed(for: id, error: error)
            }
        })
    }

    /// Frames still waiting for their thumbnail, not counting those waiting for a disconnected
    /// folder to come back.
    func tilesWithoutImage(model: SessionModel) -> Int {
        let waiting = model.folderMissing ? model.thumbnailsAwaitingFolder : []
        return tiles.filter { tile in
            guard !tile.isHidden, let content = tile.content, !content.isUnreadable else { return false }
            return !tile.hasImage && !waiting.contains(content.id)
        }.count
    }

    func scrollToColumn(_ column: Int) {
        let x = FaceStripView.gridInset + CGFloat(column) * FaceStripView.columnWidth
        let visible = scrollView.contentView.bounds
        guard x < visible.minX || x + FaceStripView.columnWidth > visible.maxX else { return }
        let target = max(0, min(x + FaceStripView.columnWidth / 2 - visible.width / 2, document.frame.width - visible.width))
        setHorizontalOffset(target)
    }

    func setHorizontalOffset(_ x: CGFloat) {
        let clip = scrollView.contentView
        guard abs(clip.bounds.minX - x) > 0.5 else { return }
        clip.scroll(to: NSPoint(x: x, y: 0))
        scrollView.reflectScrolledClipView(clip)
    }

    @objc private func scrolled(_ notification: Notification) {
        onScroll?(scrollView.contentView.bounds.minX)
    }

    override func mouseDown(with event: NSEvent) {
        let point = document.convert(event.locationInWindow, from: nil)
        for (index, tile) in tiles.enumerated() where index < ids.count && !tile.isHidden && tile.frame.contains(point) {
            onClick?(ids[index])
            return
        }
    }

    /// A click on a frame, for the automation harness.
    func click(_ id: String) -> Bool {
        guard ids.contains(id) else { return false }
        onClick?(id)
        return true
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
