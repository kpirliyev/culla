import CullaAnalysis
import CullaCore
import Foundation
import Testing

@Suite("Tuning")
struct TuningTests {
    @Test func defaultsAreTheChosenThresholds() {
        let tuning = Tuning()
        #expect(tuning.eyesClosedBelow == 0.26)
        #expect(tuning.blurryBelow == 25)
        #expect(tuning.clippedHighlightsAbove == 0.30)
        #expect(tuning.clippedShadowsAbove == 0.50)
        #expect(tuning.lowAestheticsBelow == 0.30)
        #expect(tuning.stackGapSeconds == 10)
        #expect(tuning.stackDistance == 0.60)
        #expect(tuning.nearDuplicateDistance == 0.08)
        #expect(tuning.eyesClosedCertainBelow == 0.20)
        #expect(tuning.blurryCertainBelow == 15)
        #expect(tuning.tiltedHorizonAboveDegrees == 3)
        #expect(tuning.lensSmudgeAbove == 0.5)
        #expect(!tuning.flagTiltedHorizon)
        #expect(tuning.flagCutOffFaces && tuning.flagLensSmudge && tuning.flagUtility)
        #expect(tuning.flagLowAesthetics && tuning.flagExposure)
    }

    @Test func settingsFromAnOlderBuildLoadWithDefaultsForNewKeys() throws {
        // What a build before the flag thresholds wrote, with the stack settings changed.
        let json = """
            {"backgroundFaceRatio":0.4,"facesTakePriority":true,"stackGapSeconds":3,"maxYawDegrees":40,
             "minStackSize":2,"minFaceFraction":0.04,"stackDistance":0.45,"countWinkAsClosed":false,
             "nearDuplicateDistance":0.08}
            """
        let tuning = try JSONDecoder().decode(Tuning.self, from: Data(json.utf8))
        #expect(tuning.stackGapSeconds == 3)
        #expect(tuning.stackDistance == 0.45)
        #expect(tuning.eyesClosedBelow == 0.26)
        #expect(tuning.blurryBelow == 25)
        #expect(tuning.clippedHighlightsAbove == 0.30)
        #expect(tuning.clippedShadowsAbove == 0.50)
        #expect(tuning.lowAestheticsBelow == 0.30)
    }

    @Test func anEmptyObjectGivesTheDefaults() throws {
        #expect(try JSONDecoder().decode(Tuning.self, from: Data("{}".utf8)) == Tuning())
    }

    @Test func roundTripKeepsEverySetting() throws {
        var tuning = Tuning()
        tuning.minFaceFraction = 0.05
        tuning.backgroundFaceRatio = 0.3
        tuning.maxYawDegrees = 30
        tuning.countWinkAsClosed = true
        tuning.facesTakePriority = false
        tuning.eyesClosedBelow = 0.2
        tuning.blurryBelow = 30
        tuning.clippedHighlightsAbove = 0.1
        tuning.clippedShadowsAbove = 0.2
        tuning.lowAestheticsBelow = -0.1
        tuning.stackGapSeconds = 4
        tuning.stackDistance = 0.5
        tuning.minStackSize = 3
        tuning.nearDuplicateDistance = 0.05
        tuning.eyesClosedCertainBelow = 0.1
        tuning.blurryCertainBelow = 9
        tuning.tiltedHorizonAboveDegrees = 5
        tuning.lensSmudgeAbove = 0.7
        tuning.flagTiltedHorizon = true
        tuning.flagCutOffFaces = false
        tuning.flagLensSmudge = false
        tuning.flagUtility = false
        tuning.flagLowAesthetics = false
        tuning.flagExposure = false
        let decoded = try JSONDecoder().decode(Tuning.self, from: JSONEncoder().encode(tuning))
        #expect(decoded == tuning)
    }

    @Test func aWrongTypeStillFails() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Tuning.self, from: Data(#"{"blurryBelow":"soft"}"#.utf8))
        }
    }
}

