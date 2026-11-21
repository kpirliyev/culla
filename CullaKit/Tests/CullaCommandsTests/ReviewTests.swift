import CullaAnalysis
import CullaCommands
import CullaCore
import CullaSession
import Foundation
import Testing

/// A session of photos one minute apart with made-up scores: `blur` sets the sharpness, `eyes`
/// a face with that openness, `clipping` the clipped highlights.
private func session(_ specs: [(id: String, blur: Double, eyes: Double?, clipping: Double)]) -> SessionState {
    let start = Date(timeIntervalSince1970: 1_000_000)
    let items = specs.enumerated().map { index, spec -> PhotoItem in
        let file = PhotoFile(
            id: spec.id, url: URL(fileURLWithPath: "/shoot/\(spec.id)"), fileSize: Int64(1000 + index),
            modificationDate: start, isRAW: false
        )
        var scores = PhotoScores(analysedWidth: 1000, analysedHeight: 1000)
        scores.subjectSharpness = spec.blur
        scores.clippedHighlights = spec.clipping
        if let eyes = spec.eyes {
            scores.faces = [FaceScores(box: UnitRect(x: 0.4, y: 0.3, width: 0.2, height: 0.2), sizeFraction: 0.2,
                                       leftEyeOpenness: eyes, rightEyeOpenness: eyes)]
        }
        let metadata = PhotoMetadata(captureDate: start.addingTimeInterval(Double(index) * 60), pixelWidth: 1000, pixelHeight: 1000)
        return PhotoItem(file: file, metadata: metadata, scores: scores)
    }
    return SessionState(photos: items)
}

@Suite("Review order and openings")
struct ReviewOrderTests {
    @Test func groupsOpenWhereTheDesignSays() {
        #expect(GroupID.eyesClosed.opening == .loupe(.closedEyes))
        #expect(GroupID.blurry.opening == .loupe(.focusPoint))
        #expect(GroupID.exposure.opening == .loupe(.clipping))
        #expect(GroupID.otherIssues.opening == .loupe(.none))
        #expect(GroupID.unreviewed.opening == .loupe(.none))
        #expect(GroupID.duplicates.opening == .duplicateReview)
        #expect(GroupID.similarStacks.opening == .stackReview)
        #expect(GroupID.similarStacks.opening.opensReview && !GroupID.similarStacks.opening.opensLoupe)
        for group in [GroupID.allPhotos, .kept, .rejected] {
            #expect(group.opening == .grid, "\(group)")
        }
        #expect(GroupID.eyesClosed.opening.zoomsToEvidence)
        #expect(GroupID.blurry.opening.zoomsToEvidence)
        #expect(!GroupID.exposure.opening.zoomsToEvidence)
    }

    @Test func startReviewingSkipsGroupsWithNothingLeft() {
        var state = session([
            ("a", 60, nil, 0), ("b", 10, nil, 0), ("c", 60, nil, 0.5),
        ])
        // No faces, so Eyes Closed is empty and skipped; Blurry comes first.
        #expect(ReviewGuide.firstGroupToReview(in: state) == .blurry)
        state.apply(.setDecision(.rejected, ids: ["b"]))
        #expect(ReviewGuide.firstGroupToReview(in: state) == .exposure)
        #expect(ReviewGuide.nextGroupToReview(after: .blurry, in: state) == .exposure)
        // After the last defect group, the sweep of everything unreviewed.
        #expect(ReviewGuide.nextGroupToReview(after: .exposure, in: state) == .unreviewed)
        state.apply(.setDecision(.kept, ids: ["a", "c"]))
        #expect(ReviewGuide.firstGroupToReview(in: state) == nil)
        #expect(ReviewGuide.nextGroupToReview(after: .exposure, in: state) == nil)
    }

    @Test func tuningIsOfferedForGroupsItChanges() {
        #expect(GroupID.allCases.filter(\.hasTuning) == [.duplicates, .similarStacks, .eyesClosed, .blurry, .exposure, .otherIssues])
        for group in GroupID.allCases {
            #expect(TuningControl.controls(for: group).isEmpty == !group.hasTuning, "\(group)")
        }
    }
}

