import CoreGraphics
import CullaAnalysis
import CullaCore
import Foundation
import Testing

@Suite("EyeGeometry")
struct EyeGeometryTests {
    /// Points on an ellipse with semi-axes `a` (across) and `b` (up), including both corners and
    /// the top and bottom, so the expected openness is exactly b / a.
    private func eye(a: Double, b: Double, centre: CGPoint = CGPoint(x: 200, y: 150), angle: Double = 0) -> [CGPoint] {
        (0..<16).map { step in
            let t = Double(step) * .pi / 8
            let x = a * cos(t)
            let y = b * sin(t)
            return CGPoint(
                x: centre.x + x * cos(angle) - y * sin(angle),
                y: centre.y + x * sin(angle) + y * cos(angle)
            )
        }
    }

    @Test func wideOpenEye() throws {
        let openness = try #require(EyeGeometry.openness(of: eye(a: 15, b: 6)))
        #expect(abs(openness - 0.4) < 1e-9)
    }

    @Test func nearlyClosedEye() throws {
        let openness = try #require(EyeGeometry.openness(of: eye(a: 15, b: 0.5)))
        #expect(abs(openness - 1.0 / 30) < 1e-9)
        #expect(openness < 0.1)
    }

    @Test(arguments: [0.3, 1.0, 37.0 * .pi / 180, 2.5, -0.7])
    func rotatedEyeGivesTheSameValue(angle: Double) throws {
        let upright = try #require(EyeGeometry.openness(of: eye(a: 15, b: 6)))
        let rotated = try #require(EyeGeometry.openness(of: eye(a: 15, b: 6, angle: angle)))
        #expect(abs(rotated - upright) < 1e-9)
    }

    @Test func fewerThanFourPointsGiveNil() {
        #expect(EyeGeometry.openness(of: []) == nil)
        #expect(EyeGeometry.openness(of: [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 5, y: 3)]) == nil)
    }

    @Test func coincidentPointsGiveNil() {
        #expect(EyeGeometry.openness(of: Array(repeating: CGPoint(x: 3, y: 4), count: 6)) == nil)
    }
}

@Suite("GrayImage")
struct GrayImageTests {
    @Test func smoothedKeepsDimensionsAndReducesVariance() {
        let noisy = SyntheticImages.noise(width: 64, height: 48)
        let smooth = noisy.smoothed()
        #expect(smooth.width == 64 && smooth.height == 48)
        #expect(smooth.pixels.count == noisy.pixels.count)
        #expect(SyntheticImages.variance(smooth) < SyntheticImages.variance(noisy) * 0.6)
    }

    @Test func smoothedLeavesAFlatImageAlone() {
        let flat = SyntheticImages.flat(width: 10, height: 10, value: 77)
        #expect(flat.smoothed().pixels == flat.pixels)
    }

    @Test func smoothedOfATinyImageIsUnchanged() {
        let tiny = SyntheticImages.noise(width: 2, height: 5)
        let smooth = tiny.smoothed()
        #expect(smooth.width == 2 && smooth.height == 5 && smooth.pixels == tiny.pixels)
    }

    @Test func fromCGImageKeepsSizeAndGrayLevels() throws {
        let source = SyntheticImages.checkerboard(width: 40, height: 30, cell: 5, dark: 0, light: 255)
        let image = try #require(SyntheticImages.cgImage(source))
        let gray = try #require(GrayImage(image))
        #expect(gray.width == 40 && gray.height == 30)
        // Pure black and white survive any gray conversion; check the top-left and its neighbour cell.
        #expect(gray.pixels[0] < 10)
        #expect(gray.pixels[5] > 245)
    }
}

@Suite("ExposureMeter")
struct ExposureMeterTests {
    @Test func knownSharesOfWhiteAndBlack() {
        // 200 pixels: 30 at or above 250, 50 at or below 5, the rest mid-gray.
        var pixels = [UInt8](repeating: 128, count: 200)
        for i in 0..<20 { pixels[i] = 255 }
        for i in 20..<30 { pixels[i] = 250 }
        for i in 30..<70 { pixels[i] = 0 }
        for i in 70..<80 { pixels[i] = 5 }
        pixels[80] = 249
        pixels[81] = 6
        let clipping = ExposureMeter.measure(GrayImage(width: 20, height: 10, pixels: pixels))
        #expect(abs(clipping.highlights - 0.15) < 1e-12)
        #expect(abs(clipping.shadows - 0.25) < 1e-12)
    }

    @Test func customLevels() {
        let image = GrayImage(width: 4, height: 1, pixels: [10, 100, 200, 240])
        let clipping = ExposureMeter.measure(image, highlightLevel: 200, shadowLevel: 100)
        #expect(clipping.highlights == 0.5)
        #expect(clipping.shadows == 0.5)
    }

    @Test func midGrayIsNotClipped() {
        let clipping = ExposureMeter.measure(SyntheticImages.flat(width: 8, height: 8))
        #expect(clipping.highlights == 0 && clipping.shadows == 0)
    }
}