@Suite("PhotoFlag")
struct PhotoFlagTests {
    /// A photo that raises no flag under the default thresholds, with one main face.
    private func scores(
        openness: Double? = 0.4,
        faceSharpness: Double = 80,
        highlights: Double = 0,
        shadows: Double = 0,
        aesthetics: Double? = 0.6
    ) -> PhotoScores {
        var scores = PhotoScores(analysedWidth: 1000, analysedHeight: 800)
        scores.faces = [
            FaceScores(
                box: UnitRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2),
                sizeFraction: 0.3,
                leftEyeOpenness: openness,
                rightEyeOpenness: openness,
                sharpness: faceSharpness
            ),
        ]
        scores.subjectSharpness = 90
        scores.clippedHighlights = highlights
        scores.clippedShadows = shadows
        scores.aesthetics = aesthetics
        return scores
    }

    private func flags(_ scores: PhotoScores, _ tuning: Tuning = Tuning()) -> Set<PhotoFlag> {
        scores.summary(tuning: tuning).flags
    }

    @Test func aGoodPhotoHasNoFlags() {
        #expect(flags(scores()).isEmpty)
    }

    @Test func eyesClosedIsStrictlyBelowTheThreshold() {
        #expect(flags(scores(openness: 0.26)) == [])
        #expect(flags(scores(openness: 0.2599)) == [.eyesClosed])
        #expect(flags(scores(openness: 0.2601)) == [])
    }

    @Test func noEyeReadingIsNeverFlaggedEyesClosed() {
        #expect(flags(scores(openness: nil)).isEmpty)
        var tuning = Tuning()
        tuning.eyesClosedBelow = 10
        #expect(!flags(scores(openness: nil), tuning).contains(.eyesClosed))
        // Nor is a photo without faces.
        var noFaces = scores()
        noFaces.faces = []
        #expect(!flags(noFaces, tuning).contains(.eyesClosed))
    }

    @Test func eyesClosedFollowsTheWinkSetting() {
        var wink = scores()
        wink.faces[0].leftEyeOpenness = 0.05
        #expect(flags(wink) == [])
        var tuning = Tuning()
        tuning.countWinkAsClosed = true
        #expect(flags(wink, tuning) == [.eyesClosed])
    }

    @Test func blurryIsStrictlyBelowTheThreshold() {
        #expect(flags(scores(faceSharpness: 25)) == [])
        #expect(flags(scores(faceSharpness: 24.99)) == [.blurry])
        #expect(flags(scores(faceSharpness: 25.01)) == [])
    }

    @Test func blurryUsesTheBlurScoreTheSummaryChose() {
        // Judged on the subject (90) when faces do not take priority, so a soft face is not enough.
        var tuning = Tuning()
        tuning.facesTakePriority = false
        #expect(flags(scores(faceSharpness: 5), tuning) == [])
        #expect(flags(scores(faceSharpness: 5)) == [.blurry])
    }

    @Test func clippedHighlightsAreStrictlyAboveTheThreshold() {
        #expect(flags(scores(highlights: 0.30)) == [])
        #expect(flags(scores(highlights: 0.3001)) == [.clippedHighlights])
        #expect(flags(scores(highlights: 0.2999)) == [])
    }

    @Test func clippedShadowsAreStrictlyAboveTheThreshold() {
        #expect(flags(scores(shadows: 0.50)) == [])
        #expect(flags(scores(shadows: 0.5001)) == [.clippedShadows])
        #expect(flags(scores(shadows: 0.4999)) == [])
    }

    @Test func lowAestheticsIsStrictlyBelowTheThreshold() {
        #expect(flags(scores(aesthetics: 0.30)) == [])
        #expect(flags(scores(aesthetics: 0.2999)) == [.lowAesthetics])
        #expect(flags(scores(aesthetics: 0.3001)) == [])
    }

    @Test func noAestheticsScoreIsNeverFlagged() {
        var tuning = Tuning()
        tuning.lowAestheticsBelow = 1
        #expect(flags(scores(aesthetics: nil), tuning).isEmpty)
    }

    @Test func thresholdsComeFromTheTuning() {
        var tuning = Tuning()
        tuning.eyesClosedBelow = 0.5
        tuning.blurryBelow = 100
        tuning.clippedHighlightsAbove = 0
        tuning.clippedShadowsAbove = 0
        tuning.lowAestheticsBelow = 0.9
        tuning.flagTiltedHorizon = true
        tuning.tiltedHorizonAboveDegrees = 0
        tuning.lensSmudgeAbove = 0
        var photo = scores(highlights: 0.01, shadows: 0.01)
        photo.horizonDegrees = 1
        photo.smudgeConfidence = 0.1
        photo.isUtility = true
        photo.faces[0].isCutByEdge = true
        #expect(flags(photo, tuning) == Set(PhotoFlag.allCases))
    }

    @Test func flagsCanCombine() {
        #expect(flags(scores(openness: 0.1, faceSharpness: 10, shadows: 0.6)) == [.eyesClosed, .blurry, .clippedShadows])
    }
}

