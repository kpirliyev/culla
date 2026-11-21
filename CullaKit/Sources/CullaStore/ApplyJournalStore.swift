import CullaCore
import CullaSession
import Foundation
import GRDB

/// One run of Apply or Copy Keepers as the journal keeps it.
public struct ApplyRunRecord: Sendable, Hashable, Identifiable {
    public var id: Int64
    public var sessionID: Int64
    public var kind: ApplyRunKind
    public var state: ApplyRunState
    public var options: ApplyOptions
    /// The plan's summary, for the banner and the run's description.
    public var summary: ApplySummary
    public var folderPath: String
    /// Copy Keepers: the folder copied into, and its bookmark when the caller saved one (the
    /// sandboxed app needs it to undo after a relaunch).
    public var destinationPath: String?
    public var destinationBookmark: Data?
    public var startedAt: Date
    /// When the run, or its latest undo, ended.
    public var finishedAt: Date?
    public var failure: String?
    public var stepCount: Int
    /// Steps undo would still take back: done, recorded as started, or skipped by an earlier undo.
    public var undoableStepCount: Int

    /// True when undo has something to take back and the run is not under way.
    public var isUndoable: Bool { state != .running && state.isUndoable && undoableStepCount > 0 }
}

extension CullaDatabase: ApplyJournal {
    // MARK: - Runs

