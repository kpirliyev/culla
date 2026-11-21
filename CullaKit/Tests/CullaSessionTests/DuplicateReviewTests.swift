import CullaAnalysis
import CullaCore
import CullaSession
import Foundation
import Testing

/// A photo with a given file name, folder, pixel size and RAW companion.
private func copy(
    _ name: String,
    at seconds: Double,
    folder: String = "",
    width: Int? = 6000,
    height: Int? = 4000,
    raw: Bool = false,
    rawCompanion: Bool = false
) -> PhotoItem {
    let id = folder.isEmpty ? name : "\(folder)/\(name)"
    let url = URL(fileURLWithPath: "/shoot/\(id)")
    let companion = url.deletingPathExtension().appendingPathExtension("NEF")
    return PhotoItem(
        file: PhotoFile(
            id: id,
            url: url,
            companions: rawCompanion ? [companion] : [],
            fileSize: 1000,
            modificationDate: Fixtures.start,
            isRAW: raw
        ),
        metadata: PhotoMetadata(captureDate: Fixtures.start.addingTimeInterval(seconds), pixelWidth: width, pixelHeight: height)
    )
}

private func decisions(_ state: SessionState, _ ids: [String]) -> [Decision] {
    ids.map { state.photo($0)!.decision }
}

@Suite("Duplicates: the copy to keep")
struct DuplicatePickTests {
    @Test func theHighestResolutionComesFirst() {
        var state = SessionState(photos: [
            copy("IMG_1.jpg", at: 0, width: 1600, height: 1200, raw: true),
            copy("IMG_1 copy.jpg", at: 0.001),
        ])
        state.setDuplicateSets([PhotoDuplicateSet(kind: .near, members: ["IMG_1.jpg", "IMG_1 copy.jpg"])])
        let pick = state.duplicatePick(forSetContaining: "IMG_1.jpg")
        #expect(pick?.id == "IMG_1 copy.jpg")
        #expect(pick?.reason == .highestResolution)
        #expect(pick?.reason.description == "highest resolution")
        #expect(pick?.ranking == ["IMG_1 copy.jpg", "IMG_1.jpg"])
    }

    @Test func thenRAWOverJPEG() {
        var state = SessionState(photos: [copy("IMG_2.jpg", at: 0), copy("IMG_2 copy.jpg", at: 0.001, rawCompanion: true)])
        state.setDuplicateSets([PhotoDuplicateSet(kind: .exact, members: ["IMG_2.jpg", "IMG_2 copy.jpg"])])
        let pick = state.duplicatePick(forSetContaining: "IMG_2.jpg")
        #expect(pick?.id == "IMG_2 copy.jpg")
        #expect(pick?.reason == .rawFile)
    }

    @Test func thenTheOriginalName() {
        var state = SessionState(photos: [copy("IMG_3 (1).jpg", at: 0), copy("IMG_3.jpg", at: 0.001), copy("IMG_3-1.jpg", at: 0.002)])
        state.setDuplicateSets([PhotoDuplicateSet(kind: .exact, members: ["IMG_3 (1).jpg", "IMG_3.jpg", "IMG_3-1.jpg"])])
        let pick = state.duplicatePick(forSetContaining: "IMG_3-1.jpg")
        #expect(pick?.id == "IMG_3.jpg")
        #expect(pick?.reason == .originalName)
    }

    @Test func thenTheShorterNameThenTheFirstByName() {
        var state = SessionState(photos: [
            copy("Beach-edit.jpg", at: 0), copy("Beach.jpg", at: 0.001),
            copy("IMG_9.jpg", at: 10, folder: "b"), copy("IMG_9.jpg", at: 10.001, folder: "a"),
        ])
        state.setDuplicateSets([
            PhotoDuplicateSet(kind: .exact, members: ["Beach-edit.jpg", "Beach.jpg"]),
            PhotoDuplicateSet(kind: .exact, members: ["b/IMG_9.jpg", "a/IMG_9.jpg"]),
        ])
        #expect(state.duplicatePick(forSetContaining: "Beach.jpg")?.reason == .shorterName)
        #expect(state.duplicatePick(forSetContaining: "Beach.jpg")?.id == "Beach.jpg")
        let byPath = state.duplicatePick(forSetContaining: "b/IMG_9.jpg")
        #expect(byPath?.id == "a/IMG_9.jpg")
        #expect(byPath?.reason == .firstByName)
        #expect(state.duplicatePick(forSetContaining: "nope") == nil)
    }

