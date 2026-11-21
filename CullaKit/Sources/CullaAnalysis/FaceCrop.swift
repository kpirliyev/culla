import CoreGraphics
import Foundation

/// A face cut out of the analysed image for a second landmarks pass, and the way back from the
/// cut-out's pixels to the image's.
///
/// Vision's face landmarks (revision 4, the default since macOS 15) come back degenerate for a
/// face whose box is less than about 9 % of the image's height: every point of every region
/// collapses onto one spot, so no eye can be measured. That limit is relative, not a pixel
/// count. Measured on a 108-photo shoot, the same faces fail when the image is decoded at
/// 1024 px and at 6016 px, while a cut-out in which the face is a fifth of the height gives
/// landmarks for faces only 32 px tall. So faces that come back without eyes are cut out with
/// room around them and measured again.
public struct FaceCrop: Sendable, Hashable {
    /// The part of the analysed image that is cut, in whole pixels, origin at the top-left.
    public let source: CGRect
    /// Size of the cut-out handed to Vision. Smaller than `source` when the face is scaled down.
    public let width: Int
    public let height: Int
    /// The face box inside the cut-out, normalised with the origin at the bottom-left, the way
    /// Vision expects a face observation it is given.
    public let faceInCrop: CGRect

    /// Room left on each side of the face, as a share of the face's size. With 2 the cut-out is
    /// five face sizes tall, so the face is a fifth of it, well above Vision's limit even where
    /// the image edge clips the cut-out. More room gives eye readings closer to those Vision
    /// gives on the whole image, which the eye threshold was chosen from.
    public static let paddings: [Double] = [2, 3, 1]
    /// Faces taller than this are scaled down to it, which keeps the cut-out small without
    /// changing the readings: at 256 px they agree with full-size cut-outs to about 0.01.
    public static let maxFaceHeight = 256.0

    /// Faces smaller than this share of the image's short side get no second pass. It sits
    /// below the default smallest checked face (`Tuning.minFaceFraction`, 0.04), so lowering
    /// that setting a little still finds readings, and above sizes where no face is judged.
    public static let minimumFaceFraction = 0.03
    /// Nor do faces under this many pixels tall: the eye is then a few pixels wide, and readings
    /// from faces scaled down to 32 px stray up to 0.14 from full-size ones.
    public static let minimumFacePixels = 48.0

    /// - Parameters:
    ///   - face: the face box in the analysed image's pixels, origin at the top-left.
    ///   - padding: room on each side, as a share of the face's width and height.
    public init?(face: CGRect, imageWidth: Int, imageHeight: Int, padding: Double, maxFaceHeight: Double = FaceCrop.maxFaceHeight) {
        guard face.width > 0, face.height > 0, imageWidth > 0, imageHeight > 0 else { return nil }
        let padded = face.insetBy(dx: -face.width * padding, dy: -face.height * padding)
        let bounds = CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight)
        let clipped = padded.integral.intersection(bounds)
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else { return nil }

        let scale = min(1, maxFaceHeight / Double(face.height))
        source = clipped
        width = max(1, Int((Double(clipped.width) * scale).rounded()))
        height = max(1, Int((Double(clipped.height) * scale).rounded()))
        faceInCrop = CGRect(
            x: (face.minX - clipped.minX) / clipped.width,
            y: (clipped.maxY - face.maxY) / clipped.height,
            width: face.width / clipped.width,
            height: face.height / clipped.height
        )
    }

    /// True when the cut-out is scaled rather than cut at the image's own pixels.
    public var isScaled: Bool { width != Int(source.width) || height != Int(source.height) }

    /// Maps a point in the cut-out's pixels (origin at the top-left) to the analysed image's
    /// pixels. Each axis uses its own factor, so rounding the cut-out's size never stretches the
    /// result: points come back in the image's square pixels.
    public func imagePoint(fromCrop point: CGPoint) -> CGPoint {
        CGPoint(
            x: source.minX + point.x * source.width / Double(width),
            y: source.minY + point.y * source.height / Double(height)
        )
    }

    /// Whether a face should be measured again on a cut-out: an eye has no reading and the face
    /// is large enough for a reading to mean something.
    public static func needsSecondPass(
        leftOpenness: Double?,
        rightOpenness: Double?,
        faceHeight: Double,
        imageShortSide: Int
    ) -> Bool {
        guard leftOpenness == nil || rightOpenness == nil, imageShortSide > 0 else { return false }
        return faceHeight >= minimumFacePixels
            && faceHeight / Double(imageShortSide) >= minimumFaceFraction
    }
}
