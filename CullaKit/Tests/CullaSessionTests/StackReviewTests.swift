import CullaAnalysis
import CullaCore
import CullaSession
import Foundation
import Testing

/// Ten photos p0 to p9, a second apart, each with scores of the given sharpness (default 90).
private func photos(sharpness: [String: Double] = [:], count: Int = 10) -> [PhotoItem] {
    (0..<count).map { index in
        let id = "p\(index)"
        return Fixtures.item(id, at: Double(index), scores: Fixtures.scores(sharpness: sharpness[id] ?? 90))
    }
}

private func decisions(_ state: SessionState, _ ids: [String]) -> [Decision] {
    ids.map { state.photo($0)!.decision }
}

/// Stacks [p0 p1 p2] with pick p1, [p4 p5] with pick p5, [p7 p8] without a pick.
private func stackedState() -> SessionState {
    var state = SessionState(photos: photos())
    state.setStacks([
        PhotoStack(members: ["p0", "p1", "p2"], bestPick: "p1"),
        PhotoStack(members: ["p4", "p5"], bestPick: "p5"),
        PhotoStack(members: ["p7", "p8"]),
    ])
    return state
}

@Suite("Stack review: accepting")
struct AcceptStackTests {
    @Test func returnKeepsThePickAndRejectsTheRest() {
        var state = stackedState()
        let change = state.acceptStack(containing: "p2")
        #expect(change.changedIDs == ["p0", "p1", "p2"])
        #expect(!change.stackEditsChanged)
        #expect(decisions(state, ["p0", "p1", "p2"]) == [.rejected, .kept, .rejected])
        #expect(state.undoEdit == .acceptStack(stackID: "p0"))
        #expect(state.undoAction == .setDecisions(["p0": .rejected, "p1": .kept, "p2": .rejected]))

        // One undo step takes it all back, and redo applies it again.
        #expect(state.undo()?.changedIDs == ["p0", "p1", "p2"])
        #expect(decisions(state, ["p0", "p1", "p2"]) == [.unreviewed, .unreviewed, .unreviewed])
        #expect(state.redo()?.changedIDs == ["p0", "p1", "p2"])
        #expect(decisions(state, ["p0", "p1", "p2"]) == [.rejected, .kept, .rejected])
        #expect(state.redoEdit == nil)
    }

    @Test func framesMarkedKeptAreTheOnesKept() {
        var state = stackedState()
        state.apply(.setDecision(.kept, ids: ["p0", "p2"]))
        let change = state.acceptStack(containing: "p0")
        #expect(change.changedIDs == ["p1"])
        #expect(decisions(state, ["p0", "p1", "p2"]) == [.kept, .rejected, .kept])
        state.undo()
        #expect(decisions(state, ["p0", "p1", "p2"]) == [.kept, .unreviewed, .kept])
    }

    @Test func rejectedFramesStayRejectedAndARejectedPickIsReplaced() {
        // The user rejected the pick p1; of the frames left the sharpest, p2, is kept.
        var state = SessionState(photos: photos(sharpness: ["p0": 40, "p2": 80]))
        state.setStacks([PhotoStack(members: ["p0", "p1", "p2"], bestPick: "p1")])
        state.apply(.setDecision(.rejected, ids: ["p1"]))
        let change = state.acceptStack(containing: "p1")
        #expect(change.changedIDs == ["p0", "p2"])
        #expect(decisions(state, ["p0", "p1", "p2"]) == [.rejected, .rejected, .kept])
    }

    @Test func withoutAPickTheFirstFrameIsKept() {
        // No scores: nothing to rank by.
        var state = SessionState(photos: (0..<3).map { Fixtures.item("p\($0)", at: Double($0)) })
        state.setStacks([PhotoStack(members: ["p0", "p1", "p2"])])
        state.acceptStack(containing: "p1")
        #expect(decisions(state, ["p0", "p1", "p2"]) == [.kept, .rejected, .rejected])
    }

    @Test func aDecidedStackOrAPhotoOutsideStacksChangesNothing() {
        var state = stackedState()
        #expect(state.acceptStack(containing: "p3").isEmpty)
        #expect(state.acceptStack(containing: "nope").isEmpty)
        state.acceptStack(containing: "p4")
        let undoCount = state.undoEdit
        #expect(state.acceptStack(containing: "p4").isEmpty)
        // No step was recorded for the empty accept.
        #expect(state.undoEdit == undoCount)
        state.undo()
        #expect(!state.canUndo)
    }

    @Test func acceptingClearsTheRedoHistory() {
        var state = stackedState()
        state.apply(.setDecision(.kept, ids: ["p9"]))
        state.undo()
        #expect(state.canRedo)
        state.acceptStack(containing: "p0")
        #expect(!state.canRedo)
    }
}

