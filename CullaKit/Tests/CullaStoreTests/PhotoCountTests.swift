import CullaCore
import CullaSession
import CullaStore
import Foundation
import Testing

@Suite("Recent session counts")
struct PhotoCountTests {
    @Test func countsPhotosKeptAndRejectedPerSession() async throws {
        let database = try CullaDatabase.inMemory()
        let first = try await database.openSession(folder: URL(fileURLWithPath: "/shoots/a", isDirectory: true))
        let second = try await database.openSession(folder: URL(fileURLWithPath: "/shoots/b", isDirectory: true))
        let empty = try await database.openSession(folder: URL(fileURLWithPath: "/shoots/c", isDirectory: true))
        let date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func photo(_ id: String, _ decision: Decision) -> StoredPhoto {
            StoredPhoto(id: id, fileSize: 10, modificationDate: date, isRAW: false, decision: decision)
        }
        try await database.replacePhotos(
            [photo("1.jpg", .kept), photo("2.jpg", .rejected), photo("3.jpg", .unreviewed), photo("4.jpg", .kept)],
            sessionID: first.id
        )
        try await database.replacePhotos([photo("1.jpg", .unreviewed)], sessionID: second.id)

        let counts = try await database.photoCounts(sessionIDs: [first.id, second.id, empty.id])
        #expect(counts[first.id] == SessionPhotoCounts(photos: 4, kept: 2, rejected: 1))
        #expect(counts[second.id] == SessionPhotoCounts(photos: 1, kept: 0, rejected: 0))
        #expect(counts[empty.id] == nil)
        #expect(try await database.photoCounts(sessionIDs: []).isEmpty)
    }
}
