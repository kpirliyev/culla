import CullaCore
import Foundation
import Testing

@Suite("FaceScores")
struct FaceScoresTests {
    private func face(left: Double?, right: Double?) -> FaceScores {
        FaceScores(box: .full, sizeFraction: 0.5, leftEyeOpenness: left, rightEyeOpenness: right)
    }

    @Test func bothEyesWithoutCountingWinksTakesTheMoreOpenEye() {
        #expect(face(left: 0.05, right: 0.35).eyeOpenness(countWinkAsClosed: false) == 0.35)
        #expect(face(left: 0.35, right: 0.05).eyeOpenness(countWinkAsClosed: false) == 0.35)
    }

    @Test func bothEyesCountingWinksTakesTheMoreClosedEye() {
        #expect(face(left: 0.05, right: 0.35).eyeOpenness(countWinkAsClosed: true) == 0.05)
        #expect(face(left: 0.35, right: 0.05).eyeOpenness(countWinkAsClosed: true) == 0.05)
    }

    @Test(arguments: [false, true])
    func oneEyeMissingUsesTheOther(countWinkAsClosed: Bool) {
        #expect(face(left: 0.2, right: nil).eyeOpenness(countWinkAsClosed: countWinkAsClosed) == 0.2)
        #expect(face(left: nil, right: 0.3).eyeOpenness(countWinkAsClosed: countWinkAsClosed) == 0.3)
        #expect(face(left: nil, right: nil).eyeOpenness(countWinkAsClosed: countWinkAsClosed) == nil)
    }

    @Test func blinkFlaggedNeedsBothEyesClosed() {
        var face = FaceScores(box: .full, sizeFraction: 0.5)
        #expect(!face.blinkFlagged)
        face.blinkLeft = true
        #expect(!face.blinkFlagged)
        face.blinkRight = false
        #expect(!face.blinkFlagged)
        face.blinkRight = true
        #expect(face.blinkFlagged)
        face.blinkLeft = nil
        #expect(!face.blinkFlagged)
    }
}

@Suite("FeatureVector")
struct FeatureVectorTests {
    @Test func roundTrip() {
        let values: [Float] = [0, 1, -1, 0.5, .pi, -.greatestFiniteMagnitude, .leastNonzeroMagnitude, 1e-20]
        let data = FeatureVector.encode(values)
        #expect(data.count == values.count * MemoryLayout<Float>.stride)
        #expect(FeatureVector.decode(data) == values)
    }

    @Test func emptyRoundTrip() {
        #expect(FeatureVector.decode(FeatureVector.encode([])).isEmpty)
    }

    @Test func decodesFromADataSlice() {
        // Data slices keep their parent's indices; decoding must not assume they start at zero.
        let values: [Float] = [3, 4, 5]
        let padded = Data([0xFF]) + FeatureVector.encode(values)
        #expect(FeatureVector.decode(padded.dropFirst()) == values)
    }

    @Test func photoScoresExposeTheDecodedVector() {
        var scores = PhotoScores(analysedWidth: 10, analysedHeight: 10)
        #expect(scores.featureVector == nil)
        scores.featurePrint = FeatureVector.encode([1, 2, 3])
        #expect(scores.featureVector == [1, 2, 3])
    }
}

@Suite("PhotoRecord")
struct PhotoRecordTests {
    private let modified = Date(timeIntervalSince1970: 1_700_000_000)

    private func record(captureDate: Date?) -> PhotoRecord {
        let file = PhotoFile(
            id: "a.jpg",
            url: URL(fileURLWithPath: "/tmp/a.jpg"),
            fileSize: 1,
            modificationDate: modified,
            isRAW: false
        )
        return PhotoRecord(file: file, metadata: PhotoMetadata(captureDate: captureDate), scores: nil)
    }

    @Test func sortDatePrefersTheCaptureDate() {
        let captured = Date(timeIntervalSince1970: 1_600_000_000)
        #expect(record(captureDate: captured).sortDate == captured)
    }

    @Test func sortDateFallsBackToTheModificationDate() {
        #expect(record(captureDate: nil).sortDate == modified)
    }

    @Test func idAndNameComeFromTheFile() {
        let record = record(captureDate: nil)
        #expect(record.id == "a.jpg")
        #expect(record.file.name == "a.jpg")
    }
}

@Suite("StageTimings")
struct StageTimingsTests {
    @Test func totalAddsTheStages() {
        #expect(StageTimings(decode: 0.25, pixels: 0.5, vision: 1).total == 1.75)
    }
}
