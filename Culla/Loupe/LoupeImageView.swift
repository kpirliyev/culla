import AppKit
import CullaCommands
import CullaCore
import QuartzCore

/// The loupe's photo: an `NSScrollView` whose document is the photo at one document unit per
/// image pixel, so the scroll view's magnification is points per image pixel and a zoom factor
/// (device pixels per image pixel, see `LoupeZoom`) is `magnification × backingScale`.
///
/// Pinching zooms (the scroll view's own magnification), as does the scroll wheel with ⌘ or ⌥
/// held; two-finger scrolling and dragging pan. A double click asks the controller to zoom.
/// Every change the person makes is reported through `onZoomChange`; zooms set by commands
/// come in through `apply(_:)`.
@MainActor
final class LoupeImageView: NSScrollView {
    let document = LoupeDocumentView()
    /// The zoom the view shows, as the person or `apply(_:)` last left it.
    private(set) var zoom = LoupeZoom.fit
    /// The photo's full size in pixels, upright. The document's size.
    private(set) var pixelSize = CGSize(width: 3, height: 2)

    /// Called when the person zooms or pans.
    var onZoomChange: ((LoupeZoom) -> Void)?
    /// Called on a double click, with the point clicked in unit image coordinates.
    var onDoubleClick: ((UnitPoint) -> Void)?
    /// Called on any mouse down on the photo, before it is handled (a pane takes the focus).
    var onMouseDown: (() -> Void)?
    /// Called after the viewport changed size and the zoom was applied to it again.
    var onResize: (() -> Void)?

