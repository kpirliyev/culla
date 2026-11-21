import CoreGraphics
import CullaAnalysis
import CullaCore
import CullaFiles

/// Where the thumbnail and the two crops of a photo are cut, and at what size they are saved and
/// shown. The image writer and the contact sheets both read this, so a page always knows the
/// exact size of a file it shows, before it loads, and for scores reused from an earlier run.
///
/// Everything is derived from the stored scores alone (the analysed size, the faces and the
/// summary), never from the decoded image.
struct Previews {
    struct Size: Equatable {
        var width: Int
        var height: Int
    }

    /// One saved image: the part of the analysed image it shows, and its size on disk.
    struct Cut: Equatable {
        var source: CGRect
        var file: Size
    }

    /// Long side of a saved thumbnail and of a saved face crop.
    static let thumbnailPixels = 360
    /// Side of the focus crop, cut at one image pixel per crop pixel.
    static let focusPixels = 320
    /// Height thumbnails and face crops are shown at on the sheets.
    static let displayHeight = 180

    let analysedWidth: Int
    let analysedHeight: Int
    let thumbnail: Size
    /// Nil when there is no main face with an eye reading.
    let face: Cut?
    /// Nil only for an image with no pixels.
    let focus: Cut?

    init(scores: PhotoScores, summary: PhotoSummary) {
        let width = scores.analysedWidth
        let height = scores.analysedHeight
        analysedWidth = width
        analysedHeight = height
        let thumb = ImageLoader.scaledSize(width: width, height: height, maxPixelSize: Self.thumbnailPixels)
        thumbnail = Size(width: thumb.width, height: thumb.height)

        // The face with the most closed eyes, with some room around it, scaled down like a thumbnail.
        if let worst = summary.worstEyesFace, scores.faces.indices.contains(worst) {
            let box = scores.faces[worst].box.inset(byFraction: -0.3).clamped()
            let rect = box.pixelRect(imageWidth: width, imageHeight: height)
            face = ImageLoader.cropRect(rect, imageWidth: width, imageHeight: height).map { source in
                let size = ImageLoader.scaledSize(
                    width: Int(source.width), height: Int(source.height), maxPixelSize: Self.thumbnailPixels
                )
                return Cut(source: source, file: Size(width: size.width, height: size.height))
            }
        } else {
            face = nil
        }

        // The sharpest spot of the judged region at one image pixel per crop pixel, because
        // softness cannot be seen in a thumbnail. The origin is a whole pixel, so the crop is the
        // full side rather than one pixel wider where the rectangle would be widened to pixels.
        let side = Double(Self.focusPixels)
        let w = Double(width)
        let h = Double(height)
        let originX = min(max(summary.focusPoint.x * w - side / 2, 0), max(0, w - side)).rounded(.down)
        let originY = min(max(summary.focusPoint.y * h - side / 2, 0), max(0, h - side)).rounded(.down)
        let rect = CGRect(x: originX, y: originY, width: min(side, w), height: min(side, h))
        focus = ImageLoader.cropRect(rect, imageWidth: width, imageHeight: height).map { source in
            Cut(source: source, file: Size(width: Int(source.width), height: Int(source.height)))
        }
    }

    /// The size a thumbnail or face crop is shown at: `displayHeight` tall so a row of tiles lines
    /// up, except that a panorama is held to `thumbnailPixels` wide and gets shorter instead.
    static func display(_ file: Size) -> Size {
        guard file.width > 0, file.height > 0 else { return Size(width: 1, height: 1) }
        let aspect = Double(file.width) / Double(file.height)
        let widthAtDisplayHeight = Int((Double(displayHeight) * aspect).rounded())
        if widthAtDisplayHeight <= thumbnailPixels {
            return Size(width: max(1, widthAtDisplayHeight), height: displayHeight)
        }
        return Size(width: thumbnailPixels, height: max(1, Int((Double(thumbnailPixels) / aspect).rounded())))
    }
}
