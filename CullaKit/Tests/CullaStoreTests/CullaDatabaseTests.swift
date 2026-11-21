import CullaCore
import CullaSession
@testable import CullaStore
import Foundation
import Testing

/// A fresh folder under the system's temporary directory, removed when the value goes away.
final class TemporaryFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CullaStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

private let start = Date(timeIntervalSinceReferenceDate: 800_000_000.123456)

private func storedPhoto(_ id: String, decision: Decision = .unreviewed, rating: Int = 0) -> StoredPhoto {
    StoredPhoto(
        id: id,
        fileSize: 1234,
        modificationDate: start,
        isRAW: false,
        companionNames: id.hasSuffix(".jpg") ? [id.replacingOccurrences(of: ".jpg", with: ".NEF").components(separatedBy: "/").last!] : [],
        decision: decision,
        rating: rating,
        metadata: PhotoMetadata(captureDate: start.addingTimeInterval(1.25), pixelWidth: 6000, pixelHeight: 4000, cameraModel: "Z 6")
    )
}

private func scores(sharpness: Double) -> PhotoScores {
    var scores = PhotoScores(analysedWidth: 2048, analysedHeight: 1365)
    scores.subjectSharpness = sharpness
    scores.featurePrint = FeatureVector.encode([0.25, 0.5, 0.75])
    scores.faces = [FaceScores(box: UnitRect(x: 0.1, y: 0.2, width: 0.3, height: 0.3), sizeFraction: 0.3, leftEyeOpenness: 0.2)]
    return scores
}

@Suite("CullaDatabase")
struct CullaDatabaseTests {
    @Test func aFreshFileIsMigrated() async throws {
        let folder = try TemporaryFolder()
        let file = folder.url.appendingPathComponent("nested/Culla.sqlite")
        let database = try await CullaDatabase.open(at: file)
        #expect(try await database.appliedMigrations() == ["1", "2", "3", "4"])
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(try await database.recentSessions().isEmpty)
    }

    /// M5: a shoot's own detection settings are kept with its session; nil means it follows the
    /// default. A database from M4 gains the column empty.
    @Test func aShootsOwnTuningIsKeptWithItsSession() async throws {
        let folder = try TemporaryFolder()
        let file = folder.url.appendingPathComponent("Culla.sqlite")
        let shoot = URL(fileURLWithPath: "/Volumes/Card/DCIM/100NIKON")
        var sessionID: Int64 = 0
        do {
            let old = try CullaDatabase(fileURL: file, migratingUpTo: "3")
            sessionID = try await old.openSession(folder: shoot).id
        }
        let database = try CullaDatabase(fileURL: file)
        #expect(try await database.appliedMigrations() == ["1", "2", "3", "4"])
        #expect(try await database.session(id: sessionID)?.tuning == nil)
        let data = Data("{\"blurryBelow\":15}".utf8)
        try await database.updateTuning(data, sessionID: sessionID)
        #expect(try await database.session(id: sessionID)?.tuning == data)
        #expect(try await database.openSession(folder: shoot).tuning == data)
        try await database.updateTuning(nil, sessionID: sessionID)
        #expect(try await database.session(forFolder: shoot)?.tuning == nil)
    }

    @Test func everythingSurvivesClosingAndReopening() async throws {
        let folder = try TemporaryFolder()
        let file = folder.url.appendingPathComponent("Culla.sqlite")
        let shoot = URL(fileURLWithPath: "/Volumes/Card/DCIM/100NIKON")
        let key = ScoreKey(path: "/Volumes/Card/DCIM/100NIKON/a.jpg", fileSize: 1234, modificationDate: start)
        let sessionID: Int64
        do {
            let database = try CullaDatabase(fileURL: file)
            let session = try await database.openSession(folder: shoot, bookmark: Data([1, 2, 3]))
            sessionID = session.id
            try await database.replacePhotos([storedPhoto("a.jpg"), storedPhoto("sub/b.jpg")], sessionID: session.id)
            try await database.saveMarks([PhotoMark(id: "a.jpg", decision: .rejected, rating: 2)], sessionID: session.id)
            try await database.updatePlace(SessionPlace(group: "blurry", focusedPhotoID: "a.jpg", viewMode: "loupe"), sessionID: session.id)
            try await database.saveScores(scores(sharpness: 42), for: key)
        }

        let reopened = try CullaDatabase(fileURL: file)
        let session = try #require(try await reopened.session(forFolder: shoot))
        #expect(session.id == sessionID)
        #expect(session.bookmark == Data([1, 2, 3]))
        #expect(session.place == SessionPlace(group: "blurry", focusedPhotoID: "a.jpg", viewMode: "loupe"))
        #expect(session.name == "100NIKON")

        let photos = try await reopened.photos(sessionID: session.id).sorted { $0.id < $1.id }
        #expect(photos.map(\.id) == ["a.jpg", "sub/b.jpg"])
        #expect(photos[0].decision == .rejected && photos[0].rating == 2)
        #expect(photos[1].decision == .unreviewed)
        // Dates come back to the last bit, so files are recognised as unchanged.
        #expect(photos[0].modificationDate == start)
        #expect(photos[0].metadata == storedPhoto("a.jpg").metadata)
        #expect(photos[1].companionNames == ["b.NEF"])
        let file1 = photos[1].file(in: shoot)
        #expect(file1.url.path == "/Volumes/Card/DCIM/100NIKON/sub/b.jpg")
        #expect(file1.companions.map(\.path) == ["/Volumes/Card/DCIM/100NIKON/sub/b.NEF"])

        let cached = try await reopened.scores(for: [key])
        #expect(cached[key]?.subjectSharpness == 42)
        #expect(cached[key]?.featureVector == [0.25, 0.5, 0.75])
        #expect(cached[key]?.faces.first?.leftEyeOpenness == 0.2)
    }

