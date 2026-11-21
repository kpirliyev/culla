import CullaAnalysis
import Foundation
import Testing

private let start = Date(timeIntervalSince1970: 1_700_000_000)

/// Feature vectors at known distances from `base`.
private let base: [Float] = [0, 0, 0, 0]
private func near(_ distance: Float) -> [Float] { [distance, 0, 0, 0] }

@Suite("StackGrouper")
struct StackGrouperTests {
    private func candidate(
        _ seconds: Double,
        feature: [Float]? = base,
        burst: String? = nil,
        hasCaptureDate: Bool = true
    ) -> StackCandidate {
        StackCandidate(
            date: start.addingTimeInterval(seconds),
            hasCaptureDate: hasCaptureDate,
            burstID: burst,
            feature: feature
        )
    }

    @Test func framesWithinTheGapAndDistanceJoin() {
        let stacking = StackGrouper.group(
            [candidate(0), candidate(1, feature: near(0.1)), candidate(2.5, feature: near(0.3))],
            tuning: Tuning()
        )
        #expect(stacking.stacks == [[0, 1, 2]])
        #expect(stacking.links.allSatisfy { $0.isLinked })
    }

    @Test func aGapOverTheLimitSplits() {
        let stacking = StackGrouper.group(
            [candidate(0), candidate(1), candidate(12), candidate(13)],
            tuning: Tuning()
        )
        #expect(stacking.stacks == [[0, 1], [2, 3]])
        #expect(stacking.links.map(\.isLinked) == [true, false, true])
        #expect(abs(stacking.links[1].gapSeconds - 11) < 1e-9)
    }

    @Test func aDistanceOverTheLimitSplits() {
        let stacking = StackGrouper.group(
            [candidate(0), candidate(0.5), candidate(1, feature: near(0.9)), candidate(1.5, feature: near(0.9))],
            tuning: Tuning()
        )
        #expect(stacking.stacks == [[0, 1], [2, 3]])
        let distance = stacking.links[1].distance ?? -1
        #expect(abs(distance - 0.9) < 1e-6)
        #expect(!stacking.links[1].isLinked)
    }

    @Test func missingFeaturesNeverLookAlike() {
        let stacking = StackGrouper.group([candidate(0), candidate(1, feature: nil)], tuning: Tuning())
        #expect(stacking.stacks.isEmpty)
        #expect(stacking.links.first?.distance == nil)
    }

    @Test func sameBurstJoinsRegardlessOfGapAndDistance() {
        let stacking = StackGrouper.group(
            [
                candidate(0, burst: "B1"),
                candidate(30, feature: near(5), burst: "B1"),
                candidate(31, feature: nil, burst: "B1"),
            ],
            tuning: Tuning()
        )
        #expect(stacking.stacks == [[0, 1, 2]])
    }

    @Test func differentBurstsDoNotJoinByBurst() {
        let stacking = StackGrouper.group(
            [candidate(0, burst: "B1"), candidate(30, burst: "B2")],
            tuning: Tuning()
        )
        #expect(stacking.stacks.isEmpty)
    }

    @Test func photosWithoutACaptureDateNeverJoinByTime() {
        let stacking = StackGrouper.group(
            [
                candidate(0, hasCaptureDate: false),
                candidate(0.1, hasCaptureDate: false),
                candidate(0.2),
                candidate(0.3, hasCaptureDate: false),
            ],
            tuning: Tuning()
        )
        #expect(stacking.stacks.isEmpty)
        #expect(stacking.links.allSatisfy { !$0.isLinked })
    }

    @Test func minStackSizeIsRespected() {
        var tuning = Tuning()
        tuning.minStackSize = 3
        let stacking = StackGrouper.group(
            [candidate(0), candidate(1), candidate(20), candidate(21), candidate(22)],
            tuning: tuning
        )
        #expect(stacking.stacks == [[2, 3, 4]])

        // A minimum below two still never makes single-photo stacks.
        tuning.minStackSize = 1
        #expect(StackGrouper.group([candidate(0), candidate(20)], tuning: tuning).stacks.isEmpty)
    }

    @Test func orderIsByDateAndLinksJoinNeighbours() {
        let candidates = [candidate(5), candidate(1), candidate(3), candidate(1), candidate(-2)]
        let stacking = StackGrouper.group(candidates, tuning: Tuning())
        // Equal dates keep their input order.
        #expect(stacking.order == [4, 1, 3, 2, 0])
        #expect(stacking.links.count == stacking.order.count - 1)
        for (position, link) in stacking.links.enumerated() {
            let gap = candidates[stacking.order[position + 1]].date
                .timeIntervalSince(candidates[stacking.order[position]].date)
            #expect(abs(link.gapSeconds - gap) < 1e-9)
            #expect(link.gapSeconds >= 0)
        }
        // Stacks list their members in time order.
        for stack in stacking.stacks {
            let dates = stack.map { candidates[$0].date }
            #expect(dates == dates.sorted())
        }
    }

    @Test func defaultLimitsAreTenSecondsAndADistanceOfPointSix() {
        let within = StackGrouper.group([candidate(0), candidate(10, feature: near(0.59))], tuning: Tuning())
        #expect(within.stacks == [[0, 1]])
        let pastGap = StackGrouper.group([candidate(0), candidate(10.01, feature: near(0.59))], tuning: Tuning())
        #expect(pastGap.stacks.isEmpty)
        let pastDistance = StackGrouper.group([candidate(0), candidate(10, feature: near(0.61))], tuning: Tuning())
        #expect(pastDistance.stacks.isEmpty)
    }

