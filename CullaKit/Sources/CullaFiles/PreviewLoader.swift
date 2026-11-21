import CoreGraphics
import CullaCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The three image sizes the app shows. See docs/architecture.md, "Images".
public enum PreviewSize: Sendable, Hashable {
    /// Grid, filmstrip and stacks. Taken from the preview embedded in the file when it is large
    /// enough, else decoded.
    case thumbnail(maxPixelSize: Int = PreviewLoader.thumbnailPixelSize)
    /// Loupe and compare, fitted to the window. Also taken from a large enough embedded preview.
    case screen(maxPixelSize: Int)
    /// 100% zoom: the file itself, decoded at full size. For a RAW file this is the RAW render.
    case full

    var maxPixelSize: Int? {
        switch self {
        case .thumbnail(let size), .screen(let size): max(1, size)
        case .full: nil
        }
    }
}

/// A decoded image, upright, and where it came from.
public struct Preview: Sendable {
    public var image: CGImage
    /// True when it was cut from the preview embedded in the file rather than decoded from the
    /// image itself.
    public var usedEmbeddedPreview: Bool

    public init(image: CGImage, usedEmbeddedPreview: Bool) {
        self.image = image
        self.usedEmbeddedPreview = usedEmbeddedPreview
    }
}

/// When `PreviewLoader` looks for a preview embedded in the file before decoding it.
public enum EmbeddedPreviewPolicy: Sendable, Hashable {
    /// For RAW files only. The default.
    case rawFilesOnly
    /// For every file. ImageIO decodes the image instead when a JPEG has no embedded thumbnail,
    /// so `Preview.usedEmbeddedPreview` can then be true for a decoded image.
    case always
    /// Never: always decode.
    case never
}

/// Loads images at the three sizes the app shows, always upright (EXIF orientation applied).
///
/// The fast path is the preview a camera embeds in its files. A RAW file from a modern camera
/// carries a full-size JPEG rendering, and ImageIO can hand it out scaled without touching the
/// RAW data: on a 24 MP Nikon NEF that takes about 0.04 s against 0.36 s for a RAW decode. So for
/// RAW files the embedded preview is used when it holds at least the requested size, else the
/// file is decoded. JPEG and HEIC files carry at most a small EXIF thumbnail (about 160 px), too
/// small for the grid, and ImageIO decodes them at a reduced scale about as fast as it reads such
/// a thumbnail, so they are decoded directly (see `EmbeddedPreviewPolicy`).
///
/// The `load` functions block; call them through `BlockingQueue`, or use the async `preview`.
public enum PreviewLoader {
    /// The long side of a grid thumbnail.
    public static let thumbnailPixelSize = 512

    /// Loads an image at the given size, blocking the calling thread. Never scales up.
    public static func load(
        _ url: URL,
        size: PreviewSize,
        embeddedPreview: EmbeddedPreviewPolicy = .rawFilesOnly
    ) throws -> Preview {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions),
              CGImageSourceGetCount(source) > 0
        else {
            throw ImageLoaderError.cannotOpen(url)
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, sourceOptions) as? [CFString: Any] ?? [:]
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let longSide = max(width, height)

        guard let requested = size.maxPixelSize else {
            return Preview(image: try decode(source, url: url, maxPixelSize: longSide > 0 ? longSide : nil), usedEmbeddedPreview: false)
        }
        // What a full decode would give: the requested size, or the image's own when smaller.
        let target = longSide > 0 ? min(requested, longSide) : requested
        let tryEmbedded = switch embeddedPreview {
        case .always: true
        case .never: false
        case .rawFilesOnly: CGImageSourceGetType(source).flatMap { UTType($0 as String) }?.conforms(to: .rawImage) ?? false
        }
        if tryEmbedded, let embedded = embeddedImage(source, maxPixelSize: requested),
           max(embedded.width, embedded.height) >= target - 1 {
            return Preview(image: embedded, usedEmbeddedPreview: true)
        }
        return Preview(image: try decode(source, url: url, maxPixelSize: requested), usedEmbeddedPreview: false)
    }

    /// Loads an image at the given size on `BlockingQueue.shared`, off the cooperative pool.
    public static func preview(
        _ url: URL,
        size: PreviewSize,
        embeddedPreview: EmbeddedPreviewPolicy = .rawFilesOnly
    ) async throws -> Preview {
        try await BlockingQueue.shared.run { try load(url, size: size, embeddedPreview: embeddedPreview) }
    }

    /// The preview embedded in the file, scaled to at most `maxPixelSize` and upright, or nil
    /// when the file has none. Never decodes the image itself.
    static func embeddedImage(_ source: CGImageSource, maxPixelSize: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Decodes the image itself, upright and scaled to at most `maxPixelSize` (nil: full size).
    static func decode(_ source: CGImageSource, url: URL, maxPixelSize: Int?) throws -> CGImage {
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if let maxPixelSize { options[kCGImageSourceThumbnailMaxPixelSize] = maxPixelSize }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImageLoaderError.cannotDecode(url)
        }
        return image
    }
}
