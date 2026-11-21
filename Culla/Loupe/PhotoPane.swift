import AppKit
import CullaAnalysis
import CullaCommands
import CullaCore
import CullaFiles
import CullaSession
import SwiftUI

/// One photo in a pane of stack review, compare or duplicate review: a real loupe (zoomable,
/// pannable, pixel for pixel from 100%) with a caption above it.
///
/// Images, sharpest last, as in the loupe: the grid thumbnail at once if it is in memory, the
/// screen-size image (usually decoded ahead), and the full-size image only while the zoom shows
/// more than the screen-size image holds. The pane keeps the image it shows until the next one is
/// ready, so stepping never flashes an empty pane.
///
/// The pane does not decide its zoom: its controller applies the zoom the panes share, and the
/// pane reports the person's pinches, scrolls and drags through `onZoomChange`.
@MainActor
final class PhotoPane: NSView {
    let imageView = LoupeImageView()
    private let imageArea = NSView()
    private let captionHost: NSHostingView<AnyView>
    private let badgeView = NSView()
    private let ringView = NSView()
    private let previews: ScreenPreviewCache
    private let thumbnails: ThumbnailCache
    private let store: LoupeImageStore
    private(set) var photo: PhotoItem?
    private var fileKey: String?
    private var screenTask: Task<Void, Never>?
    private var thumbnailTask: Task<Void, Never>?
    /// The photo whose full-size image is decoded ahead while zoomed, such as the next frame.
    var ahead: PhotoItem?

    /// The person zoomed or panned this pane.
    var onZoomChange: ((LoupeZoom) -> Void)?
    /// A click anywhere on the pane.
    var onClick: (() -> Void)?
    /// The photo became as sharp as the zoom needs.
    var onSharp: (() -> Void)?

    private(set) var resolution = LoupeStatus.Resolution.none
    private(set) var loadingFullSize = false
    // Timings of the last photo shown, for the automation dump.
    private var shownAt: CFTimeInterval = 0
    private(set) var lastFirstImageMs: Double?
    private(set) var lastSharpMs: Double?
    private var sharpPending = false

    static let captionHeight: CGFloat = 26

