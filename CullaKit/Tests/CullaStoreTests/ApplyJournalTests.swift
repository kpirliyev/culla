import CullaCore
import CullaSession
@testable import CullaStore
import Foundation
import Testing

private let shoot = URL(fileURLWithPath: "/Volumes/Card/DCIM/100NIKON", isDirectory: true)
private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

private func plan(_ action: RejectAction = .moveToRejectedFolder) -> ApplyPlan {
    ApplyPlan(
        kind: .apply, folder: shoot, options: ApplyOptions(rejectAction: action),
        photos: [PlannedPhoto(id: "a.jpg", files: ["a.jpg", "a.NEF"], disposition: .moveToRejectedFolder, sidecar: SidecarMark(decision: .rejected, rating: 2), sidecarPath: "a.xmp")],
        summary: ApplySummary(kept: 3, rejected: 1, unreviewed: 2, rejectedFiles: 2, rejectedBytes: 12_345)
    )
}

private func steps() -> [ApplyStep] {
    let stamp = FileStamp(size: 10, seconds: 1_700_000_000, nanoseconds: 5)
    return [
        ApplyStep(index: 0, photoID: "", role: .folder, action: .createFolder(path: "/x/_Rejected")),
        ApplyStep(index: 1, photoID: "a.jpg", role: .photo, action: .move(from: "/x/a.jpg", to: "/x/_Rejected/a.jpg", stamp: stamp)),
        ApplyStep(index: 2, photoID: "a.jpg", role: .companion, action: .move(from: "/x/a.NEF", to: "/x/_Rejected/a.NEF", stamp: stamp)),
        ApplyStep(index: 3, photoID: "a.jpg", role: .sidecar, action: .writeSidecar(
            path: "/x/_Rejected/a.xmp", mark: SidecarMark(decision: .rejected, rating: 2),
            previous: .existed(Data("old".utf8), stamp), written: Data("new".utf8), tempPath: "/x/_Rejected/.culla-1.tmp"
        )),
        ApplyStep(index: 4, photoID: "b.jpg", role: .photo, action: .trash(path: "/x/b.jpg", stamp: stamp, trashedPath: "/Users/u/.Trash/b.jpg")),
        ApplyStep(index: 5, photoID: "c.jpg", role: .photo, action: .copy(from: "/x/c.jpg", to: "/y/c.jpg", tempPath: "/y/.culla-2.tmp", stamp: nil)),
    ]
}

private func appliedPhoto(_ id: String) -> AppliedPhoto {
    var scores = PhotoScores(analysedWidth: 100, analysedHeight: 80)
    scores.subjectSharpness = 12
    let item = PhotoItem(
        file: PhotoFile(id: id, url: shoot.appendingPathComponent(id), companions: [shoot.appendingPathComponent("a.NEF")], fileSize: 10, modificationDate: start, isRAW: false),
        metadata: PhotoMetadata(captureDate: start, cameraModel: "Z 6"),
        decision: .rejected, rating: 2, scores: scores
    )
    return AppliedPhoto(item)
}

@Suite("Apply journal")
struct ApplyJournalTests {
    @Test func runsAndStepsSurviveClosingAndReopening() async throws {
        let folder = try TemporaryFolder()
        let file = folder.url.appendingPathComponent("Culla.sqlite")
        var runID: Int64 = 0
        var sessionID: Int64 = 0
        do {
            let database = try CullaDatabase(fileURL: file)
            sessionID = try await database.openSession(folder: shoot).id
            let run = try await database.startApplyRun(
                sessionID: sessionID, plan: plan(), photos: [appliedPhoto("a.jpg")], destinationBookmark: Data([1, 2, 3]), now: start
            )
            runID = run.id
            #expect(run.state == .running && run.stepCount == 0 && !run.isUndoable)
            #expect(run.folderPath == shoot.path && run.startedAt == start && run.destinationBookmark == Data([1, 2, 3]))
            try await database.recordSteps(steps(), runID: runID)
            var done = steps()[1]
            done.state = .done
            try await database.updateStep(done, runID: runID)
            var started = steps()[3]
            started.state = .started
            try await database.updateStep(started, runID: runID)
        }

        let reopened = try CullaDatabase(fileURL: file)
        let run = try #require(try await reopened.applyRun(id: runID))
        #expect(run.state == .running)
        #expect(run.kind == .apply && run.options == ApplyOptions())
        #expect(run.summary.rejectedBytes == 12_345)
        #expect(run.stepCount == 6 && run.undoableStepCount == 2)
        let saved = try await reopened.applySteps(runID: runID)
        var expected = steps()
        expected[1].state = .done
        expected[3].state = .started
        #expect(saved == expected)
        let photos = try await reopened.appliedPhotos(runID: runID)
        #expect(photos.map(\.id) == ["a.jpg"])
        #expect(photos.first?.decision == .rejected && photos.first?.rating == 2)
        #expect(photos.first?.scores == nil, "scores are not kept in the journal")
        #expect(photos.first?.metadata.cameraModel == "Z 6")

        // The crash is found on the next launch and recovered.
        #expect(try await reopened.interruptedApplyRuns().map(\.id) == [runID])
        #expect(try await reopened.interruptedApplyRuns(sessionID: sessionID + 1).isEmpty)
        #expect(try await reopened.latestUndoableApplyRun(sessionID: sessionID) == nil)
        try await reopened.markApplyRunInterrupted(id: runID, now: start)
        let interrupted = try #require(try await reopened.applyRun(id: runID))
        #expect(interrupted.state == .failed && interrupted.failure == "Interrupted" && interrupted.finishedAt == start)
        #expect(try await reopened.latestUndoableApplyRun(sessionID: sessionID)?.id == runID)
        #expect(try await reopened.interruptedApplyRuns().isEmpty)
    }

