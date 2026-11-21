import CoreGraphics
import CullaFiles
import Foundation
import Testing

@Suite("ImageLoader")
struct ImageLoaderTests {
    /// A gradient with a bright block, so a decoded copy can be checked for orientation.
    private func makeImage(width: Int, height: Int) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        for x in 0..<width {
            let shade = CGFloat(x) / CGFloat(max(width - 1, 1))
            context.setFillColor(red: shade, green: 0.3, blue: 1 - shade, alpha: 1)
            context.fill(CGRect(x: x, y: 0, width: 1, height: height))
        }
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width / 4, height: height / 4))
        return try #require(context.makeImage())
    }

    @Test func writeAndLoadScaledDown() throws {
        let folder = try TemporaryFolder()
        let url = folder.url.appendingPathComponent("gradient.jpg")
        try ImageLoader.writeJPEG(try makeImage(width: 400, height: 300), to: url)

        let loaded = try ImageLoader.load(url: url, maxPixelSize: 100)
        #expect(max(loaded.width, loaded.height) == 100)
        #expect(loaded.width == 100 && loaded.height == 75)
    }

    @Test func loadNeverScalesUp() throws {
        let folder = try TemporaryFolder()
        let url = folder.url.appendingPathComponent("small.jpg")
        try ImageLoader.writeJPEG(try makeImage(width: 120, height: 80), to: url)

        let loaded = try ImageLoader.load(url: url, maxPixelSize: 4096)
        #expect(loaded.width == 120 && loaded.height == 80)
    }

    @Test func loadKeepsAPortraitImageUpright() throws {
        let folder = try TemporaryFolder()
        let url = folder.url.appendingPathComponent("portrait.jpg")
        try ImageLoader.writeJPEG(try makeImage(width: 60, height: 200), to: url)

        let loaded = try ImageLoader.load(url: url, maxPixelSize: 50)
        #expect(loaded.height == 50)
        #expect(loaded.width == 15)
    }

    @Test func loadingSomethingThatIsNotAnImageThrows() throws {
        let folder = try TemporaryFolder()
        let url = try folder.file("broken.jpg", contents: Data("definitely not a JPEG".utf8))
        #expect(throws: ImageLoaderError.self) { try ImageLoader.load(url: url, maxPixelSize: 100) }
    }

    @Test func loadingAMissingFileThrows() {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString).jpg")
        #expect(throws: ImageLoaderError.self) { try ImageLoader.load(url: missing, maxPixelSize: 100) }
    }

    @Test func writingIntoAMissingFolderThrows() throws {
        let image = try makeImage(width: 10, height: 10)
        let url = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/x.jpg")
        #expect(throws: ImageLoaderError.self) { try ImageLoader.writeJPEG(image, to: url) }
    }

    @Test func scaledShrinksToTheLongSide() throws {
        let image = try makeImage(width: 300, height: 200)
        let scaled = try #require(ImageLoader.scaled(image, maxPixelSize: 150))
        #expect(scaled.width == 150 && scaled.height == 100)
    }

    @Test func scaledNeverScalesUp() throws {
        let image = try makeImage(width: 300, height: 200)
        let same = try #require(ImageLoader.scaled(image, maxPixelSize: 1000))
        #expect(same === image)
        let exact = try #require(ImageLoader.scaled(image, maxPixelSize: 300))
        #expect(exact === image)
    }

    @Test func scaledKeepsAtLeastOnePixel() throws {
        let image = try makeImage(width: 400, height: 2)
        let scaled = try #require(ImageLoader.scaled(image, maxPixelSize: 10))
        #expect(scaled.width == 10 && scaled.height == 1)
    }

    @Test(arguments: [(300, 200, 150), (200, 300, 150), (400, 2, 10), (120, 80, 4096), (1001, 333, 360), (360, 360, 360)])
    func scaledSizeMatchesWhatScaledProduces(width: Int, height: Int, maxPixelSize: Int) throws {
        let image = try makeImage(width: width, height: height)
        let scaled = try #require(ImageLoader.scaled(image, maxPixelSize: maxPixelSize))
        let size = ImageLoader.scaledSize(width: width, height: height, maxPixelSize: maxPixelSize)
        #expect(scaled.width == size.width && scaled.height == size.height)
    }

    @Test(arguments: [
        CGRect(x: 10, y: 20, width: 30, height: 40),
        CGRect(x: 10.5, y: 20.25, width: 30, height: 40),
        CGRect(x: 70, y: -10, width: 50, height: 50),
        CGRect(x: -5.5, y: 79.5, width: 300, height: 300),
    ])
    func cropRectMatchesWhatCropProduces(rect: CGRect) throws {
        let image = try makeImage(width: 100, height: 80)
        let crop = try #require(ImageLoader.crop(image, to: rect))
        let expected = try #require(ImageLoader.cropRect(rect, imageWidth: 100, imageHeight: 80))
        #expect(crop.width == Int(expected.width) && crop.height == Int(expected.height))
    }

    @Test func cropRectOutsideIsNil() {
        #expect(ImageLoader.cropRect(CGRect(x: 150, y: 0, width: 10, height: 10), imageWidth: 100, imageHeight: 80) == nil)
    }

    @Test func cropInsideTheImage() throws {
        let image = try makeImage(width: 100, height: 80)
        let crop = try #require(ImageLoader.crop(image, to: CGRect(x: 10, y: 20, width: 30, height: 40)))
        #expect(crop.width == 30 && crop.height == 40)
    }

    @Test func cropIsClippedToTheImage() throws {
        let image = try makeImage(width: 100, height: 80)
        let crop = try #require(ImageLoader.crop(image, to: CGRect(x: 70, y: -10, width: 50, height: 50)))
        #expect(crop.width == 30 && crop.height == 40)
    }

    @Test func cropOutsideTheImageIsNil() throws {
        let image = try makeImage(width: 100, height: 80)
        #expect(ImageLoader.crop(image, to: CGRect(x: 150, y: 10, width: 20, height: 20)) == nil)
        #expect(ImageLoader.crop(image, to: CGRect(x: -50, y: -50, width: 20, height: 20)) == nil)
        // Touching the edge from outside leaves no pixel.
        #expect(ImageLoader.crop(image, to: CGRect(x: 100, y: 0, width: 10, height: 10)) == nil)
    }
}