    @Test func singleAndEmptyInputs() {
        let one = StackGrouper.group([candidate(0)], tuning: Tuning())
        #expect(one.order == [0] && one.links.isEmpty && one.stacks.isEmpty)
        let none = StackGrouper.group([], tuning: Tuning())
        #expect(none.order.isEmpty && none.links.isEmpty && none.stacks.isEmpty)
    }
}

@Suite("DuplicateFinder")
struct DuplicateFinderTests {
    /// Each set as "kind members", such as "exact 0,2", for comparing whole results at once.
    private func describe(_ sets: [DuplicateSet]) -> [String] {
        sets.map { "\($0.kind.rawValue) \($0.members.map(String.init).joined(separator: ","))" }
    }

    /// Records which candidates the finder asked to hash.
    private final class HashLog {
        var asked: [Int] = []
    }

    @Test func exactCopiesAreFoundThroughTheHash() {
        let candidates = [
            DuplicateCandidate(fileSize: 100),
            DuplicateCandidate(fileSize: 100),
            DuplicateCandidate(fileSize: 100),
            DuplicateCandidate(fileSize: 200),
        ]
        let hashes = ["h1", "h2", "h1", "h1"]
        let sets = DuplicateFinder.find(candidates, tuning: Tuning(), contentHash: { hashes[$0] })
        #expect(describe(sets) == ["exact 0,2"])
    }

    @Test func onlyFilesWhoseSizeCollidesAreHashed() {
        let candidates = [
            DuplicateCandidate(fileSize: 10),
            DuplicateCandidate(fileSize: 20),
            DuplicateCandidate(fileSize: 10),
            DuplicateCandidate(fileSize: 30),
            DuplicateCandidate(fileSize: 20),
            DuplicateCandidate(fileSize: 40),
        ]
        let log = HashLog()
        let sets = DuplicateFinder.find(candidates, tuning: Tuning(), contentHash: { index in
            log.asked.append(index)
            return "same"
        })
        #expect(log.asked.sorted() == [0, 1, 2, 4])
        #expect(sets.map(\.members) == [[0, 2], [1, 4]])
        #expect(sets.allSatisfy { $0.kind == .exact })
    }

    @Test func unreadableFilesAreNotExactCopies() {
        let candidates = [DuplicateCandidate(fileSize: 10), DuplicateCandidate(fileSize: 10)]
        #expect(DuplicateFinder.find(candidates, tuning: Tuning(), contentHash: { _ in nil }).isEmpty)
    }

    @Test func nearDuplicatesNeedASmallDistanceAndTheSameInstant() {
        let shot = start
        let candidates = [
            DuplicateCandidate(fileSize: 1, captureDate: shot, feature: base),
            DuplicateCandidate(fileSize: 2, captureDate: shot, feature: near(0.05)),
            // Same instant, but too different.
            DuplicateCandidate(fileSize: 3, captureDate: shot, feature: near(0.5)),
            // Alike, but a different moment.
            DuplicateCandidate(fileSize: 4, captureDate: shot.addingTimeInterval(60), feature: near(0.01)),
        ]
        let sets = DuplicateFinder.find(candidates, tuning: Tuning(), contentHash: { _ in nil })
        #expect(describe(sets) == ["near 0,1"])
    }

    @Test func aMissingCaptureDateCountsAsTheSameInstant() {
        let candidates = [
            DuplicateCandidate(fileSize: 1, captureDate: start, feature: base),
            DuplicateCandidate(fileSize: 2, captureDate: nil, feature: near(0.05)),
        ]
        let sets = DuplicateFinder.find(candidates, tuning: Tuning(), contentHash: { _ in nil })
        #expect(describe(sets) == ["near 0,1"])
    }

    @Test func burstFramesAFractionOfASecondApartAreNotDuplicates() {
        let candidates = [
            DuplicateCandidate(fileSize: 1, captureDate: start, feature: base),
            DuplicateCandidate(fileSize: 2, captureDate: start.addingTimeInterval(0.3), feature: near(0.001)),
        ]
        #expect(DuplicateFinder.find(candidates, tuning: Tuning(), contentHash: { _ in nil }).isEmpty)
    }

    @Test func missingFeaturesAreNeverNearDuplicates() {
        let candidates = [
            DuplicateCandidate(fileSize: 1, captureDate: start, feature: nil),
            DuplicateCandidate(fileSize: 2, captureDate: start, feature: base),
        ]
        #expect(DuplicateFinder.find(candidates, tuning: Tuning(), contentHash: { _ in nil }).isEmpty)
    }

    @Test func aSetMixingAnExactPairWithANearMemberIsNear() {
        let candidates = [
            DuplicateCandidate(fileSize: 500, captureDate: start, feature: base),
            DuplicateCandidate(fileSize: 500, captureDate: start, feature: base),
            // A resized copy: different size, so never hashed.
            DuplicateCandidate(fileSize: 120, captureDate: start, feature: near(0.03)),
            DuplicateCandidate(fileSize: 999, captureDate: start.addingTimeInterval(100), feature: near(3)),
        ]
        let sets = DuplicateFinder.find(candidates, tuning: Tuning(), contentHash: { _ in "same" })
        #expect(describe(sets) == ["near 0,1,2"])
    }

    @Test func setsAreOrderedByTheirFirstMember() {
        let candidates = [
            DuplicateCandidate(fileSize: 7),
            DuplicateCandidate(fileSize: 8),
            DuplicateCandidate(fileSize: 8),
            DuplicateCandidate(fileSize: 7),
        ]
        let hashes = ["a", "b", "b", "a"]
        let sets = DuplicateFinder.find(candidates, tuning: Tuning(), contentHash: { hashes[$0] })
        #expect(sets.map(\.members) == [[0, 3], [1, 2]])
    }
}