    @Test func runsAreListedNewestFirstAndMoveThroughTheirStates() async throws {
        let database = try CullaDatabase.inMemory()
        let session = try await database.openSession(folder: shoot)
        let other = try await database.openSession(folder: URL(fileURLWithPath: "/other"))
        let first = try await database.startApplyRun(sessionID: session.id, plan: plan(), now: start)
        let second = try await database.startApplyRun(sessionID: session.id, plan: plan(.markOnly), now: start.addingTimeInterval(60))
        _ = try await database.startApplyRun(sessionID: other.id, plan: plan(), now: start.addingTimeInterval(30))
        #expect(try await database.applyRuns(sessionID: session.id).map(\.id) == [second.id, first.id])

        for run in [first, second] {
            try await database.recordSteps(steps(), runID: run.id)
            for var step in steps() {
                step.state = .done
                try await database.updateStep(step, runID: run.id)
            }
            try await database.setRunState(.done, failure: nil, runID: run.id)
        }
        #expect(try await database.latestUndoableApplyRun(sessionID: session.id)?.id == second.id)

        // Undone, the newest one is no longer offered; the one before it is.
        for var step in steps() {
            step.state = .undone
            try await database.updateStep(step, runID: second.id)
        }
        try await database.setRunState(.undone, failure: nil, runID: second.id)
        #expect(try await database.latestUndoableApplyRun(sessionID: session.id)?.id == first.id)

        // Partly undone stays on offer.
        var skipped = steps()[2]
        skipped.state = .undoSkipped
        skipped.note = "It changed since the apply."
        try await database.updateStep(skipped, runID: first.id)
        try await database.setRunState(.partlyUndone, failure: nil, runID: first.id)
        let partly = try #require(try await database.latestUndoableApplyRun(sessionID: session.id))
        #expect(partly.id == first.id && partly.state == .partlyUndone)
        #expect(try await database.applySteps(runID: first.id)[2].note == "It changed since the apply.")

        // A failed run with nothing done has nothing to undo.
        let failed = try await database.startApplyRun(sessionID: session.id, plan: plan(), now: start.addingTimeInterval(120))
        try await database.recordSteps(steps(), runID: failed.id)
        try await database.setRunState(.failed, failure: "boom", runID: failed.id)
        #expect(try await database.applyRun(id: failed.id)?.failure == "boom")
        #expect(try await database.latestUndoableApplyRun(sessionID: session.id)?.id == first.id)

        await #expect(throws: CullaDatabaseError.self) {
            try await database.updateStep(steps()[0], runID: 9999)
        }
        await #expect(throws: CullaDatabaseError.self) {
            try await database.startApplyRun(sessionID: 9999, plan: plan())
        }
        // Deleting a session deletes its journal.
        try await database.deleteSession(id: session.id)
        #expect(try await database.applyRuns(sessionID: session.id).isEmpty)
        #expect(try await database.applySteps(runID: first.id).isEmpty)
    }

    @Test func aDatabaseWithMigrationsOneAndTwoIsMigrated() async throws {
        let folder = try TemporaryFolder()
        let file = folder.url.appendingPathComponent("Culla.sqlite")
        var sessionID: Int64 = 0
        do {
            // As the M3 app left it.
            let old = try CullaDatabase(fileURL: file, migratingUpTo: "2")
            #expect(try await old.appliedMigrations() == ["1", "2"])
            sessionID = try await old.openSession(folder: shoot).id
            try await old.replacePhotos([StoredPhoto(id: "a.jpg", fileSize: 10, modificationDate: start, isRAW: false, decision: .kept, rating: 4)], sessionID: sessionID)
            try await old.saveStackEdits(StackEdits(bestPicks: ["a.jpg"]), sessionID: sessionID)
            await #expect(throws: (any Error).self) { try await old.applyRuns(sessionID: sessionID) }
        }
        let migrated = try CullaDatabase(fileURL: file)
        #expect(try await migrated.appliedMigrations() == ["1", "2", "3", "4"])
        #expect(try await migrated.photos(sessionID: sessionID).map(\.rating) == [4])
        #expect(try await migrated.stackEdits(sessionID: sessionID).bestPicks == ["a.jpg"])
        #expect(try await migrated.applyRuns(sessionID: sessionID).isEmpty)
        let run = try await migrated.startApplyRun(sessionID: sessionID, plan: plan())
        #expect(try await migrated.applyRuns(sessionID: sessionID).map(\.id) == [run.id])
    }

    @Test func cachedScoresFollowRenamedFiles() async throws {
        let database = try CullaDatabase.inMemory()
        var scores = PhotoScores(analysedWidth: 10, analysedHeight: 10)
        scores.subjectSharpness = 42
        let old = ScoreKey(path: "/shoot/a.jpg", fileSize: 10, modificationDate: start)
        let stale = ScoreKey(path: "/shoot/sub/a.jpg", fileSize: 99, modificationDate: start)
        try await database.saveScores([old: scores, stale: PhotoScores(analysedWidth: 1, analysedHeight: 1)])
        try await database.moveCachedScores(["/shoot/a.jpg": "/shoot/sub/a.jpg"])
        let moved = ScoreKey(path: "/shoot/sub/a.jpg", fileSize: 10, modificationDate: start)
        #expect(try await database.scores(for: [moved])[moved]?.subjectSharpness == 42)
        #expect(try await database.scores(for: [old]).isEmpty)
        #expect(try await database.cachedScoreCount() == 1)
    }
}