    private var isApplying = false
    private var dragStart: (point: NSPoint, origin: NSPoint)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        contentView = CenteringClipView()
        documentView = document
        allowsMagnification = true
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        scrollerKnobStyle = .light
        horizontalScrollElasticity = .none
        verticalScrollElasticity = .none
        drawsBackground = false
        contentView.drawsBackground = false
        usesPredominantAxisScrolling = false
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(boundsChanged(_:)), name: NSView.boundsDidChangeNotification, object: contentView
        )
        document.onMouseDown = { [weak self] event in self?.documentMouseDown(event) }
        document.onMouseDragged = { [weak self] event in self?.documentMouseDragged(event) }
        document.onMouseUp = { [weak self] _ in self?.dragStart = nil }
        setAccessibilityLabel(localized("a11y.photo", default: "Photo"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var backingScale: Double { Double(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2) }

    /// The arithmetic for the photo in the viewport as it is now.
    var geometry: LoupeGeometry {
        LoupeGeometry(
            imageWidth: pixelSize.width, imageHeight: pixelSize.height,
            viewportWidth: contentSize.width, viewportHeight: contentSize.height,
            backingScale: backingScale,
            fitMargin: Self.fitMargin
        )
    }

    /// Room around the photo at fit, so it does not touch the header or the filmstrip.
    static let fitMargin = 14.0

    /// The zoom factor shown now.
    var factor: Double { Double(magnification) * backingScale }

    /// The visible part of the photo in unit image coordinates.
    var visibleUnitRect: UnitRect {
        let visible = contentView.documentVisibleRect.intersection(document.bounds)
        guard pixelSize.width > 0, pixelSize.height > 0 else { return .full }
        return UnitRect(
            x: visible.minX / pixelSize.width, y: visible.minY / pixelSize.height,
            width: visible.width / pixelSize.width, height: visible.height / pixelSize.height
        )
    }

    // MARK: Showing

    /// Sets the photo's size (a new photo, or a better guess at its shape) and applies a zoom.
    func setPixelSize(_ size: CGSize, zoom: LoupeZoom) {
        let size = CGSize(width: max(1, size.width.rounded()), height: max(1, size.height.rounded()))
        if size != pixelSize {
            pixelSize = size
            document.frame = CGRect(origin: .zero, size: size)
        }
        apply(zoom)
    }

    /// Shows a zoom: fit, or a factor and centre, made valid for this photo and viewport.
    func apply(_ requested: LoupeZoom) {
        let geometry = geometry
        let normal = geometry.normalized(requested)
        let factor = geometry.factor(of: normal)
        let scale = backingScale
        isApplying = true
        defer { isApplying = false }
        minMagnification = CGFloat(geometry.factorRange.lowerBound / scale)
        maxMagnification = CGFloat(geometry.factorRange.upperBound / scale)
        magnification = CGFloat(factor / scale)
        let visible = contentView.bounds.size
        let centre = normal.centre ?? UnitPoint(x: 0.5, y: 0.5)
        var origin = NSPoint(
            x: centre.x * pixelSize.width - visible.width / 2,
            y: centre.y * pixelSize.height - visible.height / 2
        )
        // Whole device pixels, so at 100% each image pixel lands on one display pixel.
        origin.x = (origin.x * factor).rounded() / factor
        origin.y = (origin.y * factor).rounded() / factor
        contentView.scroll(to: contentView.constrainBoundsRect(NSRect(origin: origin, size: visible)).origin)
        reflectScrolledClipView(contentView)
        zoom = normal
        lastApplied = normal
        zoomDidChange()
    }

    /// The zoom `apply(_:)` last set.
    private(set) var lastApplied = LoupeZoom.fit

    private var tiledSize = NSSize.zero

    /// Lays out the clip view after any change of size. A resize moves the clip view's bounds,
    /// which is not the person zooming; afterwards fit stays fit and a zoom keeps its factor and
    /// centre.
    override func tile() {
        isApplying = true
        super.tile()
        isApplying = false
        guard window != nil, contentSize != tiledSize else { return }
        tiledSize = contentSize
        apply(zoom)
        onResize?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { apply(zoom) }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        apply(zoom)
    }

    @objc private func boundsChanged(_ notification: Notification) {
        guard !isApplying else { return }
        let geometry = geometry
        let factor = factor
        let current: LoupeZoom
        // Within 2% of fit is fit: no one zooms that little on purpose.
        if geometry.isFit(factor, tolerance: 0.02) || factor < geometry.factorRange.lowerBound {
            current = .fit
        } else {
            let rect = visibleUnitRect
            current = .zoomed(factor: factor, centre: UnitPoint(x: rect.x + rect.width / 2, y: rect.y + rect.height / 2))
        }
        zoom = current
        zoomDidChange()
        onZoomChange?(current)
    }

    private func zoomDidChange() {
        let factor = factor
        document.setScale(pointsPerPixel: Double(magnification), factor: factor)
        document.setVisibleRect(contentView.documentVisibleRect)
        documentCursor = zoom.isZoomed ? .openHand : nil
    }

    // MARK: Zooming and panning with the mouse

    override func scrollWheel(with event: NSEvent) {
        let flags = event.modifierFlags
        guard flags.contains(.command) || flags.contains(.option) else {
            super.scrollWheel(with: event)
            return
        }
        // A smooth zoom about the pointer: a notch of a wheel is about 12%, a trackpad follows
        // the fingers.
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.01 : event.scrollingDeltaY * 0.12
        guard delta != 0 else { return }
        // An event made without a window carries its location in screen coordinates.
        var location = event.locationInWindow
        if event.window == nil, let window { location = window.convertPoint(fromScreen: location) }
        let point = document.convert(location, from: nil)
        let target = min(max(magnification * CGFloat(exp(delta)), minMagnification), maxMagnification)
        setMagnification(target, centeredAt: point)
    }

    private func documentMouseDown(_ event: NSEvent) {
        onMouseDown?()
        if event.clickCount == 2 {
            let point = document.convert(event.locationInWindow, from: nil)
            onDoubleClick?(UnitPoint(x: point.x / pixelSize.width, y: point.y / pixelSize.height))
            return
        }
        guard zoom.isZoomed else { return }
        dragStart = (event.locationInWindow, contentView.bounds.origin)
        NSCursor.closedHand.set()
    }

    private func documentMouseDragged(_ event: NSEvent) {
        guard let start = dragStart else { return }
        let scale = max(magnification, 0.0001)
        let dx = (event.locationInWindow.x - start.point.x) / scale
        let dy = (event.locationInWindow.y - start.point.y) / scale
        // The document is flipped: dragging up shows what is below.
        let origin = NSPoint(x: start.origin.x - dx, y: start.origin.y + dy)
        contentView.scroll(to: contentView.constrainBoundsRect(NSRect(origin: origin, size: contentView.bounds.size)).origin)
        reflectScrolledClipView(contentView)
    }
}

/// Keeps a document smaller than the viewport in its middle.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        let size = document.frame.size
        if rect.width > size.width {
            rect.origin.x = (size.width - rect.width) / 2
        }
        if rect.height > size.height {
            rect.origin.y = (size.height - rect.height) / 2
        }
        return rect
    }
}

