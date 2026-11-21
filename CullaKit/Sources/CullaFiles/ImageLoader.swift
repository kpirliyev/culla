import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageLoaderError: Error, CustomStringConvertible, LocalizedError {
    case cannotOpen(URL)
    case cannotDecode(URL)
    case cannotWrite(URL)

    /// In English, for logs and developer tools.
    public var description: String {
        switch self {
        case .cannotOpen(let url): "Cannot open \(url.lastPathComponent)"
        case .cannotDecode(let url): "Cannot decode \(url.lastPathComponent)"
        case .cannotWrite(let url): "Cannot write \(url.lastPathComponent)"
        }
    }

    /// In the person's language, for the interface.
    public var errorDescription: String? {
        switch self {
        case .cannotOpen(let url): localized("Cannot open \(url.lastPathComponent)")
        case .cannotDecode(let url): localized("Cannot decode \(url.lastPathComponent)")
        case .cannotWrite(let url): localized("Cannot write \(url.lastPathComponent)")
        }
    }
}

/// Decodes, scales, crops and writes images through ImageIO and Core Graphics.
public enum ImageLoader {
    /// Decodes a file upright, scaled down so its long side is at most `maxPixelSize`. Never scales up.
    public static func load(url: URL, maxPixelSize: Int) throws -> CGImage {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            throw ImageLoaderError.cannotOpen(url)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImageLoaderError.cannotDecode(url)
        }
        return image
    }

    /// A copy scaled so its long side is at most `maxPixelSize`. Returns the image itself when already small enough.
    public static func scaled(_ image: CGImage, maxPixelSize: Int) -> CGImage? {
        guard max(image.width, image.height) > maxPixelSize else { return image }
        let (width, height) = scaledSize(width: image.width, height: image.height, maxPixelSize: maxPixelSize)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// Crops to a pixel rectangle whose origin is the top-left corner. The rectangle is clipped to the image.
    public static func crop(_ image: CGImage, to rect: CGRect) -> CGImage? {
        guard let clipped = cropRect(rect, imageWidth: image.width, imageHeight: image.height) else { return nil }
        return image.cropping(to: clipped)
    }

    /// The size `scaled(_:maxPixelSize:)` gives an image of this size, without needing the image.
    /// Pages that show a scaled copy use it to know the copy's size before it loads.
    public static func scaledSize(width: Int, height: Int, maxPixelSize: Int) -> (width: Int, height: Int) {
        let longSide = max(width, height)
        guard longSide > maxPixelSize else { return (width, height) }
        let scale = Double(maxPixelSize) / Double(longSide)
        return (
            max(1, Int((Double(width) * scale).rounded())),
            max(1, Int((Double(height) * scale).rounded()))
        )
    }

    /// The pixel rectangle `crop(_:to:)` cuts from an image of this size: `rect` widened to whole
    /// pixels and clipped to the image. Nil when nothing of it lies inside.
    public static func cropRect(_ rect: CGRect, imageWidth: Int, imageHeight: Int) -> CGRect? {
        let bounds = CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight)
        let clipped = rect.integral.intersection(bounds)
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else { return nil }
        return clipped
    }

    public static func writeJPEG(_ image: CGImage, to url: URL, quality: Double = 0.75) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else {
            throw ImageLoaderError.cannotWrite(url)
        }
        let properties = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageLoaderError.cannotWrite(url)
        }
    }
}
