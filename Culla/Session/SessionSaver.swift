import CullaAnalysis
import CullaCore
import CullaSession
import CullaStore
import Foundation
import Observation
import os

/// Saves a session's changes to the database in the order they were made, off the main thread.
///
/// Every decision and rating is handed over the moment it is made; GRDB runs the write on its own
/// queue and the main thread never waits for it. Saves of where the user is (group, focus, view
/// mode) are merged: only the latest is written. Quitting waits for `flush()`.
@MainActor
@Observable
final class SessionSaver {
    @ObservationIgnored let database: CullaDatabase
    @ObservationIgnored let sessionID: Int64
    @ObservationIgnored private let activity: ActivityTracker
    @ObservationIgnored private var tail: Task<Void, Never>?
    @ObservationIgnored private var latestPlace: SessionPlace?
    @ObservationIgnored private var placeQueued = false
    @ObservationIgnored private var latestEdits: StackEdits?
    @ObservationIgnored private var editsQueued = false
    @ObservationIgnored private var latestTuning: Tuning??
    @ObservationIgnored private var tuningQueued = false
    /// The last save that failed, for the status bar to report. Cleared by the next save that works.
    private(set) var lastError: String?
    @ObservationIgnored private(set) var pending = 0

    private static let log = Logger(subsystem: "com.kpirliyev.Culla", category: "save")

    init(database: CullaDatabase, sessionID: Int64, activity: ActivityTracker) {
        self.database = database
        self.sessionID = sessionID
        self.activity = activity
    }

    /// Queues a write. Writes run one after another, in the order they were queued.
    func enqueue(_ label: String, _ work: @escaping @Sendable (CullaDatabase, Int64) async throws -> Void) {
        pending += 1
        activity.begin(.saving)
        let previous = tail
        let database = database
        let sessionID = sessionID
        tail = Task { [weak self] in
            await previous?.value
            do {
                try await work(database, sessionID)
                if self?.lastError != nil { self?.lastError = nil }
            } catch {
                Self.log.error("Saving \(label, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                self?.lastError = localized("Could not save: \(error.localizedDescription)")
            }
            self?.pending -= 1
            self?.activity.end(.saving)
        }
    }

    func saveMarks(_ marks: [PhotoMark]) {
        guard !marks.isEmpty else { return }
        enqueue("marks") { database, sessionID in
            try await database.saveMarks(marks, sessionID: sessionID)
        }
    }

    func savePhotos(_ photos: [PhotoItem]) {
        let stored = photos.map(StoredPhoto.init)
        enqueue("photos") { database, sessionID in
            try await database.replacePhotos(stored, sessionID: sessionID)
        }
    }

    /// Saves the manual stack edits (joined stacks, frames split out, hand-chosen picks), replacing
    /// the saved ones. Several calls before the write starts write only the latest edits.
    func saveStackEdits(_ edits: StackEdits) {
        latestEdits = edits
        guard !editsQueued else { return }
        editsQueued = true
        enqueue("stack edits") { [weak self] database, sessionID in
            guard let edits = await self?.takeEdits() else { return }
            try await database.saveStackEdits(edits, sessionID: sessionID)
        }
    }

    private func takeEdits() -> StackEdits? {
        editsQueued = false
        return latestEdits
    }

    /// Saves where the user is. Several calls before the write starts write only the last place.
    func savePlace(_ place: SessionPlace) {
        latestPlace = place
        guard !placeQueued else { return }
        placeQueued = true
        enqueue("place") { [weak self] database, sessionID in
            let place = await self?.takePlace()
            if let place { try await database.updatePlace(place, sessionID: sessionID) }
        }
    }

    private func takePlace() -> SessionPlace? {
        placeQueued = false
        return latestPlace
    }

    /// Saves the shoot's own detection settings, or nil when it follows the default. Several
    /// calls before the write starts (a slider being dragged) write only the latest.
    func saveTuning(_ tuning: Tuning?) {
        latestTuning = .some(tuning)
        guard !tuningQueued else { return }
        tuningQueued = true
        enqueue("tuning") { [weak self] database, sessionID in
            guard let tuning = await self?.takeTuning() else { return }
            let data = try tuning.map { try JSONEncoder().encode($0) }
            try await database.updateTuning(data, sessionID: sessionID)
        }
    }

    private func takeTuning() -> Tuning?? {
        tuningQueued = false
        return latestTuning
    }

    /// Waits until everything queued so far is written.
    func flush() async {
        while let task = tail {
            await task.value
            if tail == task { break }
        }
    }
}