    @Test func incrementalSavesTouchOnlyTheGivenPhotos() async throws {
        let database = try CullaDatabase.inMemory()
        let session = try await database.openSession(folder: URL(fileURLWithPath: "/shoot"))
        let ids = (0..<10_000).map { String(format: "IMG_%05d.jpg", $0) }
        try await database.replacePhotos(ids.map { storedPhoto($0) }, sessionID: session.id)

        try await database.saveMarks([PhotoMark(id: ids[5], decision: .kept, rating: 5)], sessionID: session.id)
        var photos = Dictionary(uniqueKeysWithValues: try await database.photos(sessionID: session.id).map { ($0.id, $0) })
        #expect(photos[ids[5]]?.decision == .kept)
        #expect(photos[ids[5]]?.rating == 5)
        #expect(photos.values.filter { $0.decision != .unreviewed }.count == 1)

        // All 10,000 at once, as a bulk change would.
        let clock = ContinuousClock()
        let began = clock.now
        try await database.saveMarks(ids.map { PhotoMark(id: $0, decision: .rejected, rating: 1) }, sessionID: session.id)
        let elapsed = clock.now - began
        print("  saving 10,000 decisions: \(elapsed)")
        #expect(elapsed < .seconds(5))
        photos = Dictionary(uniqueKeysWithValues: try await database.photos(sessionID: session.id).map { ($0.id, $0) })
        #expect(photos.values.allSatisfy { $0.decision == .rejected && $0.rating == 1 })
        // A photo the session does not have is skipped.
        try await database.saveMarks([PhotoMark(id: "nope.jpg", decision: .kept, rating: 0)], sessionID: session.id)
        #expect(try await database.photos(sessionID: session.id).count == 10_000)
    }