@Suite("Stack review: moving between stacks")
struct StackNavigationTests {
    @Test func stacksInCaptureOrder() {
        let state = stackedState()
        #expect(state.stacks.map(\.id) == ["p0", "p4", "p7"])
        #expect(state.stackIndex(containing: "p5") == 1)
        #expect(state.stackIndex(containing: "p3") == nil)

        #expect(state.nextStack(after: "p0")?.id == "p4")
        #expect(state.nextStack(after: "p2")?.id == "p4")
        // From a photo outside every stack: the first stack after it.
        #expect(state.nextStack(after: "p3")?.id == "p4")
        #expect(state.nextStack(after: "p8") == nil)
        #expect(state.nextStack(after: "p9") == nil)
        #expect(state.previousStack(before: "p5")?.id == "p0")
        #expect(state.previousStack(before: "p6")?.id == "p4")
        #expect(state.previousStack(before: "p1") == nil)
        #expect(state.nextStack(after: "nope") == nil)
    }

    @Test func decidedStacksAndCounts() {
        var state = stackedState()
        #expect(state.stackCounts == GroupCount(left: 3, total: 3))
        #expect(state.count(of: .similarStacks) == GroupCount(left: 7, total: 7))
        #expect(!state.isDecided(stackAt: 1))
        #expect(state.unreviewedCount(ofStackAt: 1) == 2)

        state.apply(.setDecision(.kept, ids: ["p4"]))
        #expect(!state.isStackDecided(containing: "p4"))
        #expect(state.decisionSummary(ofStackAt: 1) == DecisionSummary(unreviewed: 1, kept: 1, rejected: 0))
        #expect(state.decisionSummary(ofStackAt: 1).isMixed)
        state.acceptStack(containing: "p4")
        #expect(state.isStackDecided(containing: "p5"))
        #expect(state.isDecided(stackAt: 1))
        #expect(state.stackCounts == GroupCount(left: 2, total: 3))
        // The group's own count stays in photos.
        #expect(state.count(of: .similarStacks) == GroupCount(left: 5, total: 7))
        state.undo()
        #expect(state.stackCounts == GroupCount(left: 3, total: 3))
        #expect(!state.isDecided(stackAt: 99))
        #expect(!state.isStackDecided(containing: "p3"))
    }

    @Test func nextUndecidedStackSkipsDecidedOnesAndCanWrap() {
        var state = stackedState()
        #expect(state.nextUndecidedStack()?.id == "p0")
        state.acceptStack(containing: "p4")
        #expect(state.nextUndecidedStack(after: "p0")?.id == "p7")
        // Down arrow on the first stack leaves it undecided; Return on the last one then finds
        // no stack after it.
        state.acceptStack(containing: "p7")
        #expect(state.nextUndecidedStack(after: "p7") == nil)
        // Wrapping brings back the stack skipped earlier, but never the one asked from.
        #expect(state.nextUndecidedStack(after: "p7", wrapping: true)?.id == "p0")
        #expect(state.nextUndecidedStack(after: "p1", wrapping: true) == nil)
        state.acceptStack(containing: "p0")
        #expect(state.nextUndecidedStack() == nil)
        #expect(state.stackCounts == GroupCount(left: 0, total: 3))
    }
}

@Suite("Stack review: correcting stacks")
struct StackEditTests {
    @Test func addToStackMergesStacksAndLoosePhotos() {
        var state = stackedState()
        let change = state.addToStack(["p3", "p4"])
        #expect(change.stackEditsChanged)
        #expect(change.changedIDs.isEmpty)
        #expect(!change.isEmpty)
        #expect(state.stacks.map(\.members) == [["p0", "p1", "p2"], ["p3", "p4", "p5"], ["p7", "p8"]])
        #expect(state.stackEdits.joined == [["p3", "p4", "p5"]])
        #expect(state.undoEdit == .addToStack(ids: ["p3", "p4"]))
        #expect(state.undoAction == nil)
        #expect(state.members(of: .similarStacks).contains("p3"))

        // Two stacks become one.
        state.addToStack(["p2", "p7"])
        #expect(state.stacks.map(\.members) == [["p0", "p1", "p2", "p7", "p8"], ["p3", "p4", "p5"]])

        #expect(state.undo()?.stackEditsChanged == true)
        #expect(state.stacks.map(\.members) == [["p0", "p1", "p2"], ["p3", "p4", "p5"], ["p7", "p8"]])
        state.undo()
        #expect(state.stacks == stackedState().stacks)
        #expect(state.stackEdits.isEmpty)
        state.redo()
        #expect(state.stacks.map(\.members) == [["p0", "p1", "p2"], ["p3", "p4", "p5"], ["p7", "p8"]])
    }

