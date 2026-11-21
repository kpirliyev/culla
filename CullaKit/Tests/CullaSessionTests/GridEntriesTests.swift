import CullaAnalysis
import CullaCore
import CullaSession
import Foundation
import Testing

@Suite("Collapsed stacks in the grid")
struct GridEntriesTests {
    /// p0 to p9; stacks [p1 p2 p3] with pick p2 and [p6 p7] without a pick.
    private func state() -> SessionState {
        var state = SessionState(photos: (0..<10).map { Fixtures.item("p\($0)", at: Double($0), scores: Fixtures.scores()) })
        state.setStacks([
            PhotoStack(members: ["p1", "p2", "p3"], bestPick: "p2"),
            PhotoStack(members: ["p6", "p7"]),
        ])
        return state
    }

    @Test func allPhotosCollapsesEachStackToOneTile() {
        var state = state()
        state.apply(.setDecisions(["p1": .kept, "p3": .rejected]))
        let grid = state.gridEntries(of: .allPhotos)
        #expect(grid.collapsesStacks)
        #expect(grid.entries.map(\.id) == ["p0", "p1", "p4", "p5", "p6", "p8", "p9"])
        #expect(grid.entries.map(\.representative) == ["p0", "p2", "p4", "p5", "p6", "p8", "p9"])
        let first = try! #require(grid[1].collapsedStack)
        #expect(first.frameCount == 3)
        #expect(first.representativeIsBestPick)
        #expect(first.unreviewedCount == 1)
        #expect(first.decisions == DecisionSummary(unreviewed: 1, kept: 1, rejected: 1))
        #expect(first.decisions.isMixed)
        #expect(!first.isDecided)
        let second = try! #require(grid[4].collapsedStack)
        // Without a pick the first frame stands for the stack.
        #expect(second.representative == "p6" && !second.representativeIsBestPick)
        #expect(second.decisions.uniform == .unreviewed)
        #expect(grid[0].collapsedStack == nil)
    }

    @Test func otherGroupsListEveryFrame() {
        let state = state()
        #expect(!SessionState.collapsesStacks(in: .unreviewed))
        #expect(!SessionState.collapsesStacks(in: .similarStacks))
        #expect(SessionState.collapsesStacks(in: .allPhotos))
        let grid = state.gridEntries(of: .unreviewed)
        #expect(!grid.collapsesStacks)
        #expect(grid.entries.map(\.id) == state.members(of: .unreviewed))
        // A group can still be collapsed when asked; the tile sits at its first frame there.
        var decided = state
        decided.apply(.setDecision(.kept, ids: ["p1"]))
        let collapsed = decided.gridEntries(of: .unreviewed, collapsingStacks: true)
        #expect(collapsed.entries.map(\.id) == ["p0", "p1", "p4", "p5", "p6", "p8", "p9"])
        #expect(decided.entryIndex(containing: "p3", in: collapsed) == 1)
        #expect(decided.entryIndex(containing: "p1", in: collapsed) == 1)
    }

    @Test func anExpandedStackIsListedFrameByFrame() {
        let state = state()
        let grid = state.gridEntries(of: .allPhotos, expanded: ["p1"])
        #expect(grid.entries.map(\.id) == ["p0", "p1", "p2", "p3", "p4", "p5", "p6", "p8", "p9"])
        #expect(grid.entries[1].collapsedStack == nil)
        #expect(state.entryIndex(containing: "p3", in: grid) == 3)
        #expect(state.entryIndex(containing: "p7", in: grid) == 6)
    }

    @Test func navigationOnTheCollapsedList() {
        let state = state()
        let grid = state.gridEntries(of: .allPhotos)
        #expect(state.entryIndex(containing: "p0", in: grid) == 0)
        #expect(state.entryIndex(containing: "p3", in: grid) == 1)
        #expect(state.entryIndex(containing: "p7", in: grid) == 4)
        #expect(state.entryIndex(containing: "nope", in: grid) == nil)
        #expect(state.entry(after: "p2", in: grid)?.id == "p4")
        #expect(state.entry(after: "p0", in: grid)?.id == "p1")
        #expect(state.entry(before: "p4", in: grid)?.id == "p1")
        #expect(state.entry(before: "p7", in: grid)?.id == "p5")
        #expect(state.entry(after: "p9", in: grid) == nil)
        #expect(state.entry(before: "p0", in: grid) == nil)

        // In a group that does not show the photo: the entries around where it would be.
        var decided = state
        decided.apply(.setDecision(.kept, ids: ["p0", "p5", "p9"]))
        let kept = decided.gridEntries(of: .kept)
        #expect(kept.entries.map(\.id) == ["p0", "p5", "p9"])
        #expect(decided.entryIndex(containing: "p4", in: kept) == nil)
        #expect(decided.entry(after: "p4", in: kept)?.id == "p5")
        #expect(decided.entry(before: "p4", in: kept)?.id == "p0")
    }

    @Test func withoutStacksTheListIsTheMembers() {
        let state = SessionState(photos: (0..<5).map { Fixtures.item("p\($0)", at: Double($0)) })
        let grid = state.gridEntries(of: .allPhotos)
        #expect(grid.entries.map(\.id) == state.members(of: .allPhotos))
        #expect(grid.count == 5 && !grid.isEmpty)
    }
}
