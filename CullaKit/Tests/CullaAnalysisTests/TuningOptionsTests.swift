import CullaAnalysis
import CullaCore
import Foundation
import Testing

/// The Settings rows added in M5 that are not thresholds: which faces count, the group photo rule,
/// where sharpness is measured, burst data and the two kinds of duplicates. Each one's default
/// keeps the behaviour from before it existed.
@Suite("Tuning options")
struct TuningOptionsTests {
    private func face(_ eyes: Double, size: Double = 0.2, yaw: Double = 0, x: Double = 0.1) -> FaceScores {
        FaceScores(box: UnitRect(x: x, y: 0.3, width: size, height: size), sizeFraction: size,
                   leftEyeOpenness: eyes, rightEyeOpenness: eyes, yawDegrees: yaw)
    }

    private func scores(_ faces: [FaceScores], subject: Double = 60, frame: Double = 60) -> PhotoScores {
        var scores = PhotoScores(analysedWidth: 1000, analysedHeight: 1000)
        scores.faces = faces
        scores.subjectSharpness = subject
        scores.frameSharpness = frame
        return scores
    }

    @Test func newOptionsDefaultToTheOldBehaviour() throws {
        let tuning = Tuning()
        #expect(tuning.ignoreBackgroundFaces && tuning.skipProfiles && tuning.useBurstData)
        #expect(tuning.findExactDuplicates && tuning.findNearDuplicates)
        #expect(tuning.groupPhotoRule == .anyMainFace && tuning.sharpnessArea == .subject)
        // A file written before these existed, and one naming a rule a later version added.
        let old = try JSONDecoder().decode(Tuning.self, from: Data(#"{"blurryBelow": 20}"#.utf8))
        #expect(old.ignoreBackgroundFaces && old.groupPhotoRule == .anyMainFace && old.blurryBelow == 20)
        let future = try JSONDecoder().decode(Tuning.self, from: Data(#"{"groupPhotoRule": "twoFaces", "blurryBelow": 21}"#.utf8))
        #expect(future.groupPhotoRule == .anyMainFace && future.blurryBelow == 21)
        var changed = Tuning()
        changed.groupPhotoRule = .mostFaces
        changed.sharpnessArea = .wholeFrame
        changed.findNearDuplicates = false
        #expect(try JSONDecoder().decode(Tuning.self, from: JSONEncoder().encode(changed)) == changed)
    }

    @Test func theGroupPhotoRulePicksWhichFaceDecides() {
        // Three main faces: two shut, one open.
        let photo = scores([face(0.05, x: 0.1), face(0.10, x: 0.4), face(0.40, x: 0.7)])
        var tuning = Tuning()
        #expect(photo.summary(tuning: tuning).flags.contains(.eyesClosed))
        #expect(photo.summary(tuning: tuning).worstEyesFace == 0)
        tuning.groupPhotoRule = .mostFaces
        #expect(photo.summary(tuning: tuning).flags.contains(.eyesClosed))
        #expect(photo.summary(tuning: tuning).eyeOpenness == 0.10)
        tuning.groupPhotoRule = .allFaces
        #expect(!photo.summary(tuning: tuning).flags.contains(.eyesClosed))
        // One of two shut is not most.
        let pair = scores([face(0.05, x: 0.1), face(0.40, x: 0.5)])
        tuning.groupPhotoRule = .mostFaces
        #expect(!pair.summary(tuning: tuning).flags.contains(.eyesClosed))
    }

    @Test func backgroundFacesAndProfilesCanBeCounted() {
        // A large open face, a small shut one behind, and a shut profile.
        let photo = scores([face(0.40, size: 0.30), face(0.05, size: 0.06, x: 0.6), face(0.05, size: 0.25, yaw: 70, x: 0.3)])
        var tuning = Tuning()
        #expect(photo.summary(tuning: tuning).mainFaces == [0])
        tuning.ignoreBackgroundFaces = false
        #expect(photo.summary(tuning: tuning).mainFaces == [0, 1])
        #expect(photo.summary(tuning: tuning).flags.contains(.eyesClosed))
        tuning = Tuning()
        tuning.skipProfiles = false
        #expect(photo.summary(tuning: tuning).mainFaces == [0, 2])
        tuning.maxYawDegrees = 80
        tuning.skipProfiles = true
        #expect(photo.summary(tuning: tuning).mainFaces == [0, 2])
    }

    @Test func sharpnessCanBeMeasuredOnTheWholeFrame() {
        let photo = scores([], subject: 50, frame: 12)
        var tuning = Tuning()
        #expect(!photo.summary(tuning: tuning).flags.contains(.blurry))
        tuning.sharpnessArea = .wholeFrame
        #expect(photo.summary(tuning: tuning).blurScore == 12)
        #expect(photo.summary(tuning: tuning).tier(of: .blurry) == .certain)
    }

    @Test func burstDataCanBeIgnored() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        // Far apart in time and unlike, but marked as one burst.
        let candidates = [
            StackCandidate(date: start, hasCaptureDate: true, burstID: "B", feature: [0, 0]),
            StackCandidate(date: start.addingTimeInterval(100), hasCaptureDate: true, burstID: "B", feature: [5, 5]),
        ]
        var tuning = Tuning()
        #expect(StackGrouper.group(candidates, tuning: tuning).stacks == [[0, 1]])
        tuning.useBurstData = false
        #expect(StackGrouper.group(candidates, tuning: tuning).stacks.isEmpty)
    }

    @Test func exactAndNearDuplicatesCanEachBeSwitchedOff() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let candidates = [
            DuplicateCandidate(fileSize: 100, captureDate: start, feature: [0, 0]),
            DuplicateCandidate(fileSize: 100, captureDate: start.addingTimeInterval(500), feature: [9, 9]),
            DuplicateCandidate(fileSize: 300, captureDate: start.addingTimeInterval(900), feature: [1, 1]),
            DuplicateCandidate(fileSize: 400, captureDate: start.addingTimeInterval(900), feature: [1.01, 1]),
        ]
        let hash = { (index: Int) -> String? in index < 2 ? "same" : "h\(index)" }
        var tuning = Tuning()
        #expect(DuplicateFinder.find(candidates, tuning: tuning, contentHash: hash).map(\.kind) == [.exact, .near])
        tuning.findExactDuplicates = false
        #expect(DuplicateFinder.find(candidates, tuning: tuning, contentHash: hash).map(\.members) == [[2, 3]])
        tuning = Tuning()
        tuning.findNearDuplicates = false
        #expect(DuplicateFinder.find(candidates, tuning: tuning, contentHash: hash).map(\.members) == [[0, 1]])
    }
}