@Suite("SharpnessMeter")
struct SharpnessMeterTests {
    @Test func sharpNoiseScoresClearlyHigherThanItsBlurredCopy() {
        let sharp = SyntheticImages.noise(width: 256, height: 256)
        let blurred = SyntheticImages.boxBlurred(sharp, radius: 3)
        let sharpScore = SharpnessMeter.map(of: sharp).measure(in: .full)
        let blurredScore = SharpnessMeter.map(of: blurred).measure(in: .full)
        #expect(sharpScore.score > 2 * blurredScore.score)
        #expect(sharpScore.edgeStrength > 2 * blurredScore.edgeStrength)
    }

    @Test func fineCheckerboardScoresClearlyHigherThanItsBlurredCopy() {
        // A blur wider than the 4-pixel cells. A narrower one leaves a softened but still periodic
        // pattern, which the contrast-normalised score reads as a sharp pattern of lower contrast;
        // only the raw edge strength falls then (checked below).
        let sharp = SyntheticImages.checkerboard(width: 256, height: 256, cell: 4)
        let sharpScore = SharpnessMeter.map(of: sharp).measure(in: .full)
        let blurred = SharpnessMeter.map(of: SyntheticImages.boxBlurred(sharp, radius: 3)).measure(in: .full)
        #expect(sharpScore.score > 2 * blurred.score)
        let softened = SharpnessMeter.map(of: SyntheticImages.boxBlurred(sharp, radius: 2)).measure(in: .full)
        #expect(sharpScore.edgeStrength > 2 * softened.edgeStrength)
    }

    @Test func singlePixelCheckerboardIsTreatedAsNoise() {
        // The light smoothing before measuring exists to cancel pixel-level noise, and a one-pixel
        // checkerboard is exactly that pattern, so it reads as flat.
        let map = SharpnessMeter.map(of: SyntheticImages.checkerboard(width: 128, height: 128, cell: 1))
        #expect(map.measure(in: .full).score < 1e-6)
    }

    @Test func flatImageScoresZero() {
        let result = SharpnessMeter.map(of: SyntheticImages.flat(width: 200, height: 150)).measure(in: .full)
        #expect(result.score < 1e-6)
        #expect(result.edgeStrength < 1e-6)
    }

    @Test func peakLiesInTheOnlyTexturedArea() {
        // Texture in x 128..<192 and y 64..<128 of a 256 x 256 image: unit x 0.5 to 0.75, y 0.25 to 0.5.
        let image = SyntheticImages.flat(width: 256, height: 256, texturedIn: (x: 128..<192, y: 64..<128))
        let map = SharpnessMeter.map(of: image)
        let textured = UnitRect(x: 0.5, y: 0.25, width: 0.25, height: 0.25)
        for region in [UnitRect.full, UnitRect(x: 0.3, y: 0.1, width: 0.6, height: 0.6), textured] {
            let result = map.measure(in: region)
            #expect(result.peak.x > textured.x && result.peak.x < textured.maxX)
            #expect(result.peak.y > textured.y && result.peak.y < textured.maxY)
            #expect(result.score > 10)
        }
        // A region of flat background, not touching the tiles beside the texture, reads as flat.
        #expect(map.measure(in: UnitRect(x: 0, y: 0.7, width: 0.3, height: 0.3)).score < 1e-6)
    }

    @Test func mapCoversTheImageInTiles() {
        let map = SharpnessMeter.map(of: SyntheticImages.flat(width: 100, height: 65))
        #expect(map.columns == 4 && map.rows == 3)
        #expect(map.normalized.count == 12 && map.raw.count == 12)
        #expect(map.imageWidth == 100 && map.imageHeight == 65)
    }

    @Test(arguments: [(1, 1), (2, 2), (3, 3), (5, 40), (33, 1), (1, 70), (31, 31), (33, 33)])
    func tinyImagesDoNotCrash(width: Int, height: Int) {
        let map = SharpnessMeter.map(of: SyntheticImages.noise(width: width, height: height))
        for region in [
            UnitRect.full,
            UnitRect(x: 0.9, y: 0.9, width: 0.5, height: 0.5),
            UnitRect(x: 2, y: 2, width: 0.1, height: 0.1),
            UnitRect(x: 0.5, y: 0.5, width: 0, height: 0),
        ] {
            let result = map.measure(in: region)
            #expect(result.score.isFinite && result.edgeStrength.isFinite)
            #expect((0...1).contains(result.peak.x) && (0...1).contains(result.peak.y))
        }
    }
}

@Suite("FeatureMath")
struct FeatureMathTests {
    @Test func identicalVectorsAreZeroApart() {
        #expect(FeatureMath.distance([0.5, -1, 2], [0.5, -1, 2]) == 0)
    }

    @Test func knownDistance() throws {
        let distance = try #require(FeatureMath.distance([0, 0, 1], [3, 4, 1]))
        #expect(abs(distance - 5) < 1e-6)
    }

    @Test func vectorsThatCannotBeComparedGiveNil() {
        #expect(FeatureMath.distance([1, 2], [1, 2, 3]) == nil)
        #expect(FeatureMath.distance([], []) == nil)
    }
}
