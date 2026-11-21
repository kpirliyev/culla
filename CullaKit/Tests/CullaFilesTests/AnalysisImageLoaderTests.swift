import CoreGraphics
import CullaFiles
import Foundation
import Testing

@Suite("AnalysisImageLoader")
struct AnalysisImageLoaderTests {
    /// The colour at the centre of an image, as 8-bit sRGB.
    private func centreColour(of image: CGImage) throws -> (r: Int, g: Int, b: Int) {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.draw(image, in: CGRect(x: -image.width / 2, y: -image.height / 2, width: image.width, height: image.height))
        return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
    }

    private func writeDNG(_ folder: TemporaryFolder, name: String, previewWidth: Int, previewHeight: Int) throws -> URL {
        let data = TestDNG.data(
            rawWidth: 600, rawHeight: 400, rawColour: .init(r: 8000, g: 40000, b: 8000),
            previewWidth: previewWidth, previewHeight: previewHeight, previewColour: .init(r: 250, g: 10, b: 10)
        )
        return try folder.file(name, contents: data)
    }

    @Test func aRAWFileIsAnalysedOnItsEmbeddedPreviewWhenLargeEnough() throws {
        let folder = try TemporaryFolder()
        let url = try writeDNG(folder, name: "big.dng", previewWidth: 600, previewHeight: 400)
        let loaded = try AnalysisImageLoader.load(url: url, maxPixelSize: 512)
        #expect(loaded.source == .embeddedPreview)
        #expect(loaded.image.width == 512 && loaded.image.height == 341)
        let colour = try centreColour(of: loaded.image)
        #expect(colour.r > 200 && colour.g < 60, "the red preview, not the green RAW data")
        #expect(loaded.decodeSeconds >= 0)
    }

    @Test func aRAWFileWithASmallPreviewIsDecoded() throws {
        let folder = try TemporaryFolder()
        // The preview's long side, 200, is under half the 512 analysis size.
        let url = try writeDNG(folder, name: "small.dng", previewWidth: 200, previewHeight: 133)
        let loaded = try AnalysisImageLoader.load(url: url, maxPixelSize: 512)
        #expect(loaded.source == .rawDecode)
        #expect(loaded.image.width == 512 && loaded.image.height == 341)
        let colour = try centreColour(of: loaded.image)
        #expect(colour.g > colour.r + 100, "the green RAW data, not the red preview")
    }

    @Test func aPreviewOfExactlyHalfTheAnalysisSizeIsEnough() throws {
        let folder = try TemporaryFolder()
        let url = try writeDNG(folder, name: "half.dng", previewWidth: 256, previewHeight: 171)
        let loaded = try AnalysisImageLoader.load(url: url, maxPixelSize: 512)
        #expect(loaded.source == .embeddedPreview)
        #expect(loaded.image.width == 256)
    }

    @Test func theMinimumIsHalfTheAnalysisSizeOrOfTheImage() {
        #expect(AnalysisImageLoader.minimumEmbeddedPixelSize(maxPixelSize: 4096, imageLongSide: 6016) == 2048)
        #expect(AnalysisImageLoader.minimumEmbeddedPixelSize(maxPixelSize: 4096, imageLongSide: 3000) == 1500)
        #expect(AnalysisImageLoader.minimumEmbeddedPixelSize(maxPixelSize: 4096, imageLongSide: 0) == 2048)
        #expect(AnalysisImageLoader.minimumEmbeddedPixelSize(maxPixelSize: 1, imageLongSide: 1) == 1)
    }

    @Test func otherFilesAreDecodedExactlyAsImageLoaderDoes() throws {
        let folder = try TemporaryFolder()
        let url = try TestImages.writeJPEG(to: folder.url.appendingPathComponent("a.jpg"), width: 1200, height: 800, orientation: 6)
        let loaded = try AnalysisImageLoader.load(url: url, maxPixelSize: 600)
        #expect(loaded.source == .decode)
        // Orientation 6 is applied: the stored 1200 x 800 comes out 400 x 600.
        #expect(loaded.image.width == 400 && loaded.image.height == 600)
        let reference = try ImageLoader.load(url: url, maxPixelSize: 600)
        #expect(loaded.image.width == reference.width && loaded.image.height == reference.height)
        #expect(loaded.image.dataProvider?.data as Data? == reference.dataProvider?.data as Data?)
    }

    @Test func aJPEGWithAnEmbeddedThumbnailIsStillDecoded() throws {
        let folder = try TemporaryFolder()
        let url = try TestImages.writeJPEG(
            to: folder.url.appendingPathComponent("thumb.jpg"), width: 1200, height: 800, embedThumbnail: true
        )
        let loaded = try AnalysisImageLoader.load(url: url, maxPixelSize: 1000)
        #expect(loaded.source == .decode)
        #expect(loaded.image.width == 1000)
    }

    @Test func neverScalesUp() async throws {
        let folder = try TemporaryFolder()
        let url = try TestImages.writeJPEG(to: folder.url.appendingPathComponent("s.jpg"), width: 300, height: 200)
        let loaded = try await AnalysisImageLoader.image(url: url)
        #expect(loaded.image.width == 300 && loaded.image.height == 200)
    }

    @Test func unreadableFilesThrow() throws {
        let folder = try TemporaryFolder()
        let broken = try folder.file("broken.jpg", contents: Data("not an image".utf8))
        #expect(throws: ImageLoaderError.self) { try AnalysisImageLoader.load(url: broken) }
        #expect(throws: ImageLoaderError.self) {
            try AnalysisImageLoader.load(url: folder.url.appendingPathComponent("missing.nef"))
        }
    }
}
