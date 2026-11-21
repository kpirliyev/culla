import CullaAnalysis
import CullaCore
import CullaSession
import Foundation
import Testing

/// How the limits stay meaningful on a busy machine: every time is CPU time of the test's
/// thread, the best of five runs (see `Timing`). Operations that walk the whole shoot are
/// compared with a baseline measured beside them, one pass over All Photos, and must cost no
/// more than a fixed number of such passes; that catches the regressions that matter (a step
/// that becomes quadratic, or redoes a whole-shoot pass per set or per edit, costs hundreds or
/// thousands of passes) without depending on how fast or busy the machine is. Operations that
/// must not walk the shoot at all have absolute CPU limits far above their cost but far below
/// one pass in a debug build.
@Suite("Stacks and duplicates speed")
struct StackPerformanceTests {
    @Test func collapsedListAndStackNavigationOn20000Photos() {
        let count = 20_000
        var state = SessionState(photos: (0..<count).map { index in
            Fixtures.item(String(format: "IMG_%05d.jpg", index), at: Double(index) * 2, scores: Fixtures.scores(sharpness: Double(index % 100)))
        })
        // 4,000 stacks of four frames, one photo between stacks, and 1,000 duplicate pairs.
        let ids = state.photos.map(\.id)
        state.setStacks(stride(from: 0, to: count, by: 5).map { start in
            PhotoStack(members: Array(ids[start..<start + 4]), bestPick: ids[start + 1])
        })
        state.setDuplicateSets(stride(from: 4, to: count, by: 20).map { start in
            PhotoDuplicateSet(kind: .exact, members: [ids[start], ids[start + 5]])
        })
        #expect(state.stacks.count == 4000)

        // One pass over the shoot, the unit the costly operations are measured in.
        let pass = { _ = state.members(of: .allPhotos) }
        var timings: [(String, Double)] = []
        var passes: [String: Double] = [:]
        func measure(_ name: String, _ work: () -> Void) {
            timings.append((name, Timing.best(work)))
        }
        func measureInPasses(_ name: String, _ work: () -> Void) {
            let (seconds, baseline) = Timing.bestBeside(baseline: pass, work)
            timings.append((name, seconds))
            passes[name] = seconds / baseline
        }

        var grid = state.gridEntries(of: .allPhotos)
        measure("members of All Photos", pass)
        measureInPasses("collapsed list of All Photos") { grid = state.gridEntries(of: .allPhotos) }
        #expect(grid.count == 8000)
        let middle = ids[count / 2 + 2]
        measure("entry containing a photo, next and previous") {
            _ = state.entryIndex(containing: middle, in: grid)
            _ = state.entry(after: middle, in: grid)
            _ = state.entry(before: middle, in: grid)
        }
        measure("stack counts") { _ = state.stackCounts }
        measure("next and previous stack") {
            _ = state.nextStack(after: middle)
            _ = state.previousStack(before: middle)
        }
        measure("next undecided stack from the start") { _ = state.nextUndecidedStack(after: ids[0]) }

        // Return on every stack in turn, as a person clearing them would.
        var accepting = state
        var current: String? = accepting.nextUndecidedStack()?.id
        var accepted = 0
        let acceptTime = Timing.cpuSeconds {
            while let id = current, accepted < 500 {
                accepting.acceptStack(containing: id)
                current = accepting.nextUndecidedStack(after: id)?.id
                accepted += 1
            }
        }
        timings.append(("accept a stack and find the next (mean of 500)", acceptTime / Double(accepted)))
        #expect(accepting.stackCounts == GroupCount(left: 3500, total: 4000))

        measureInPasses("accept all exact duplicates and undo") {
            var copy = state
            let result = copy.acceptAllExactDuplicates()
            #expect(result.sets == 1000)
            copy.undo()
        }

        // Regrouping with edits in place.
        var edited = state
        for index in stride(from: 0, to: 1000, by: 10) {
            edited.splitFromStack(ids[index * 5])
            edited.addToStack([ids[index * 5 + 4], ids[index * 5 + 5]])
        }
        let automatic = SessionGrouping(stacks: state.automaticStacks, duplicateSets: state.duplicateSets)
        measureInPasses("apply a grouping with 200 edits") { edited.applyGrouping(automatic) }
        measureInPasses("apply a grouping without edits") { state.applyGrouping(automatic) }

        for (name, seconds) in timings {
            let ratio = passes[name].map { String(format: " (%.1f passes)", $0) } ?? ""
            print(String(format: "  %@: %.3f ms CPU", name, seconds * 1000) + ratio)
        }
        let byName = Dictionary(uniqueKeysWithValues: timings)
        // In passes over All Photos. Measured on an M2 in a debug build: about 2, 10, 18 and 11.
        // Each limit is about four times that, and well below what a per-set or per-edit pass,
        // or anything quadratic, would cost (1,000 sets, 200 edits, 20,000 photos).
        #expect(passes["collapsed list of All Photos"]! < 8)
        #expect(passes["accept all exact duplicates and undo"]! < 40)
        #expect(passes["apply a grouping with 200 edits"]! < 80)
        #expect(passes["apply a grouping without edits"]! < 50)
        // Operations that must not walk all 20,000 photos. Measured at a few microseconds (stack
        // counts walks the 4,000 stacks: about 0.3 ms); one pass costs about 7 ms in a debug
        // build. The limits leave room for a slow core and still fail if any of them starts
        // walking the shoot repeatedly.
        #expect(byName["entry containing a photo, next and previous"]! < 0.001)
        #expect(byName["stack counts"]! < 0.005)
        #expect(byName["next and previous stack"]! < 0.005)
        #expect(byName["next undecided stack from the start"]! < 0.005)
        #expect(byName["accept a stack and find the next (mean of 500)"]! < 0.005)
    }
}
