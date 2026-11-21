#!/usr/bin/env swift
// Draws Culla's app icon with Core Graphics and writes every size the asset catalog's
// AppIcon.appiconset needs, plus its Contents.json.
//
// Usage: swift Scripts/make_icon.swift [output .appiconset folder] [--preview <folder>]
//   default output: Culla/Assets.xcassets/AppIcon.appiconset (relative to the repository)
//   --preview also writes icon-16.png, icon-32.png, icon-128.png and icon-1024.png there, each
//   drawn at that size, for checking legibility.
//
// The mark: a dark rounded square holding a three-by-three grid of photos. Eight are muted; the
// one in the middle is green with a tick: the keeper picked from many. Three colours, flat, no
// text, in the macOS 26 icon grid (an 824-point body on a 1,024-point canvas). At 64 pixels and
// below the body fills more of the canvas, the tiles snap to whole pixels and the tick is left
// out, so the grid and its one green photo still read at 16 pixels.

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Palette {
    static let ink = CGColor(srgbRed: 0.106, green: 0.129, blue: 0.169, alpha: 1)       // #1B212B
    static let slate = CGColor(srgbRed: 0.333, green: 0.380, blue: 0.459, alpha: 1)     // #556175
    static let keeper = CGColor(srgbRed: 0.204, green: 0.769, blue: 0.396, alpha: 1)    // #34C465
}

/// A rounded rectangle, as macOS draws icon bodies and tiles.
func roundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: min(radius, rect.width / 2), cornerHeight: min(radius, rect.height / 2), transform: nil)
}

/// Draws the icon into a square bitmap of `pixels` on a side.
func render(pixels: Int) -> CGImage {
    let size = CGFloat(pixels)
    let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setShouldAntialias(true)
    context.interpolationQuality = .high
    let unit = size / 1024
    let small = pixels <= 64

    // The body: 824 of 1,024 points, centred, a little high to leave room for the shadow. Small
    // sizes use more of the canvas so the mark is not lost.
    let bodySide = (small ? 940 : 824) * unit
    let body = CGRect(x: (size - bodySide) / 2, y: (size - bodySide) / 2 + (small ? 0 : 8 * unit), width: bodySide, height: bodySide)
    let bodyPath = roundedRect(body, radius: bodySide * 0.2245)

    context.saveGState()
    if !small {
        context.setShadow(offset: CGSize(width: 0, height: -10 * unit), blur: 24 * unit, color: CGColor(gray: 0, alpha: 0.35))
    }
    context.addPath(bodyPath)
    context.setFillColor(Palette.ink)
    context.fillPath()
    context.restoreGState()

    // Three by three photos; the middle one is the keeper. At small sizes the tiles are snapped
    // to whole pixels so the grid stays crisp.
    let inset = bodySide * (small ? 0.16 : 0.2)
    let area = body.insetBy(dx: inset, dy: inset)
    var gap = area.width * (small ? 0.1 : 0.085)
    var tile = (area.width - gap * 2) / 3
    var origin = area.origin
    if small {
        tile = max(2, tile.rounded())
        gap = max(1, ((area.width - tile * 3) / 2).rounded(.down))
        let span = tile * 3 + gap * 2
        origin = CGPoint(x: ((size - span) / 2).rounded(), y: ((size - span) / 2).rounded())
    }
    let tileRadius = tile * (small ? 0.18 : 0.17)
    for row in 0..<3 {
        for column in 0..<3 {
            let rect = CGRect(x: origin.x + CGFloat(column) * (tile + gap), y: origin.y + CGFloat(row) * (tile + gap), width: tile, height: tile)
            let isKeeper = row == 1 && column == 1
            context.addPath(roundedRect(rect, radius: tileRadius))
            context.setFillColor(isKeeper ? Palette.keeper : Palette.slate)
            context.fillPath()
            guard isKeeper, tile >= 10 else { continue }
            // A tick in the body's colour.
            let tick = CGMutablePath()
            tick.move(to: CGPoint(x: rect.minX + rect.width * 0.25, y: rect.minY + rect.height * 0.50))
            tick.addLine(to: CGPoint(x: rect.minX + rect.width * 0.43, y: rect.minY + rect.height * 0.31))
            tick.addLine(to: CGPoint(x: rect.minX + rect.width * 0.76, y: rect.minY + rect.height * 0.69))
            context.addPath(tick)
            context.setStrokeColor(Palette.ink)
            context.setLineWidth(max(1.5, rect.width * 0.13))
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.strokePath()
        }
    }

    return context.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "make_icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot write \(url.path)"])
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "make_icon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot finish \(url.path)"])
    }
}

// MARK: - Main

let arguments = Array(CommandLine.arguments.dropFirst())
let scriptFolder = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let repository = scriptFolder.deletingLastPathComponent()
var output = repository.appendingPathComponent("Culla/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
var preview: URL?
var index = 0
while index < arguments.count {
    if arguments[index] == "--preview", index + 1 < arguments.count {
        preview = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        index += 2
    } else {
        output = URL(fileURLWithPath: arguments[index], isDirectory: true)
        index += 1
    }
}

let slots: [(points: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
var images: [[String: String]] = []
for slot in slots {
    let pixels = slot.points * slot.scale
    let name = "icon_\(slot.points)x\(slot.points)\(slot.scale == 2 ? "@2x" : "").png"
    try writePNG(render(pixels: pixels), to: output.appendingPathComponent(name))
    images.append(["filename": name, "idiom": "mac", "scale": "\(slot.scale)x", "size": "\(slot.points)x\(slot.points)"])
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: output.appendingPathComponent("Contents.json"))
print("Wrote \(slots.count) icons to \(output.path)")

if let preview {
    try FileManager.default.createDirectory(at: preview, withIntermediateDirectories: true)
    for pixels in [16, 32, 128, 1024] {
        try writePNG(render(pixels: pixels), to: preview.appendingPathComponent("icon-\(pixels).png"))
    }
    print("Wrote previews to \(preview.path)")
}
