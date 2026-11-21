import CullaAnalysis
import CullaCommands
import CullaCore
import CullaSession
import Foundation
import Testing

/// A burst of frames 0.3 s apart. Each spec gives the frame's sharpness and, optionally, the eye
/// openness of each of its faces (people side by side, at the same places in every frame).
private func burst(_ specs: [(id: String, blur: Double, eyes: [Double?])], pick: String?, tuning: Tuning = Tuning()) -> SessionState {
    let start = Date(timeIntervalSince1970: 2_000_000)
    let items = specs.enumerated().map { index, spec -> PhotoItem in
        let file = PhotoFile(
            id: spec.id, url: URL(fileURLWithPath: "/shoot/\(spec.id)"), fileSize: 5000,
            modificationDate: start, isRAW: false
        )
        var scores = PhotoScores(analysedWidth: 1000, analysedHeight: 1000)
        scores.subjectSharpness = spec.blur
        scores.faces = spec.eyes.enumerated().compactMap { person, eyes in
            guard let eyes else { return nil }
            return FaceScores(
                box: UnitRect(x: 0.2 + Double(person) * 0.3, y: 0.3, width: 0.15, height: 0.2), sizeFraction: 0.2,
                leftEyeOpenness: eyes, rightEyeOpenness: eyes, sharpness: spec.blur
            )
        }
        let metadata = PhotoMetadata(captureDate: start.addingTimeInterval(Double(index) * 0.3), pixelWidth: 1000, pixelHeight: 1000)
        return PhotoItem(file: file, metadata: metadata, scores: scores)
    }
    var state = SessionState(photos: items, tuning: tuning)
    state.setStacks([PhotoStack(members: specs.map(\.id), bestPick: pick)])
    return state
}

@Suite("Stack review")
struct StackReviewTests {
    @Test func notesSayWhatIsWrongNextToThePick() throws {
        let state = burst([
            ("a", 60, [0.9, 0.1]), ("b", 70, [0.9, 0.9]), ("c", 40, [0.9, 0.9]), ("d", 69, [0.9, nil]),
        ], pick: "b")
        let stack = try #require(state.stacks.first)
        let strip = state.faceStrip(forStackContaining: "a")
        #expect(StackReview.notes(for: "a", in: stack, state: state, strip: strip) == [.eyesClosed, .softerThanPick])
        // Within the sharpness margin of the pick, and nobody's eyes closed: only the missing face.
        #expect(StackReview.notes(for: "d", in: stack, state: state, strip: strip) == [.missingFace])
        // The pick carries no comparisons with itself.
        #expect(StackReview.notes(for: "b", in: stack, state: state, strip: strip).isEmpty)
        #expect(StackReview.caption(StackReview.notes(for: "a", in: stack, state: state, strip: strip)) == "eyes closed, softer than the pick")
    }

    @Test func blurryFramesSayBlurryRatherThanSofter() throws {
        let state = burst([("a", 10, []), ("b", 70, [])], pick: "b")
        let stack = try #require(state.stacks.first)
        #expect(StackReview.notes(for: "a", in: stack, state: state) == [.blurry])
    }

    @Test func framesWithoutScoresSaySo() throws {
        var state = burst([("a", 60, []), ("b", 70, [])], pick: "b")
        state.setScores(nil, for: "a")
        let stack = try #require(state.stack(containing: "b"))
        #expect(StackReview.notes(for: "a", in: stack, state: state) == [.notAnalysed])
    }

    @Test func pickReasonNamesWhatDecidedIt() throws {
        let eyes = burst([("a", 80, [0.1]), ("b", 70, [0.9]), ("c", 40, [0.9])], pick: "b")
        #expect(StackReview.pickReason(of: try #require(eyes.stacks.first), state: eyes) == "sharpest frame with all eyes open")
        let plain = burst([("a", 50, []), ("b", 70, [])], pick: "b")
        #expect(StackReview.pickReason(of: try #require(plain.stacks.first), state: plain) == "sharpest frame")
        var hand = plain
        hand.chooseBestPick("a", inStackContaining: "a")
        #expect(StackReview.pickReason(of: try #require(hand.stacks.first), state: hand) == "chosen by you")
    }