    init(previews: ScreenPreviewCache, thumbnails: ThumbnailCache, activity: ActivityTracker) {
        self.previews = previews
        self.thumbnails = thumbnails
        store = LoupeImageStore(activity: activity)
        captionHost = NSHostingView(rootView: AnyView(EmptyView()))
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        wantsLayer = true
        captionHost.sizingOptions = []
        imageArea.wantsLayer = true
        imageArea.layer?.backgroundColor = Palette.loupeBackground.cgColor
        imageView.frame = imageArea.bounds
        imageView.autoresizingMask = [.width, .height]
        imageArea.addSubview(imageView)
        badgeView.wantsLayer = true
        badgeView.layer?.actions = LoupeDocumentView.noActions
        imageArea.addSubview(badgeView)
        ringView.wantsLayer = true
        ringView.layer?.actions = LoupeDocumentView.noActions
        ringView.layer?.cornerRadius = 3
        imageArea.addSubview(ringView)
        for view in [captionHost, imageArea] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            captionHost.topAnchor.constraint(equalTo: topAnchor),
            captionHost.leadingAnchor.constraint(equalTo: leadingAnchor),
            captionHost.trailingAnchor.constraint(equalTo: trailingAnchor),
            captionHost.heightAnchor.constraint(equalToConstant: Self.captionHeight),
            imageArea.topAnchor.constraint(equalTo: captionHost.bottomAnchor),
            imageArea.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageArea.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageArea.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        imageView.onZoomChange = { [weak self] zoom in self?.userZoomed(zoom) }
        imageView.onMouseDown = { [weak self] in self?.onClick?() }
        imageView.onDoubleClick = { [weak self] point in self?.doubleClicked(at: point) }
        store.onFullImage = { [weak self] id in self?.fullImageArrived(id) }
        // A pane that grows or shrinks (the best-pick pane or the face strip hidden, the window
        // resized) keeps fit at fit and a zoom at its factor and centre (`LoupeImageView.tile`);
        // what it needs of the full-size image may change with it.
        imageView.onResize = { [weak self] in
            guard let self else { return }
            self.updateFullSizeNeed()
            self.checkSharp()
            self.layoutBadge()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func layout() {
        super.layout()
        layoutBadge()
    }

    // MARK: Caption, badge and ring

    func setCaption<Content: View>(_ view: Content) {
        captionHost.rootView = AnyView(view)
    }

    /// The decision badge in the photo's top right corner, as in the loupe.
    func setDecision(_ decision: Decision?) {
        let kind: TileArtwork.Kind? = switch decision {
        case .kept: .kept
        case .rejected: .rejected
        default: nil
        }
        let scale = window?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let kind, let image = TileArtwork.image(kind, size: 24, scale: scale) {
            badgeView.layer?.contents = image
            badgeView.layer?.contentsScale = scale
            badgeView.isHidden = false
        } else {
            badgeView.isHidden = true
        }
        CATransaction.commit()
        layoutBadge()
    }

    /// The ring that marks the pane keys act on: white for the focus, or none.
    func setRing(_ color: NSColor?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ringView.layer?.borderColor = color?.cgColor
        ringView.layer?.borderWidth = color == nil ? 0 : 1.5
        ringView.isHidden = color == nil
        CATransaction.commit()
    }

    private func layoutBadge() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ringView.frame = imageArea.bounds.insetBy(dx: 1, dy: 1)
        let photo = imageView.document.convert(imageView.document.bounds, to: imageArea)
        let visible = photo.intersection(imageArea.bounds)
        let bounds = visible.isNull ? imageArea.bounds : visible
        badgeView.frame = CGRect(x: bounds.maxX - 24 - 10, y: bounds.maxY - 24 - 10, width: 24, height: 24)
        CATransaction.commit()
    }

    // MARK: Showing a photo

    /// Shows a photo at a zoom. The image on screen stays until a better one for the new photo
    /// is ready, so nothing flashes.
    func show(_ photo: PhotoItem?, zoom: LoupeZoom) {
        guard let photo else {
            self.photo = nil
            fileKey = nil
            screenTask?.cancel(); screenTask = nil
            imageView.document.setImage(nil)
            imageView.document.setFullImage(nil)
            imageView.document.setFaces([])
            store.want([])
            resolution = .none
            setDecision(nil)
            return
        }
        let key = Self.fileKey(photo)
        if photo.id == self.photo?.id, key == fileKey {
            self.photo = photo
            apply(zoom)
            return
        }
        self.photo = photo
        fileKey = key
        shownAt = CACurrentMediaTime()
        lastFirstImageMs = nil
        lastSharpMs = nil
        sharpPending = true
        screenTask?.cancel(); screenTask = nil
        screenTask = nil
        thumbnailTask?.cancel()
        let screen = previews.cached(photo.file)
        let thumbnail = screen == nil ? thumbnails.cachedThumbnail(for: photo.file) : nil
        imageView.document.setFullImage(nil)
        if let base = screen ?? thumbnail {
            imageView.document.setImage(base)
            lastFirstImageMs = (CACurrentMediaTime() - shownAt) * 1000
        }
        let reference = (screen ?? thumbnail).map { CGSize(width: $0.width, height: $0.height) }
        imageView.setPixelSize(LoupeViewController.fullPixelSize(photo, reference: reference), zoom: zoom)
        resolution = screen.map { LoupeViewController.isFullSize($0, photo) ? .full : .screen } ?? (thumbnail != nil ? .thumbnail : resolution)
        if screen == nil {
            loadScreenImage(photo, needsThumbnail: thumbnail == nil)
        }
        updateFullSizeNeed()
        checkSharp()
        layoutBadge()
    }

    private func loadScreenImage(_ photo: PhotoItem, needsThumbnail: Bool) {
        let id = photo.id
        let previews = previews
        if needsThumbnail {
            // The thumbnail is usually on disk: it fills in while the screen image decodes.
            let thumbnails = thumbnails
            thumbnailTask = Task { [weak self] in
                guard let image = try? await thumbnails.thumbnail(for: photo.file) else { return }
                guard let self, !Task.isCancelled, self.photo?.id == id, self.resolution == .none || self.resolution == .thumbnail else { return }
                if self.resolution == .none {
                    self.imageView.document.setImage(image)
                    self.resolution = .thumbnail
                    if self.lastFirstImageMs == nil { self.lastFirstImageMs = (CACurrentMediaTime() - self.shownAt) * 1000 }
                }
            }
        }
        screenTask = Task { [weak self] in
            let image = try? await previews.image(for: photo.file)
            guard let self, !Task.isCancelled, self.photo?.id == id else { return }
            self.screenTask = nil
            guard let image else { return }
            self.thumbnailTask?.cancel()
            self.imageView.document.setImage(image)
            if self.imageView.document.fullImage == nil {
                self.resolution = LoupeViewController.isFullSize(image, photo) ? .full : .screen
            }
            if self.lastFirstImageMs == nil { self.lastFirstImageMs = (CACurrentMediaTime() - self.shownAt) * 1000 }
            let size = LoupeViewController.fullPixelSize(photo, reference: CGSize(width: image.width, height: image.height))
            if size != self.imageView.pixelSize { self.imageView.setPixelSize(size, zoom: self.imageView.zoom) }
            self.updateFullSizeNeed()
            self.checkSharp()
        }
    }

    /// Loads the photo again when nothing of it could be shown, such as while its folder could
    /// not be reached. Called when the folder is back.
    func retryIfBlank() {
        guard let photo, !photo.isUnreadable, resolution == .none, screenTask == nil else { return }
        loadScreenImage(photo, needsThumbnail: true)
    }

    /// Decodes the photo again when the screen-size image on show is smaller than the decode size
    /// now asks for: the viewport grew, as when the current frame takes the best pick's place. The
    /// smaller image stays on screen until the larger one is ready.
    func screenSizeChanged() {
        guard let photo, !photo.isUnreadable, screenTask == nil, imageView.document.fullImage == nil,
              let shown = imageView.document.image else { return }
        let fullLongSide = max(photo.metadata.pixelWidth ?? 0, photo.metadata.pixelHeight ?? 0)
        let wanted = fullLongSide > 0 ? min(previews.pixelSize, fullLongSide) : previews.pixelSize
        guard max(shown.width, shown.height) < wanted else { return }
        loadScreenImage(photo, needsThumbnail: false)
    }

    static func fileKey(_ photo: PhotoItem) -> String {
        "\(photo.file.fileSize)|\(photo.file.modificationDate.timeIntervalSinceReferenceDate)"
    }

    /// Applies the zoom the panes share.
    func apply(_ zoom: LoupeZoom) {
        guard zoom != imageView.zoom else {
            updateFullSizeNeed()
            return
        }
        // Zooming out to where the full-size image is not needed: its tiles are hidden first, so
        // the zoom does not hand every tile of it (about 96 MB at 24 MP) to Core Animation on
        // the way out. That cost 112 ms of the main thread with two panes.
        let geometry = imageView.geometry
        if imageView.document.fullImage != nil,
           !geometry.needsLargerImage(factor: geometry.factor(of: geometry.normalized(zoom)), availableLongSide: screenLongSide) {
            imageView.document.tilesLayer.isHidden = true
        }
        imageView.apply(zoom)
        updateFullSizeNeed()
        checkSharp()
        layoutBadge()
    }

    func setFaces(_ faces: [LoupeFaceBox]) {
        imageView.document.setFaces(faces)
    }

    private func userZoomed(_ zoom: LoupeZoom) {
        updateFullSizeNeed()
        layoutBadge()
        // Layout passes move the clip view by a rounding error: not the person zooming.
        if Self.nearlyEqual(zoom, imageView.lastApplied) { return }
        // Only the person's own pinches, scrolls and drags are passed on to the other panes; the
        // clip view also moves when the pane is laid out or its photo changes size.
        guard let type = NSApp.currentEvent?.type, Self.userEvents.contains(type) else { return }
        onZoomChange?(zoom)
    }

    private static let userEvents: Set<NSEvent.EventType> = [
        .scrollWheel, .magnify, .smartMagnify, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .gesture, .beginGesture, .endGesture,
    ]

    static func nearlyEqual(_ a: LoupeZoom, _ b: LoupeZoom) -> Bool {
        switch (a, b) {
        case (.fit, .fit): return true
        case let (.zoomed(f1, c1), .zoomed(f2, c2)):
            return abs(f1 - f2) <= f2 * 0.005 && abs(c1.x - c2.x) < 0.003 && abs(c1.y - c2.y) < 0.003
        default: return false
        }
    }

    private func doubleClicked(at point: CullaCore.UnitPoint) {
        let zoom: LoupeZoom = imageView.zoom.isZoomed ? .fit : imageView.geometry.zoom(.fit, to: 1, keeping: point)
        imageView.apply(zoom)
        userZoomed(imageView.zoom)
    }

    // MARK: Full size

    private var screenLongSide: Int {
        photo.flatMap { previews.cached($0.file) }.map { max($0.width, $0.height) } ?? previews.pixelSize
    }

    /// Asks for the full-size image when the zoom needs it, and lets it go when it does not.
    func updateFullSizeNeed() {
        guard let photo, !photo.isUnreadable else {
            store.want([])
            loadingFullSize = false
            return
        }
        let needs = imageView.geometry.needsLargerImage(factor: imageView.factor, availableLongSide: screenLongSide)
        guard needs else {
            store.want([])
            loadingFullSize = false
            if imageView.document.fullImage != nil {
                // Hidden now; the tiles (about 96 MB for 24 MP) are let go on the next turn of the
                // run loop, so freeing them does not add to the frame that zooms out.
                imageView.document.tilesLayer.isHidden = true
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.imageView.geometry.needsLargerImage(factor: self.imageView.factor, availableLongSide: self.screenLongSide) else { return }
                    self.imageView.document.setFullImage(nil)
                }
                if let image = imageView.document.image { resolution = LoupeViewController.isFullSize(image, photo) ? .full : .screen }
            }
            return
        }
        var wanted: [(id: String, file: PhotoFile)] = [(photo.id, photo.file)]
        if let ahead, ahead.id != photo.id, !ahead.isUnreadable,
           max(ahead.metadata.pixelWidth ?? 0, ahead.metadata.pixelHeight ?? 0) > previews.pixelSize {
            wanted.append((ahead.id, ahead.file))
        }
        store.want(wanted)
        if let full = store.fullImage(for: photo.id) { showFull(full) }
        loadingFullSize = store.fullImage(for: photo.id) == nil
    }

