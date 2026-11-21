import CullaAnalysis
import CullaCommands
import CullaCore
import CullaSession
import Testing

@Suite("Loupe zoom")
struct LoupeZoomTests {
    /// A 6000 x 4000 photo in a 1000 x 600 point viewport on a Retina display.
    let geometry = LoupeGeometry(imageWidth: 6000, imageHeight: 4000, viewportWidth: 1000, viewportHeight: 600, backingScale: 2)

    @Test func fitShowsTheWholePhoto() {
        // Height limits: 600 points for 4000 pixels, 0.15 points per pixel, 0.3 device pixels.
        #expect(abs(geometry.fitFactor - 0.3) < 1e-9)
        let rect = geometry.visibleRect(.fit)
        #expect(rect == UnitRect(x: 0, y: 0, width: 1, height: 1))
    }

    @Test func oneHundredPercentIsOneImagePixelPerDevicePixel() {
        #expect(geometry.pointsPerPixel(factor: 1) == 0.5)
        // At 100% the 1000-point viewport is 2000 device pixels: a third of the width.
        let rect = geometry.visibleRect(.zoomed(factor: 1, centre: UnitPoint(x: 0.5, y: 0.5)))
        #expect(abs(rect.width - 2000.0 / 6000) < 1e-9)
        #expect(abs(rect.height - 1200.0 / 4000) < 1e-9)
    }

    @Test func fitLeavesAMargin() {
        let framed = LoupeGeometry(imageWidth: 6000, imageHeight: 4000, viewportWidth: 1000, viewportHeight: 600, backingScale: 2, fitMargin: 20)
        // 560 points of height for 4000 pixels.
        #expect(abs(framed.fitFactor - 0.28) < 1e-9)
        // The whole photo is still what fit shows.
        #expect(framed.visibleRect(.fit) == UnitRect(x: 0, y: 0, width: 1, height: 1))
    }

    @Test func fitNeverEnlargesASmallPhotoBeyondOnePixelPerPoint() {
        let small = LoupeGeometry(imageWidth: 400, imageHeight: 300, viewportWidth: 1000, viewportHeight: 600, backingScale: 2)
        #expect(small.fitFactor == 2)
        // It can still be shown at 100%, its real size, below fit; the whole photo shows.
        #expect(small.factorRange == 1...4)
        #expect(small.normalized(.zoomed(factor: 1, centre: UnitPoint(x: 0.2, y: 0.2))) == .zoomed(factor: 1, centre: UnitPoint(x: 0.5, y: 0.5)))
        #expect(small.normalized(.zoomed(factor: 0.5, centre: UnitPoint(x: 0.2, y: 0.2))).factor == 1)
        #expect(small.normalized(.zoomed(factor: 2, centre: UnitPoint(x: 0.2, y: 0.2))) == .fit)
    }

    @Test func zoomIsClampedFromFitTo400Percent() {
        #expect(geometry.clampedFactor(10) == 4)
        #expect(abs(geometry.clampedFactor(0.01) - 0.3) < 1e-9)
        #expect(geometry.normalized(.zoomed(factor: 0.2, centre: UnitPoint(x: 0.9, y: 0.9))) == .fit)
    }

    @Test func centreStaysInsideThePhoto() {
        let zoom = geometry.normalized(.zoomed(factor: 1, centre: UnitPoint(x: 0.01, y: 0.99)))
        let centre = zoom.centre!
        #expect(abs(centre.x - 1.0 / 6) < 1e-9)  // half of a third of the width
        #expect(abs(centre.y - 0.85) < 1e-9)  // 1 - half of 0.3
        let rect = geometry.visibleRect(zoom)
        #expect(rect.x >= -1e-9 && rect.maxY <= 1 + 1e-9)
    }

    @Test func zoomingKeepsTheAnchorStill() {
        let start = LoupeZoom.zoomed(factor: 1, centre: UnitPoint(x: 0.5, y: 0.5))
        let anchor = UnitPoint(x: 0.6, y: 0.55)
        let zoomed = geometry.zoom(start, to: 2, keeping: anchor)
        // The anchor's distance from the centre, in device pixels, is unchanged.
        let before = (anchor.x - 0.5) * 6000 * 1
        let after = (anchor.x - zoomed.centre!.x) * 6000 * 2
        #expect(abs(before - after) < 1e-6)
        #expect(zoomed.factor == 2)
        // Zooming out past fit lands on fit.
        #expect(geometry.zoom(zoomed, to: 0.1, keeping: anchor) == .fit)
    }

    @Test func zoomingInFromFitAnchorsAtTheCursor() {
        let zoomed = geometry.zoom(.fit, to: 1, keeping: UnitPoint(x: 0.25, y: 0.5))
        // From fit (factor 0.3) to 1 the anchor pulls the centre towards it.
        #expect(zoomed.centre!.x < 0.5 && zoomed.centre!.x > 0.25)
    }