@Suite("Bulk reject words")
struct BulkRejectTests {
    @Test func theQuestionStatesTheCountAndTheGroup() {
        #expect(BulkReject.question(count: 12, group: .blurry) == "Reject 12 photos that are certainly blurry?")
        #expect(BulkReject.question(count: 1, group: .blurry) == "Reject 1 photo that is certainly blurry?")
        #expect(BulkReject.question(count: 3, group: .eyesClosed) == "Reject 3 photos that certainly have closed eyes?")
        #expect(BulkReject.buttonTitle(count: 12) == "Reject 12 Photos")
        #expect(BulkReject.buttonTitle(count: 1) == "Reject 1 Photo")
    }

    @Test func noneSaysWhy() {
        #expect(BulkReject.noneMessage(group: .blurry) == "No undecided photos left that are certainly blurry.")
        #expect(BulkReject.noneMessage(group: .exposure).contains("always Likely"))
    }

    @Test func onlyUndecidedCertainPhotosAreRejected() {
        var state = session([("a", 5, nil, 0), ("b", 20, nil, 0), ("c", 8, nil, 0), ("d", 60, nil, 0)])
        // 5 and 8 are below the Certain line (15); 20 is Likely.
        #expect(state.undecidedCertainMembers(of: .blurry) == ["a", "c"])
        state.apply(.setDecision(.kept, ids: ["a"]))
        #expect(state.undecidedCertainMembers(of: .blurry) == ["c"])
        #expect(state.undecidedCertainMembers(of: .exposure).isEmpty)
    }
}

@Suite("Analysis words and concurrency")
struct AnalysisTextTests {
    @Test func toolbarLine() {
        #expect(AnalysisText.running(done: 420, total: 1240, secondsRemaining: 118) == "Analysing 420 of 1,240 · about 2 min left")
        #expect(AnalysisText.running(done: 3, total: 1240, secondsRemaining: nil) == "Analysing 3 of 1,240")
        #expect(AnalysisText.paused(done: 420, total: 1240) == "Paused · 420 of 1,240 analysed")
    }

    @Test func timeLeftIsRoundedSoItDoesNotFlicker() {
        #expect(AnalysisText.timeLeft(nil) == nil)
        #expect(AnalysisText.timeLeft(0.2) == "finishing")
        #expect(AnalysisText.timeLeft(20) == "less than a minute left")
        #expect(AnalysisText.timeLeft(70) == "about 1 min left")
        #expect(AnalysisText.timeLeft(3_700) == "about 1 h left")
        #expect(AnalysisText.timeLeft(5_000) == "about 1 h 20 min left")
    }

    @Test func summaryBanner() {
        #expect(AnalysisText.summary(AnalysisSummary(photos: 1240, stacks: 86, duplicateSets: 3, likelyRejects: 41))
            == "1,240 photos · 86 stacks · 41 likely rejects")
        #expect(AnalysisText.summary(AnalysisSummary(photos: 1, stacks: 0, duplicateSets: 0, likelyRejects: 1))
            == "1 photo · no stacks · 1 likely reject")
        let state = session([("a", 5, nil, 0.5), ("b", 60, nil, 0), ("c", 8, nil, 0)])
        let summary = AnalysisSummary(state)
        #expect(summary.photos == 3)
        // a is in Blurry and Exposure but counts once.
        #expect(summary.likelyRejects == 2)
    }

    @Test func concurrencyFollowsMemoryAndPower() {
        let gb: UInt64 = 1 << 30
        #expect(AnalysisConcurrency.limit(engineDefault: 8, physicalMemory: 8 * gb, onBattery: false, reduceOnBattery: true) == 4)
        #expect(AnalysisConcurrency.limit(engineDefault: 8, physicalMemory: 16 * gb, onBattery: false, reduceOnBattery: true) == 8)
        #expect(AnalysisConcurrency.limit(engineDefault: 8, physicalMemory: 64 * gb, onBattery: false, reduceOnBattery: true) == 8)
        #expect(AnalysisConcurrency.limit(engineDefault: 8, physicalMemory: 16 * gb, onBattery: true, reduceOnBattery: true) == 4)
        #expect(AnalysisConcurrency.limit(engineDefault: 8, physicalMemory: 16 * gb, onBattery: true, reduceOnBattery: false) == 8)
        #expect(AnalysisConcurrency.limit(engineDefault: 8, physicalMemory: 16 * gb, onBattery: false, reduceOnBattery: true, memoryPressure: .warning) == 4)
        #expect(AnalysisConcurrency.limit(engineDefault: 8, physicalMemory: 16 * gb, onBattery: true, reduceOnBattery: true, memoryPressure: .critical) == 1)
        #expect(AnalysisConcurrency.limit(engineDefault: 2, physicalMemory: 4 * gb, onBattery: true, reduceOnBattery: true) == 1)
    }
}