    private func fullImageArrived(_ id: String) {
        guard let photo, photo.id == id, let full = store.fullImage(for: id),
              imageView.geometry.needsLargerImage(factor: imageView.factor, availableLongSide: screenLongSide)
        else { return }
        showFull(full)
        loadingFullSize = false
        checkSharp()
    }

    private func showFull(_ full: TiledImage) {
        if imageView.document.fullImage != nil, imageView.document.tilesLayer.isHidden { imageView.document.showTiles() }
        guard imageView.document.fullImage?.tiles.first??.image !== full.tiles.first??.image else { return }
        let size = CGSize(width: full.width, height: full.height)
        if abs(size.width - imageView.pixelSize.width) > 0.5 || abs(size.height - imageView.pixelSize.height) > 0.5 {
            imageView.setPixelSize(size, zoom: imageView.zoom)
        }
        imageView.document.setFullImage(full)
        resolution = .full
    }

    private func checkSharp() {
        guard sharpPending, photo != nil else { return }
        let needsFull = imageView.geometry.needsLargerImage(factor: imageView.factor, availableLongSide: screenLongSide)
        guard resolution == .full || (resolution == .screen && !needsFull) else { return }
        lastSharpMs = (CACurrentMediaTime() - shownAt) * 1000
        sharpPending = false
        onSharp?()
    }

