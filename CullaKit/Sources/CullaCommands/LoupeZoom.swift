import CullaAnalysis
import CullaCore
import CullaSession

/// How the loupe shows its photo: fitted to the view, or zoomed.
///
/// A zoom is held as a `factor` and a `centre`, both independent of the window, the photo's size
/// and the screen, so the same zoom can be applied to the next photo of a burst ("sticky zoom"):
///
/// - `factor` is device pixels per image pixel. 1 is 100%: one pixel of the photo on one pixel
///   of the display, which on a Retina display is half a point. 0.5 shows the photo at half that
///   size, 4 at 400%.
/// - `centre` is the middle of the visible part of the photo in unit image coordinates (0...1,
///   origin at the top-left corner), so it means the same spot on any frame of a burst.
public enum LoupeZoom: Sendable, Hashable {
    case fit
    case zoomed(factor: Double, centre: UnitPoint)

    public var isZoomed: Bool {
        if case .zoomed = self { return true }
        return false
    }

    public var factor: Double? {
        if case .zoomed(let factor, _) = self { return factor }
        return nil
    }

    public var centre: UnitPoint? {
        if case .zoomed(_, let centre) = self { return centre }
        return nil
    }
}

/// The arithmetic of the loupe for one photo in one viewport: the fit factor, the zoom range, what
/// is visible, and zooming about a point. Pure, so it is tested without a window.
public struct LoupeGeometry: Sendable, Hashable {
    /// The photo's size in pixels, upright.
    public var imageWidth: Double
    public var imageHeight: Double
    /// The viewport's size in points.
    public var viewportWidth: Double
    public var viewportHeight: Double
    /// Device pixels per point: 2 on a Retina display.
    public var backingScale: Double
    /// Room left around the photo at fit, in points, so it does not touch the loupe's edges.
    public var fitMargin: Double

    /// The most the loupe zooms in: 400%.
    public static let maximumFactor = 4.0
    /// Fit never enlarges a photo beyond one image pixel per point, so a small file is not shown
    /// softer than it is.
    public static let maximumFitPointsPerPixel = 1.0

    public init(imageWidth: Double, imageHeight: Double, viewportWidth: Double, viewportHeight: Double, backingScale: Double, fitMargin: Double = 0) {
        self.fitMargin = max(0, fitMargin)
        self.imageWidth = max(1, imageWidth)
        self.imageHeight = max(1, imageHeight)
        self.viewportWidth = max(1, viewportWidth)
        self.viewportHeight = max(1, viewportHeight)
        self.backingScale = max(1, backingScale)
    }

    /// The factor at which the whole photo fits the viewport.
    public var fitFactor: Double {
        let width = max(1, viewportWidth - 2 * fitMargin)
        let height = max(1, viewportHeight - 2 * fitMargin)
        let pointsPerPixel = min(width / imageWidth, height / imageHeight, Self.maximumFitPointsPerPixel)
        return pointsPerPixel * backingScale
    }

    /// The smallest and largest factor the loupe allows: from fit to 400%. A small photo that
    /// fit enlarges can also be shown at 100%, its real size, so 100% means the same on every
    /// frame of a shoot.
    public var factorRange: ClosedRange<Double> {
        let fit = fitFactor
        return min(fit, 1)...max(fit, Self.maximumFactor)
    }

    /// True when a factor is fit, give or take `tolerance` (a share of the fit factor).
    public func isFit(_ factor: Double, tolerance: Double = 0.0001) -> Bool {
        abs(factor - fitFactor) <= fitFactor * tolerance
    }

    public func clampedFactor(_ factor: Double) -> Double {
        min(max(factor, factorRange.lowerBound), factorRange.upperBound)
    }

    /// Points on screen per image pixel at a factor: the scroll view's magnification when one
    /// document unit is one image pixel.
    public func pointsPerPixel(factor: Double) -> Double {
        factor / backingScale
    }

    /// The factor of a zoom, fit included.
    public func factor(of zoom: LoupeZoom) -> Double {
        switch zoom {
        case .fit: fitFactor
        case .zoomed(let factor, _): clampedFactor(factor)
        }
    }

    /// The share of the photo's width and height the viewport shows at a factor (at most 1).
    public func visibleFraction(factor: Double) -> (width: Double, height: Double) {
        let points = pointsPerPixel(factor: factor)
        return (min(1, viewportWidth / (imageWidth * points)), min(1, viewportHeight / (imageHeight * points)))
    }

    /// Moves a centre just enough that the visible part stays inside the photo. On an axis where
    /// the whole photo is visible the centre is the middle.
    public func clampedCentre(_ centre: UnitPoint, factor: Double) -> UnitPoint {
        let visible = visibleFraction(factor: factor)
        func clamp(_ value: Double, _ fraction: Double) -> Double {
            guard fraction < 1 else { return 0.5 }
            return min(max(value, fraction / 2), 1 - fraction / 2)
        }
        return UnitPoint(x: clamp(centre.x, visible.width), y: clamp(centre.y, visible.height))
    }

    /// A zoom made valid for this photo and viewport: factor within range, centre inside. A zoom
    /// at the fit factor becomes fit.
    public func normalized(_ zoom: LoupeZoom) -> LoupeZoom {
        guard case .zoomed(let factor, let centre) = zoom else { return .fit }
        let clamped = clampedFactor(factor)
        if isFit(clamped) { return .fit }
        return .zoomed(factor: clamped, centre: clampedCentre(centre, factor: clamped))
    }