/// The photo at one unit per image pixel, with its overlays above it in the same coordinates:
/// the clipping overlay and the face boxes. Flipped, so y runs down as in unit image coordinates.
@MainActor
final class LoupeDocumentView: NSView {
    let imageLayer = CALayer()
    /// The full-size image, in tiles above `imageLayer`; see `setFullImage(_:)`.
    let tilesLayer = CALayer()
    let clippingLayer = CALayer()
    let facesLayer = CALayer()
    private var faceLayers: [CALayer] = []
    private(set) var fullImage: TiledImage?
    private var tiles: [Int: CALayer] = [:]
    private var shownRect = CGRect.zero
    /// Tiles of the full-size image, in image pixels.
    nonisolated static let tileSize = 1024
    private var faces: [LoupeFaceBox] = []
    private var pointsPerPixel = 1.0
    private var factor = 1.0
    private(set) var image: CGImage?

    var onMouseDown: ((NSEvent) -> Void)?
    var onMouseDragged: ((NSEvent) -> Void)?
    var onMouseUp: ((NSEvent) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        for sublayer in [imageLayer, tilesLayer, clippingLayer, facesLayer] {
            sublayer.actions = Self.noActions
            layer?.addSublayer(sublayer)
        }
        imageLayer.contentsGravity = .resize
        clippingLayer.contentsGravity = .resize
        clippingLayer.magnificationFilter = .nearest
        clippingLayer.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    static let noActions: [String: any CAAction] = [
        "contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "frame": NSNull(), "hidden": NSNull(),
        "borderWidth": NSNull(), "borderColor": NSNull(), "opacity": NSNull(), "cornerRadius": NSNull(),
        "magnificationFilter": NSNull(), "minificationFilter": NSNull(), "sublayers": NSNull(),
    ]

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for sublayer in [imageLayer, tilesLayer, clippingLayer, facesLayer] { sublayer.frame = bounds }
        layoutTiles()
        layoutFaces()
        CATransaction.commit()
    }

    /// Shows the full-size image over the screen-size one, in tiles of 1,024 pixels made ready
    /// for Core Animation off the main thread (`DisplayImage`).
    ///
    /// Only the tiles where the view shows, and half a view around it, are handed to Core
    /// Animation, which copies each one it is given: a step to the next photo at 100% hands over
    /// about a tenth of a 24 MP photo, and panning adds tiles as they come near. The screen-size
    /// image underneath fills in until they do.
    func setFullImage(_ image: TiledImage?) {
        if image == nil, fullImage == nil { return }
        fullImage = image
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in tiles.values { layer.removeFromSuperlayer() }
        tiles = [:]
        tilesLayer.isHidden = image == nil
        layoutTiles()
        CATransaction.commit()
        updateFilters()
    }

    /// The part of the document on screen, so the tiles there are drawn.
    func setVisibleRect(_ rect: CGRect) {
        shownRect = rect
        // Hidden tiles are not laid out: at fit they would all be handed to Core Animation.
        guard fullImage != nil, !tilesLayer.isHidden else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutTiles()
        CATransaction.commit()
    }