@Suite("Other issues and tiers")
struct OtherIssuesAndTierTests {
    private func scores(
        openness: Double? = 0.4,
        sharpness: Double = 80,
        horizon: Double? = nil,
        smudge: Double? = nil,
        utility: Bool? = nil,
        cut: Bool = false
    ) -> PhotoScores {
        var scores = PhotoScores(analysedWidth: 1000, analysedHeight: 800)
        scores.faces = [
            FaceScores(
                box: UnitRect(x: cut ? 0 : 0.4, y: 0.4, width: 0.2, height: 0.2),
                sizeFraction: 0.3,
                leftEyeOpenness: openness,
                rightEyeOpenness: openness,
                sharpness: sharpness,
                isCutByEdge: cut
            ),
        ]
        scores.subjectSharpness = 90
        scores.aesthetics = 0.6
        scores.horizonDegrees = horizon
        scores.smudgeConfidence = smudge
        scores.isUtility = utility
        return scores
    }

    private func summary(_ scores: PhotoScores, _ change: (inout Tuning) -> Void = { _ in }) -> PhotoSummary {
        var tuning = Tuning()
        change(&tuning)
        return scores.summary(tuning: tuning)
    }

    @Test func tiltedHorizonIsOffByDefault() {
        #expect(summary(scores(horizon: 10)).flags.isEmpty)
        let on = { (tuning: inout Tuning) in tuning.flagTiltedHorizon = true }
        #expect(summary(scores(horizon: 3), on).flags.isEmpty)
        #expect(summary(scores(horizon: 3.1), on).flags == [.tiltedHorizon])
        #expect(summary(scores(horizon: -3.1), on).flags == [.tiltedHorizon])
        // A line tilted by 178 degrees is a line tilted by 2.
        #expect(summary(scores(horizon: 178), on).flags.isEmpty)
        #expect(summary(scores(horizon: nil), on).flags.isEmpty)
    }

    @Test func aMainFaceCutByTheEdge() {
        #expect(summary(scores(cut: true)).flags == [.faceCutOff])
        #expect(summary(scores(cut: true)) { $0.flagCutOffFaces = false }.flags.isEmpty)
        // A background face cut by the edge does not count.
        var background = scores()
        background.faces.append(FaceScores(box: UnitRect(x: 0, y: 0, width: 0.05, height: 0.05), sizeFraction: 0.05, isCutByEdge: true))
        #expect(summary(background).flags.isEmpty)
    }

    @Test func lensSmudgeIsStrictlyAboveTheThreshold() {
        #expect(summary(scores(smudge: 0.5)).flags.isEmpty)
        #expect(summary(scores(smudge: 0.51)).flags == [.lensSmudge])
        #expect(summary(scores(smudge: 0.9)) { $0.flagLensSmudge = false }.flags.isEmpty)
    }

    @Test func utilityImages() {
        #expect(summary(scores(utility: true)).flags == [.utility])
        #expect(summary(scores(utility: false)).flags.isEmpty)
        #expect(summary(scores(utility: true)) { $0.flagUtility = false }.flags.isEmpty)
    }

    @Test func exposureAndAestheticsCanBeSwitchedOff() {
        var photo = scores()
        photo.clippedHighlights = 0.9
        photo.clippedShadows = 0.9
        photo.aesthetics = -0.5
        #expect(summary(photo).flags == [.clippedHighlights, .clippedShadows, .lowAesthetics])
        #expect(summary(photo) { $0.flagExposure = false }.flags == [.lowAesthetics])
        #expect(summary(photo) { $0.flagLowAesthetics = false }.flags == [.clippedHighlights, .clippedShadows])
    }

    @Test func eyesClosedTiers() {
        #expect(summary(scores(openness: 0.25)).tier(of: .eyesClosed) == .likely)
        #expect(summary(scores(openness: 0.20)).tier(of: .eyesClosed) == .likely)
        #expect(summary(scores(openness: 0.199)).tier(of: .eyesClosed) == .certain)
        #expect(summary(scores(openness: 0.4)).tier(of: .eyesClosed) == nil)
    }

    @Test func blurryTiers() {
        #expect(summary(scores(sharpness: 24)).tier(of: .blurry) == .likely)
        #expect(summary(scores(sharpness: 15)).tier(of: .blurry) == .likely)
        #expect(summary(scores(sharpness: 14.9)).tier(of: .blurry) == .certain)
        #expect(summary(scores(sharpness: 14.9)) { $0.blurryCertainBelow = 10 }.tier(of: .blurry) == .likely)
    }

    @Test func otherFlagsAreAlwaysLikely() {
        var photo = scores(smudge: 1, utility: true, cut: true)
        photo.clippedHighlights = 1
        let result = summary(photo)
        #expect(result.tiers == [.faceCutOff: .likely, .lensSmudge: .likely, .utility: .likely, .clippedHighlights: .likely])
    }

    @Test func tiersHoldExactlyTheFlags() {
        let result = summary(scores(openness: 0.1, sharpness: 5, smudge: 1))
        #expect(Set(result.tiers.keys) == result.flags)
        #expect(FlagTier.certain < FlagTier.likely)
    }
}
