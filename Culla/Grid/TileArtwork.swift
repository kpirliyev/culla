import AppKit

/// Small images drawn once and shared by every tile: decision badges, the "New" pill, rating
/// stars and the unreadable mark. Drawing them once keeps scrolling a large grid cheap; each
/// tile only swaps layer contents.
@MainActor
enum TileArtwork {
    enum Kind: Hashable {
        case kept
        case rejected
        case new
        case stars(Int)
        case unreadable
        case unreadableCaption
        case bestPick
        /// A reason Culla flagged the photo: solid amber when Certain, an amber ring when Likely.
        case reason(symbol: String, certain: Bool)
        /// "+2": more reasons than fit.
        case more(Int)
        /// A stack marker with its frame count.
        case stackCount(Int)
        /// A collapsed stack whose frames have different decisions: a ring split in the shares of
        /// kept (green), rejected (red) and unreviewed (grey) frames, with a stack glyph inside.
        case decisionSummary(kept: Int, rejected: Int, unreviewed: Int)
    }

    private struct Key: Hashable {
        var kind: Kind
        var size: Int
        var scale: Int
        /// Drawn for Increase Contrast: opaque rims and thicker rings.
        var contrast: Bool
    }

    private static var cache: [Key: CGImage] = [:]

    /// The artwork at a point size (badge diameter, pill or star height) and screen scale.
    static func image(_ kind: Kind, size: CGFloat, scale: CGFloat) -> CGImage? {
        let key = Key(kind: kind, size: Int(size.rounded()), scale: Int(scale.rounded()), contrast: SystemAccessibility.increaseContrast)
        if let image = cache[key] { return image }
        let image = render(kind, size: CGFloat(key.size), scale: CGFloat(max(1, key.scale)), contrast: key.contrast)
        cache[key] = image
        return image
    }

    /// The point size of the artwork for a kind at a given badge size.
    static func pointSize(_ kind: Kind, size: CGFloat) -> CGSize {
        switch kind {
        case .kept, .rejected, .bestPick, .reason, .more, .decisionSummary: CGSize(width: size, height: size)
        case .stackCount(let count):
            CGSize(width: (stackString(count, size: size).size().width + size * 0.95 + size * 0.45).rounded(.up), height: size)
        // As wide as the word needs in the language ("NEW", "НОВ.", "TÄZE"), never narrower than before.
        case .new: CGSize(width: max((size * 2.0).rounded(), (newString(size: size).size().width + size * 0.8).rounded(.up)), height: (size * 0.82).rounded())
        case .stars(let count): CGSize(width: CGFloat(count) * size + CGFloat(max(0, count - 1)) * 1.5, height: size)
        case .unreadable: CGSize(width: size, height: size)
        case .unreadableCaption:
            CGSize(width: (captionString(size: size).size().width + 2).rounded(.up), height: size)
        }
    }