    @Test func thePickFollowsNewMetadata() {
        var state = SessionState(photos: [copy("a.jpg", at: 0), copy("b.jpg", at: 0.001)])
        state.setDuplicateSets([PhotoDuplicateSet(kind: .near, members: ["a.jpg", "b.jpg"])])
        #expect(state.duplicatePick(forSetContaining: "a.jpg")?.id == "a.jpg")
        // A rescan finds b.jpg was replaced by a larger export.
        let bigger = copy("b.jpg", at: 0.001, width: 8000, height: 6000)
        state.merge(scanned: [ScannedPhoto(file: state.photo("a.jpg")!.file, metadata: state.photo("a.jpg")!.metadata),
                              ScannedPhoto(file: bigger.file, metadata: bigger.metadata)])
        #expect(state.duplicatePick(forSetContaining: "a.jpg")?.id == "b.jpg")
    }
}

@Suite("Duplicates: accepting")
struct AcceptDuplicatesTests {
    /// Two exact sets and one near set.
    private func state() -> SessionState {
        var state = SessionState(photos: [
            copy("A.jpg", at: 0), copy("A copy.jpg", at: 0.001), copy("A copy 2.jpg", at: 0.002),
            copy("B (1).jpg", at: 10), copy("B.jpg", at: 10.001),
            copy("C.jpg", at: 20, width: 1000, height: 800), copy("C-small.jpg", at: 20.001, width: 500, height: 400),
            copy("D.jpg", at: 30),
        ])
        state.setDuplicateSets([
            PhotoDuplicateSet(kind: .exact, members: ["A.jpg", "A copy.jpg", "A copy 2.jpg"]),
            PhotoDuplicateSet(kind: .exact, members: ["B (1).jpg", "B.jpg"]),
            PhotoDuplicateSet(kind: .near, members: ["C.jpg", "C-small.jpg"]),
        ])
        return state
    }

    @Test func returnKeepsThePickAndRejectsTheRest() {
        var state = state()
        let change = state.acceptDuplicateSet(containing: "A copy 2.jpg")
        #expect(change.changedIDs == ["A.jpg", "A copy.jpg", "A copy 2.jpg"])
        #expect(decisions(state, ["A.jpg", "A copy.jpg", "A copy 2.jpg"]) == [.kept, .rejected, .rejected])
        #expect(state.undoEdit == .acceptDuplicateSet(setID: "A.jpg"))
        state.undo()
        #expect(decisions(state, ["A.jpg", "A copy.jpg", "A copy 2.jpg"]) == [.unreviewed, .unreviewed, .unreviewed])
        state.redo()
        #expect(decisions(state, ["A.jpg", "A copy.jpg", "A copy 2.jpg"]) == [.kept, .rejected, .rejected])
    }

    @Test func aCopyMarkedKeptIsTheOneKept() {
        var state = state()
        state.apply(.setDecision(.kept, ids: ["A copy.jpg"]))
        let change = state.acceptDuplicateSet(containing: "A.jpg")
        #expect(change.changedIDs == ["A.jpg", "A copy 2.jpg"])
        #expect(decisions(state, ["A.jpg", "A copy.jpg", "A copy 2.jpg"]) == [.rejected, .kept, .rejected])
    }

    @Test func aRejectedPickGivesWayToTheNextInRank() {
        var state = state()
        state.apply(.setDecision(.rejected, ids: ["A.jpg"]))
        state.acceptDuplicateSet(containing: "A.jpg")
        // "A copy.jpg" ranks before "A copy 2.jpg": both are copies, and it is shorter.
        #expect(decisions(state, ["A.jpg", "A copy.jpg", "A copy 2.jpg"]) == [.rejected, .kept, .rejected])
    }

