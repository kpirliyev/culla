import CullaCore
import CullaSession
import CullaStore
import Foundation
import Testing

private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

private func item(_ id: String, at seconds: Double) -> PhotoItem {
    PhotoItem(
        file: PhotoFile(id: id, url: URL(fileURLWithPath: "/shoot/\(id)"), fileSize: 1000, modificationDate: start, isRAW: false),
        metadata: PhotoMetadata(captureDate: start.addingTimeInterval(seconds))
    )
}

@Suite("CullaDatabase stack edits")
struct StackEditsStoreTests {
    @Test func editsAndHandPicksSurviveReopening() async throws {
        let folder = try TemporaryFolder()
        let file = folder.url.appendingPathComponent("Culla.sqlite")
        let shoot = URL(fileURLWithPath: "/shoot")
        let photos = (0..<8).map { item("p\($0)", at: Double($0)) }
        let automatic = [
            PhotoStack(members: ["p0", "p1", "p2"], bestPick: "p1"),
            PhotoStack(members: ["p4", "p5"], bestPick: "p4"),
        ]

        // Correct the stacks as a user would, saving whenever a change says so.
        var state = SessionState(photos: photos)
        state.setStacks(automatic)
        let sessionID: Int64
        do {
            let database = try CullaDatabase(fileURL: file)
            let session = try await database.openSession(folder: shoot)
            sessionID = session.id
            try await database.replacePhotos(with: state.photos, sessionID: session.id)
            #expect(try await database.stackEdits(sessionID: session.id).isEmpty)
            for change in [
                state.addToStack(["p3", "p4"]),
                state.splitFromStack("p0"),
                state.chooseBestPick("p5", inStackContaining: "p4"),
            ] {
                #expect(change.stackEditsChanged)
                try await database.saveStackEdits(state.stackEdits, sessionID: session.id)
                try await database.saveMarks(state.marks(for: change.changedIDs), sessionID: session.id)
            }
        }

        // Reopen: a fresh state from the stored photos, the automatic stacks recomputed, and the
        // edits loaded on top give the same stacks.
        let reopened = try CullaDatabase(fileURL: file)
        let edits = try await reopened.stackEdits(sessionID: sessionID)
        #expect(edits == state.stackEdits)
        #expect(edits.splitOut == ["p0"])
        #expect(edits.bestPicks == ["p5"])
        #expect(edits.joined == [["p3", "p4", "p5"]])
        let stored = try await reopened.photos(sessionID: sessionID)
        var restored = SessionState(photos: stored.map { $0.photoItem(in: shoot) })
        restored.setStackEdits(edits)
        restored.applyGrouping(SessionGrouping(stacks: automatic, duplicateSets: []))
        #expect(restored.stacks == state.stacks)
        #expect(restored.handPickedBestPicks == ["p5"])
        #expect(restored.stack(containing: "p3")?.bestPick == "p5")
        #expect(try await reopened.appliedMigrations() == ["1", "2", "3", "4"])
    }

    @Test func emptyEditsDeleteTheRowAndSessionsCascade() async throws {
        let database = try CullaDatabase.inMemory()
        let session = try await database.openSession(folder: URL(fileURLWithPath: "/shoot"))
        let edits = StackEdits(joined: [["a", "b"]], splitOut: ["c"], bestPicks: ["a"])
        try await database.saveStackEdits(edits, sessionID: session.id)
        #expect(try await database.stackEdits(sessionID: session.id) == edits)
        // Saving again replaces.
        let fewer = StackEdits(bestPicks: ["b"])
        try await database.saveStackEdits(fewer, sessionID: session.id)
        #expect(try await database.stackEdits(sessionID: session.id) == fewer)
        try await database.saveStackEdits(StackEdits(), sessionID: session.id)
        #expect(try await database.stackEdits(sessionID: session.id).isEmpty)

        try await database.saveStackEdits(edits, sessionID: session.id)
        try await database.deleteSession(id: session.id)
        #expect(try await database.stackEdits(sessionID: session.id).isEmpty)
        await #expect(throws: CullaDatabaseError.self) {
            try await database.saveStackEdits(edits, sessionID: 999)
        }
        // Each session has its own edits.
        let other = try await database.openSession(folder: URL(fileURLWithPath: "/other"))
        #expect(try await database.stackEdits(sessionID: other.id).isEmpty)
    }
}