    /// Shows the full-size image's tiles again after they were hidden, laying out those in view.
    func showTiles() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tilesLayer.isHidden = false
        layoutTiles()
        CATransaction.commit()
    }

    /// Number of tiles of the full-size image handed to Core Animation, for the automation dump.
    var tileCount: Int { tiles.count }

    /// Number of face boxes drawn, for the automation dump.
    var faceCount: Int { faces.count }

    private func layoutTiles() {
        guard let image = fullImage, bounds.width > 0, bounds.height > 0 else { return }
        let scaleX = bounds.width / CGFloat(image.width)
        let scaleY = bounds.height / CGFloat(image.height)
        // What shows, and half a view around it, in image pixels.
        let wanted = shownRect.insetBy(dx: -shownRect.width / 2, dy: -shownRect.height / 2)
        let wantedPixels = CGRect(x: wanted.minX / scaleX, y: wanted.minY / scaleY, width: wanted.width / scaleX, height: wanted.height / scaleY)
        let crisp = factor >= 0.999
        for (key, tile) in image.tiles.enumerated() {
            guard let tile else { continue }
            let frame = CGRect(x: tile.rect.minX * scaleX, y: tile.rect.minY * scaleY, width: tile.rect.width * scaleX, height: tile.rect.height * scaleY)
            if let layer = tiles[key] {
                layer.frame = frame
                continue
            }
            guard tile.rect.intersects(wantedPixels) else { continue }
            let layer = CALayer()
            layer.actions = Self.noActions
            layer.contentsGravity = .resize
            layer.contents = tile.image
            layer.magnificationFilter = crisp ? .nearest : .linear
            layer.minificationFilter = .linear
            layer.frame = frame
            tilesLayer.addSublayer(layer)
            tiles[key] = layer
        }
    }

    /// Shows an image filling the document: the screen-size image, or the thumbnail while it
    /// loads.
    func setImage(_ image: CGImage?) {
        guard image !== self.image else { return }
        self.image = image
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = image
        CATransaction.commit()
        updateFilters()
    }

    func setClippingMask(_ mask: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clippingLayer.contents = mask
        clippingLayer.isHidden = mask == nil
        CATransaction.commit()
    }

    func setFaces(_ faces: [LoupeFaceBox]) {
        guard faces != self.faces else { return }
        self.faces = faces
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        while faceLayers.count < faces.count {
            let layer = CALayer()
            layer.actions = Self.noActions
            facesLayer.addSublayer(layer)
            faceLayers.append(layer)
        }
        for (index, layer) in faceLayers.enumerated() { layer.isHidden = index >= faces.count }
        layoutFaces()
        CATransaction.commit()
    }

    /// The scroll view's magnification changed: face lines keep their width on screen, and the
    /// photo is drawn pixel for pixel from 100% on.
    func setScale(pointsPerPixel: Double, factor: Double) {
        guard pointsPerPixel != self.pointsPerPixel || factor != self.factor else { return }
        self.pointsPerPixel = max(pointsPerPixel, 0.0001)
        self.factor = factor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateFilters()
        layoutFaces()
        CATransaction.commit()
    }

    private func updateFilters() {
        // The image's pixels against the display pixels it covers.
        let drawnSmaller = Double(image?.width ?? 0) > Double(bounds.width) * factor * 1.02
        // From 100% on, the full-size image shows each pixel as a crisp square, as other photo
        // editors do. A smaller stand-in waiting for it is smoothed instead.
        let isFullSize = Double(image?.width ?? 0) >= Double(bounds.width) * 0.99
        let crisp = factor >= 0.999
        imageLayer.magnificationFilter = isFullSize && crisp ? .nearest : .linear
        imageLayer.minificationFilter = drawnSmaller ? .trilinear : .linear
        for layer in tiles.values { layer.magnificationFilter = crisp ? .nearest : .linear }
    }

    private func layoutFaces() {
        let size = bounds.size
        let unit = 1 / pointsPerPixel
        for (index, face) in faces.enumerated() where index < faceLayers.count {
            let layer = faceLayers[index]
            let box = face.box
            layer.frame = CGRect(x: box.x * size.width, y: box.y * size.height, width: box.width * size.width, height: box.height * size.height)
            let width: Double = face.isMain ? (face.isTargeted ? 3 : 2) : 1
            layer.borderWidth = CGFloat(width * unit)
            layer.cornerRadius = CGFloat(4 * unit)
            layer.borderColor = face.color.cgColor
            // Closed eyes are marked by more than colour: an eye-slash badge on the box's corner.
            let badge = layer.sublayers?.first ?? {
                let badge = CALayer()
                badge.actions = Self.noActions
                badge.contentsGravity = .resize
                layer.addSublayer(badge)
                return badge
            }()
            let scale = window?.backingScaleFactor ?? 2
            if face.eyesClosed, face.isMain, let image = TileArtwork.image(.reason(symbol: "eye.slash", certain: true), size: 18, scale: scale) {
                let side = CGFloat(18 * unit)
                badge.isHidden = false
                badge.contents = image
                badge.contentsScale = scale
                badge.frame = CGRect(x: -side / 2, y: -side / 2, width: side, height: side)
            } else {
                badge.isHidden = true
            }
            // A dark hairline outside keeps a light outline readable on a bright face.
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = face.isMain ? 0.6 : 0
            layer.shadowRadius = CGFloat(1.5 * unit)
            layer.shadowOffset = .zero
        }
    }

    override func mouseDown(with event: NSEvent) { onMouseDown?(event) }
    override func mouseDragged(with event: NSEvent) { onMouseDragged?(event) }
    override func mouseUp(with event: NSEvent) { onMouseUp?(event) }
}

/// One face box the loupe draws.
struct LoupeFaceBox: Equatable {
    var box: UnitRect
    var isMain: Bool
    var eyesClosed: Bool
    var isTargeted: Bool

    /// Amber when the eyes look closed, a light neutral otherwise; faint for faces that are not
    /// main faces, which never flag a photo.
    var color: NSColor {
        let base = eyesClosed ? Palette.flagged : NSColor(white: 0.95, alpha: 1)
        return base.withAlphaComponent(isMain ? 0.95 : 0.4)
    }
}
