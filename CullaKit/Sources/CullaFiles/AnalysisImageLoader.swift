import CoreGraphics
import CullaCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Where the image a photo is analysed on came from.
public enum AnalysisImageSource: String, Sendable, Hashable, Codable, CaseIterable {
    /// The preview the camera embedded in a RAW file, scaled to the analysis size.
    case embeddedPreview
    /// ImageIO's reduced-size decode of a RAW file, used when the file holds no embedded preview
    /// large enough. ImageIO chooses how it renders a RAW file at a reduced size: measured on a
    /// Nikon D3200 NEF on macOS 27.2 it hands out the embedded preview itself, pixel for pixel.
    case rawDecode
    /// A reduced-size decode of any other file (JPEG, HEIC, PNG, TIFF).
    case decode
}

/// The image one photo is analysed on, upright, and how it was obtained.
public struct AnalysisImage: Sendable {
    public var image: CGImage
    public var source: AnalysisImageSource
    /// Seconds spent opening and decoding, measured on the thread that did the work.
    public var decodeSeconds: Double

    public init(image: CGImage, source: AnalysisImageSource, decodeSeconds: Double) {
        self.image = image
        self.source = source
        self.decodeSeconds = decodeSeconds
    }
}

/// Loads the image a photo is analysed on. `culla-eval` and the app's analysis pipeline both use
/// it, so they measure exactly the same pixels.
///
/// - RAW files: the preview the camera embedded, when its long side, scaled to at most the
///   analysis size, is at least `minimumEmbeddedPixelSize(maxPixelSize:imageLongSide:)`: half the
///   analysis size (2,048 px for the default 4,096), or half the RAW's own long side when that
///   is smaller. Below that, sharpness measured on the preview would no longer be comparable with
///   sharpness measured at the analysis size, so the file is decoded instead (`.rawDecode`).
///   Modern cameras embed a full-size JPEG, so this path almost always applies.
/// - Other files: a normal reduced-size decode (`.decode`), exactly as `ImageLoader.load` does.
///
/// Never scales up. `load` blocks; call it through `BlockingQueue` or use `image(url:maxPixelSize:)`.
public enum AnalysisImageLoader {
    /// Long side, in pixels, of the image photos are analysed at unless a caller asks otherwise.
    public static let defaultMaxPixelSize = 4096

    /// The smallest long side an embedded preview must have to be analysed instead of the RAW
    /// data: half the analysis size, or half the image's own long side when that is smaller.
    public static func minimumEmbeddedPixelSize(maxPixelSize: Int, imageLongSide: Int) -> Int {
        let target = imageLongSide > 0 ? min(maxPixelSize, imageLongSide) : maxPixelSize
        return max(1, target / 2)
    }

    /// Loads the analysis image, blocking the calling thread.
    public static func load(url: URL, maxPixelSize: Int = defaultMaxPixelSize) throws -> AnalysisImage {
        let clock = ContinuousClock()
        let start = clock.now
        let maxPixelSize = max(1, maxPixelSize)
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        // Errors match `ImageLoader.load`: a file ImageIO opens but cannot decode is `cannotDecode`.
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            throw ImageLoaderError.cannotOpen(url)
        }
        let isRAW = CGImageSourceGetType(source).flatMap { UTType($0 as String) }?.conforms(to: .rawImage) ?? false

        if isRAW {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, sourceOptions) as? [CFString: Any] ?? [:]
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
            let minimum = minimumEmbeddedPixelSize(maxPixelSize: maxPixelSize, imageLongSide: max(width, height))
            if let embedded = PreviewLoader.embeddedImage(source, maxPixelSize: maxPixelSize),
               max(embedded.width, embedded.height) >= minimum {
                return AnalysisImage(image: embedded, source: .embeddedPreview, decodeSeconds: seconds(since: start, clock))
            }
        }
        let image = try PreviewLoader.decode(source, url: url, maxPixelSize: maxPixelSize)
        return AnalysisImage(image: image, source: isRAW ? .rawDecode : .decode, decodeSeconds: seconds(since: start, clock))
    }

    /// Loads the analysis image on `BlockingQueue.shared`, off the cooperative pool.
    public static func image(url: URL, maxPixelSize: Int = defaultMaxPixelSize) async throws -> AnalysisImage {
        try await BlockingQueue.shared.run { try load(url: url, maxPixelSize: maxPixelSize) }
    }

    private static func seconds(since start: ContinuousClock.Instant, _ clock: ContinuousClock) -> Double {
        let elapsed = clock.now - start
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }
}
