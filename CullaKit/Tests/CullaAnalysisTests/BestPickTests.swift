import CullaAnalysis
import CullaCore
import Foundation
import Testing

@Suite("BestPick")
struct BestPickTests {
    private let tuning = Tuning()

    private func frame(
        eyesClosed: Bool = false,
        sharpness: Double = 50,
        faceQuality: Double? = nil,
        aesthetics: Double? = nil
    ) -> BestPickCandidate {
        BestPickCandidate(eyesClosed: eyesClosed, sharpness: sharpness, faceQuality: faceQuality, aesthetics: aesthetics)
    }

    @Test func openEyesBeatClosedEyesWhateverTheSharpness() {
        let frames = [frame(eyesClosed: true, sharpness: 90), frame(sharpness: 30)]
        #expect(BestPick.best(frames, tuning: tuning) == 1)
    }

    @Test func whenEveryFrameHasClosedEyesSharpnessDecides() {
        let frames = [frame(eyesClosed: true, sharpness: 40), frame(eyesClosed: true, sharpness: 60)]
        #expect(BestPick.best(frames, tuning: tuning) == 1)
    }

    @Test func theSharperFrameWins() {
        let frames = [frame(sharpness: 40, faceQuality: 0.9, aesthetics: 0.9), frame(sharpness: 60, faceQuality: 0.1, aesthetics: -0.5)]
        #expect(BestPick.best(frames, tuning: tuning) == 1)
    }

    @Test func withinTheSharpnessMarginFaceQualityDecides() {
        // 60 and 58 lie within the default margin of 3, so the better face wins.
        let frames = [frame(sharpness: 60, faceQuality: 0.4), frame(sharpness: 58, faceQuality: 0.8)]
        #expect(BestPick.best(frames, tuning: tuning) == 1)
        var strict = tuning
        strict.bestPickSharpnessMargin = 0
        #expect(BestPick.best(frames, tuning: strict) == 0)
    }

    @Test func withinTheFaceQualityMarginAestheticsDecides() {
        let frames = [
            frame(sharpness: 60, faceQuality: 0.80, aesthetics: 0.1),
            frame(sharpness: 60, faceQuality: 0.78, aesthetics: 0.5),
            frame(sharpness: 60, faceQuality: 0.50, aesthetics: 0.9),
        ]
        #expect(BestPick.best(frames, tuning: tuning) == 1)
    }

    @Test func aFrameWithoutAFaceRatingLosesToOneWithIt() {
        let frames = [frame(sharpness: 60), frame(sharpness: 60, faceQuality: 0.2)]
        #expect(BestPick.best(frames, tuning: tuning) == 1)
    }

    @Test func tiesGoToTheEarlierFrame() {
        let frames = [frame(sharpness: 60, faceQuality: 0.5, aesthetics: 0.3), frame(sharpness: 60, faceQuality: 0.5, aesthetics: 0.3)]
        #expect(BestPick.best(frames, tuning: tuning) == 0)
        #expect(BestPick.best([frame(), frame(), frame()], tuning: tuning) == 0)
        #expect(BestPick.best([], tuning: tuning) == nil)
    }

    @Test func theMarginIsMeasuredFromTheBestNotFromNeighbours() {
        // 60, 58 and 56: 56 is within 3 of 58 but not of 60, so it is out whatever the order.
        let frames = [frame(sharpness: 56, faceQuality: 0.9), frame(sharpness: 60, faceQuality: 0.3), frame(sharpness: 58, faceQuality: 0.5)]
        #expect(BestPick.best(frames, tuning: tuning) == 2)
    }

    @Test func rankingListsEveryFrameBestFirst() {
        let frames = [
            frame(eyesClosed: true, sharpness: 90),
            frame(sharpness: 20),
            frame(sharpness: 70),
            frame(sharpness: 69, faceQuality: 0.9),
        ]
        #expect(BestPick.ranking(frames, tuning: tuning) == [3, 2, 1, 0])
    }

    @Test func candidatesAreReadFromScoresWithTheCurrentTuning() {
        var scores = PhotoScores(analysedWidth: 1000, analysedHeight: 800)
        scores.subjectSharpness = 12
        scores.aesthetics = 0.4
        scores.faces = [
            FaceScores(box: UnitRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3), sizeFraction: 0.3,
                       leftEyeOpenness: 0.22, rightEyeOpenness: 0.24, captureQuality: 0.6, sharpness: 70),
            FaceScores(box: UnitRect(x: 0.6, y: 0.2, width: 0.3, height: 0.3), sizeFraction: 0.3,
                       leftEyeOpenness: 0.4, rightEyeOpenness: 0.4, captureQuality: 0.8, sharpness: 50),
        ]
        let candidate = BestPickCandidate(scores: scores, tuning: tuning)
        #expect(candidate.eyesClosed)
        #expect(candidate.sharpness == 70)
        #expect(abs((candidate.faceQuality ?? 0) - 0.7) < 1e-9)
        #expect(candidate.aesthetics == 0.4)

        var lenient = tuning
        lenient.eyesClosedBelow = 0.2
        #expect(!BestPickCandidate(scores: scores, tuning: lenient).eyesClosed)
    }

    @Test func theMarginsAreTuningValuesThatSurviveCoding() throws {
        var tuning = Tuning()
        tuning.bestPickSharpnessMargin = 7
        tuning.bestPickFaceQualityMargin = 0.2
        let decoded = try JSONDecoder().decode(Tuning.self, from: JSONEncoder().encode(tuning))
        #expect(decoded == tuning)
        let old = try JSONDecoder().decode(Tuning.self, from: Data("{}".utf8))
        #expect(old.bestPickSharpnessMargin == 3 && old.bestPickFaceQualityMargin == 0.05)
    }
}
