import CullaCore
import CullaFiles
import CullaPipeline
import CullaSession
import CullaStore
import Foundation
import Testing

@Suite("Apply and undo", .serialized, .timeLimit(.minutes(5)))
struct ApplyAndUndoTests {
    // MARK: - The central test: apply then undo restores the folder exactly

    @Test func moveToRejectedFolderThenUndoRestoresTheFolderExactly() async throws {
        let (shoot, state) = try standardShoot()
        let original = shoot.listing
        let applier = try await applier(for: shoot.root)
        let plan = await ShootApplier.plan(for: state, folder: shoot.root, options: ApplyOptions())
        #expect(plan.canApply)
        #expect(plan.summary.rejected == 4 && plan.summary.unreadable == 2)
        // IMG_0001 jpg, CR3, xmp; IMG_0005 jpg, NEF; IMG_0006 heic and its darktable sidecar; IMG_0008.
        #expect(plan.summary.rejectedFiles == 8 && plan.summary.rejectedBytesAreExact)

        let applied = try await applier.apply(plan, session: state)
        let result = applied.result
        #expect(result.state == .done, "\(result.failure ?? "")")
        #expect(result.failure == nil && result.skippedSidecars.isEmpty)
        #expect(Set(result.removedPhotoIDs) == ["IMG_0001.jpg", "IMG_0008.jpg", "day2/IMG_0005.jpg", "day2/deeper/IMG_0006.heic"])
        #expect(result.incompletePhotoIDs.isEmpty)
        #expect(result.movedFiles == 8)
        #expect(result.sidecarsWritten == 7)
        #expect(applied.run.state == .done && applied.run.isUndoable)
        #expect(shoot.leftoverTemporaryFiles.isEmpty)

        let after = shoot.listing
        // Rejects moved with all their files, subfolders kept under _Rejected.
        for path in ["IMG_0001.jpg", "IMG_0001.CR3", "IMG_0001.xmp", "day2/IMG_0005.jpg", "day2/IMG_0005.NEF",
                     "day2/deeper/IMG_0006.heic", "day2/deeper/IMG_0006.heic.xmp"] {
            #expect(after.files[path] == nil)
            #expect(after.files["_Rejected/" + path]?.sha256 == original.files[path]?.sha256 || path.hasSuffix("IMG_0001.xmp"))
            if !path.hasSuffix(".xmp") { #expect(after.files["_Rejected/" + path]?.stamp == original.files[path]?.stamp) }
        }
        // The name collision got a suffix shared by the photo and its new sidecar, and nothing
        // that was already in _Rejected changed.
        #expect(after.files["_Rejected/IMG_0008 3.jpg"]?.sha256 == original.files["IMG_0008.jpg"]?.sha256)
        #expect(after.files["_Rejected/IMG_0008.jpg"] == original.files["_Rejected/IMG_0008.jpg"])
        #expect(after.files["_Rejected/IMG_0008 2.xmp"] == original.files["_Rejected/IMG_0008 2.xmp"])
        let fields = { (path: String) in try XMPSidecar.read(contentsOf: shoot.root.appendingPathComponent(path)) }
        #expect(try fields("_Rejected/IMG_0008 3.xmp") == XMPSidecarFields(rating: -1, label: "Red", decision: .rejected, cullaRating: 0))
        // The Lightroom sidecar moved and was merged; its other settings are still there.
        #expect(try fields("_Rejected/IMG_0001.xmp") == XMPSidecarFields(rating: -1, label: "Red", decision: .rejected, cullaRating: 0))
        let merged = try String(contentsOf: shoot.root.appendingPathComponent("_Rejected/IMG_0001.xmp"), encoding: .utf8)
        #expect(merged.contains("crs:Exposure2012=\"+0.35\"") && merged.contains("<rdf:li>255, 255</rdf:li>"))
        #expect(try fields("_Rejected/day2/IMG_0005.xmp") == XMPSidecarFields(rating: -1, label: "Red", decision: .rejected, cullaRating: 4))
        #expect(try fields("_Rejected/day2/deeper/IMG_0006.xmp").decision == .rejected)
        // Kept and rated photos got sidecars in place; the element-form sidecar was merged.
        #expect(try fields("IMG_0002.xmp") == XMPSidecarFields(rating: 3, label: "Green", decision: .kept, cullaRating: 3))
        #expect(try fields("IMG_0004.xmp") == XMPSidecarFields(rating: 2, label: nil, decision: .unreviewed, cullaRating: 2))
        #expect(try fields("day2/IMG_0007.xmp") == XMPSidecarFields(rating: 1, label: "Green", decision: .kept, cullaRating: 0))
        // Unreviewed unrated, unreadable and non-photo files are untouched.
        for path in ["IMG_0003.jpg", "IMG_0009.jpg", "IMG_0010.jpg", "notes.txt", "IMG_0002.jpg", "day2/IMG_0007.jpg"] {
            #expect(after.files[path] == original.files[path])
        }
        #expect(after.files["IMG_0003.xmp"] == nil && after.files["IMG_0009.xmp"] == nil && after.files["IMG_0010.xmp"] == nil)

        // The rescan no longer sees the rejects, and the session agrees once they are removed.
        var session = state
        session.removeAppliedPhotos(result.removedPhotoIDs)
        let rescanned = try PhotoScanner.scan(folder: shoot.root).map(\.id)
        #expect(Set(rescanned) == Set(session.photos.map(\.id)))
        #expect(!session.canUndo)

        // Undo.
        let undone = try await applier.undo(runID: applied.run.id, known: applied.removedPhotos)
        #expect(undone.report.state == .undone)
        #expect(undone.report.skipped.isEmpty)
        #expect(undone.run.state == .undone && !undone.run.isUndoable)
        let restored = shoot.listing
        #expect(restored == original, "\(restored.difference(from: original))")
        #expect(Set(undone.report.restoredPhotoIDs) == Set(result.removedPhotoIDs))
        session.restoreAppliedPhotos(undone.restoredPhotos)
        #expect(session.photos.map(\.mark) == state.photos.map(\.mark))
        #expect(try await applier.latestUndoableRun() == nil)

        // Undoing again finds nothing to do and changes nothing.
        let again = try await applier.undo(runID: applied.run.id)
        #expect(again.report.undoneSteps == 0 && shoot.listing == original)
    }

    @Test func markOnlyThenUndoRestoresTheFolderExactly() async throws {
        let (shoot, state) = try standardShoot()
        let original = shoot.listing
        let applier = try await applier(for: shoot.root)
        let plan = await ShootApplier.plan(for: state, folder: shoot.root, options: ApplyOptions(rejectAction: .markOnly))
        let applied = try await applier.apply(plan, session: state)
        #expect(applied.result.state == .done)
        #expect(applied.result.removedPhotoIDs.isEmpty && applied.result.movedFiles == 0)
        #expect(applied.result.sidecarsWritten == 7)
        let after = shoot.listing
        // Every photo file is where it was; rejects carry their mark beside them.
        for (path, file) in original.files where !path.hasSuffix(".xmp") {
            #expect(after.files[path] == file)
        }
        let fields = { (path: String) in try XMPSidecar.read(contentsOf: shoot.root.appendingPathComponent(path)) }
        #expect(try fields("IMG_0001.xmp").rating == -1)
        #expect(try fields("IMG_0008.xmp").decision == .rejected)
        #expect(try fields("day2/deeper/IMG_0006.xmp").decision == .rejected)
        // The darktable sidecar is not Culla's to change.
        #expect(after.files["day2/deeper/IMG_0006.heic.xmp"] == original.files["day2/deeper/IMG_0006.heic.xmp"])

        let undone = try await applier.undo(runID: applied.run.id)
        #expect(undone.report.state == .undone && undone.report.skipped.isEmpty)
        #expect(shoot.listing == original, "\(shoot.listing.difference(from: original))")
    }

    @Test func moveToTrashThenUndoRestoresTheFolderExactly() async throws {
        let (shoot, state) = try standardShoot()
        let original = shoot.listing
        let applier = try await applier(for: shoot.root)
        let plan = await ShootApplier.plan(for: state, folder: shoot.root, options: ApplyOptions(rejectAction: .moveToTrash))
        let applied = try await applier.apply(plan, session: state)
        defer { removeTrashedFiles(of: applied.result.steps) }
        #expect(applied.result.state == .done, "\(applied.result.failure ?? "")")
        #expect(applied.result.trashedFiles == 8)
        #expect(applied.result.sidecarsWritten == 3)
        // Every trashed file's place in the Trash was recorded, and it is there.
        for step in applied.result.steps {
            guard case let .trash(path, stamp, trashed) = step.action else { continue }
            #expect(!FileOps.exists(path))
            #expect(trashed.map { FileOps.stamp($0) } == stamp)
        }
        #expect(!FileOps.exists(shoot.root.appendingPathComponent("IMG_0001.xmp").path))

        let undone = try await applier.undo(runID: applied.run.id)
        #expect(undone.report.state == .undone && undone.report.skipped.isEmpty)
        #expect(shoot.listing == original, "\(shoot.listing.difference(from: original))")
        for step in undone.report.steps {
            if case let .trash(_, _, trashed?) = step.action { #expect(!FileOps.exists(trashed)) }
        }
    }

    @Test func copyKeepersThenUndoRemovesOnlyTheCopies() async throws {
        let (shoot, state) = try standardShoot()
        let destination = try Scratch("CullaKeepers")
        // Something the user already has there, under a name a keeper wants.
        try "theirs".write(to: destination.url.appendingPathComponent("IMG_0002.jpg"), atomically: false, encoding: .utf8)
        try FileManager.default.createDirectory(at: destination.url.appendingPathComponent("day2"), withIntermediateDirectories: true)
        let originalSource = shoot.listing
        let originalDestination = Listing(destination.url)
        let applier = try await applier(for: shoot.root)
        let plan = await ShootApplier.copyKeepersPlan(for: state, folder: shoot.root, destination: destination.url, options: ApplyOptions())
        #expect(plan.canApply)
        #expect(plan.photos.map(\.id).sorted() == ["IMG_0002.jpg", "IMG_0003.jpg", "IMG_0004.jpg", "IMG_0010.jpg", "day2/IMG_0007.jpg"])

        let applied = try await applier.apply(plan, session: state)
        #expect(applied.result.state == .done, "\(applied.result.failure ?? "")")
        #expect(applied.result.removedPhotoIDs.isEmpty)
        #expect(applied.result.copiedFiles == 6)
        #expect(shoot.listing == originalSource, "the shoot is only read")
        let copied = Listing(destination.url)
        #expect(copied.files["IMG_0002.jpg"] == originalDestination.files["IMG_0002.jpg"])
        #expect(copied.files["IMG_0002 2.jpg"]?.sha256 == originalSource.files["IMG_0002.jpg"]?.sha256)
        #expect(try XMPSidecar.read(contentsOf: destination.url.appendingPathComponent("IMG_0002 2.xmp")).decision == .kept)
        #expect(copied.files["IMG_0003.jpg"]?.sha256 == originalSource.files["IMG_0003.jpg"]?.sha256)
        #expect(copied.files["IMG_0010.jpg"] != nil && copied.files["IMG_0010.xmp"] == nil)
        #expect(try XMPSidecar.read(contentsOf: destination.url.appendingPathComponent("day2/IMG_0007.xmp")).rating == 1)
        #expect(try XMPSidecar.read(contentsOf: destination.url.appendingPathComponent("day2/IMG_0007.xmp")).decision == .kept)
        #expect(copied.files["IMG_0001.jpg"] == nil && copied.files["IMG_0008.jpg"] == nil)
        #expect(copied.folders.allSatisfy { !$0.hasPrefix("_Rejected") })

        let undone = try await applier.undo(runID: applied.run.id)
        #expect(undone.report.state == .undone && undone.report.skipped.isEmpty)
        #expect(undone.report.restoredPhotoIDs.isEmpty)
        #expect(Listing(destination.url) == originalDestination, "\(Listing(destination.url).difference(from: originalDestination))")
        #expect(shoot.listing == originalSource)
    }

    @Test func copyKeepersUndoKeepsACopyChangedSince() async throws {
        let (shoot, state) = try standardShoot()
        let destination = try Scratch("CullaKeepers")
        let applier = try await applier(for: shoot.root)
        let plan = await ShootApplier.copyKeepersPlan(for: state, folder: shoot.root, destination: destination.url, options: ApplyOptions())
        let applied = try await applier.apply(plan, session: state)
        try "edited".write(to: destination.url.appendingPathComponent("IMG_0003.jpg"), atomically: false, encoding: .utf8)
        let undone = try await applier.undo(runID: applied.run.id)
        #expect(undone.report.state == .partlyUndone)
        #expect(undone.report.skipped.map(\.reason) == [.changed])
        #expect(Listing(destination.url).files.keys.sorted() == ["IMG_0003.jpg"])
    }

    @Test func aReadOnlyShootIsBlockedAndNothingIsTouched() async throws {
        let (shoot, state) = try standardShoot()
        let plan = state.applyPlan(folder: shoot.root, folderIsWritable: false)
        let journal = MemoryApplyJournal()
        let result = await ApplyExecutor(journal: journal).run(plan, runID: 1)
        #expect(result.state == .failed && result.steps.isEmpty)
        #expect(result.failure?.contains("readOnlyFolder") == true)
        #expect(await journal.state(runID: 1) == .failed)
    }

    @Test func folderWritabilityIsReported() throws {
        let scratch = try Scratch()
        #expect(ShootFolderAccess.writability(of: scratch.url) == .writable)
        #expect(ShootFolderAccess.writability(of: scratch.url.appendingPathComponent("nope")) == .missing)
        let locked = scratch.url.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        #expect(ShootFolderAccess.writability(of: locked) == .folderNotWritable)
    }

    @Test func aMissingFileStopsTheRunBeforeAnythingIsDone() async throws {
        let (shoot, state) = try standardShoot()
        let plan = state.applyPlan(folder: shoot.root)
        try FileManager.default.removeItem(at: shoot.root.appendingPathComponent("day2/IMG_0005.NEF"))
        let before = shoot.listing
        let journal = MemoryApplyJournal()
        let result = await ApplyExecutor(journal: journal).run(plan, runID: 7)
        #expect(result.state == .failed && !result.changedAnything)
        #expect(result.failure?.contains("IMG_0005.NEF") == true)
        #expect(shoot.listing == before)
    }

    @Test func aFileAppearingAtTheDestinationIsNeverOverwritten() async throws {
        let (shoot, state) = try standardShoot()
        let plan = state.applyPlan(folder: shoot.root)
        let original = shoot.listing
        let target = shoot.root.appendingPathComponent("_Rejected/IMG_0001.CR3")
        // The names are chosen, then a file takes one of them before its move.
        let applier = try await applier(for: shoot.root) { step in
            if case let .move(_, to, _) = step.action, to == target.path, !FileOps.exists(to) {
                try Data("squatter".utf8).write(to: target)
            }
        }
        let applied = try await applier.apply(plan, session: state)
        #expect(applied.result.state == .failed)
        #expect(try Data(contentsOf: target) == Data("squatter".utf8))
        #expect(applied.result.incompletePhotoIDs == ["IMG_0001.jpg"])
        try FileManager.default.removeItem(at: target)
        let undone = try await applier.undo(runID: applied.run.id)
        #expect(undone.report.state == .undone)
        #expect(shoot.listing == original, "\(shoot.listing.difference(from: original))")
    }

    @Test func cancellingStopsBetweenStepsAndCanBeUndone() async throws {
        let (shoot, state) = try standardShoot()
        let original = shoot.listing
        let plan = state.applyPlan(folder: shoot.root)
        let gate = AsyncGate()
        let applier = try await applier(for: shoot.root) { step in
            if step.index == 3 { gate.open() }
        }
        let task = Task { try await applier.apply(plan, session: state) }
        await gate.wait()
        task.cancel()
        let applied = try await task.value
        #expect(applied.result.state == .cancelled)
        #expect(applied.result.steps.contains { $0.state == .pending })
        #expect(applied.run.state == .cancelled && applied.run.isUndoable)
        #expect(try await applier.latestUndoableRun()?.id == applied.run.id)
        let undone = try await applier.undo(runID: applied.run.id)
        #expect(undone.report.state == .undone)
        #expect(shoot.listing == original, "\(shoot.listing.difference(from: original))")
    }

    @Test func progressIsReportedForEveryStep() async throws {
        let (shoot, state) = try standardShoot()
        let plan = state.applyPlan(folder: shoot.root)
        let seen = Recorder<ApplyProgress>()
        let applier = try await applier(for: shoot.root)
        let applied = try await applier.apply(plan, session: state) { seen.append($0) }
        let reports = seen.values
        #expect(reports.first?.done == 0)
        #expect(reports.last == ApplyProgress(done: applied.result.steps.count, total: applied.result.steps.count, currentPhotoID: nil))
        #expect(zip(reports, reports.dropFirst()).allSatisfy { $0.done < $1.done })
        _ = try await applier.undo(runID: applied.run.id)
    }

    @Test func anUnparseableSidecarIsLeftAloneAndReported() async throws {
        let (shoot, state) = try standardShoot()
        try shoot.write("IMG_0002.xmp", "<x:xmpmeta> broken")
        let original = shoot.listing
        let applier = try await applier(for: shoot.root)
        let plan = await ShootApplier.plan(for: state, folder: shoot.root, options: ApplyOptions(rejectAction: .markOnly))
        let applied = try await applier.apply(plan, session: state)
        #expect(applied.result.state == .done)
        #expect(applied.result.skippedSidecars.map(\.photoID) == ["IMG_0002.jpg"])
        #expect(applied.result.skippedSidecars.first?.note?.contains("not well-formed") == true)
        #expect(shoot.listing.files["IMG_0002.xmp"] == original.files["IMG_0002.xmp"])
        _ = try await applier.undo(runID: applied.run.id)
        #expect(shoot.listing == original)
    }
}

/// Values recorded from any thread.
final class Recorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Value] = []

    func append(_ value: Value) { lock.withLock { stored.append(value) } }
    var values: [Value] { lock.withLock { stored } }
}

/// Lets one task wait until another thread opens the gate.
final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            defer { waiters = [] }
            return waiters
        }
        for waiter in waiting { waiter.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { () -> Bool in
                if isOpen { return true }
                waiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }
}
