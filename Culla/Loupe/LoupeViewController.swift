import AppKit
import CullaAnalysis
import CullaCommands
import CullaCore
import CullaSession
import SwiftUI

/// The loupe: one photo, zoomable and pannable, with a slim header above it and the filmstrip
/// below. It follows the model: the focused photo, the zoom commands set, the overlays.
///
/// Images, sharpest last:
/// 1. the grid thumbnail, if it is in memory, at once;
/// 2. the screen-size image (`ScreenPreviewCache`), usually already decoded because the
///    neighbours of the photo in view are decoded ahead;
/// 3. the full-size image, only when the zoom shows more than the screen-size image holds
///    (`LoupeImageStore`); while zoomed, the next photo's is decoded ahead too, so stepping
///    through a burst at 100% stays sharp.
/// All share the document's coordinates (one unit per full-size pixel), so swapping one for the
/// next never moves the photo.
@MainActor
final class LoupeViewController: NSViewController {
    let model: SessionModel
    let status = LoupeStatus()
    let imageView = LoupeImageView()
    let filmstrip: FilmstripController
    private let store: LoupeImageStore
    private var headerHost: NSHostingView<LoupeHeaderView>!
    private var legendHost: NSHostingView<ClippingLegend>!
    private var unreadableHost: NSHostingView<UnreadablePhotoView>?
    /// A view of its own, above the photo: a sublayer of the image area would be drawn under the
    /// scroll view.
    private let decisionBadgeView = NSView()
    private var decisionBadge: CALayer { decisionBadgeView.layer! }
    private let imageArea = NSView()
    private var observation: ObservationToken?
    /// The face strip under the photo, shown with F: the photo's stack, or its own faces.
    private(set) var faceStrip: FaceStripView!
    private var faceStripHeight: NSLayoutConstraint!
    private var faceCrops: FaceCropStore!

    private var isActive = false
    private var folderWasMissing = false
    private var shownID: String?
    private var shownFileKey: String?
    private var shownZoomRevision = -1
    private var screenTask: Task<Void, Never>?
    /// +1 after moving forward, -1 after moving back: which neighbour is decoded ahead.
    private var direction = 1
    private var shownPosition: Int?

    // Timings, for the automation dump.
    private var sharpPending: (kind: String, startedAt: CFTimeInterval)?
    private(set) var lastZoomToSharpMs: Double?
    private(set) var lastStepToSharpMs: Double?
    private(set) var lastStepToFirstImageMs: Double?

    static let headerHeight: CGFloat = 36