    private static func render(_ kind: Kind, size: CGFloat, scale: CGFloat, contrast: Bool) -> CGImage? {
        let points = pointSize(kind, size: size)
        let width = Int((points.width * scale).rounded(.up))
        let height = Int((points.height * scale).rounded(.up))
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        defer { NSGraphicsContext.restoreGraphicsState() }
        let bounds = CGRect(origin: .zero, size: points)

        switch kind {
        case .kept:
            drawBadge(in: bounds, fill: Palette.kept, symbol: "checkmark", contrast: contrast)
        case .rejected:
            drawBadge(in: bounds, fill: Palette.rejected, symbol: "xmark", contrast: contrast)
        case .bestPick:
            drawBadge(in: bounds, fill: NSColor(white: 0.1, alpha: contrast ? 0.95 : 0.75), symbol: "star.fill", tint: Palette.flagged, contrast: contrast)
        case .new:
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: bounds.height / 2, yRadius: bounds.height / 2)
            NSColor(white: 0.97, alpha: 0.94).setFill()
            path.fill()
            NSColor(white: 0, alpha: 0.25).setStroke()
            path.lineWidth = 0.5
            path.stroke()
            drawText(localized("badge.new", default: "NEW"), font: newFont(size: size), color: NSColor(white: 0.08, alpha: 1), in: bounds, kern: 0.4)
        case .stars(let count):
            for index in 0..<count {
                let rect = CGRect(x: CGFloat(index) * (size + 1.5), y: 0, width: size, height: size)
                drawSymbol("star.fill", in: rect, pointSize: size * 0.82, color: Palette.star, weight: .regular)
            }
        case .unreadable:
            drawSymbol("exclamationmark.triangle.fill", in: bounds, pointSize: size * 0.8, color: Palette.flagged, weight: .regular)
        case .reason(let symbol, let certain):
            // A dark rim keeps both forms readable on a white sky and on black.
            let outer = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.25, dy: 0.25))
            NSColor(white: 0, alpha: contrast ? 0.92 : certain ? 0.4 : 0.62).setFill()
            outer.fill()
            if certain {
                NSBezierPath(ovalIn: bounds.insetBy(dx: contrast ? 1.5 : 1, dy: contrast ? 1.5 : 1)).fill(with: Palette.flagged)
                drawSymbol(symbol, in: bounds, pointSize: size * 0.5, color: NSColor(white: 0.08, alpha: contrast ? 1 : 0.92), weight: .bold)
            } else {
                let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: contrast ? 2.25 : 1.75, dy: contrast ? 2.25 : 1.75))
                ring.lineWidth = max(contrast ? 2 : 1.25, size * (contrast ? 0.12 : 0.08))
                Palette.flagged.setStroke()
                ring.stroke()
                drawSymbol(symbol, in: bounds, pointSize: size * 0.46, color: Palette.flagged, weight: .semibold)
            }
        case .more(let count):
            NSBezierPath(ovalIn: bounds.insetBy(dx: 0.25, dy: 0.25)).fill(with: NSColor(white: 0, alpha: 0.62))
            let font = NSFont.systemFont(ofSize: (size * 0.42).rounded(), weight: .bold)
            drawText("+\(count)", font: font, color: Palette.flagged, in: bounds, kern: 0)
        case .stackCount(let count):
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25), xRadius: bounds.height / 2, yRadius: bounds.height / 2)
            NSColor(white: 0.05, alpha: 0.66).setFill()
            path.fill()
            let iconRect = CGRect(x: size * 0.3, y: 0, width: size * 0.62, height: size)
            drawSymbol("square.stack.3d.up.fill", in: iconRect, pointSize: size * 0.48, color: NSColor(white: 0.95, alpha: 1), weight: .regular)
            let string = stackString(count, size: size)
            let textSize = string.size()
            string.draw(at: CGPoint(x: iconRect.maxX + size * 0.08, y: (bounds.height - textSize.height) / 2 + 0.5))
        case .decisionSummary(let kept, let rejected, let unreviewed):
            let total = CGFloat(max(1, kept + rejected + unreviewed))
            NSBezierPath(ovalIn: bounds.insetBy(dx: 0.25, dy: 0.25)).fill(with: NSColor(white: 0.08, alpha: contrast ? 0.95 : 0.8))
            let centre = CGPoint(x: bounds.midX, y: bounds.midY)
            let radius = bounds.width / 2 - max(2, size * 0.14)
            let line = max(2, size * 0.17)
            var angle: CGFloat = 90
            // Not by colour alone: kept is a solid arc, rejected a dashed one, unreviewed a thin one.
            let segments: [(Int, NSColor, CGFloat, [CGFloat])] = [
                (kept, Palette.kept, line, []),
                (rejected, Palette.rejected, line, [max(1.5, line * 0.7), max(1.2, line * 0.55)]),
                (unreviewed, NSColor(white: contrast ? 0.8 : 0.62, alpha: 1), max(1, line * 0.45), []),
            ]
            for (count, color, width, dashes) in segments where count > 0 {
                let sweep = 360 * CGFloat(count) / total
                let arc = NSBezierPath()
                arc.appendArc(withCenter: centre, radius: radius, startAngle: angle, endAngle: angle - sweep, clockwise: true)
                arc.lineWidth = width
                if !dashes.isEmpty { arc.setLineDash(dashes, count: dashes.count, phase: 0) }
                color.setStroke()
                arc.stroke()
                angle -= sweep
            }
            drawSymbol("square.stack.3d.up.fill", in: bounds, pointSize: size * 0.36, color: NSColor(white: 0.95, alpha: 1), weight: .regular)
        case .unreadableCaption:
            let string = captionString(size: size)
            let textSize = string.size()
            string.draw(at: CGPoint(x: bounds.midX - textSize.width / 2, y: bounds.midY - textSize.height / 2))
        }
        return context.makeImage()
    }

    private static func stackString(_ count: Int, size: CGFloat) -> NSAttributedString {
        NSAttributedString(string: "\(count)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: (size * 0.55).rounded(), weight: .semibold),
            .foregroundColor: NSColor(white: 0.95, alpha: 1),
        ])
    }

    private static func newFont(size: CGFloat) -> NSFont {
        NSFont.systemFont(ofSize: (size * 0.5).rounded(), weight: .bold)
    }

    private static func newString(size: CGFloat) -> NSAttributedString {
        NSAttributedString(string: localized("badge.new", default: "NEW"), attributes: [.font: newFont(size: size), .kern: 0.4])
    }

    private static func captionString(size: CGFloat) -> NSAttributedString {
        NSAttributedString(string: localized("Can’t read file"), attributes: [
            .font: NSFont.systemFont(ofSize: (size * 0.85).rounded(), weight: .medium),
            .foregroundColor: Palette.flagged,
        ])
    }

    private static func drawBadge(in bounds: CGRect, fill: NSColor, symbol: String, tint: NSColor = .white, contrast: Bool) {
        // A thin dark rim keeps the badge readable on a white sky; with Increase Contrast it is
        // opaque and wider, with a light edge outside it for dark photos.
        let outer = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.25, dy: 0.25))
        if contrast {
            NSColor(white: 0.97, alpha: 1).setFill()
            outer.fill()
            NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill(with: NSColor(white: 0, alpha: 1))
            NSBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2)).fill(with: fill)
        } else {
            NSColor(white: 0, alpha: 0.35).setFill()
            outer.fill()
            NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill(with: fill)
        }
        drawSymbol(symbol, in: bounds, pointSize: bounds.height * 0.5, color: tint, weight: .heavy)
    }

    private static func drawSymbol(_ name: String, in rect: CGRect, pointSize: CGFloat, color: NSColor, weight: NSFont.Weight) {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
            .applying(.init(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        else { return }
        let size = image.size
        let origin = CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
        image.draw(in: CGRect(origin: origin, size: size))
    }

    private static func drawText(_ text: String, font: NSFont, color: NSColor, in rect: CGRect, kern: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .kern: kern]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        string.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2 + font.descender / 4))
    }
}

private extension NSBezierPath {
    func fill(with color: NSColor) {
        color.setFill()
        fill()
    }
}