    @Test func addToStackThatChangesNothingRecordsNothing() {
        var state = stackedState()
        #expect(state.addToStack(["p3"]).isEmpty)
        #expect(state.addToStack(["p0", "p2"]).isEmpty)
        #expect(state.addToStack(["p0"]).isEmpty)
        #expect(state.addToStack(["nope", "p9"]).isEmpty)
        #expect(!state.canUndo)
        // Two loose photos make a new stack.
        state.addToStack(["p9", "p3"])
        #expect(state.stack(containing: "p9")?.members == ["p3", "p9"])
    }

    @Test func splitOutReturnsTheFrameToUnreviewed() {
        var state = stackedState()
        state.acceptStack(containing: "p0")
        let change = state.splitFromStack("p2")
        #expect(change.changedIDs == ["p2"])
        #expect(change.stackEditsChanged)
        #expect(state.photo("p2")?.decision == .unreviewed)
        #expect(state.stack(containing: "p0")?.members == ["p0", "p1"])
        #expect(state.stack(containing: "p2") == nil)
        #expect(state.undoEdit == .splitFromStack(id: "p2"))

        // One undo brings back both the decision and the stack.
        let undone = state.undo()
        #expect(undone?.changedIDs == ["p2"])
        #expect(state.photo("p2")?.decision == .rejected)
        #expect(state.stack(containing: "p2")?.members == ["p0", "p1", "p2"])
        state.redo()
        #expect(state.stack(containing: "p2") == nil)
        #expect(state.photo("p2")?.decision == .unreviewed)
    }

    @Test func aStackLeftWithOneFrameStopsBeingAStack() {
        var state = stackedState()
        state.splitFromStack("p5")
        #expect(state.stack(containing: "p4") == nil)
        #expect(state.stacks.map(\.id) == ["p0", "p7"])
        #expect(state.splitFromStack("p4").isEmpty)
        #expect(state.splitFromStack("p3").isEmpty)
    }

    @Test func editsSurviveAutomaticRegrouping() {
        var state = stackedState()
        state.addToStack(["p3", "p4"])
        state.splitFromStack("p0")
        // The engine sends the same automatic stacks again, as it does after every batch.
        let automatic = SessionGrouping(
            stacks: [
                PhotoStack(members: ["p0", "p1", "p2"], bestPick: "p0"),
                PhotoStack(members: ["p4", "p5"], bestPick: "p5"),
                PhotoStack(members: ["p7", "p8"]),
            ],
            duplicateSets: []
        )
        state.applyGrouping(automatic)
        #expect(state.stacks.map(\.members) == [["p1", "p2"], ["p3", "p4", "p5"], ["p7", "p8"]])
        #expect(state.automaticStacks.map(\.members) == [["p0", "p1", "p2"], ["p4", "p5"], ["p7", "p8"]])
    }

    @Test func joinedPhotosStayJoinedWhenTheGrouperSeparatesThem() {
        var state = stackedState()
        state.addToStack(["p2", "p3"])
        // The grouper now splits the first stack and knows nothing of p3.
        state.applyGrouping(SessionGrouping(
            stacks: [PhotoStack(members: ["p0", "p1"]), PhotoStack(members: ["p2", "p9"])],
            duplicateSets: []
        ))
        // p0 p1 p2 p3 were joined together; p9 comes along through its automatic stack with p2.
        #expect(state.stacks.map(\.members) == [["p0", "p1", "p2", "p3", "p9"]])
    }

    @Test func aSplitOutPhotoStaysOutWhateverShapeTheStacksTake() {
        var state = stackedState()
        state.splitFromStack("p1")
        // The automatic stack changes shape and would now put p1 with other photos.
        state.applyGrouping(SessionGrouping(
            stacks: [PhotoStack(members: ["p1", "p2", "p3"]), PhotoStack(members: ["p0", "p9"])],
            duplicateSets: []
        ))
        #expect(state.stack(containing: "p1") == nil)
        #expect(state.stacks.map(\.members) == [["p0", "p9"], ["p2", "p3"]])
        // Adding it to a stack again brings it back, and it is no longer split out.
        state.addToStack(["p1", "p2"])
        #expect(state.stack(containing: "p1")?.members == ["p1", "p2", "p3"])
        #expect(!state.stackEdits.splitOut.contains("p1"))
    }