    /// Lets every image go, for when the screen is hidden.
    func release() {
        screenTask?.cancel(); screenTask = nil
        thumbnailTask?.cancel()
        store.releaseAll()
        photo = nil
        fileKey = nil
        imageView.document.setImage(nil)
        imageView.document.setFullImage(nil)
        imageView.document.setFaces([])
        resolution = .none
    }

    /// True when the pane shows its photo as sharp as the zoom needs.
    var isSettled: Bool {
        guard let photo else { return true }
        if photo.isUnreadable { return true }
        return screenTask == nil && !store.isBusy && resolution != .none
    }

    var isSharp: Bool {
        guard photo != nil else { return true }
        let needsFull = imageView.geometry.needsLargerImage(factor: imageView.factor, availableLongSide: screenLongSide)
        return resolution == .full || (resolution == .screen && !needsFull)
    }

    func dumpState() -> [String: Any] {
        let rect = imageView.visibleUnitRect
        var state: [String: Any] = [
            "photo": photo?.id ?? NSNull(),
            "zoomPercent": Int((imageView.factor * 100).rounded()),
            "isFit": !imageView.zoom.isZoomed,
            "resolution": resolution.rawValue,
            "fullImageInUse": imageView.document.fullImage != nil,
            "faceBoxes": imageView.document.faceCount,
        ]
        state["visibleCentre"] = [((rect.x + rect.width / 2) * 1000).rounded() / 1000, ((rect.y + rect.height / 2) * 1000).rounded() / 1000]
        if let value = lastFirstImageMs { state["firstImageMs"] = (value * 10).rounded() / 10 }
        if let value = lastSharpMs { state["sharpMs"] = (value * 10).rounded() / 10 }
        return state
    }
}
