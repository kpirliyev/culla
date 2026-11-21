import CullaCore
import CullaFiles
import CullaPipeline
import CullaSession
import CullaStore
import Foundation
import Testing

/// A small shoot whose plan has about ten steps of every kind:
/// `a.jpg` + `a.CR3` rejected with a Lightroom sidecar, `sub/b.jpg` rejected with 2 stars,
/// `c.jpg` kept, `d.jpg` kept with an element-form sidecar.
private func smallShoot() throws -> (ShootFixture, SessionState) {
    let shoot = try ShootFixture()
    try shoot.write("a.jpg")
    try shoot.write("a.CR3", bytes: 700)
    try shoot.write("a.xmp", lightroomSidecar)
    try shoot.write("sub/b.jpg")
    try shoot.write("c.jpg")
    try shoot.write("d.jpg")
    try shoot.write("d.xmp", elementSidecar)
    let state = try shoot.session(
        decisions: ["a.jpg": .rejected, "sub/b.jpg": .rejected, "c.jpg": .kept, "d.jpg": .kept],
        ratings: ["sub/b.jpg": 2]
    )
    return (shoot, state)
}

private enum Kind: String, CaseIterable, CustomTestStringConvertible {
    case move, markOnly, trash, copy

    var testDescription: String { rawValue }

    func plan(_ state: SessionState, shoot: ShootFixture, destination: URL) -> ApplyPlan {
        switch self {
        case .move: state.applyPlan(folder: shoot.root)
        case .markOnly: state.applyPlan(folder: shoot.root, options: ApplyOptions(rejectAction: .markOnly))
        case .trash: state.applyPlan(folder: shoot.root, options: ApplyOptions(rejectAction: .moveToTrash))
        case .copy: state.copyKeepersPlan(folder: shoot.root, destination: destination)
        }
    }
}

@Suite("Apply failures and recovery", .serialized, .timeLimit(.minutes(5)))
struct ApplyFailureTests {
    /// Makes step N fail, for every N of the plan, then undoes, and checks the folder is as it
    /// was and no file was lost or duplicated in between.
    @Test(arguments: Kind.allCases)
    fileprivate func aFailureAtEveryStepCanBeUndone(kind: Kind) async throws {
        let (probe, probeState) = try smallShoot()
        let probeDestination = try Scratch("CullaKeepers")
        let stepCount = try await ApplyExecutor(journal: MemoryApplyJournal())
            .steps(for: kind.plan(probeState, shoot: probe, destination: probeDestination.url)).count
        #expect(stepCount >= 4)

        for failing in 0..<stepCount {
            let (shoot, state) = try smallShoot()
            let destination = try Scratch("CullaKeepers")
            let original = shoot.listing
            let originalDestination = Listing(destination.url)
            let applier = try await applier(for: shoot.root) { step in
                if step.index == failing { throw InjectedFailure(index: failing) }
            }
            let applied = try await applier.apply(kind.plan(state, shoot: shoot, destination: destination.url), session: state)
            defer { removeTrashedFiles(of: applied.result.steps) }
            #expect(applied.result.state == .failed)
            #expect(applied.result.failedStepIndex == failing)
            #expect(applied.result.failure == "injected failure at step \(failing)")
            #expect(applied.result.steps[failing].state == .failed)
            #expect(applied.result.steps[(failing + 1)...].allSatisfy { $0.state == .pending })
            #expect(applied.run.state == .failed && applied.run.isUndoable == (failing > 0))
            #expect(shoot.leftoverTemporaryFiles.isEmpty)

            // Nothing lost or duplicated: every photo file's content is somewhere exactly once.
            if kind == .move {
                let counts = shoot.listing.contentCounts
                for (path, file) in original.files where !path.hasSuffix(".xmp") {
                    #expect(counts[file.sha256] == 1, "step \(failing): \(path)")
                }
            }

            let undone = try await applier.undo(runID: applied.run.id)
            #expect(undone.report.state == .undone, "step \(failing): \(undone.report.skipped)")
            #expect(shoot.listing == original, "step \(failing): \(shoot.listing.difference(from: original))")
            #expect(Listing(destination.url) == originalDestination)
        }
    }