    @Test func aRescanReplacesThePhotoList() async throws {
        let database = try CullaDatabase.inMemory()
        let session = try await database.openSession(folder: URL(fileURLWithPath: "/shoot"))
        try await database.replacePhotos([storedPhoto("a.jpg"), storedPhoto("b.jpg")], sessionID: session.id)
        try await database.replacePhotos([storedPhoto("b.jpg", decision: .kept), storedPhoto("c.jpg")], sessionID: session.id)
        let photos = try await database.photos(sessionID: session.id).sorted { $0.id < $1.id }
        #expect(photos.map(\.id) == ["b.jpg", "c.jpg"])
        #expect(photos[0].decision == .kept)
        await #expect(throws: CullaDatabaseError.self) {
            try await database.replacePhotos([storedPhoto("a.jpg")], sessionID: 999)
        }
    }

    @Test func aSessionStateRoundTrips() async throws {
        let database = try CullaDatabase.inMemory()
        let folder = URL(fileURLWithPath: "/shoot")
        let session = try await database.openSession(folder: folder)
        var state = SessionState(photos: [storedPhoto("a.jpg"), storedPhoto("b.jpg")].map { $0.photoItem(in: folder) })
        let change = state.apply(.setDecision(.kept, ids: ["b.jpg"]))
        try await database.replacePhotos(with: state.photos, sessionID: session.id)
        try await database.saveMarks(state.marks(for: change.changedIDs), sessionID: session.id)

        let restored = SessionState(photos: try await database.photos(sessionID: session.id).map { $0.photoItem(in: folder) })
        #expect(restored.photos.map(\.mark) == state.photos.map(\.mark))
        #expect(restored.photos.map(\.file) == state.photos.map(\.file))
    }

    @Test func theScoreCacheMissesOnAnyChange() async throws {
        let database = try CullaDatabase.inMemory()
        let key = ScoreKey(path: "/shoot/a.jpg", fileSize: 100, modificationDate: start)
        try await database.saveScores(scores(sharpness: 10), for: key)

        #expect(try await database.scores(for: [key]).count == 1)
        let resized = ScoreKey(path: key.path, fileSize: 101, modificationDate: start)
        let touched = ScoreKey(path: key.path, fileSize: 100, modificationDate: start.addingTimeInterval(0.001))
        let elsewhere = ScoreKey(path: "/shoot/b.jpg", fileSize: 100, modificationDate: start)
        #expect(try await database.scores(for: [resized, touched, elsewhere]).isEmpty)

        // Scores from an older version never match, and are deleted as stale.
        var old = scores(sharpness: 10)
        old.version = PhotoScores.currentVersion - 1
        let oldKey = ScoreKey(path: "/shoot/old.jpg", fileSize: 1, modificationDate: start)
        try await database.saveScores(old, for: oldKey)
        #expect(try await database.scores(for: [oldKey]).isEmpty)
        #expect(try await database.deleteStaleScores() == 1)
        #expect(try await database.cachedScoreCount() == 1)

        // Saving for a changed file replaces the entry for that path.
        try await database.saveScores(scores(sharpness: 20), for: resized)
        #expect(try await database.cachedScoreCount() == 1)
        #expect(try await database.scores(for: [resized])[resized]?.subjectSharpness == 20)
        #expect(try await database.scores(for: [key]).isEmpty)

        #expect(try await database.deleteStaleScores(savedBefore: Date().addingTimeInterval(60)) == 1)
        #expect(try await database.cachedScoreCount() == 0)
    }

    @Test func recentSessionsAreNewestFirst() async throws {
        let database = try CullaDatabase.inMemory()
        let a = try await database.openSession(folder: URL(fileURLWithPath: "/a"), now: start)
        let b = try await database.openSession(folder: URL(fileURLWithPath: "/b"), now: start.addingTimeInterval(10))
        let c = try await database.openSession(folder: URL(fileURLWithPath: "/c"), now: start.addingTimeInterval(20))
        #expect(try await database.recentSessions().map(\.id) == [c.id, b.id, a.id])

        // Opening again finds the same session and moves it to the front, keeping its creation date.
        let again = try await database.openSession(folder: URL(fileURLWithPath: "/a/"), now: start.addingTimeInterval(30))
        #expect(again.id == a.id)
        #expect(again.createdAt == start)
        #expect(try await database.recentSessions().map(\.id) == [a.id, c.id, b.id])
        #expect(try await database.recentSessions(limit: 1).map(\.id) == [a.id])
    }

    @Test func deletingASessionRemovesItsPhotos() async throws {
        let database = try CullaDatabase.inMemory()
        let keep = try await database.openSession(folder: URL(fileURLWithPath: "/keep"))
        let drop = try await database.openSession(folder: URL(fileURLWithPath: "/drop"))
        try await database.replacePhotos([storedPhoto("a.jpg")], sessionID: keep.id)
        try await database.replacePhotos([storedPhoto("a.jpg"), storedPhoto("b.jpg")], sessionID: drop.id)
        try await database.deleteSession(id: drop.id)
        #expect(try await database.session(id: drop.id) == nil)
        #expect(try await database.photos(sessionID: drop.id).isEmpty)
        #expect(try await database.photos(sessionID: keep.id).count == 1)
        #expect(try await database.recentSessions().map(\.id) == [keep.id])
    }

    @Test func callsFromManyTasksAtOnce() async throws {
        let database = try CullaDatabase.inMemory()
        let session = try await database.openSession(folder: URL(fileURLWithPath: "/shoot"))
        try await database.replacePhotos((0..<100).map { storedPhoto("p\($0).jpg") }, sessionID: session.id)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<100 {
                group.addTask {
                    try await database.saveMarks([PhotoMark(id: "p\(index).jpg", decision: .kept, rating: index % 6)], sessionID: session.id)
                    let key = ScoreKey(path: "/shoot/p\(index).jpg", fileSize: 1, modificationDate: start)
                    try await database.saveScores(scores(sharpness: Double(index)), for: key)
                }
            }
            try await group.waitForAll()
        }
        #expect(try await database.photos(sessionID: session.id).allSatisfy { $0.decision == .kept })
        #expect(try await database.cachedScoreCount() == 100)
    }

    @Test func tenThousandKeysAreFetchedInOneCall() async throws {
        let folder = try TemporaryFolder()
        let database = try CullaDatabase(fileURL: folder.url.appendingPathComponent("culla.sqlite"))
        let keys = (0..<10_000).map { ScoreKey(path: "/shoot/IMG_\($0).jpg", fileSize: Int64(1000 + $0), modificationDate: start) }
        // Saved in batches of 500, as the pipeline does; every tenth file is not cached.
        let cachedKeys = keys.enumerated().filter { $0.offset % 10 != 0 }.map(\.element)
        for batch in stride(from: 0, to: cachedKeys.count, by: 500) {
            let slice = cachedKeys[batch..<min(batch + 500, cachedKeys.count)]
            try await database.saveScores(Dictionary(uniqueKeysWithValues: slice.map { ($0, scores(sharpness: Double($0.fileSize))) }))
        }
        let clock = ContinuousClock()
        let started = clock.now
        let found = try await database.scores(for: keys)
        let elapsed = clock.now - started
        #expect(found.count == 9_000)
        #expect(found[keys[1]]?.subjectSharpness == 1001)
        #expect(found[keys[9_999]]?.featureVector == [0.25, 0.5, 0.75])
        #expect(found[keys[10]] == nil)
        // Generous, for debug builds on a busy machine; release takes about a tenth of this.
        #expect(elapsed < .seconds(5))
    }
}
