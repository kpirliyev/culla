import CoreGraphics
import CullaAnalysis

/// Builds test images in code, so no test depends on files on disk.
enum SyntheticImages {
    /// A small linear congruential generator, so "random" textures are the same on every run.
    struct SeededGenerator {
        private var state: UInt64

        init(seed: UInt64) {
            state = seed
        }

        mutating func next() -> UInt8 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return UInt8(truncatingIfNeeded: state >> 56)
        }
    }

    static func flat(width: Int, height: Int, value: UInt8 = 128) -> GrayImage {
        GrayImage(width: width, height: height, pixels: [UInt8](repeating: value, count: width * height))
    }

    /// Uniform noise over the full gray range.
    static func noise(width: Int, height: Int, seed: UInt64 = 42) -> GrayImage {
        var generator = SeededGenerator(seed: seed)
        return GrayImage(width: width, height: height, pixels: (0..<width * height).map { _ in generator.next() })
    }

    /// A checkerboard of `cell`-pixel squares in two gray levels.
    static func checkerboard(width: Int, height: Int, cell: Int, dark: UInt8 = 40, light: UInt8 = 215) -> GrayImage {
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                pixels[y * width + x] = ((x / cell) + (y / cell)).isMultiple(of: 2) ? dark : light
            }
        }
        return GrayImage(width: width, height: height, pixels: pixels)
    }

    /// A flat image with noise inside one pixel rectangle only.
    static func flat(width: Int, height: Int, texturedIn rect: (x: Range<Int>, y: Range<Int>), seed: UInt64 = 7) -> GrayImage {
        var generator = SeededGenerator(seed: seed)
        var pixels = [UInt8](repeating: 128, count: width * height)
        for y in rect.y {
            for x in rect.x {
                pixels[y * width + x] = generator.next()
            }
        }
        return GrayImage(width: width, height: height, pixels: pixels)
    }

    /// A box blur of the given radius, clamping at the edges.
    static func boxBlurred(_ image: GrayImage, radius: Int) -> GrayImage {
        let width = image.width
        let height = image.height
        var result = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                var sum = 0
                var count = 0
                for dy in -radius...radius {
                    let sy = min(max(y + dy, 0), height - 1)
                    for dx in -radius...radius {
                        let sx = min(max(x + dx, 0), width - 1)
                        sum += Int(image.pixels[sy * width + sx])
                        count += 1
                    }
                }
                result[y * width + x] = UInt8(sum / count)
            }
        }
        return GrayImage(width: width, height: height, pixels: result)
    }

    static func variance(_ image: GrayImage) -> Double {
        let count = Double(image.pixels.count)
        let mean = image.pixels.reduce(0.0) { $0 + Double($1) } / count
        return image.pixels.reduce(0.0) { $0 + (Double($1) - mean) * (Double($1) - mean) } / count
    }

    /// An RGB image of the gray pixels, for the parts of the code that take a CGImage.
    static func cgImage(_ image: GrayImage) -> CGImage? {
        var rgba = [UInt8](repeating: 255, count: image.width * image.height * 4)
        for (index, value) in image.pixels.enumerated() {
            rgba[index * 4] = value
            rgba[index * 4 + 1] = value
            rgba[index * 4 + 2] = value
        }
        return rgba.withUnsafeMutableBytes { buffer -> CGImage? in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return nil }
            return context.makeImage()
        }
    }
}