    /// A crash right after a step was journalled as started: either before it was carried out,
    /// or after it was carried out but before it was recorded as done. The run is found on the
    /// next launch, marked interrupted and undone from what the disk shows.
    @Test(arguments: Kind.allCases)
    fileprivate func aCrashAtEveryStepIsRecoverable(kind: Kind) async throws {
        let (probe, probeState) = try smallShoot()
        let probeDestination = try Scratch("CullaKeepers")
        let stepCount = try await ApplyExecutor(journal: MemoryApplyJournal())
            .steps(for: kind.plan(probeState, shoot: probe, destination: probeDestination.url)).count

        for crashing in 0..<stepCount {
            for carriedOut in [false, true] {
                let (shoot, state) = try smallShoot()
                let destination = try Scratch("CullaKeepers")
                let original = shoot.listing
                let originalDestination = Listing(destination.url)
                // Stop at the crashing step itself, or just after it.
                let stopAt = carriedOut ? crashing + 1 : crashing
                let applier = try await applier(for: shoot.root) { step in
                    if step.index == stopAt { throw InjectedFailure(index: stopAt) }
                }
                let applied = try await applier.apply(kind.plan(state, shoot: shoot, destination: destination.url), session: state)
                let label = "step \(crashing), carried out: \(carriedOut)"

                // Rewrite the journal as a crash would have left it.
                let database = applier.database
                var crashed = applied.result.steps[crashing]
                if carriedOut && crashed.state != .done { continue }   // a step skipped on purpose
                crashed.state = .started
                crashed.note = nil
                var lostTrashPath: String?
                if carriedOut {
                    // The record of what the step produced never made it to the journal.
                    switch crashed.action {
                    case let .trash(path, stamp, trashed):
                        lostTrashPath = trashed
                        crashed.action = .trash(path: path, stamp: stamp, trashedPath: nil)
                    case let .copy(from, to, temp, _):
                        crashed.action = .copy(from: from, to: to, tempPath: temp, stamp: nil)
                    default: break
                    }
                }
                try await database.updateStep(crashed, runID: applied.run.id)
                if carriedOut, stopAt < applied.result.steps.count {
                    var next = applied.result.steps[stopAt]
                    next.state = .pending
                    next.note = nil
                    try await database.updateStep(next, runID: applied.run.id)
                }
                try await database.setRunState(.running, failure: nil, runID: applied.run.id)

                // Next launch.
                #expect(try await database.interruptedApplyRuns().map(\.id) == [applied.run.id], "\(label)")
                let recovered = try await applier.recoverInterruptedRuns()
                #expect(recovered.map(\.id) == [applied.run.id])
                #expect(recovered.first?.state == .failed && recovered.first?.failure == "Interrupted")
                #expect(try await database.interruptedApplyRuns().isEmpty)
                #expect(try await applier.latestUndoableRun()?.id == applied.run.id, "\(label)")

                let undone = try await applier.undo(runID: applied.run.id)
                if let lostTrashPath {
                    // The one thing a crash can lose: where in the Trash a file went.
                    #expect(undone.report.state == .partlyUndone)
                    #expect(undone.report.skipped.map(\.reason) == [.trashLocationUnknown], "\(label)")
                    let path = { () -> String in
                        if case let .trash(path, _, _) = crashed.action { return path }
                        return ""
                    }()
                    try FileOps.moveExclusive(from: lostTrashPath, to: path)
                } else {
                    #expect(undone.report.state == .undone, "\(label): \(undone.report.skipped)")
                }
                removeTrashedFiles(of: applied.result.steps)
                #expect(shoot.listing == original, "\(label): \(shoot.listing.difference(from: original))")
                #expect(Listing(destination.url) == originalDestination, "\(label)")
                #expect(shoot.leftoverTemporaryFiles.isEmpty, "\(label)")
            }
        }
    }

    // MARK: - Undo when the user interfered

    /// Applies the standard shoot with rejects moved to `_Rejected`, lets `interfere` change
    /// things, undoes, and returns the report and the folder before and after.
    private func applyInterfereUndo(
        _ interfere: (ShootFixture) throws -> Void
    ) async throws -> (report: UndoReport, original: Listing, after: Listing, shoot: ShootFixture, applier: ShootApplier, runID: Int64) {
        let (shoot, state) = try standardShoot()
        let original = shoot.listing
        let applier = try await applier(for: shoot.root)
        let applied = try await applier.apply(state.applyPlan(folder: shoot.root), session: state)
        #expect(applied.result.state == .done)
        try interfere(shoot)
        let undone = try await applier.undo(runID: applied.run.id)
        return (undone.report, original, shoot.listing, shoot, applier, applied.run.id)
    }

    @Test func aMovedFileThatWasDeletedIsSkippedAndTheRestRestored() async throws {
        let (report, original, after, _, _, _) = try await applyInterfereUndo { shoot in
            try FileManager.default.removeItem(at: shoot.root.appendingPathComponent("_Rejected/IMG_0001.CR3"))
        }
        #expect(report.state == .partlyUndone)
        #expect(report.skipped.map(\.reason) == [.missing])
        #expect(report.skipped.first?.path.hasSuffix("_Rejected/IMG_0001.CR3") == true)
        var expected = original
        expected.files["IMG_0001.CR3"] = nil
        #expect(after == expected, "\(after.difference(from: expected))")
        #expect(report.restoredPhotoIDs.contains("IMG_0001.jpg"))
    }