    @Test func runnerUpIsTheNextBestFrameNotThePick() throws {
        let state = burst([("a", 40, []), ("b", 70, []), ("c", 65, [])], pick: "b")
        #expect(StackReview.runnerUp(of: try #require(state.stacks.first), state: state) == "c")
        var unscored = state
        for id in ["a", "b", "c"] { unscored.setScores(nil, for: id) }
        // Without scores, the neighbour: after the pick, or before it for the last frame.
        #expect(StackReview.runnerUp(of: try #require(unscored.stacks.first), state: unscored) == "c")
        var last = burst([("a", 40, []), ("b", 70, [])], pick: "b")
        for id in ["a", "b"] { last.setScores(nil, for: id) }
        #expect(StackReview.runnerUp(of: try #require(last.stacks.first), state: last) == "a")
    }

    @Test func aStackOpensOnTheFirstUndecidedFrameThatIsNotThePick() throws {
        var state = burst([("a", 70, []), ("b", 40, []), ("c", 60, [])], pick: "a")
        #expect(StackReview.openingFrame(of: try #require(state.stacks.first), state: state) == "b")
        state.apply(.setDecision(.rejected, ids: ["b"]))
        #expect(StackReview.openingFrame(of: try #require(state.stacks.first), state: state) == "c")
        state.apply(.setDecision(.rejected, ids: ["c"]))
        #expect(StackReview.openingFrame(of: try #require(state.stacks.first), state: state) == "b")
    }

    @Test func acceptingComesRoundToSkippedStacks() {
        let start = Date(timeIntervalSince1970: 3_000_000)
        let items = (0..<6).map { index -> PhotoItem in
            let file = PhotoFile(id: "p\(index)", url: URL(fileURLWithPath: "/s/p\(index)"), fileSize: 1, modificationDate: start, isRAW: false)
            return PhotoItem(file: file, metadata: PhotoMetadata(captureDate: start.addingTimeInterval(Double(index) * 60)))
        }
        var state = SessionState(photos: items)
        state.setStacks([PhotoStack(members: ["p0", "p1"]), PhotoStack(members: ["p2", "p3"]), PhotoStack(members: ["p4", "p5"])])
        // The first was skipped; the second and third are accepted: the first comes back.
        state.acceptStack(containing: "p2")
        #expect(StackReview.stackAfterAccepting("p2", state: state)?.id == "p4")
        state.acceptStack(containing: "p4")
        #expect(StackReview.stackAfterAccepting("p4", state: state)?.id == "p0")
        state.acceptStack(containing: "p0")
        #expect(StackReview.stackAfterAccepting("p0", state: state) == nil)
    }

    @Test func headerWords() {
        #expect(StackReview.title(index: 11, count: 86, frames: 7) == "Stack 12 of 86 · 7 frames")
        #expect(StackReview.durationText(1.84) == "in 1.8 s")
        #expect(StackReview.durationText(12.2) == "in 12 s")
        #expect(StackReview.durationText(125) == "in 2 min 5 s")
    }

    @Test func undoNamesOfStackEdits() {
        #expect(SessionEdit.acceptStack(stackID: "a").menuName == "Accept Stack")
        #expect(SessionEdit.splitFromStack(id: "a").menuName == "Split from Stack")
        #expect(SessionEdit.addToStack(ids: ["a", "b"]).menuName == "Add to Stack")
        #expect(SessionEdit.chooseBestPick(id: "a", stackID: "a").menuName == "Make Best Pick")
        #expect(SessionEdit.chooseBestPick(id: nil, stackID: "a").menuName == "Use Culla’s Best Pick")
        #expect(SessionEdit.acceptAllExactDuplicates(sets: 3).menuName == "Accept All Exact Duplicates")
        #expect(SessionEdit.action(.setDecision(.kept, ids: ["a"])).menuName == "Keep")
    }
}

@Suite("Duplicate review")
struct DuplicateReviewWordsTests {
    @Test func differencesBetweenCopies() {
        let a = DuplicateReview.Copy(name: "a.jpg", folder: "Shoot", bytes: 100, format: "JPEG", width: 3000, height: 2000)
        var b = a
        b.name = "a copy.jpg"
        #expect(DuplicateReview.differingFields([a, b]).isEmpty)
        b.bytes = 50
        b.width = 1500
        b.height = 1000
        #expect(DuplicateReview.differingFields([a, b]) == [.size, .dimensions])
        b.folder = "Shoot ▸ sub"
        b.format = "HEIC"
        #expect(DuplicateReview.differingFields([a, b]) == [.size, .dimensions, .folder, .format, .name])
    }