    @Test func splittingAJoinedFrameKeepsTheRestJoined() {
        var state = stackedState()
        state.addToStack(["p2", "p3"])
        state.splitFromStack("p3")
        #expect(state.stackEdits.joined == [["p0", "p1", "p2"]])
        // Without the automatic stack the remaining frames still hold together.
        state.applyGrouping(SessionGrouping(stacks: [], duplicateSets: []))
        #expect(state.stacks.map(\.members) == [["p0", "p1", "p2"]])
    }

    @Test func handChosenPicksAreKeptAcrossRegrouping() {
        var state = stackedState()
        #expect(state.handPickedBestPicks.isEmpty)
        let set = state.setBestPick("p2", ofStackContaining: "p0")
        #expect(set)
        #expect(state.handPickedBestPicks == ["p2"])
        #expect(state.isHandPicked(state.stack(containing: "p0")!))
        #expect(!state.isHandPicked(state.stack(containing: "p4")!))
        // Automatic grouping proposes another pick; the hand-chosen one stays.
        state.applyGrouping(SessionGrouping(
            stacks: [PhotoStack(members: ["p0", "p1", "p2"], bestPick: "p0"), PhotoStack(members: ["p4", "p5"], bestPick: "p4")],
            duplicateSets: []
        ))
        #expect(state.stack(containing: "p0")?.bestPick == "p2")
        #expect(state.stack(containing: "p4")?.bestPick == "p4")
        // Nil goes back to Culla's pick.
        state.setBestPick(nil, ofStackContaining: "p0")
        #expect(state.stack(containing: "p0")?.bestPick == "p0")
        #expect(state.handPickedBestPicks.isEmpty)
    }

    @Test func choosingAPickIsUndoable() {
        var state = stackedState()
        let change = state.chooseBestPick("p0", inStackContaining: "p1")
        #expect(change.stackEditsChanged)
        #expect(state.stack(containing: "p0")?.bestPick == "p0")
        #expect(state.undoEdit == .chooseBestPick(id: "p0", stackID: "p0"))
        state.chooseBestPick("p2", inStackContaining: "p1")
        #expect(state.handPickedBestPicks == ["p2"])
        state.undo()
        #expect(state.handPickedBestPicks == ["p0"])
        state.undo()
        #expect(state.stack(containing: "p0")?.bestPick == "p1")
        #expect(state.handPickedBestPicks.isEmpty)
        #expect(state.chooseBestPick("p9", inStackContaining: "p1").isEmpty)
        #expect(state.chooseBestPick("p0", inStackContaining: "p3").isEmpty)
    }

    @Test func joiningStacksWithTwoHandPicksKeepsTheEarliest() {
        var state = stackedState()
        state.setBestPick("p2", ofStackContaining: "p0")
        state.setBestPick("p4", ofStackContaining: "p4")
        state.addToStack(["p0", "p4"])
        #expect(state.stack(containing: "p0")?.bestPick == "p2")
        #expect(state.handPickedBestPicks == ["p2"])
    }

    @Test func aJoinedStackGetsThePickItsScoresGive() {
        var state = SessionState(photos: photos(sharpness: ["p8": 99, "p0": 50, "p1": 50, "p2": 50]))
        state.setStacks([PhotoStack(members: ["p0", "p1", "p2"], bestPick: "p1")])
        state.addToStack(["p2", "p8"])
        #expect(state.stack(containing: "p0")?.bestPick == "p8")
        // A stack that is just the automatic one with a frame split out keeps its pick.
        state.splitFromStack("p8")
        #expect(state.stack(containing: "p0")?.bestPick == "p1")
    }

    @Test func splittingOutTheHandPickForgetsIt() {
        var state = stackedState()
        state.setBestPick("p2", ofStackContaining: "p0")
        state.splitFromStack("p2")
        #expect(state.handPickedBestPicks.isEmpty)
        #expect(state.stack(containing: "p0")?.bestPick == "p1")
    }

    @Test func loadedEditsApplyToTheStacks() {
        var state = stackedState()
        state.setStackEdits(StackEdits(joined: [["p3", "p9"]], splitOut: ["p8"], bestPicks: ["p4"]))
        #expect(state.stacks.map(\.members) == [["p0", "p1", "p2"], ["p3", "p9"], ["p4", "p5"]])
        #expect(state.stack(containing: "p5")?.bestPick == "p4")
        #expect(!state.canUndo)
        // Edits about photos the session does not have are kept but ignored.
        state.setStackEdits(StackEdits(joined: [["ghost", "p9"]], splitOut: ["ghost2"]))
        #expect(state.stack(containing: "p9") == nil)
        #expect(state.stackEdits.splitOut == ["ghost2"])
    }

