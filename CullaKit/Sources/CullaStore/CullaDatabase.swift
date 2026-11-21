import CullaCore
import CullaSession
import Foundation
import GRDB
import Synchronization

public enum CullaDatabaseError: Error, CustomStringConvertible {
    case noSuchSession(Int64)
    /// `updateStep` named a step the journal does not have.
    case noSuchApplyStep(runID: Int64, index: Int)
    case noSuchApplyRun(Int64)

    public var description: String {
        switch self {
        case .noSuchSession(let id): "No session with id \(id)"
        case let .noSuchApplyStep(runID, index): "No step \(index) in apply run \(runID)"
        case .noSuchApplyRun(let id): "No apply run with id \(id)"
        }
    }
}

/// The app's SQLite database: sessions, their photos' decisions and stack edits, and the score
/// cache.
///
/// Every method is async and safe to call from any task. Reads and writes run on GRDB's own
/// dispatch queues, never on the main thread or Swift's cooperative pool, and writes are
/// serialised, so calls can be made in any order without waiting for each other.
public final class CullaDatabase: Sendable {
    let writer: any DatabaseWriter

    /// Opens (creating if needed) the database file at `fileURL`, creating its folder too, and
    /// brings its schema up to date. Blocks while it does; prefer `open(at:)` from async code.
    public init(fileURL: URL) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        writer = try DatabasePool(path: fileURL.path, configuration: Self.configuration())
        try Self.migrator.migrate(writer)
    }

    private init(writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// Opens the database file with its schema brought up to `lastMigration` only, to build a
    /// database as an older version of the app left it. For migration tests.
    init(fileURL: URL, migratingUpTo lastMigration: String) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        writer = try DatabasePool(path: fileURL.path, configuration: Self.configuration())
        try Self.migrator.migrate(writer, upTo: lastMigration)
    }

    /// Opens the database file at `fileURL` off the calling thread. See `init(fileURL:)`.
    public static func open(at fileURL: URL) async throws -> CullaDatabase {
        try await BlockingQueue.shared.run { try CullaDatabase(fileURL: fileURL) }
    }

    /// A database that lives in memory only, for tests and previews.
    public static func inMemory() throws -> CullaDatabase {
        try CullaDatabase(writer: DatabaseQueue(configuration: configuration()))
    }

    private static func configuration() -> Configuration {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.label = "Culla"
        return configuration
    }

    // MARK: - Schema

    /// Numbered migrations. Add a new one for every schema change; never edit a shipped one.
    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("1") { db in
            try db.execute(sql: """
                CREATE TABLE session (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    folderPath TEXT NOT NULL UNIQUE,
                    bookmark BLOB,
                    createdAt REAL NOT NULL,
                    lastOpenedAt REAL NOT NULL,
                    currentGroup TEXT,
                    focusedPhotoID TEXT,
                    viewMode TEXT
                );
                CREATE INDEX session_lastOpenedAt ON session(lastOpenedAt);

                CREATE TABLE photo (
                    sessionID INTEGER NOT NULL REFERENCES session(id) ON DELETE CASCADE,
                    path TEXT NOT NULL,
                    fileSize INTEGER NOT NULL,
                    modifiedAt REAL NOT NULL,
                    isRAW INTEGER NOT NULL,
                    companions TEXT NOT NULL,
                    decision TEXT NOT NULL,
                    rating INTEGER NOT NULL,
                    metadata BLOB NOT NULL,
                    PRIMARY KEY (sessionID, path)
                ) WITHOUT ROWID;

                CREATE TABLE scoreCache (
                    path TEXT PRIMARY KEY NOT NULL,
                    fileSize INTEGER NOT NULL,
                    modifiedAt REAL NOT NULL,
                    version INTEGER NOT NULL,
                    scores BLOB NOT NULL,
                    savedAt REAL NOT NULL
                ) WITHOUT ROWID;
                """)
        }
        // M3: the user's corrections to the stacks, one row per session.
        migrator.registerMigration("2") { db in
            try db.execute(sql: """
                CREATE TABLE stackEdits (
                    sessionID INTEGER PRIMARY KEY NOT NULL REFERENCES session(id) ON DELETE CASCADE,
                    edits BLOB NOT NULL,
                    savedAt REAL NOT NULL
                );
                """)
        }
        // M4: the apply journal. One row per run of Apply or Copy Keepers, one per step.
        migrator.registerMigration("3") { db in
            try db.execute(sql: """
                CREATE TABLE applyRun (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    sessionID INTEGER NOT NULL REFERENCES session(id) ON DELETE CASCADE,
                    kind TEXT NOT NULL,
                    state TEXT NOT NULL,
                    options BLOB NOT NULL,
                    summary BLOB NOT NULL,
                    folderPath TEXT NOT NULL,
                    destinationPath TEXT,
                    destinationBookmark BLOB,
                    photos BLOB NOT NULL,
                    startedAt REAL NOT NULL,
                    finishedAt REAL,
                    failure TEXT
                );
                CREATE INDEX applyRun_session ON applyRun(sessionID, startedAt);

                CREATE TABLE applyStep (
                    runID INTEGER NOT NULL REFERENCES applyRun(id) ON DELETE CASCADE,
                    position INTEGER NOT NULL,
                    photoID TEXT NOT NULL,
                    role TEXT NOT NULL,
                    state TEXT NOT NULL,
                    action BLOB NOT NULL,
                    note TEXT,
                    PRIMARY KEY (runID, position)
                ) WITHOUT ROWID;
                """)
        }
        // M5: a shoot's own detection settings, when they differ from the default (JSON of
        // `Tuning`, which the store does not read). Null: the shoot follows the default.
        migrator.registerMigration("4") { db in
            try db.execute(sql: "ALTER TABLE session ADD COLUMN tuning BLOB")
        }
        return migrator
    }

    /// The migrations applied to this database, in order. For tests and diagnostics.
    public func appliedMigrations() async throws -> [String] {
        try await writer.read { db in try Self.migrator.appliedMigrations(db) }
    }

    // MARK: - Sessions

    /// The session for a folder, created if there is none, with its last-opened date set to now.
    /// A bookmark passed in replaces the saved one.
    public func openSession(folder: URL, bookmark: Data? = nil, now: Date = Date()) async throws -> StoredSession {
        let path = Self.folderPath(folder)
        return try await writer.write { db in
            if let existing = try Self.fetchSession(db, sql: "SELECT * FROM session WHERE folderPath = ?", [path]) {
                try db.execute(
                    sql: "UPDATE session SET lastOpenedAt = ?, bookmark = COALESCE(?, bookmark) WHERE id = ?",
                    arguments: [now.timeIntervalSinceReferenceDate, bookmark, existing.id]
                )
            } else {
                try db.execute(
                    sql: "INSERT INTO session (folderPath, bookmark, createdAt, lastOpenedAt) VALUES (?, ?, ?, ?)",
                    arguments: [path, bookmark, now.timeIntervalSinceReferenceDate, now.timeIntervalSinceReferenceDate]
                )
            }
            return try Self.fetchSession(db, sql: "SELECT * FROM session WHERE folderPath = ?", [path])!
        }
    }

    /// The session for a folder, without creating or touching it.
    public func session(forFolder folder: URL) async throws -> StoredSession? {
        let path = Self.folderPath(folder)
        return try await writer.read { db in
            try Self.fetchSession(db, sql: "SELECT * FROM session WHERE folderPath = ?", [path])
        }
    }

    public func session(id: Int64) async throws -> StoredSession? {
        try await writer.read { db in
            try Self.fetchSession(db, sql: "SELECT * FROM session WHERE id = ?", [id])
        }
    }

    /// Sessions, most recently opened first.
    public func recentSessions(limit: Int = 20) async throws -> [StoredSession] {
        try await writer.read { db in
            try Row.fetchAll(
                db, sql: "SELECT * FROM session ORDER BY lastOpenedAt DESC, id DESC LIMIT ?", arguments: [limit]
            ).map(Self.session(from:))
        }
    }

    /// How many photos each session has, and how many of them are kept and rejected, for the
    /// recent sessions list. Sessions without photos are missing from the result.
    public func photoCounts(sessionIDs: [Int64]) async throws -> [Int64: SessionPhotoCounts] {
        guard !sessionIDs.isEmpty else { return [:] }
        return try await writer.read { db in
            let placeholders = Array(repeating: "?", count: sessionIDs.count).joined(separator: ",")
            let rows = try Row.fetchAll(db, sql: """
                SELECT sessionID, COUNT(*) AS photos,
                       SUM(decision = 'kept') AS kept, SUM(decision = 'rejected') AS rejected
                FROM photo WHERE sessionID IN (\(placeholders)) GROUP BY sessionID
                """, arguments: StatementArguments(sessionIDs))
            var result: [Int64: SessionPhotoCounts] = [:]
            for row in rows {
                result[row["sessionID"]] = SessionPhotoCounts(photos: row["photos"], kept: row["kept"], rejected: row["rejected"])
            }
            return result
        }
    }

    /// Saves where the user is in a shoot.
    public func updatePlace(_ place: SessionPlace, sessionID: Int64) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE session SET currentGroup = ?, focusedPhotoID = ?, viewMode = ? WHERE id = ?",
                arguments: [place.group, place.focusedPhotoID, place.viewMode, sessionID]
            )
        }
    }

    /// Replaces the folder's bookmark, for example after resolving reported it stale.
    public func updateBookmark(_ bookmark: Data, sessionID: Int64) async throws {
        try await writer.write { db in
            try db.execute(sql: "UPDATE session SET bookmark = ? WHERE id = ?", arguments: [bookmark, sessionID])
        }
    }

    /// Records that the folder now lives at another path, for example after it was moved and its
    /// bookmark resolved to the new place. Fails if another session already has that folder.
    /// Saves a shoot's own detection settings, or nil when it follows the default.
    public func updateTuning(_ tuning: Data?, sessionID: Int64) async throws {
        try await writer.write { db in
            try db.execute(sql: "UPDATE session SET tuning = ? WHERE id = ?", arguments: [tuning, sessionID])
        }
    }

    public func updateFolder(_ folder: URL, sessionID: Int64) async throws {
        let path = Self.folderPath(folder)
        try await writer.write { db in
            try db.execute(sql: "UPDATE session SET folderPath = ? WHERE id = ?", arguments: [path, sessionID])
        }
    }

    /// Deletes a session and all its photos. The score cache is left alone.
    public func deleteSession(id: Int64) async throws {
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM session WHERE id = ?", arguments: [id])
        }
    }

    /// The form a folder's path is stored in: symbolic links resolved, then standardised.
    public static func folderPath(_ folder: URL) -> String {
        folder.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func fetchSession(_ db: Database, sql: String, _ arguments: StatementArguments) throws -> StoredSession? {
        try Row.fetchOne(db, sql: sql, arguments: arguments).map(session(from:))
    }

    private static func session(from row: Row) -> StoredSession {
        StoredSession(
            id: row["id"],
            folderPath: row["folderPath"],
            bookmark: row["bookmark"],
            createdAt: Date(timeIntervalSinceReferenceDate: row["createdAt"]),
            lastOpenedAt: Date(timeIntervalSinceReferenceDate: row["lastOpenedAt"]),
            place: SessionPlace(group: row["currentGroup"], focusedPhotoID: row["focusedPhotoID"], viewMode: row["viewMode"]),
            tuning: row["tuning"]
        )
    }

    // MARK: - Photos

    /// Every saved photo of a session, in no particular order (`SessionState` sorts them).
    public func photos(sessionID: Int64) async throws -> [StoredPhoto] {
        try await writer.read { db in
            let decoder = JSONDecoder()
            return try Row.fetchAll(db, sql: "SELECT * FROM photo WHERE sessionID = ?", arguments: [sessionID]).map { row in
                let companions: String = row["companions"]
                let metadata: Data = row["metadata"]
                let decision: String = row["decision"]
                return StoredPhoto(
                    id: row["path"],
                    fileSize: row["fileSize"],
                    modificationDate: Date(timeIntervalSinceReferenceDate: row["modifiedAt"]),
                    isRAW: row["isRAW"],
                    companionNames: try decoder.decode([String].self, from: Data(companions.utf8)),
                    decision: Decision(rawValue: decision) ?? .unreviewed,
                    rating: row["rating"],
                    metadata: (try? decoder.decode(PhotoMetadata.self, from: metadata)) ?? PhotoMetadata()
                )
            }
        }
    }

    /// Saves changed decisions and ratings: what `SessionState.marks(for:)` returns for a
    /// change's ids. One transaction however many photos; photos the session does not have are
    /// skipped.
    public func saveMarks(_ marks: [PhotoMark], sessionID: Int64) async throws {
        guard !marks.isEmpty else { return }
        try await writer.write { db in
            let statement = try db.cachedStatement(
                sql: "UPDATE photo SET decision = ?, rating = ? WHERE sessionID = ? AND path = ?"
            )
            for mark in marks {
                try statement.execute(arguments: [mark.decision.rawValue, mark.rating, sessionID, mark.id])
            }
        }
    }

    /// Replaces a session's saved photos with these, in one transaction: after the first scan of
    /// a shoot, or after a rescan merged into the session.
    public func replacePhotos(_ photos: [StoredPhoto], sessionID: Int64) async throws {
        try await writer.write { db in
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM session WHERE id = ?)", arguments: [sessionID]) == true else {
                throw CullaDatabaseError.noSuchSession(sessionID)
            }
            try db.execute(sql: "DELETE FROM photo WHERE sessionID = ?", arguments: [sessionID])
            let encoder = JSONEncoder()
            let statement = try db.cachedStatement(sql: """
                INSERT INTO photo (sessionID, path, fileSize, modifiedAt, isRAW, companions, decision, rating, metadata)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """)
            for photo in photos {
                let companions = String(decoding: try encoder.encode(photo.companionNames), as: UTF8.self)
                try statement.execute(arguments: [
                    sessionID, photo.id, photo.fileSize, photo.modificationDate.timeIntervalSinceReferenceDate,
                    photo.isRAW, companions, photo.decision.rawValue, photo.rating, try encoder.encode(photo.metadata),
                ])
            }
        }
    }

    /// Replaces a session's saved photos with the photos of a session state.
    public func replacePhotos(with items: [PhotoItem], sessionID: Int64) async throws {
        try await replacePhotos(items.map(StoredPhoto.init), sessionID: sessionID)
    }

    // MARK: - Stack edits

    /// The session's saved stack edits (photos joined and split out, hand-chosen best picks),
    /// for `SessionState.setStackEdits(_:)`. Empty when none were saved, or they cannot be read.
    public func stackEdits(sessionID: Int64) async throws -> StackEdits {
        let data = try await writer.read { db in
            try Data.fetchOne(db, sql: "SELECT edits FROM stackEdits WHERE sessionID = ?", arguments: [sessionID])
        }
        guard let data else { return StackEdits() }
        return (try? JSONDecoder().decode(StackEdits.self, from: data)) ?? StackEdits()
    }

    /// Saves a session's stack edits, replacing the saved ones: call it with
    /// `SessionState.stackEdits` whenever a change reports `stackEditsChanged`. Empty edits
    /// delete the row.
    public func saveStackEdits(_ edits: StackEdits, sessionID: Int64, now: Date = Date()) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = edits.isEmpty ? nil : try encoder.encode(edits)
        try await writer.write { db in
            guard let data else {
                try db.execute(sql: "DELETE FROM stackEdits WHERE sessionID = ?", arguments: [sessionID])
                return
            }
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM session WHERE id = ?)", arguments: [sessionID]) == true else {
                throw CullaDatabaseError.noSuchSession(sessionID)
            }
            try db.execute(
                sql: "INSERT OR REPLACE INTO stackEdits (sessionID, edits, savedAt) VALUES (?, ?, ?)",
                arguments: [sessionID, data, now.timeIntervalSinceReferenceDate]
            )
        }
    }

    // MARK: - Score cache

    /// Cached scores for these files. A file is missing from the result when nothing is cached
    /// for its path, or the cached entry is for another size, modification date or scores version.
    ///
    /// Made for a whole shoot at once: the rows are read in one transaction, then decoded on all
    /// cores, so 10,000 keys take a fraction of a second.
    public func scores(for keys: [ScoreKey]) async throws -> [ScoreKey: PhotoScores] {
        guard !keys.isEmpty else { return [:] }
        let rows = try await writer.read { db in
            let statement = try db.cachedStatement(
                sql: "SELECT scores FROM scoreCache WHERE path = ? AND fileSize = ? AND modifiedAt = ? AND version = ?"
            )
            var rows: [(key: ScoreKey, data: Data)] = []
            for key in keys {
                guard let data = try Data.fetchOne(statement, arguments: [
                    key.path, key.fileSize, key.modificationDate.timeIntervalSinceReferenceDate, PhotoScores.currentVersion,
                ]) else { continue }
                rows.append((key, data))
            }
            return rows
        }
        guard !rows.isEmpty else { return [:] }
        // Decoding is most of the cost. It runs off the cooperative pool, spread over all cores.
        return await BlockingQueue.shared.run {
            let decoded = Mutex([ScoreKey: PhotoScores](minimumCapacity: rows.count))
            let chunk = 256
            let chunks = (rows.count + chunk - 1) / chunk
            DispatchQueue.concurrentPerform(iterations: chunks) { part in
                let decoder = JSONDecoder()
                var local: [(ScoreKey, PhotoScores)] = []
                for row in rows[(part * chunk)..<min(rows.count, (part + 1) * chunk)] {
                    if let scores = try? decoder.decode(PhotoScores.self, from: row.data) { local.append((row.key, scores)) }
                }
                decoded.withLock { found in
                    for (key, scores) in local { found[key] = scores }
                }
            }
            return decoded.withLock { $0 }
        }
    }

    /// Caches scores as they arrive. An entry for the same path replaces the old one, so a file
    /// that changed leaves no stale entry behind.
    public func saveScores(_ entries: [ScoreKey: PhotoScores], now: Date = Date()) async throws {
        guard !entries.isEmpty else { return }
        try await writer.write { db in
            let encoder = JSONEncoder()
            let statement = try db.cachedStatement(sql: """
                INSERT OR REPLACE INTO scoreCache (path, fileSize, modifiedAt, version, scores, savedAt)
                VALUES (?, ?, ?, ?, ?, ?)
                """)
            for (key, scores) in entries {
                try statement.execute(arguments: [
                    key.path, key.fileSize, key.modificationDate.timeIntervalSinceReferenceDate, scores.version,
                    try encoder.encode(scores), now.timeIntervalSinceReferenceDate,
                ])
            }
        }
    }

    /// Caches one photo's scores.
    public func saveScores(_ scores: PhotoScores, for key: ScoreKey) async throws {
        try await saveScores([key: scores])
    }

    /// Deletes cached scores of another scores version, and, when a date is given, those saved
    /// before it. Returns how many entries were deleted.
    @discardableResult
    public func deleteStaleScores(savedBefore date: Date? = nil) async throws -> Int {
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM scoreCache WHERE version != ?", arguments: [PhotoScores.currentVersion])
            var deleted = db.changesCount
            if let date {
                try db.execute(sql: "DELETE FROM scoreCache WHERE savedAt < ?", arguments: [date.timeIntervalSinceReferenceDate])
                deleted += db.changesCount
            }
            return deleted
        }
    }

    /// Moves cached scores to new paths, for files renamed or moved outside Culla
    /// (`MergeResult.renamed`): keys are old absolute paths, values new ones. An entry already at
    /// a new path is replaced.
    public func moveCachedScores(_ moves: [String: String]) async throws {
        guard !moves.isEmpty else { return }
        try await writer.write { db in
            let delete = try db.cachedStatement(sql: "DELETE FROM scoreCache WHERE path = ?")
            let update = try db.cachedStatement(sql: "UPDATE scoreCache SET path = ? WHERE path = ?")
            for (old, new) in moves where old != new {
                try delete.execute(arguments: [new])
                try update.execute(arguments: [new, old])
            }
        }
    }

    /// Deletes the cached scores of these files, whatever their size and date.
    public func deleteScores(forPaths paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        try await writer.write { db in
            let statement = try db.cachedStatement(sql: "DELETE FROM scoreCache WHERE path = ?")
            for path in paths {
                try statement.execute(arguments: [path])
            }
        }
    }

    /// How many score entries are cached, for diagnostics.
    public func cachedScoreCount() async throws -> Int {
        try await writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM scoreCache") ?? 0 }
    }
}