    /// The visible part of the photo, in unit image coordinates.
    public func visibleRect(_ zoom: LoupeZoom) -> UnitRect {
        let normal = normalized(zoom)
        let factor = factor(of: normal)
        let visible = visibleFraction(factor: factor)
        let centre = normal.centre ?? UnitPoint(x: 0.5, y: 0.5)
        return UnitRect(x: centre.x - visible.width / 2, y: centre.y - visible.height / 2, width: visible.width, height: visible.height)
    }

    /// Zooms to a new factor keeping the spot at `anchor` (unit image coordinates) where it is on
    /// screen, as pinching and the scroll wheel do.
    public func zoom(_ zoom: LoupeZoom, to newFactor: Double, keeping anchor: UnitPoint) -> LoupeZoom {
        let oldFactor = factor(of: zoom)
        let target = clampedFactor(newFactor)
        let oldCentre = normalized(zoom).centre ?? UnitPoint(x: 0.5, y: 0.5)
        let ratio = oldFactor / target
        let centre = UnitPoint(
            x: anchor.x + (oldCentre.x - anchor.x) * ratio,
            y: anchor.y + (oldCentre.y - anchor.y) * ratio
        )
        return normalized(.zoomed(factor: target, centre: centre))
    }

    /// True when a factor shows more detail than an image of `availableLongSide` pixels holds, so
    /// the full-size image is needed to be sharp. A 4% margin keeps rounding from asking for it.
    public func needsLargerImage(factor: Double, availableLongSide: Int) -> Bool {
        let fullLongSide = max(imageWidth, imageHeight)
        guard Double(availableLongSide) < fullLongSide else { return false }
        return factor > Double(availableLongSide) / fullLongSide * 1.04
    }
}

/// Where the loupe zooms and which faces it steps through, from a photo's scores.
public enum LoupeTarget {
    /// The spot Z zooms to, and the face it targets if any:
    /// - in Eyes Closed, the eyes of the face with the most closed eyes;
    /// - otherwise the summary's focus point (the sharpest spot of the subject), and the main face
    ///   it falls in, if any;
    /// - with no scores, the middle of the photo.
    public static func zoomTarget(scores: PhotoScores?, summary: PhotoSummary?, group: GroupID) -> (point: UnitPoint, face: Int?) {
        guard let scores, let summary else { return (UnitPoint(x: 0.5, y: 0.5), nil) }
        if group == .eyesClosed, let worst = summary.worstEyesFace, scores.faces.indices.contains(worst) {
            return (eyePoint(of: scores.faces[worst]), worst)
        }
        let point = summary.focusPoint
        let face = summary.mainFaces.first { index in
            guard scores.faces.indices.contains(index) else { return false }
            let box = scores.faces[index].box
            return point.x >= box.x && point.x <= box.maxX && point.y >= box.y && point.y <= box.maxY
        }
        return (point, face)
    }

    /// Where a face's eyes are: across the middle of the box, about 40% of the way down.
    public static func eyePoint(of face: FaceScores) -> UnitPoint {
        UnitPoint(x: face.box.x + face.box.width / 2, y: face.box.y + face.box.height * 0.4)
    }

    /// The main faces in reading order: left to right, and top to bottom where they overlap
    /// horizontally. Tab steps through them in this order.
    public static func faceOrder(scores: PhotoScores?, summary: PhotoSummary?) -> [Int] {
        guard let scores, let summary else { return [] }
        let faces = summary.mainFaces.filter { scores.faces.indices.contains($0) }
        return faces.sorted { a, b in
            let boxA = scores.faces[a].box
            let boxB = scores.faces[b].box
            if abs(boxA.center.x - boxB.center.x) > min(boxA.width, boxB.width) / 2 {
                return boxA.center.x < boxB.center.x
            }
            return boxA.center.y < boxB.center.y
        }
    }

    /// The face after (or before) `current` in `order`, wrapping round. With no current face, the
    /// first (or last). Nil when there are no faces.
    public static func step(from current: Int?, in order: [Int], forward: Bool) -> Int? {
        guard !order.isEmpty else { return nil }
        guard let current, let position = order.firstIndex(of: current) else {
            return forward ? order.first : order.last
        }
        let next = (position + (forward ? 1 : order.count - 1)) % order.count
        return order[next]
    }

    /// True when the face's eyes look closed under the tuning (openness below
    /// `Tuning.eyesClosedBelow`); nil when its eyes were not measured.
    public static func eyesLookClosed(_ face: FaceScores, tuning: Tuning) -> Bool? {
        face.eyeOpenness(countWinkAsClosed: tuning.countWinkAsClosed).map { $0 < tuning.eyesClosedBelow }
    }
}

/// Which overlays the loupe draws over the photo. Face boxes show in Eyes Closed and the
/// clipping overlay in Exposure, unless toggled; a toggle lasts until another group is opened.
public struct LoupeOverlays: Sendable, Hashable {
    public var faceBoxesOverride: Bool?
    public var clippingOverride: Bool?

    public init(faceBoxesOverride: Bool? = nil, clippingOverride: Bool? = nil) {
        self.faceBoxesOverride = faceBoxesOverride
        self.clippingOverride = clippingOverride
    }

    public func showsFaceBoxes(in group: GroupID) -> Bool {
        faceBoxesOverride ?? (group == .eyesClosed)
    }

    public func showsClipping(in group: GroupID) -> Bool {
        clippingOverride ?? (group == .exposure)
    }

    public mutating func toggleFaceBoxes(in group: GroupID) {
        faceBoxesOverride = !showsFaceBoxes(in: group)
    }

    public mutating func toggleClipping(in group: GroupID) {
        clippingOverride = !showsClipping(in: group)
    }

    /// Opening another group goes back to that group's defaults.
    public mutating func groupChanged() {
        faceBoxesOverride = nil
        clippingOverride = nil
    }
}