    @Test func editsSurviveARescan() {
        var state = stackedState()
        state.splitFromStack("p1")
        state.merge(scanned: state.photos.map { ScannedPhoto(file: $0.file, metadata: $0.metadata) })
        #expect(state.stack(containing: "p1") == nil)
        #expect(state.stack(containing: "p0")?.members == ["p0", "p2"])
    }

    @Test func decisionsAndStackEditsShareOneHistory() {
        var state = stackedState()
        state.apply(.setDecision(.kept, ids: ["p3"]))
        state.addToStack(["p3", "p4"])
        state.acceptStack(containing: "p3")
        state.splitFromStack("p5")
        #expect(state.stacks.map(\.members) == [["p0", "p1", "p2"], ["p3", "p4"], ["p7", "p8"]])
        for _ in 0..<4 { state.undo() }
        #expect(!state.canUndo)
        #expect(state.stacks == stackedState().stacks)
        #expect(state.photos.allSatisfy { $0.decision == .unreviewed })
        for _ in 0..<4 { state.redo() }
        #expect(decisions(state, ["p3", "p4", "p5"]) == [.kept, .rejected, .unreviewed])
        #expect(state.stacks.map(\.members) == [["p0", "p1", "p2"], ["p3", "p4"], ["p7", "p8"]])
    }

    @Test func editsEncodeTheSameWhateverTheirOrder() throws {
        let a = StackEdits(joined: [["b", "a"], ["d", "c"]], splitOut: ["x", "y"], bestPicks: ["q", "p"])
        let b = StackEdits(joined: [["c", "d"], ["a", "b"]], splitOut: ["y", "x"], bestPicks: ["p", "q"])
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        #expect(try encoder.encode(a) == encoder.encode(b))
        let decoded = try JSONDecoder().decode(StackEdits.self, from: Data("{\"splitOut\":[\"x\"]}".utf8))
        #expect(decoded == StackEdits(splitOut: ["x"]))
    }
}

@Suite("Stack review: face strip and compare")
struct FaceStripAndCompareTests {
    @Test func theFaceStripMatchesTheFramesOfAStack() {
        var scores = Fixtures.scores(openness: 0.4)
        var closed = Fixtures.scores(openness: 0.05)
        scores.analysedWidth = 1500
        closed.analysedWidth = 1500
        var state = SessionState(photos: [
            Fixtures.item("a", at: 0, scores: scores),
            Fixtures.item("b", at: 1, scores: closed),
            Fixtures.item("c", at: 2),
        ])
        state.setStacks([PhotoStack(members: ["a", "b", "c"])])
        let strip = state.faceStrip(forStackContaining: "b")
        #expect(strip?.frames == ["a", "b", "c"])
        #expect(strip?.matching.rows.map(\.faces) == [[0, 0, nil]])
        #expect(state.faceStrip(forStackContaining: "nope") == nil)
    }

    @Test func compareChoosesFromTheSelection() {
        var state = stackedState()
        #expect(state.comparePhotos(selection: ["p5", "p2"], focused: "p2") == ["p2", "p5"])
        #expect(state.comparePhotos(selection: ["p3", "p1", "p2", "p0"], focused: nil) == ["p0", "p1", "p2", "p3"])
        let six = ["p0", "p1", "p2", "p3", "p4", "p5"]
        #expect(state.comparePhotos(selection: six, focused: "p1") == ["p1", "p2", "p3", "p4"])
        #expect(state.comparePhotos(selection: six, focused: "p4") == ["p2", "p3", "p4", "p5"])
        #expect(state.comparePhotos(selection: six, focused: nil) == ["p0", "p1", "p2", "p3"])
        #expect(state.comparePhotos(selection: six + ["ghost", "p0"], focused: "p9") == ["p0", "p1", "p2", "p3"])

        // One photo: the frame against its stack's pick, the pick on the right.
        #expect(state.comparePhotos(selection: ["p0"], focused: "p0") == ["p0", "p1"])
        #expect(state.comparePhotos(selection: [], focused: "p2") == ["p2", "p1"])
        // The pick itself is compared with the next frame, the last frame with the one before.
        #expect(state.compareWithBestPick("p1") == ["p1", "p2"])
        #expect(state.compareWithBestPick("p8") == ["p8", "p7"])
        state.setBestPick("p2", ofStackContaining: "p0")
        #expect(state.compareWithBestPick("p2") == ["p2", "p1"])
        // A photo in no stack has nothing to compare with.
        #expect(state.comparePhotos(selection: ["p3"], focused: "p3").isEmpty)
        #expect(state.comparePhotos(selection: [], focused: nil).isEmpty)
    }
}