    @Test func theFullImageIsNeededOnlyBeyondWhatTheScreenImageHolds() {
        // A 2560-pixel screen image of a 6000-pixel photo is sharp up to about 43%.
        #expect(!geometry.needsLargerImage(factor: 0.3, availableLongSide: 2560))
        #expect(!geometry.needsLargerImage(factor: 0.43, availableLongSide: 2560))
        #expect(geometry.needsLargerImage(factor: 1, availableLongSide: 2560))
        // A screen image as large as the photo is the photo.
        #expect(!geometry.needsLargerImage(factor: 4, availableLongSide: 6000))
    }
}

@Suite("Loupe targets and overlays")
struct LoupeTargetTests {
    /// Three faces: a closed-eyed one on the right, an open one on the left, and a small
    /// background face.
    func scores() -> PhotoScores {
        var scores = PhotoScores(analysedWidth: 1000, analysedHeight: 1000)
        scores.faces = [
            FaceScores(box: UnitRect(x: 0.6, y: 0.2, width: 0.2, height: 0.2), sizeFraction: 0.2, leftEyeOpenness: 0.1, rightEyeOpenness: 0.12, sharpness: 40),
            FaceScores(box: UnitRect(x: 0.1, y: 0.3, width: 0.2, height: 0.2), sizeFraction: 0.2, leftEyeOpenness: 0.4, rightEyeOpenness: 0.38, sharpness: 60, sharpnessPeak: UnitPoint(x: 0.2, y: 0.38)),
            FaceScores(box: UnitRect(x: 0.45, y: 0.7, width: 0.03, height: 0.03), sizeFraction: 0.03, leftEyeOpenness: 0.4, rightEyeOpenness: 0.4),
        ]
        scores.subjectPeak = UnitPoint(x: 0.5, y: 0.5)
        return scores
    }

    @Test func eyesClosedZoomsToTheWorstEyes() {
        let scores = scores()
        let summary = scores.summary(tuning: Tuning())
        #expect(summary.worstEyesFace == 0)
        let target = LoupeTarget.zoomTarget(scores: scores, summary: summary, group: .eyesClosed)
        #expect(target.face == 0)
        #expect(abs(target.point.x - 0.7) < 1e-9 && abs(target.point.y - 0.28) < 1e-9)
    }

    @Test func otherGroupsZoomToTheFocusPoint() {
        let scores = scores()
        let summary = scores.summary(tuning: Tuning())
        let target = LoupeTarget.zoomTarget(scores: scores, summary: summary, group: .allPhotos)
        // Faces take priority: the sharpest main face's peak, which lies in face 1.
        #expect(target.point == UnitPoint(x: 0.2, y: 0.38))
        #expect(target.face == 1)
    }

    @Test func withoutScoresTheMiddle() {
        let target = LoupeTarget.zoomTarget(scores: nil, summary: nil, group: .eyesClosed)
        #expect(target.point == UnitPoint(x: 0.5, y: 0.5))
        #expect(target.face == nil)
    }

    @Test func tabStepsThroughMainFacesLeftToRight() {
        let scores = scores()
        let summary = scores.summary(tuning: Tuning())
        let order = LoupeTarget.faceOrder(scores: scores, summary: summary)
        #expect(order == [1, 0])  // the background face is not a main face
        #expect(LoupeTarget.step(from: nil, in: order, forward: true) == 1)
        #expect(LoupeTarget.step(from: 1, in: order, forward: true) == 0)
        #expect(LoupeTarget.step(from: 0, in: order, forward: true) == 1)
        #expect(LoupeTarget.step(from: 1, in: order, forward: false) == 0)
        #expect(LoupeTarget.step(from: nil, in: order, forward: false) == 0)
        #expect(LoupeTarget.step(from: nil, in: [], forward: true) == nil)
    }

    @Test func eyeStateFollowsTheTuning() {
        let faces = scores().faces
        var tuning = Tuning()
        #expect(LoupeTarget.eyesLookClosed(faces[0], tuning: tuning) == true)
        #expect(LoupeTarget.eyesLookClosed(faces[1], tuning: tuning) == false)
        tuning.eyesClosedBelow = 0.05
        #expect(LoupeTarget.eyesLookClosed(faces[0], tuning: tuning) == false)
        #expect(LoupeTarget.eyesLookClosed(FaceScores(box: .full, sizeFraction: 0.5), tuning: tuning) == nil)
    }

    @Test func overlaysFollowTheGroupUntilToggled() {
        var overlays = LoupeOverlays()
        #expect(overlays.showsFaceBoxes(in: .eyesClosed))
        #expect(!overlays.showsFaceBoxes(in: .allPhotos))
        #expect(overlays.showsClipping(in: .exposure))
        #expect(!overlays.showsClipping(in: .eyesClosed))
        overlays.toggleFaceBoxes(in: .eyesClosed)
        #expect(!overlays.showsFaceBoxes(in: .eyesClosed))
        overlays.toggleClipping(in: .allPhotos)
        #expect(overlays.showsClipping(in: .allPhotos))
        overlays.groupChanged()
        #expect(overlays == LoupeOverlays())
    }
}
