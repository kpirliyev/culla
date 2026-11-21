import CullaAnalysis
import CullaCore
import Testing

@Suite("PhotoScores.summary")
struct PhotoSummaryTests {
    private func face(
        size: Double,
        yaw: Double = 0,
        left: Double? = 0.3,
        right: Double? = 0.3,
        sharpness: Double? = nil,
        peak: UnitPoint? = nil,
        blink: Bool = false,
        cut: Bool = false,
        box: UnitRect = UnitRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
    ) -> FaceScores {
        FaceScores(
            box: box,
            sizeFraction: size,
            leftEyeOpenness: left,
            rightEyeOpenness: right,
            blinkLeft: blink,
            blinkRight: blink,
            yawDegrees: yaw,
            sharpness: sharpness,
            edgeStrength: sharpness.map { $0 / 2 },
            sharpnessPeak: peak,
            isCutByEdge: cut
        )
    }

    private func scores(_ faces: [FaceScores]) -> PhotoScores {
        var scores = PhotoScores(analysedWidth: 1000, analysedHeight: 800)
        scores.faces = faces
        scores.subjectSharpness = 12
        scores.subjectEdgeStrength = 3
        scores.subjectPeak = UnitPoint(x: 0.2, y: 0.8)
        return scores
    }

    @Test func noFacesFallsBackToTheSubject() {
        let summary = scores([]).summary(tuning: Tuning())
        #expect(summary.mainFaces.isEmpty)
        #expect(summary.eyeOpenness == nil && summary.worstEyesFace == nil)
        #expect(summary.blurScore == 12 && summary.edgeStrength == 3)
        #expect(summary.focusPoint == UnitPoint(x: 0.2, y: 0.8))
        #expect(summary.faceSharpness == nil)
        #expect(!summary.blinkFlagged && !summary.hasFaceCutByEdge)
    }

    @Test func mainFacesAreChosenBySizeBackgroundRatioAndYaw() {
        let faces = [
            face(size: 0.30),            // largest: main
            face(size: 0.15),            // half the largest: main (ratio 0.4)
            face(size: 0.10),            // a third of the largest: background
            face(size: 0.25, yaw: 55),   // a profile: skipped
            face(size: 0.20, yaw: -39),  // turned, but within the limit: main
        ]
        #expect(scores(faces).summary(tuning: Tuning()).mainFaces == [0, 1, 4])
    }

    @Test func minimumFaceSizeApplies() {
        // The largest face is itself below the minimum, so nothing is checked.
        let faces = [face(size: 0.03), face(size: 0.02)]
        #expect(scores(faces).summary(tuning: Tuning()).mainFaces.isEmpty)

        var tuning = Tuning()
        tuning.minFaceFraction = 0.01
        #expect(scores(faces).summary(tuning: tuning).mainFaces == [0, 1])
    }

    @Test func aProfileDoesNotSetTheBackgroundScale() {
        // A large side-on face near the camera is skipped, and the frontal faces behind it,
        // a fifth of its size, still count: the scale comes from the largest frontal face.
        let faces = [face(size: 0.5, yaw: 80), face(size: 0.1), face(size: 0.08, yaw: -20)]
        #expect(scores(faces).summary(tuning: Tuning()).mainFaces == [1, 2])
    }

    @Test func backgroundScaleComesFromTheLargestFrontalFace() {
        // Largest frontal face 0.3: a 0.1 face is under 40 % of it and counts as background,
        // whatever the profile at 0.6 does.
        let faces = [face(size: 0.6, yaw: -70), face(size: 0.3), face(size: 0.1), face(size: 0.15, yaw: 40)]
        #expect(scores(faces).summary(tuning: Tuning()).mainFaces == [1, 3])
    }

    @Test func noFrontalFaceMeansNoMainFaces() {
        let faces = [face(size: 0.5, yaw: 80, left: 0.01, right: 0.01, blink: true, cut: true), face(size: 0.3, yaw: -45)]
        let summary = scores(faces).summary(tuning: Tuning())
        #expect(summary.mainFaces.isEmpty)
        #expect(summary.eyeOpenness == nil && !summary.blinkFlagged && !summary.hasFaceCutByEdge)
    }