    init(model: SessionModel) {
        self.model = model
        filmstrip = FilmstripController(model: model)
        store = LoupeImageStore(activity: model.activity)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.wantsLayer = true
        view.layer?.backgroundColor = Palette.loupeBackground.cgColor
        self.view = view
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        headerHost = NSHostingView(rootView: LoupeHeaderView(model: model, status: status))
        headerHost.sizingOptions = []
        legendHost = NSHostingView(rootView: ClippingLegend(status: status))
        legendHost.sizingOptions = [.intrinsicContentSize]

        imageArea.wantsLayer = true
        imageArea.layer?.backgroundColor = Palette.loupeBackground.cgColor
        imageView.frame = imageArea.bounds
        imageView.autoresizingMask = [.width, .height]
        imageArea.addSubview(imageView)
        decisionBadgeView.wantsLayer = true
        decisionBadge.actions = LoupeDocumentView.noActions
        imageArea.addSubview(decisionBadgeView)

        let strip = filmstrip.scrollView
        let separator = NSBox()
        separator.boxType = .custom
        separator.borderWidth = 0
        separator.fillColor = Palette.separator
        faceCrops = FaceCropStore(previews: model.previews, thumbnails: model.thumbnails, activity: model.activity)
        faceStrip = FaceStripView(crops: faceCrops)
        faceStrip.isHidden = true
        faceStripHeight = faceStrip.heightAnchor.constraint(equalToConstant: 0)
        for subview in [headerHost!, imageArea, faceStrip!, separator, strip, legendHost!] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            headerHost.topAnchor.constraint(equalTo: view.topAnchor),
            headerHost.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerHost.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            headerHost.heightAnchor.constraint(equalToConstant: Self.headerHeight),
            imageArea.topAnchor.constraint(equalTo: headerHost.bottomAnchor),
            imageArea.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            imageArea.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            imageArea.bottomAnchor.constraint(equalTo: faceStrip.topAnchor),
            faceStrip.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            faceStrip.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            faceStrip.bottomAnchor.constraint(equalTo: separator.topAnchor),
            faceStripHeight,
            separator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
            separator.bottomAnchor.constraint(equalTo: strip.topAnchor),
            strip.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            strip.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            strip.heightAnchor.constraint(equalToConstant: FilmstripController.height),
            legendHost.leadingAnchor.constraint(equalTo: imageArea.leadingAnchor, constant: 12),
            legendHost.bottomAnchor.constraint(equalTo: imageArea.bottomAnchor, constant: -12),
        ])

        imageView.onZoomChange = { [weak self] zoom in self?.userChangedZoom(zoom) }
        imageView.onDoubleClick = { [weak self] point in self?.doubleClicked(at: point) }
        store.onFullImage = { [weak self] id in self?.fullImageArrived(id) }
        faceCrops.onCrops = { [weak self] in self?.faceStrip.cropsArrived() }
        faceStrip.onCellClick = { [weak self] row, column in
            guard let self else { return }
            let layout = self.faceStrip.layout
            if layout.singlePhoto {
                if let face = layout.cells.first?[column]?.face { self.model.zoomLoupe(toFace: face) }
            } else {
                self.model.selectFaceCell(row: row, column: column)
            }
        }
        observation = observeChanges { [weak self] in self?.sync() }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        layoutBadge()
        filmstrip.stripDidLayout()
        // Images are prepared in the window's colour space, so Core Animation need not convert
        // them on the main thread.
        if let space = view.window?.colorSpace?.cgColorSpace, space != model.previews.colorSpace {
            model.previews.colorSpace = space
            store.colorSpace = space
        }
        // Screen-size images are decoded for the viewport; a much larger window needs larger ones.
        let scale = view.window?.backingScaleFactor ?? 2
        let longSide = Int(max(imageView.contentSize.width, imageView.contentSize.height) * scale)
        if longSide > 0, model.previews.setViewportLongSide(longSide), isActive, let photo = model.focusedPhoto,
           photo.id == shownID, !photo.isUnreadable {
            loadScreenImage(photo)
        }
    }

    // MARK: Following the model

    private func sync() {
        let timing = MainThreadTiming.begin("loupe.sync")
        defer { timing.end() }
        let active = model.viewMode == .loupe && !model.order.isEmpty
        if active != isActive {
            isActive = active
            filmstrip.isActive = active
            if !active { deactivate() }
        }
        guard active else { return }
        let photo = model.focusedPhoto
        let zoomRevision = model.loupeZoomRevision
        let overlays = model.loupeOverlays
        _ = model.loupeTargetFace
        // A photo left blank while its folder could not be reached loads again when it is back.
        let folderBack = folderWasMissing && !model.folderMissing
        folderWasMissing = model.folderMissing
        _ = overlays

        if let photo {
            let key = Self.fileKey(photo)
            if photo.id != shownID || key != shownFileKey {
                show(photo)
            }
        } else if shownID != nil {
            shownID = nil
            imageView.document.setImage(nil)
            imageView.document.setFullImage(nil)
        }
        if folderBack, let photo, photo.id == shownID, !photo.isUnreadable, screenTask == nil,
           imageView.document.image == nil || status.resolution == .thumbnail {
            loadScreenImage(photo)
        }
        if zoomRevision != shownZoomRevision {
            shownZoomRevision = zoomRevision
            imageView.apply(model.loupeZoom)
            model.loupeViewChanged(imageView.zoom)
            zoomChanged(byCommand: true)
        }
        updateOverlays(photo)
        updateBadge(photo)
        updateFaceStrip(photo)
    }

    private func updateFaceStrip(_ photo: PhotoItem?) {
        _ = model.revision
        let shown = model.faceStripInLoupe && photo.map { !$0.isUnreadable } == true
        faceStrip.isHidden = !shown
        guard shown, let photo else {
            if faceStripHeight.constant != 0 { faceStripHeight.constant = 0 }
            faceCrops.want([])
            return
        }
        faceStrip.show(FaceStripLayout.make(model: model, for: photo.id)) { [model] in model.state.photo($0) }
        faceStrip.scrollToCurrent()
        let cap = max(faceStrip.minimumHeight, (view.bounds.height * 0.3).rounded())
        let height = min(faceStrip.idealHeight, cap)
        if abs(faceStripHeight.constant - height) > 0.5 { faceStripHeight.constant = height }
    }

    private static func fileKey(_ photo: PhotoItem) -> String {
        "\(photo.file.fileSize)|\(photo.file.modificationDate.timeIntervalSinceReferenceDate)|\(photo.isUnreadable)"
    }

    private func deactivate() {
        screenTask?.cancel()
        screenTask = nil
        store.releaseAll()
        shownID = nil
        shownFileKey = nil
        imageView.document.setImage(nil)
        imageView.document.setFullImage(nil)
        imageView.document.setClippingMask(nil)
        imageView.document.setFaces([])
        status.resolution = .none
        status.loadingFullSize = false
        status.clipping = nil
        shownZoomRevision = model.loupeZoomRevision
        sharpPending = nil
    }

    // MARK: Showing a photo

    private func show(_ photo: PhotoItem) {
        let now = CACurrentMediaTime()
        if let position = model.order.position(of: photo.id), let previous = shownPosition, position != previous {
            direction = position > previous ? 1 : -1
        }
        shownPosition = model.order.position(of: photo.id)
        shownID = photo.id
        shownFileKey = Self.fileKey(photo)
        lastStepToFirstImageMs = nil
        screenTask?.cancel()
        screenTask = nil

        if photo.isUnreadable {
            showUnreadable(photo)
            store.want([])
            model.loupeShownID = photo.id
            sharpPending = nil
            return
        }
        hideUnreadable()

        let screen = model.previews.cached(photo.file)
        let thumbnail = screen == nil ? model.thumbnails.cachedThumbnail(for: photo.file) : nil
        let base = screen ?? thumbnail
        imageView.document.setFullImage(nil)
        imageView.document.setImage(base)
        imageView.setPixelSize(Self.fullPixelSize(photo, reference: base.map(Self.size) ?? store.fullImage(for: photo.id).map { CGSize(width: $0.width, height: $0.height) }), zoom: model.loupeZoom)
        status.resolution = screen.map { Self.isFullSize($0, photo) ? .full : .screen } ?? (thumbnail != nil ? .thumbnail : .none)
        if base != nil { lastStepToFirstImageMs = (CACurrentMediaTime() - now) * 1000 }
        sharpPending = ("step", now)

        if screen != nil {
            model.loupeShownID = photo.id
        } else {
            loadScreenImage(photo)
        }
        updateFullSizeNeed()
        checkSharp()
        prefetchNeighbours(of: photo)
    }

    private func loadScreenImage(_ photo: PhotoItem) {
        let id = photo.id
        let previews = model.previews
        screenTask = Task { [weak self] in
            let image = try? await previews.image(for: photo.file)
            guard let self, !Task.isCancelled, self.shownID == id else { return }
            if let image {
                self.imageView.document.setImage(image)
                if self.imageView.document.fullImage == nil {
                    self.status.resolution = Self.isFullSize(image, photo) ? .full : .screen
                }
                // The thumbnail may have had another shape (an embedded preview): use the real one.
                let size = Self.fullPixelSize(photo, reference: Self.size(image))
                if size != self.imageView.pixelSize { self.imageView.setPixelSize(size, zoom: self.imageView.zoom) }
                if self.lastStepToFirstImageMs == nil, let started = self.sharpPending?.startedAt {
                    self.lastStepToFirstImageMs = (CACurrentMediaTime() - started) * 1000
                }
            } else if self.imageView.document.image == nil,
                      let thumbnail = try? await self.model.thumbnails.thumbnail(for: photo.file), self.shownID == id {
                self.imageView.document.setImage(thumbnail)
                self.status.resolution = .thumbnail
            }
            self.model.loupeShownID = id
            self.screenTask = nil
            self.updateFullSizeNeed()
            self.updateOverlays(self.model.focusedPhoto)
            self.checkSharp()
        }
    }

    /// The photo's full size in pixels, upright: the long side from its metadata, the shape from
    /// a decoded image (which is upright, where the metadata's width and height may not be).
    static func size(_ image: CGImage) -> CGSize {
        CGSize(width: image.width, height: image.height)
    }

    static func fullPixelSize(_ photo: PhotoItem, reference: CGSize?) -> CGSize {
        // The metadata's size, turned to the decoded image's orientation when that differs.
        if let width = photo.metadata.pixelWidth, let height = photo.metadata.pixelHeight, width > 0, height > 0 {
            guard let reference, reference.width > 0, reference.height > 0,
                  (reference.width >= reference.height) != (width >= height), width != height
            else { return CGSize(width: width, height: height) }
            return CGSize(width: height, height: width)
        }
        let metadataLong = max(photo.metadata.pixelWidth ?? 0, photo.metadata.pixelHeight ?? 0)
        let referenceLong = reference.map { Int(max($0.width, $0.height)) } ?? 0
        let long = Double(max(metadataLong, referenceLong, 1))
        let aspect: Double
        if let reference, reference.height > 0 {
            aspect = Double(reference.width) / Double(reference.height)
        } else if let width = photo.metadata.pixelWidth, let height = photo.metadata.pixelHeight, height > 0 {
            aspect = Double(width) / Double(height)
        } else {
            aspect = 1.5
        }
        return aspect >= 1 ? CGSize(width: long, height: (long / aspect).rounded()) : CGSize(width: (long * aspect).rounded(), height: long)
    }

    /// True when a decoded image already holds every pixel of the photo.
    static func isFullSize(_ image: CGImage, _ photo: PhotoItem) -> Bool {
        let metadataLong = max(photo.metadata.pixelWidth ?? 0, photo.metadata.pixelHeight ?? 0)
        return max(image.width, image.height) >= metadataLong
    }

    private func prefetchNeighbours(of photo: PhotoItem) {
        let state = model.state
        let group = model.group
        var ids: [String] = []
        let ahead = direction > 0 ? state.next(after: photo.id, in: group) : state.previous(before: photo.id, in: group)
        let behind = direction > 0 ? state.previous(before: photo.id, in: group) : state.next(after: photo.id, in: group)
        if let ahead {
            ids.append(ahead)
            if let further = direction > 0 ? state.next(after: ahead, in: group) : state.previous(before: ahead, in: group) {
                ids.append(further)
            }
        }
        if let behind { ids.append(behind) }
        for id in ids {
            if let item = state.photo(id), !item.isUnreadable { model.previews.prefetch(item.file) }
        }
    }

    // MARK: Zoom

    private func userChangedZoom(_ zoom: LoupeZoom) {
        guard isActive, shownID != nil else { return }
        model.loupeViewChanged(zoom)
        zoomChanged(byCommand: false)
    }

    private func doubleClicked(at point: CullaCore.UnitPoint) {
        if imageView.zoom.isZoomed {
            model.setLoupeZoom(.fit)
        } else {
            // 100%, keeping the spot clicked under the pointer.
            model.setLoupeZoom(imageView.geometry.zoom(.fit, to: 1, keeping: point))
        }
    }

    private func zoomChanged(byCommand: Bool) {
        status.factor = imageView.factor
        status.isFit = !imageView.zoom.isZoomed
        if byCommand { sharpPending = ("zoom", CACurrentMediaTime()) }
        updateFullSizeNeed()
        checkSharp()
        layoutBadge()
    }

    /// Asks for the full-size image when the zoom needs it (and, while zoomed, for the next
    /// photo's), and lets it go when it does not.
    private func updateFullSizeNeed() {
        guard isActive, let photo = model.focusedPhoto, photo.id == shownID, !photo.isUnreadable else {
            store.want([])
            status.loadingFullSize = false
            return
        }
        let geometry = imageView.geometry
        let screenLong = model.previews.cached(photo.file).map { max($0.width, $0.height) } ?? model.previews.pixelSize
        let needs = geometry.needsLargerImage(factor: imageView.factor, availableLongSide: screenLong)
        guard needs else {
            store.want([])
            status.loadingFullSize = false
            // Back to the screen-size image alone, so the full-size one's memory is freed.
            if imageView.document.fullImage != nil {
                imageView.document.setFullImage(nil)
                if let image = imageView.document.image {
                    status.resolution = Self.isFullSize(image, photo) ? .full : .screen
                }
            }
            return
        }
        var wanted: [(id: String, file: PhotoFile)] = [(photo.id, photo.file)]
        let state = model.state
        let aheadID = direction > 0 ? state.next(after: photo.id, in: model.group) : state.previous(before: photo.id, in: model.group)
        if let aheadID, let ahead = state.photo(aheadID), !ahead.isUnreadable,
           max(ahead.metadata.pixelWidth ?? 0, ahead.metadata.pixelHeight ?? 0) > model.previews.pixelSize {
            wanted.append((ahead.id, ahead.file))
        }
        store.want(wanted)
        if let full = store.fullImage(for: photo.id) {
            showFull(full, photo)
        }
        status.loadingFullSize = store.fullImage(for: photo.id) == nil
    }

    private func fullImageArrived(_ id: String) {
        guard id == shownID, let photo = model.focusedPhoto, photo.id == id, let full = store.fullImage(for: id) else { return }
        let screenLong = model.previews.cached(photo.file).map { max($0.width, $0.height) } ?? model.previews.pixelSize
        guard imageView.geometry.needsLargerImage(factor: imageView.factor, availableLongSide: screenLong) else { return }
        showFull(full, photo)
        status.loadingFullSize = false
        checkSharp()
    }

    private func showFull(_ full: TiledImage, _ photo: PhotoItem) {
        guard imageView.document.fullImage?.tiles.first??.image !== full.tiles.first??.image else { return }
        let size = CGSize(width: full.width, height: full.height)
        if abs(size.width - imageView.pixelSize.width) > 0.5 || abs(size.height - imageView.pixelSize.height) > 0.5 {
            imageView.setPixelSize(size, zoom: imageView.zoom)
        }
        imageView.document.setFullImage(full)
        status.resolution = .full
    }

    /// Records how long the last zoom or step took to show a sharp image.
    private func checkSharp() {
        guard let pending = sharpPending, let photo = model.focusedPhoto, photo.id == shownID else { return }
        let screenLong = model.previews.cached(photo.file).map { max($0.width, $0.height) } ?? model.previews.pixelSize
        let needsFull = imageView.geometry.needsLargerImage(factor: imageView.factor, availableLongSide: screenLong)
        let sharp = status.resolution == .full || (status.resolution == .screen && !needsFull)
        guard sharp else { return }
        let ms = (CACurrentMediaTime() - pending.startedAt) * 1000
        if pending.kind == "zoom" { lastZoomToSharpMs = ms } else { lastStepToSharpMs = ms }
        sharpPending = nil
    }

    // MARK: Overlays

    private func updateOverlays(_ photo: PhotoItem?) {
        let timing = MainThreadTiming.begin("loupe.overlays")
        defer { timing.end() }
        guard let photo, !photo.isUnreadable else {
            imageView.document.setFaces([])
            imageView.document.setClippingMask(nil)
            status.clipping = nil
            return
        }
        let state = model.state
        // Face boxes.
        if model.showsFaceBoxes, let scores = photo.scores {
            let main = Set(state.summary(for: photo.id)?.mainFaces ?? [])
            let target = model.loupeTargetFace
            imageView.document.setFaces(scores.faces.enumerated().map { index, face in
                LoupeFaceBox(
                    box: face.box,
                    isMain: main.contains(index),
                    eyesClosed: LoupeTarget.eyesLookClosed(face, tuning: state.tuning) == true,
                    isTargeted: target == index && imageView.zoom.isZoomed
                )
            })
        } else {
            imageView.document.setFaces([])
        }
        // Clipping, measured on the screen-size image.
        if model.showsClipping, let source = model.previews.cached(photo.file) {
            let id = photo.id
            if let mask = store.clippingMask(for: source, ready: { [weak self] in
                guard let self, self.shownID == id else { return }
                self.updateOverlays(self.model.focusedPhoto)
            }) {
                imageView.document.setClippingMask(mask.image)
                status.clipping = (mask.highlights, mask.shadows)
            }
        } else {
            imageView.document.setClippingMask(nil)
            status.clipping = nil
        }
    }

    // MARK: Decision badge and unreadable files

    /// A kept or rejected photo carries the grid's badge in the top right corner of the view, so
    /// a rejected photo is marked without being dimmed.
    private func updateBadge(_ photo: PhotoItem?) {
        let kind: TileArtwork.Kind? = switch photo?.decision {
        case .kept where photo?.isUnreadable == false: .kept
        case .rejected where photo?.isUnreadable == false: .rejected
        default: nil
        }
        let scale = view.window?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let kind, let image = TileArtwork.image(kind, size: Self.badgeSize, scale: scale) {
            decisionBadge.contents = image
            decisionBadge.contentsScale = scale
            decisionBadgeView.isHidden = false
        } else {
            decisionBadgeView.isHidden = true
        }
        CATransaction.commit()
        layoutBadge()
        imageView.setAccessibilityLabel(photo.map { photo in
            let name = photo.file.name
            return switch photo.decision {
            case .unreviewed: localized("\(name), unreviewed")
            case .kept: localized("\(name), kept")
            case .rejected: localized("\(name), rejected")
            }
        })
    }

    static let badgeSize: CGFloat = 26

    private func layoutBadge() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // In the photo's top right corner, or the view's when the photo fills it.
        let photo = imageView.document.convert(imageView.document.bounds, to: imageArea)
        let bounds = photo.intersection(imageArea.bounds).isNull ? imageArea.bounds : photo.intersection(imageArea.bounds)
        decisionBadgeView.frame = CGRect(
            x: bounds.maxX - Self.badgeSize - 12, y: bounds.maxY - Self.badgeSize - 12,
            width: Self.badgeSize, height: Self.badgeSize
        )
        CATransaction.commit()
    }

    private func showUnreadable(_ photo: PhotoItem) {
        imageView.isHidden = true
        imageView.document.setImage(nil)
        status.resolution = .none
        if let unreadableHost {
            unreadableHost.rootView = UnreadablePhotoView(photo: photo)
            unreadableHost.isHidden = false
            return
        }
        let host = NSHostingView(rootView: UnreadablePhotoView(photo: photo))
        host.translatesAutoresizingMaskIntoConstraints = false
        imageArea.addSubview(host)
        NSLayoutConstraint.activate([
            host.centerXAnchor.constraint(equalTo: imageArea.centerXAnchor),
            host.centerYAnchor.constraint(equalTo: imageArea.centerYAnchor),
            host.widthAnchor.constraint(lessThanOrEqualTo: imageArea.widthAnchor),
        ])
        unreadableHost = host
    }

    private func hideUnreadable() {
        imageView.isHidden = false
        unreadableHost?.isHidden = true
    }

    // MARK: Automation

    /// True when nothing the loupe needs for the photo in view is still loading.
    var isSettled: Bool {
        guard isActive, let photo = model.focusedPhoto else { return true }
        if photo.isUnreadable { return true }
        return shownID == photo.id && screenTask == nil && !store.isBusy && !store.isMakingMask && (faceStrip.isHidden || !faceCrops.isBusy)
    }

    /// The loupe's state for the automation dump.
    func dumpState() -> [String: Any] {
        let geometry = imageView.geometry
        let rect = imageView.visibleUnitRect
        let pixels = imageView.pixelSize
        var state: [String: Any] = [
            "active": isActive,
            "shown": shownID ?? NSNull(),
            "zoomFactor": round3(imageView.factor),
            "zoomPercent": Int((imageView.factor * 100).rounded()),
            "fitFactor": round3(geometry.fitFactor),
            "isFit": !imageView.zoom.isZoomed,
            "resolution": status.resolution.rawValue,
            "fullImageInUse": imageView.document.fullImage != nil,
            "fullImagesHeld": store.heldIDs,
            "loadingFullSize": status.loadingFullSize,
            "pixelSize": [Int(pixels.width), Int(pixels.height)],
            "imageSize": imageView.document.fullImage.map { [$0.width, $0.height] } ?? imageView.document.image.map { [$0.width, $0.height] } ?? [],
            "screenImageSize": imageView.document.image.map { [$0.width, $0.height] } ?? [],
            "fullImageTiles": imageView.document.tileCount,
            "visibleRect": [round3(rect.x), round3(rect.y), round3(rect.width), round3(rect.height)],
            "visibleRectPixels": [Int(rect.x * pixels.width), Int(rect.y * pixels.height), Int(rect.width * pixels.width), Int(rect.height * pixels.height)],
            "visibleCentre": [round3(rect.x + rect.width / 2), round3(rect.y + rect.height / 2)],
            "decisionBadge": decisionBadgeView.isHidden ? NSNull() : [Int(decisionBadgeView.frame.minX), Int(decisionBadgeView.frame.minY)] as Any,
            "targetedFace": model.loupeTargetFace ?? NSNull(),
            "modelZoom": model.loupeZoom.factor.map { round3($0) } ?? "fit",
            "zoomRevision": model.loupeZoomRevision,
            "faceOrder": model.loupeFaceOrder,
            "faceBoxes": model.showsFaceBoxes,
            "clipping": model.showsClipping,
            // The filter of the image on top: the full-size tiles when shown, else the screen image.
            "magnificationFilter": imageView.document.fullImage != nil
                ? (imageView.factor >= 0.999 ? "nearest" : "linear")
                : imageView.document.imageLayer.magnificationFilter.rawValue,
            "filmstripVisible": filmstrip.visibleRange,
            "faceStripShown": !faceStrip.isHidden,
            "filmstripTilesWithoutImage": filmstrip.visibleTilesWithoutImage,
            "viewport": [Int(imageView.contentSize.width), Int(imageView.contentSize.height)],
            "backingScale": imageView.backingScale,
        ]
        if let clipping = status.clipping {
            state["clippingMeasured"] = ["highlights": round3(clipping.highlights), "shadows": round3(clipping.shadows)]
        }
        if let value = lastZoomToSharpMs { state["lastZoomToSharpMs"] = (value * 10).rounded() / 10 }
        if let value = lastStepToSharpMs { state["lastStepToSharpMs"] = (value * 10).rounded() / 10 }
        if let value = lastStepToFirstImageMs { state["lastStepToFirstImageMs"] = (value * 10).rounded() / 10 }
        return state
    }

    private func round3(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }
}
