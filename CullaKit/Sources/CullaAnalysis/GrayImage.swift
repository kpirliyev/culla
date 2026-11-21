import Accelerate
import CoreGraphics

/// An 8-bit grayscale copy of an image, row by row from the top.
public struct GrayImage: Sendable {
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height, "pixel count must equal width x height")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public init?(_ image: CGImage) {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height)
        let space = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2) ?? CGColorSpaceCreateDeviceGray()
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: space,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.init(width: width, height: height, pixels: pixels)
    }

    /// A lightly blurred copy (3x3 binomial), which keeps sensor noise from reading as detail.
    public func smoothed() -> GrayImage {
        guard width >= 3, height >= 3 else { return self }
        var result = [UInt8](repeating: 0, count: pixels.count)
        let kernel: [Int16] = [1, 2, 1, 2, 4, 2, 1, 2, 1]
        pixels.withUnsafeBufferPointer { source in
            result.withUnsafeMutableBufferPointer { destination in
                var input = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: source.baseAddress),
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: width
                )
                var output = vImage_Buffer(
                    data: destination.baseAddress,
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: width
                )
                vImageConvolve_Planar8(
                    &input, &output, nil, 0, 0, kernel, 3, 3, 16, 0, vImage_Flags(kvImageEdgeExtend)
                )
            }
        }
        return GrayImage(width: width, height: height, pixels: result)
    }
}