    @Test func eyeOpennessIsTheLowestAmongMainFaces() {
        let faces = [
            face(size: 0.3, left: 0.35, right: 0.33),
            face(size: 0.2, left: 0.08, right: 0.06),
            face(size: 0.25, left: 0.2, right: nil),
            face(size: 0.05, left: 0.01, right: 0.01), // background: ignored
            face(size: 0.3, yaw: 70, left: 0, right: 0), // profile: ignored
        ]
        let summary = scores(faces).summary(tuning: Tuning())
        #expect(summary.eyeOpenness == 0.08)
        #expect(summary.worstEyesFace == 1)
    }

    @Test func countingWinksChangesWhichFaceIsWorst() {
        let faces = [
            face(size: 0.3, left: 0.02, right: 0.30), // a wink
            face(size: 0.3, left: 0.10, right: 0.12),
        ]
        let lenient = scores(faces).summary(tuning: Tuning())
        #expect(lenient.eyeOpenness == 0.12 && lenient.worstEyesFace == 1)

        var tuning = Tuning()
        tuning.countWinkAsClosed = true
        let strict = scores(faces).summary(tuning: tuning)
        #expect(strict.eyeOpenness == 0.02 && strict.worstEyesFace == 0)
    }

    @Test func facesWithoutEyeReadingsDoNotSetOpenness() {
        let faces = [face(size: 0.3, left: nil, right: nil), face(size: 0.3, left: 0.25, right: 0.2)]
        let summary = scores(faces).summary(tuning: Tuning())
        #expect(summary.eyeOpenness == 0.25 && summary.worstEyesFace == 1)
    }

    @Test func blurUsesTheSharpestMainFaceWhenFacesTakePriority() {
        let faces = [
            face(size: 0.3, sharpness: 40, peak: UnitPoint(x: 0.45, y: 0.45)),
            face(size: 0.3, sharpness: 70, peak: UnitPoint(x: 0.55, y: 0.5)),
            face(size: 0.05, sharpness: 300), // background: ignored even though sharper
        ]
        let summary = scores(faces).summary(tuning: Tuning())
        #expect(summary.faceSharpness == 70)
        #expect(summary.blurScore == 70)
        #expect(summary.edgeStrength == 35)
        #expect(summary.focusPoint == UnitPoint(x: 0.55, y: 0.5))
    }

    @Test func focusPointFallsBackToTheFaceCentre() {
        let box = UnitRect(x: 0.1, y: 0.2, width: 0.2, height: 0.4)
        let summary = scores([face(size: 0.3, sharpness: 50, peak: nil, box: box)]).summary(tuning: Tuning())
        #expect(summary.focusPoint == box.center)
    }

    @Test func blurUsesTheSubjectWhenFacesDoNotTakePriority() {
        var tuning = Tuning()
        tuning.facesTakePriority = false
        let faces = [face(size: 0.3, sharpness: 70, peak: UnitPoint(x: 0.55, y: 0.5))]
        let summary = scores(faces).summary(tuning: tuning)
        #expect(summary.faceSharpness == 70)
        #expect(summary.blurScore == 12)
        #expect(summary.edgeStrength == 3)
        #expect(summary.focusPoint == UnitPoint(x: 0.2, y: 0.8))
    }

    @Test func mainFacesWithoutSharpnessLeaveTheSubjectInCharge() {
        let summary = scores([face(size: 0.3, sharpness: nil)]).summary(tuning: Tuning())
        #expect(summary.faceSharpness == nil)
        #expect(summary.blurScore == 12)
    }

    @Test func cutByEdgeAndBlinkOnlyCountForMainFaces() {
        let background = [face(size: 0.3), face(size: 0.05, blink: true, cut: true)]
        let quiet = scores(background).summary(tuning: Tuning())
        #expect(!quiet.blinkFlagged && !quiet.hasFaceCutByEdge)

        let profile = [face(size: 0.3), face(size: 0.3, yaw: 60, blink: true, cut: true)]
        let alsoQuiet = scores(profile).summary(tuning: Tuning())
        #expect(!alsoQuiet.blinkFlagged && !alsoQuiet.hasFaceCutByEdge)

        let main = [face(size: 0.3), face(size: 0.25, blink: true, cut: true)]
        let flagged = scores(main).summary(tuning: Tuning())
        #expect(flagged.blinkFlagged && flagged.hasFaceCutByEdge)
    }
}
