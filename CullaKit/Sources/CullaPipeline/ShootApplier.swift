import CullaCore
import CullaFiles
import CullaSession
import CullaStore
import Foundation

/// Applying decisions to one shoot, and undoing that: the plan's disk facts, the journal in the
/// database, the executor and what the session needs afterwards, in one place.
///
/// The session itself stays with the caller (the app's `SessionModel` owns its `SessionState`),
/// so every method takes or returns plain values; see each one for what to do with the session.
public struct ShootApplier: Sendable {
    public let database: CullaDatabase
    public let sessionID: Int64
    private let faultInjector: ApplyExecutor.FaultInjector?

    /// - Parameter faultInjector: for tests: called before each step is carried out; throwing
    ///   makes that step fail.
    public init(database: CullaDatabase, sessionID: Int64, faultInjector: ApplyExecutor.FaultInjector? = nil) {
        self.database = database
        self.sessionID = sessionID
        self.faultInjector = faultInjector
    }

    private var executor: ApplyExecutor { ApplyExecutor(journal: database, faultInjector: faultInjector) }

    // MARK: Before applying

    /// Whether the shoot folder can be changed, read off the cooperative pool.
    public static func writability(of folder: URL) async -> ShootFolderAccess.Writability {
        await BlockingQueue.shared.run { ShootFolderAccess.writability(of: folder) }
    }

    /// Sizes of companions and the sidecars already beside the photos, for an exact plan
    /// summary. Reads one listing per folder, off the cooperative pool.
    public static func facts(for photos: [PhotoItem], folder: URL) async -> ShootFileFacts {
        let files = photos.map(\.file)
        return await BlockingQueue.shared.run { ShootFileFacts.gather(for: files, folder: folder) }
    }

    /// The plan for the Review and Apply screen: writability and disk facts read off the
    /// cooperative pool, then `SessionState.applyPlan` (pure).
    public static func plan(for state: SessionState, folder: URL, options: ApplyOptions) async -> ApplyPlan {
        let writability = await writability(of: folder)
        let facts = await facts(for: state.photos, folder: folder)
        return state.applyPlan(folder: folder, options: options, folderIsWritable: writability.isWritable, facts: facts)
    }

    /// The Copy Keepers To plan for a read-only shoot.
    public static func copyKeepersPlan(for state: SessionState, folder: URL, destination: URL, options: ApplyOptions) async -> ApplyPlan {
        let writability = await writability(of: destination)
        let facts = await facts(for: state.photos, folder: folder)
        return state.copyKeepersPlan(
            folder: folder, destination: destination, options: options,
            destinationIsWritable: writability.isWritable, facts: facts
        )
    }

    // MARK: Applying

    /// What `apply` did.
    public struct Applied: Sendable {
        public var run: ApplyRunRecord
        public var result: ApplyRunResult
        /// The photos the run took out of the shoot, as they were in the session (with scores):
        /// keep them for `undo` while the shoot stays open.
        public var removedPhotos: [AppliedPhoto]
    }

    /// Carries out a plan (Apply or Copy Keepers), journalled.
    ///
    /// Afterwards: `state.removeAppliedPhotos(applied.result.removedPhotoIDs)` (which also clears
    /// the decision undo history), or `state.clearHistory()` when nothing was removed but the
    /// shoot folder was written (Mark Only); then save the session's photos
    /// (`CullaDatabase.replacePhotos(with:sessionID:)`) and tell `ShootAnalysis`
    /// (`update(photos:)`). Show the banner from `applied.result` and `applied.run.summary`.
    ///
    /// - Parameters:
    ///   - session: the session the plan was made from, for the photos that will leave it.
    ///   - destinationBookmark: Copy Keepers: a bookmark to the destination, saved with the run
    ///     so the sandboxed app can undo after a relaunch.
    ///   - progress: called from a background task after each step.
    public func apply(
        _ plan: ApplyPlan,
        session: SessionState,
        destinationBookmark: Data? = nil,
        progress: @escaping @Sendable (ApplyProgress) -> Void = { _ in }
    ) async throws -> Applied {
        let leaving = session.appliedPhotos(plan.leavingPhotoIDs)
        let run = try await database.startApplyRun(
            sessionID: sessionID, plan: plan, photos: leaving, destinationBookmark: destinationBookmark
        )
        let result = await executor.run(plan, runID: run.id, progress: progress)
        let removed = Set(result.removedPhotoIDs)
        // Read in a task of its own: a cancelled run is a result, not an error.
        let database = database
        let finished = try await Task { try await database.applyRun(id: run.id) }.value
        return Applied(
            run: finished ?? run,
            result: result,
            removedPhotos: leaving.filter { removed.contains($0.id) }
        )
    }

    // MARK: Undoing

    /// What `undo` did.
    public struct Undone: Sendable {
        public var run: ApplyRunRecord
        public var report: UndoReport
        /// The photos that are back in the shoot, with their decisions and ratings (and scores
        /// when the caller passed them in): hand them to `SessionState.restoreAppliedPhotos(_:)`.
        public var restoredPhotos: [AppliedPhoto]
    }

    /// Undoes a run, whole or what is left of it. Afterwards: `state.restoreAppliedPhotos(
    /// undone.restoredPhotos)`, save the session's photos, tell `ShootAnalysis`, and show
    /// `undone.report.skipped` if it is not empty.
    ///
    /// - Parameter known: the photos `apply` returned, if the shoot stayed open since; their
    ///   scores come back too. Otherwise the journal's copies are used, without scores (the score
    ///   cache has them, since the files are back at their paths with their old dates).
    public func undo(
        runID: Int64,
        known: [AppliedPhoto] = [],
        progress: @escaping @Sendable (ApplyProgress) -> Void = { _ in }
    ) async throws -> Undone {
        let steps = try await database.applySteps(runID: runID)
        let report = await executor.undo(steps, runID: runID, progress: progress)
        // Once undo has run, its outcome is read even if the task was cancelled meanwhile.
        let database = database
        let (saved, record) = try await Task {
            (try await database.appliedPhotos(runID: runID), try await database.applyRun(id: runID))
        }.value
        var byID: [String: AppliedPhoto] = [:]
        for photo in saved { byID[photo.id] = photo }
        for photo in known { byID[photo.id] = photo }
        guard let run = record else { throw CullaDatabaseError.noSuchApplyRun(runID) }
        return Undone(run: run, report: report, restoredPhotos: report.restoredPhotoIDs.compactMap { byID[$0] })
    }

    // MARK: Journal

    /// The run Undo Apply acts on, if any.
    public func latestUndoableRun() async throws -> ApplyRunRecord? {
        try await database.latestUndoableApplyRun(sessionID: sessionID)
    }

    /// On launch: runs of this session a crash interrupted, marked as interrupted so they can be
    /// undone like a failed run. Offer "Culla quit while applying. Undo what was done?".
    public func recoverInterruptedRuns() async throws -> [ApplyRunRecord] {
        let interrupted = try await database.interruptedApplyRuns(sessionID: sessionID)
        var recovered: [ApplyRunRecord] = []
        for run in interrupted {
            try await database.markApplyRunInterrupted(id: run.id)
            if let updated = try await database.applyRun(id: run.id) { recovered.append(updated) }
        }
        return recovered
    }
}