    @Test func words() {
        #expect(DuplicateReview.pickCaption(.highestResolution) == "Keep: highest resolution")
        #expect(DuplicateReview.bulkResult(sets: 12, rejected: 14) == "Cleared 12 sets, rejected 14 photos.")
        #expect(DuplicateReview.bulkResult(sets: 1, rejected: 1) == "Cleared 1 set, rejected 1 photo.")
        #expect(DuplicateReview.title(index: 1, count: 3) == "Set 2 of 3")
    }
}

@Suite("Stack review layout")
struct StackReviewLayoutTests {
    @Test func bothPanesAndTheStripByDefault() {
        let layout = StackReviewLayout(pickPaneWanted: true, faceStripWanted: true, stackHasFaces: true, faceBoxesOn: true)
        #expect(layout.showsPickPane)
        #expect(layout.showsFaceStrip)
    }

    @Test func hidingThePickPaneLeavesTheStrip() {
        let layout = StackReviewLayout(pickPaneWanted: false, faceStripWanted: true, stackHasFaces: true, faceBoxesOn: true)
        #expect(!layout.showsPickPane)
        #expect(layout.showsFaceStrip)
    }

    @Test func aHiddenOrEmptyStripTakesNoHeight() {
        let hidden = StackReviewLayout(pickPaneWanted: true, faceStripWanted: false, stackHasFaces: true, faceBoxesOn: true)
        #expect(!hidden.showsFaceStrip)
        #expect(hidden.faceStripHeight(ideal: 180, minimum: 102, available: 600) == 0)
        let empty = StackReviewLayout(pickPaneWanted: true, faceStripWanted: true, stackHasFaces: false, faceBoxesOn: true)
        #expect(!empty.showsFaceStrip)
        #expect(empty.faceStripHeight(ideal: 22, minimum: 22, available: 600) == 0)
    }

    @Test func faceBoxesFollowFAndTheOverlay() {
        // Faces wanted: the boxes follow the overlay (B).
        #expect(StackReviewLayout(pickPaneWanted: true, faceStripWanted: true, stackHasFaces: true, faceBoxesOn: true).showsFaceBoxes)
        #expect(!StackReviewLayout(pickPaneWanted: true, faceStripWanted: true, stackHasFaces: true, faceBoxesOn: false).showsFaceBoxes)
        // Faces hidden by F: no boxes, whatever the overlay says.
        #expect(!StackReviewLayout(pickPaneWanted: true, faceStripWanted: false, stackHasFaces: true, faceBoxesOn: true).showsFaceBoxes)
        #expect(!StackReviewLayout(pickPaneWanted: true, faceStripWanted: false, stackHasFaces: true, faceBoxesOn: false).showsFaceBoxes)
        // A stack without faces shows no strip, but F still says faces are wanted: the boxes
        // follow the wish, not the strip.
        let noFaces = StackReviewLayout(pickPaneWanted: false, faceStripWanted: true, stackHasFaces: false, faceBoxesOn: true)
        #expect(!noFaces.showsFaceStrip)
        #expect(noFaces.showsFaceBoxes)
        #expect(StackReviewLayout.showsFaceBoxes(faceStripWanted: true, faceBoxesOn: true))
        #expect(!StackReviewLayout.showsFaceBoxes(faceStripWanted: false, faceBoxesOn: true))
    }

    @Test func theStripTakesItsRowsUpToAShare() {
        let layout = StackReviewLayout(pickPaneWanted: true, faceStripWanted: true, stackHasFaces: true, faceBoxesOn: true)
        // Two rows fit.
        #expect(layout.faceStripHeight(ideal: 174, minimum: 102, available: 600) == 174)
        // Five rows do not: 36% of the room.
        #expect(layout.faceStripHeight(ideal: 390, minimum: 102, available: 600) == 216)
        // A small window still shows one row.
        #expect(layout.faceStripHeight(ideal: 390, minimum: 102, available: 200) == 102)
    }
}
