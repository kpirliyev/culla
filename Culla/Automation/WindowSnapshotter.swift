#if DEBUG
import AppKit
import ImageIO
import QuartzCore
import UniformTypeIdentifiers

/// Draws the window into an image without any privacy permission: the app draws its own window
/// frame view (titlebar, toolbar and content) into a bitmap with `NSView.cacheDisplay(in:to:)`,
/// instead of reading the screen. It includes SwiftUI content, layer contents such as the grid's
/// thumbnails, and the toolbar's glass controls.
///
/// `CALayer.render(in:)` is kept for comparison: it also needs no permission, but it drops the
/// effects macOS 26 draws with layer filters, so toolbar controls come out wrong (the selected
/// segment's icon and disabled button text vanish).
///
/// Neither shows what the window server adds outside the app: the window's shadow, and the
/// desktop behind translucent materials (Culla uses none).
@MainActor
enum WindowSnapshotter {
    enum Method: String {
        /// `NSView.cacheDisplay(in:to:)` of the window's frame view. The default.
        case cache
        /// `CALayer.render(in:)` of the frame view, for comparison.
        case layer
    }

    static func capture(_ window: NSWindow, method: Method = .cache, scale requested: CGFloat? = nil) -> CGImage? {
        window.layoutIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
        let base: CGImage? = switch method {
        case .layer: renderLayers(window, scale: requested ?? window.backingScaleFactor)
        case .cache: cacheDisplay(window, scale: requested)
        }
        guard let base else { return nil }
        // Sheets and alerts are windows of their own: draw them over the window where they sit.
        var overlays = window.sheets
        if let modal = NSApp.modalWindow, modal !== window, !overlays.contains(modal) { overlays.append(modal) }
        // Popovers, such as the tuning panel, are windows of their own too.
        for other in NSApp.windows where other !== window && !overlays.contains(other)
            && String(describing: type(of: other)).contains("Popover") && other.isVisible {
            overlays.append(other)
        }
        overlays = overlays.filter(\.isVisible)
        guard !overlays.isEmpty else { return base }
        return composite(base, window: window, overlays: overlays, method: method)
    }

    private static func composite(_ base: CGImage, window: NSWindow, overlays: [NSWindow], method: Method) -> CGImage? {
        let scale = CGFloat(base.width) / window.frame.width
        guard let context = CGContext(
            data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return base }
        context.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        for overlay in overlays {
            overlay.displayIfNeeded()
            let image: CGImage? = switch method {
            case .layer: renderLayers(overlay, scale: scale)
            case .cache: cacheDisplay(overlay, scale: scale)
            }
            guard let image else { continue }
            let frame = overlay.frame
            let rect = CGRect(
                x: (frame.minX - window.frame.minX) * scale, y: (frame.minY - window.frame.minY) * scale,
                width: frame.width * scale, height: frame.height * scale
            )
            // The panel's glass is drawn by the window server and does not come out; a plain
            // panel stands in for it so the alert reads as one.
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -6 * scale), blur: 24 * scale, color: CGColor(gray: 0, alpha: 0.55))
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 16 * scale, cornerHeight: 16 * scale, transform: nil))
            context.setFillColor(CGColor(gray: 0.17, alpha: 1))
            context.fillPath()
            context.restoreGState()
            context.draw(image, in: rect)
        }
        return context.makeImage()
    }

    private static func renderLayers(_ window: NSWindow, scale: CGFloat) -> CGImage? {
        guard let content = window.contentView, let frameView = content.superview ?? Optional(content),
              let layer = frameView.layer
        else { return nil }
        let size = frameView.bounds.size
        let width = Int((size.width * scale).rounded())
        let height = Int((size.height * scale).rounded())
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        // What shows behind layers with no background of their own.
        context.setFillColor(window.backgroundColor.usingColorSpace(.sRGB)?.cgColor ?? CGColor(gray: 0.13, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        if layer.isGeometryFlipped == false, frameView.isFlipped {
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
        }
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.render(in: context)
        }
        return context.makeImage()
    }

    /// At the window's own scale, or at `scale` pixels per point when given (so a snapshot's size
    /// does not depend on the screen the window happens to be on).
    private static func cacheDisplay(_ window: NSWindow, scale: CGFloat? = nil) -> CGImage? {
        guard let view = window.contentView?.superview ?? window.contentView else { return nil }
        let representation: NSBitmapImageRep?
        if let scale, scale != window.backingScaleFactor {
            let size = view.bounds.size
            representation = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int((size.width * scale).rounded()),
                pixelsHigh: Int((size.height * scale).rounded()), bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            )
            representation?.size = size
        } else {
            representation = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        }
        guard let representation else { return nil }
        view.cacheDisplay(in: view.bounds, to: representation)
        return representation.cgImage
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}
#endif
