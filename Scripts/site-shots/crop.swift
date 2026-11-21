// Crops a PNG and scales it to a size, for Scripts/site-shots.py.
// Usage: swift crop.swift <in.png> <out.png> <x> <y> <width> <height> <out width> <out height>
// The crop is in pixels from the top left; the scaling uses Core Graphics' high-quality filter.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count == 9, let numbers = Optional(arguments[3...].compactMap { Int($0) }), numbers.count == 6 else {
    FileHandle.standardError.write(Data("usage: crop.swift in.png out.png x y width height outWidth outHeight\n".utf8))
    exit(2)
}
let input = URL(fileURLWithPath: arguments[1])
let output = URL(fileURLWithPath: arguments[2])
guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      let cropped = image.cropping(to: CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]))
else {
    FileHandle.standardError.write(Data("cannot read or crop \(input.path)\n".utf8))
    exit(1)
}
let width = numbers[4], height = numbers[5]
guard let context = CGContext(
    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { exit(1) }
context.interpolationQuality = .high
context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
guard let result = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)
else { exit(1) }
CGImageDestinationAddImage(destination, result, nil)
guard CGImageDestinationFinalize(destination) else { exit(1) }