    @Test func aMovedFileThatWasModifiedIsLeftWhereItIs() async throws {
        let (report, original, after, _, _, _) = try await applyInterfereUndo { shoot in
            let handle = try FileHandle(forWritingTo: shoot.root.appendingPathComponent("_Rejected/day2/IMG_0005.NEF"))
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("edited".utf8))
            try handle.close()
        }
        #expect(report.state == .partlyUndone)
        // The changed file is skipped, so its folders are not empty either: they stay, and that
        // alone would not make the undo partial.
        #expect(report.skipped.map(\.reason) == [.changed, .folderNotEmpty])
        #expect(after.files["day2/IMG_0005.NEF"] == nil)
        #expect(after.files["_Rejected/day2/IMG_0005.NEF"]?.sha256 != original.files["day2/IMG_0005.NEF"]?.sha256)
        #expect(after.files["day2/IMG_0005.jpg"] == original.files["day2/IMG_0005.jpg"])
        #expect(after.files["IMG_0001.CR3"] == original.files["IMG_0001.CR3"])
        #expect(!after.folders.contains("_Rejected/day2/deeper"))
    }

    @Test func aMovedFileThatWasReplacedIsLeftWhereItIs() async throws {
        let (report, original, after, _, _, _) = try await applyInterfereUndo { shoot in
            let url = shoot.root.appendingPathComponent("_Rejected/IMG_0008 3.jpg")
            let content = try Data(contentsOf: url)
            try FileManager.default.removeItem(at: url)
            try content.write(to: url)
        }
        // Same content, but a new modification date: it is not provably the file Culla moved.
        #expect(report.skipped.map(\.reason) == [.changed])
        #expect(after.files["IMG_0008.jpg"] == nil)
        #expect(after.files["_Rejected/IMG_0008 3.jpg"]?.sha256 == original.files["IMG_0008.jpg"]?.sha256)
        // Its sidecar was removed, as it held exactly what Culla wrote.
        #expect(after.files["_Rejected/IMG_0008 3.xmp"] == nil)
    }

    @Test func somethingNewAtTheOriginalPathIsNeverOverwritten() async throws {
        let (report, original, after, shoot, applier, runID) = try await applyInterfereUndo { shoot in
            try Data("a new photo".utf8).write(to: shoot.root.appendingPathComponent("IMG_0001.jpg"))
        }
        #expect(report.state == .partlyUndone)
        #expect(report.skipped.map(\.reason) == [.originalPathOccupied])
        #expect(try Data(contentsOf: shoot.root.appendingPathComponent("IMG_0001.jpg")) == Data("a new photo".utf8))
        #expect(after.files["_Rejected/IMG_0001.jpg"]?.sha256 == original.files["IMG_0001.jpg"]?.sha256)
        #expect(after.files["IMG_0001.CR3"] == original.files["IMG_0001.CR3"])
        #expect(!report.restoredPhotoIDs.contains("IMG_0001.jpg"))

        // Once the place is free again, undoing again finishes the job.
        #expect(try await applier.latestUndoableRun()?.id == runID)
        try FileManager.default.removeItem(at: shoot.root.appendingPathComponent("IMG_0001.jpg"))
        let retry = try await applier.undo(runID: runID)
        #expect(retry.report.state == .undone && retry.report.skipped.isEmpty)
        #expect(retry.report.restoredPhotoIDs.contains("IMG_0001.jpg"))
        #expect(shoot.listing == original, "\(shoot.listing.difference(from: original))")
    }

    @Test func anEmptiedRejectedFolderIsReportedAndKeptPhotosAreStillRestored() async throws {
        let (report, original, after, _, _, _) = try await applyInterfereUndo { shoot in
            try FileManager.default.removeItem(at: shoot.root.appendingPathComponent("_Rejected"))
        }
        #expect(report.state == .partlyUndone)
        #expect(report.skipped.allSatisfy { $0.reason == .missing })
        // Eight moved files, and the Lightroom sidecar that moved with IMG_0001 and was merged.
        #expect(report.skipped.count == 9)
        #expect(report.restoredPhotoIDs.isEmpty)
        // The kept photos' sidecars are back as they were; nothing was recreated in _Rejected.
        for path in ["IMG_0002.xmp", "IMG_0004.xmp"] { #expect(after.files[path] == nil) }
        #expect(after.files["day2/IMG_0007.xmp"] == original.files["day2/IMG_0007.xmp"])
        #expect(!after.folders.contains("_Rejected"))
        for (path, file) in original.files where !path.hasPrefix("_Rejected") && after.files[path] != nil {
            #expect(after.files[path] == file)
        }
    }

    @Test func aSidecarAnotherProgramChangedIsKept() async throws {
        let (report, original, after, shoot, _, _) = try await applyInterfereUndo { shoot in
            let url = shoot.root.appendingPathComponent("IMG_0002.xmp")
            let edited = try XMPSidecar.merged(Data(contentsOf: url), mark: SidecarMark(decision: .kept, rating: 5))
            try edited.write(to: url)
        }
        #expect(report.skipped.map(\.reason) == [.changed])
        #expect(try XMPSidecar.read(contentsOf: shoot.root.appendingPathComponent("IMG_0002.xmp")).rating == 5)
        var expected = original
        expected.files["IMG_0002.xmp"] = after.files["IMG_0002.xmp"]
        #expect(after == expected, "\(after.difference(from: expected))")
    }
}