@Suite("Tuning controls")
struct TuningControlTests {
    @Test func everyKeyReadsAndWritesItsValue() {
        for key in TuningKey.allCases {
            var tuning = Tuning()
            let value = switch key.kind {
            case .toggle: 1 - key.value(in: tuning)
            case .choice: key.value(in: tuning) + 1
            case .slider: key == .minStackSize ? key.value(in: tuning) + 1 : key.value(in: tuning) + 0.5
            }
            key.set(value, in: &tuning)
            #expect(key.value(in: tuning) == value, "\(key)")
        }
    }

    @Test func controlsFormatAndSnap() throws {
        let eyes = try #require(TuningControl.controls(for: .eyesClosed).first)
        #expect(eyes.key == .eyesClosedBelow)
        #expect(eyes.format(0.26) == "0.26")
        #expect(eyes.snapped(0.2649) == 0.26)
        #expect(eyes.snapped(2) == 0.5)
        let highlights = try #require(TuningControl.controls(for: .exposure).first)
        #expect(highlights.format(0.3) == "30%")
        let gap = try #require(TuningControl.controls(for: .similarStacks).first)
        #expect(gap.format(10) == "10 s")
        #expect(gap.key.affectsGrouping)
        #expect(!eyes.key.affectsGrouping)
    }

    @Test func countLinesShowTheChange() throws {
        let eyes = try #require(TuningControl.controls(for: .eyesClosed).first)
        #expect(eyes.countLine(before: 41, after: 28) == "Eyes closed: 41 → 28 photos")
        #expect(eyes.countLine(before: 41, after: 41) == "Eyes closed: 41 photos")
        #expect(eyes.countLine(before: 1, after: 1) == "Eyes closed: 1 photo")
    }

    @Test func countsFollowTheTuningWithoutTouchingDecisions() {
        var state = session([
            ("a", 60, 0.10, 0), ("b", 60, 0.22, 0), ("c", 60, 0.40, 0), ("d", 10, nil, 0.6),
        ])
        state.apply(.setDecision(.kept, ids: ["b"]))
        var counts = TuningCounts(state)
        #expect(counts.count(.flag(.eyesClosed)) == 2)
        #expect(counts.count(.certain(.eyesClosed)) == 1)
        #expect(counts.count(.flag(.blurry)) == 1)
        #expect(counts.count(.flag(.clippedHighlights)) == 1)

        var tuning = state.tuning
        TuningKey.eyesClosedBelow.set(0.15, in: &tuning)
        state.tuning = tuning
        counts = TuningCounts(state)
        #expect(counts.count(.flag(.eyesClosed)) == 1)
        #expect(state.photo("b")?.decision == .kept)

        state.tuning = TuningControl.resetting(.eyesClosed, in: state.tuning)
        #expect(state.tuning.eyesClosedBelow == Tuning().eyesClosedBelow)
        #expect(TuningCounts(state).count(.flag(.eyesClosed)) == 2)
    }

    @Test func resetTouchesOnlyTheGroupsControls() {
        var tuning = Tuning()
        tuning.blurryBelow = 40
        tuning.eyesClosedBelow = 0.1
        let reset = TuningControl.resetting(.blurry, in: tuning)
        #expect(reset.blurryBelow == Tuning().blurryBelow)
        #expect(reset.eyesClosedBelow == 0.1)
    }
}