    /// Starts a run in the journal, as `.running` with no steps yet, before anything is done.
    /// Hand its id to `ApplyExecutor.run(_:runID:progress:)`.
    ///
    /// - Parameter photos: the photos the run will take out of the session
    ///   (`SessionState.appliedPhotos(_:)` of the plan's moved or trashed rejects), saved without
    ///   scores so an undo after a relaunch can bring back their decisions and ratings.
    public func startApplyRun(
        sessionID: Int64,
        plan: ApplyPlan,
        photos: [AppliedPhoto] = [],
        destinationBookmark: Data? = nil,
        now: Date = Date()
    ) async throws -> ApplyRunRecord {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let options = try encoder.encode(plan.options)
        let summary = try encoder.encode(plan.summary)
        let snapshot = try encoder.encode(photos.map(\.withoutScores))
        let id = try await writer.write { db -> Int64 in
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM session WHERE id = ?)", arguments: [sessionID]) == true else {
                throw CullaDatabaseError.noSuchSession(sessionID)
            }
            try db.execute(sql: """
                INSERT INTO applyRun (sessionID, kind, state, options, summary, folderPath, destinationPath,
                                      destinationBookmark, photos, startedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    sessionID, plan.kind.rawValue, ApplyRunState.running.rawValue, options, summary,
                    Self.folderPath(plan.folder), plan.destination.map(Self.folderPath), destinationBookmark,
                    snapshot, now.timeIntervalSinceReferenceDate,
                ])
            return db.lastInsertedRowID
        }
        return try await applyRun(id: id)!
    }

    public func applyRun(id: Int64) async throws -> ApplyRunRecord? {
        try await writer.read { db in
            try Row.fetchOne(db, sql: Self.runQuery + " WHERE r.id = ?", arguments: [id]).map(Self.run(from:))
        }
    }

    /// A session's runs, newest first.
    public func applyRuns(sessionID: Int64) async throws -> [ApplyRunRecord] {
        try await writer.read { db in
            try Row.fetchAll(
                db, sql: Self.runQuery + " WHERE r.sessionID = ? ORDER BY r.startedAt DESC, r.id DESC", arguments: [sessionID]
            ).map(Self.run(from:))
        }
    }

    /// The newest run of the session that undo can take back: done, failed, cancelled or partly
    /// undone, with something left to undo. What the Undo Apply command acts on.
    public func latestUndoableApplyRun(sessionID: Int64) async throws -> ApplyRunRecord? {
        try await applyRuns(sessionID: sessionID).first { $0.isUndoable }
    }

    /// Runs still marked running: on launch, these were interrupted by a crash or a forced quit.
    /// Offer to undo them (after `markApplyRunInterrupted(id:)`). Nil `sessionID` lists every
    /// session's. Only call this when no run is under way in this process.
    public func interruptedApplyRuns(sessionID: Int64? = nil) async throws -> [ApplyRunRecord] {
        try await writer.read { db in
            var sql = Self.runQuery + " WHERE r.state = ?"
            var arguments: StatementArguments = [ApplyRunState.running.rawValue]
            if let sessionID {
                sql += " AND r.sessionID = ?"
                arguments += [sessionID]
            }
            return try Row.fetchAll(db, sql: sql + " ORDER BY r.startedAt DESC, r.id DESC", arguments: arguments).map(Self.run(from:))
        }
    }

    /// Records that a run found running on launch was interrupted: it becomes `.failed` with
    /// that message, and so undoable like any run that stopped part-way. Its steps are left as
    /// they are; undo looks at the disk for any recorded as started.
    public func markApplyRunInterrupted(id: Int64, now: Date = Date()) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE applyRun SET state = ?, failure = ?, finishedAt = ? WHERE id = ? AND state = ?",
                arguments: [ApplyRunState.failed.rawValue, "Interrupted", now.timeIntervalSinceReferenceDate, id, ApplyRunState.running.rawValue]
            )
        }
    }

    /// A run's steps in order.
    public func applySteps(runID: Int64) async throws -> [ApplyStep] {
        try await writer.read { db in
            let decoder = JSONDecoder()
            return try Row.fetchAll(db, sql: "SELECT * FROM applyStep WHERE runID = ? ORDER BY position", arguments: [runID]).map { row in
                let action: Data = row["action"]
                let role: String = row["role"]
                let state: String = row["state"]
                return ApplyStep(
                    index: row["position"],
                    photoID: row["photoID"],
                    role: ApplyFileRole(rawValue: role) ?? .photo,
                    action: try decoder.decode(ApplyStepAction.self, from: action),
                    state: ApplyStepState(rawValue: state) ?? .started,
                    note: row["note"]
                )
            }
        }
    }

    /// The photos a run took out of the session, as saved when it started (without scores).
    public func appliedPhotos(runID: Int64) async throws -> [AppliedPhoto] {
        let data = try await writer.read { db in
            try Data.fetchOne(db, sql: "SELECT photos FROM applyRun WHERE id = ?", arguments: [runID])
        }
        guard let data else { return [] }
        return try JSONDecoder().decode([AppliedPhoto].self, from: data)
    }

    // MARK: - ApplyJournal

    public func recordSteps(_ steps: [ApplyStep], runID: Int64) async throws {
        let encoder = JSONEncoder()
        let rows = try steps.map { step in (step, try encoder.encode(step.action)) }
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM applyStep WHERE runID = ?", arguments: [runID])
            let statement = try db.cachedStatement(sql: """
                INSERT INTO applyStep (runID, position, photoID, role, state, action, note) VALUES (?, ?, ?, ?, ?, ?, ?)
                """)
            for (step, action) in rows {
                try statement.execute(arguments: [runID, step.index, step.photoID, step.role.rawValue, step.state.rawValue, action, step.note])
            }
        }
    }

    public func updateStep(_ step: ApplyStep, runID: Int64) async throws {
        let action = try JSONEncoder().encode(step.action)
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE applyStep SET state = ?, action = ?, note = ? WHERE runID = ? AND position = ?",
                arguments: [step.state.rawValue, action, step.note, runID, step.index]
            )
            guard db.changesCount == 1 else { throw CullaDatabaseError.noSuchApplyStep(runID: runID, index: step.index) }
        }
    }

    public func setRunState(_ state: ApplyRunState, failure: String?, runID: Int64) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE applyRun SET state = ?, failure = ?, finishedAt = ? WHERE id = ?",
                arguments: [state.rawValue, failure, Date().timeIntervalSinceReferenceDate, runID]
            )
        }
    }

    // MARK: - Rows

    private static let runQuery = """
        SELECT r.*,
               (SELECT COUNT(*) FROM applyStep s WHERE s.runID = r.id) AS stepCount,
               (SELECT COUNT(*) FROM applyStep s WHERE s.runID = r.id AND s.state IN ('done', 'started', 'undoSkipped')) AS undoableCount
        FROM applyRun r
        """

    private static func run(from row: Row) throws -> ApplyRunRecord {
        let decoder = JSONDecoder()
        let kind: String = row["kind"]
        let state: String = row["state"]
        let options: Data = row["options"]
        let summary: Data = row["summary"]
        let finished: Double? = row["finishedAt"]
        return ApplyRunRecord(
            id: row["id"],
            sessionID: row["sessionID"],
            kind: ApplyRunKind(rawValue: kind) ?? .apply,
            state: ApplyRunState(rawValue: state) ?? .failed,
            options: (try? decoder.decode(ApplyOptions.self, from: options)) ?? ApplyOptions(),
            summary: (try? decoder.decode(ApplySummary.self, from: summary)) ?? ApplySummary(),
            folderPath: row["folderPath"],
            destinationPath: row["destinationPath"],
            destinationBookmark: row["destinationBookmark"],
            startedAt: Date(timeIntervalSinceReferenceDate: row["startedAt"]),
            finishedAt: finished.map(Date.init(timeIntervalSinceReferenceDate:)),
            failure: row["failure"],
            stepCount: row["stepCount"],
            undoableStepCount: row["undoableCount"]
        )
    }
}
