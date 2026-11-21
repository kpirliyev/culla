import CoreGraphics
import CullaAnalysis
import Testing

@Suite("FaceCrop")
struct FaceCropTests {
    private func close(_ a: CGPoint, _ b: CGPoint, _ tolerance: Double = 1e-9) -> Bool {
        abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
    }

    private func close(_ a: CGRect, _ b: CGRect, _ tolerance: Double = 1e-9) -> Bool {
        close(a.origin, b.origin, tolerance) && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    @Test func paddingSurroundsTheFaceAtTheImagesOwnPixels() throws {
        let face = CGRect(x: 1000, y: 800, width: 100, height: 120)
        let crop = try #require(FaceCrop(face: face, imageWidth: 4000, imageHeight: 3000, padding: 2))
        #expect(crop.source == CGRect(x: 800, y: 560, width: 500, height: 600))
        #expect(crop.width == 500 && crop.height == 600)
        #expect(!crop.isScaled)
        // The face is the middle fifth, measured from the bottom-left as Vision expects.
        #expect(close(crop.faceInCrop, CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)))
    }

    @Test func theFaceBoxIsGivenFromTheBottomLeft() throws {
        // A crop clipped at the top of the image: the face sits high in it.
        let face = CGRect(x: 100, y: 10, width: 50, height: 50)
        let crop = try #require(FaceCrop(face: face, imageWidth: 1000, imageHeight: 1000, padding: 1))
        #expect(crop.source == CGRect(x: 50, y: 0, width: 150, height: 110))
        #expect(close(crop.faceInCrop, CGRect(x: 50.0 / 150, y: 50.0 / 110, width: 50.0 / 150, height: 50.0 / 110)))
    }

    @Test func theCropIsClippedToTheImage() throws {
        let face = CGRect(x: 0, y: 950, width: 80, height: 50)
        let crop = try #require(FaceCrop(face: face, imageWidth: 1200, imageHeight: 1000, padding: 2))
        #expect(crop.source == CGRect(x: 0, y: 850, width: 240, height: 150))
        #expect(close(crop.faceInCrop, CGRect(x: 0, y: 0, width: 80.0 / 240, height: 50.0 / 150)))
    }

    @Test func fractionalBoxesAreWidenedToWholePixels() throws {
        let face = CGRect(x: 100.4, y: 200.6, width: 50.2, height: 60.3)
        let crop = try #require(FaceCrop(face: face, imageWidth: 2000, imageHeight: 2000, padding: 1))
        #expect(crop.source == CGRect(x: 50, y: 140, width: 151, height: 182))
        // The face box inside it is still exact.
        let corner = crop.imagePoint(fromCrop: CGPoint(
            x: crop.faceInCrop.minX * Double(crop.width),
            y: (1 - crop.faceInCrop.maxY) * Double(crop.height)
        ))
        #expect(close(corner, face.origin, 1e-6))
    }

    @Test func pointsMapBackToTheImage() throws {
        let face = CGRect(x: 1000, y: 800, width: 100, height: 120)
        let crop = try #require(FaceCrop(face: face, imageWidth: 4000, imageHeight: 3000, padding: 2))
        #expect(close(crop.imagePoint(fromCrop: .zero), CGPoint(x: 800, y: 560)))
        #expect(close(crop.imagePoint(fromCrop: CGPoint(x: 500, y: 600)), CGPoint(x: 1300, y: 1160)))
        #expect(close(crop.imagePoint(fromCrop: CGPoint(x: 250, y: 300)), CGPoint(x: 1050, y: 860)))
    }

    @Test func largeFacesAreScaledDownAndMappedBack() throws {
        let face = CGRect(x: 1000, y: 1000, width: 400, height: 512)
        let crop = try #require(FaceCrop(face: face, imageWidth: 6000, imageHeight: 4000, padding: 1, maxFaceHeight: 256))
        #expect(crop.isScaled)
        #expect(crop.source == CGRect(x: 600, y: 488, width: 1200, height: 1536))
        #expect(crop.width == 600 && crop.height == 768)
        #expect(close(crop.imagePoint(fromCrop: CGPoint(x: 600, y: 768)), CGPoint(x: 1800, y: 2024)))
        #expect(close(crop.imagePoint(fromCrop: CGPoint(x: 300, y: 384)), CGPoint(x: 1200, y: 1256)))
    }

    @Test func roundingTheScaledSizeDoesNotStretchTheImage() throws {
        // 333 x 211 scaled by 0.5 rounds to 167 x 106 (not 166.5 x 105.5). Mapping back uses
        // each axis's own factor, so the far corner still lands on the far corner.
        let face = CGRect(x: 111, y: 70.5, width: 111, height: 70)
        let crop = try #require(FaceCrop(face: face, imageWidth: 1000, imageHeight: 1000, padding: 1, maxFaceHeight: 35))
        #expect(crop.source == CGRect(x: 0, y: 0, width: 333, height: 211))
        #expect(crop.width == 167 && crop.height == 106)
        let far = crop.imagePoint(fromCrop: CGPoint(x: crop.width, y: crop.height))
        #expect(close(far, CGPoint(x: 333, y: 211), 1e-9))
    }

    @Test func openOutlinesMeasureTheSameInTheCropAndTheImage() throws {
        // An eye outline 40 x 12 pixels in the image, cut out with scaling: mapped back, it
        // measures the same as it does in the image itself.
        let face = CGRect(x: 2000, y: 1500, width: 600, height: 600)
        let crop = try #require(FaceCrop(face: face, imageWidth: 6000, imageHeight: 4000, padding: 1, maxFaceHeight: 200))
        let eye = [CGPoint(x: 2200, y: 1700), CGPoint(x: 2220, y: 1694), CGPoint(x: 2240, y: 1700), CGPoint(x: 2220, y: 1706)]
        let inCrop = eye.map { point in
            CGPoint(
                x: (point.x - crop.source.minX) * Double(crop.width) / crop.source.width,
                y: (point.y - crop.source.minY) * Double(crop.height) / crop.source.height
            )
        }
        let back = inCrop.map(crop.imagePoint)
        let expected = try #require(EyeGeometry.openness(of: eye))
        let measured = try #require(EyeGeometry.openness(of: back))
        #expect(abs(measured - expected) < 1e-9)
        #expect(abs(expected - 0.3) < 1e-9)
    }

    @Test func emptyFacesAndImagesGiveNoCrop() {
        #expect(FaceCrop(face: .zero, imageWidth: 100, imageHeight: 100, padding: 1) == nil)
        #expect(FaceCrop(face: CGRect(x: 0, y: 0, width: 10, height: 10), imageWidth: 0, imageHeight: 100, padding: 1) == nil)
        #expect(FaceCrop(face: CGRect(x: 500, y: 500, width: 10, height: 10), imageWidth: 100, imageHeight: 100, padding: 1) == nil)
    }

    @Test func onlyFacesWithoutAReadingThatAreLargeEnoughGetASecondPass() {
        // 2723 px short side: 0.03 of it is 81.7 px.
        func needs(_ left: Double?, _ right: Double?, height: Double, shortSide: Int = 2723) -> Bool {
            FaceCrop.needsSecondPass(leftOpenness: left, rightOpenness: right, faceHeight: height, imageShortSide: shortSide)
        }
        #expect(needs(nil, nil, height: 200))
        #expect(needs(0.3, nil, height: 200))
        #expect(needs(nil, 0.3, height: 200))
        #expect(!needs(0.3, 0.3, height: 200))
        #expect(!needs(nil, nil, height: 81))
        #expect(needs(nil, nil, height: 82))
        // The pixel floor applies to small images, where 3 % of the short side is under 48 px.
        #expect(!needs(nil, nil, height: 47, shortSide: 1000))
        #expect(needs(nil, nil, height: 48, shortSide: 1000))
        #expect(!needs(nil, nil, height: 200, shortSide: 0))
    }
}