    @Test func aDecidedSetOrAPhotoOutsideSetsChangesNothing() {
        var state = state()
        #expect(state.acceptDuplicateSet(containing: "D.jpg").isEmpty)
        state.acceptDuplicateSet(containing: "B.jpg")
        #expect(state.acceptDuplicateSet(containing: "B.jpg").isEmpty)
        state.undo()
        #expect(!state.canUndo)
    }

    @Test func acceptAllExactDuplicatesIsOneStepAndSkipsNearDuplicates() {
        var state = state()
        // Set B is half decided already: its pick is kept by hand.
        state.apply(.setDecision(.kept, ids: ["B.jpg"]))
        let result = state.acceptAllExactDuplicates()
        #expect(result.sets == 2)
        #expect(result.photos == 4)
        #expect(result.change.changedIDs == ["A.jpg", "A copy.jpg", "A copy 2.jpg", "B (1).jpg"])
        #expect(decisions(state, ["A.jpg", "A copy.jpg", "A copy 2.jpg", "B (1).jpg", "B.jpg"]) == [.kept, .rejected, .rejected, .rejected, .kept])
        // The near-duplicate set is untouched.
        #expect(decisions(state, ["C.jpg", "C-small.jpg"]) == [.unreviewed, .unreviewed])
        #expect(state.undoEdit == .acceptAllExactDuplicates(sets: 2))

        // Nothing left to accept.
        let again = state.acceptAllExactDuplicates()
        #expect(again.sets == 0 && again.photos == 0 && again.change.isEmpty)

        // One undo takes the whole bulk accept back.
        #expect(state.undo()?.changedIDs.count == 4)
        #expect(decisions(state, ["A.jpg", "A copy.jpg", "A copy 2.jpg", "B (1).jpg", "B.jpg"]) == [.unreviewed, .unreviewed, .unreviewed, .unreviewed, .kept])
        state.redo()
        #expect(state.duplicateSetCounts(kind: .exact) == GroupCount(left: 0, total: 2))
        #expect(state.duplicateSetCounts(kind: .near) == GroupCount(left: 1, total: 1))
    }

    @Test func navigationAndCounts() {
        var state = state()
        #expect(state.duplicateSetCounts() == GroupCount(left: 3, total: 3))
        #expect(state.duplicateSetIndex(containing: "B.jpg") == 1)
        #expect(state.nextDuplicateSet(after: "A copy.jpg")?.id == "B (1).jpg")
        #expect(state.nextDuplicateSet(after: "C.jpg") == nil)
        #expect(state.previousDuplicateSet(before: "C-small.jpg")?.id == "B (1).jpg")
        #expect(state.previousDuplicateSet(before: "D.jpg")?.id == "C.jpg")
        #expect(state.nextDuplicateSet(after: "nope") == nil)
        #expect(state.nextUndecidedDuplicateSet()?.id == "A.jpg")

        state.acceptDuplicateSet(containing: "B.jpg")
        #expect(state.isDecided(duplicateSetAt: 1))
        #expect(state.isDuplicateSetDecided(containing: "B (1).jpg"))
        #expect(!state.isDuplicateSetDecided(containing: "A.jpg"))
        #expect(state.nextUndecidedDuplicateSet(after: "A.jpg")?.id == "C.jpg")
        state.acceptDuplicateSet(containing: "C.jpg")
        #expect(state.nextUndecidedDuplicateSet(after: "C.jpg") == nil)
        #expect(state.nextUndecidedDuplicateSet(after: "C.jpg", wrapping: true)?.id == "A.jpg")
        #expect(state.duplicateSetCounts() == GroupCount(left: 1, total: 3))
        // The group's own count stays in photos.
        #expect(state.count(of: .duplicates) == GroupCount(left: 3, total: 7))
    }
}
