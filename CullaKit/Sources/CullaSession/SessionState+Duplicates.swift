import CullaAnalysis
import CullaCore
import Foundation

/// The copy of a duplicate set Culla proposes to keep.
public struct DuplicatePick: Sendable, Hashable {
    /// The photo to keep.
    public var id: String
    /// Why, in the terms of `DuplicateRanking`; `DuplicateReview.pickCaption(_:)` gives it in words.
    public var reason: DuplicatePickReason
    /// Every rule that narrowed the choice, in the order applied.
    public var reasons: [DuplicatePickReason]
    /// The set's photos, the one to keep first.
    public var ranking: [String]
}

/// What `acceptAllExactDuplicates()` did.
public struct BulkAcceptResult: Sendable, Hashable {
    /// The photos whose decision changed: save these.
    public var change: SessionChange
    /// How many sets it changed.
    public var sets: Int
    /// How many photos it changed (`change.changedIDs.count`).
    public var photos: Int { change.changedIDs.count }
}

// Duplicates (User Flows, Flow 4).
extension SessionState {
    // MARK: - The copy to keep

    /// The copy Culla proposes to keep in the photo's duplicate set, by `DuplicateRanking`:
    /// highest resolution, then RAW over JPEG, then the original name over a copy name, then the
    /// shorter name, then the first by name. Computed from the current metadata each time it is
    /// asked, so it follows any change. Nil when the photo is in no set.
    public func duplicatePick(forSetContaining id: String) -> DuplicatePick? {
        guard let index = duplicateSetIndex(containing: id) else { return nil }
        let members = duplicateSets[index].members
        let copies = members.map { member -> DuplicateCopy in
            let item = photo(member)!
            let pixels: Int? = if let width = item.metadata.pixelWidth, let height = item.metadata.pixelHeight {
                width * height
            } else {
                nil
            }
            return DuplicateCopy(
                pixelCount: pixels,
                hasRAW: item.file.isRAW || !item.file.companions.isEmpty,
                fileName: item.file.name,
                tieBreaker: item.id
            )
        }
        guard let pick = DuplicateRanking.pick(copies) else { return nil }
        return DuplicatePick(
            id: members[pick.index],
            reason: pick.reason,
            reasons: pick.reasons,
            ranking: DuplicateRanking.ranking(copies).map { members[$0] }
        )
    }

    // MARK: - Looking up sets

    /// The position of the photo's set in `duplicateSets`.
    public func duplicateSetIndex(containing id: String) -> Int? {
        positions[id].flatMap { duplicateSetOf[$0] }
    }

    /// True when no copy of the set is Unreviewed.
    public func isDecided(duplicateSetAt index: Int) -> Bool {
        duplicateSets.indices.contains(index) && setUnreviewed[index] == 0
    }

    /// True when no copy of the photo's set is Unreviewed. False when the photo is in no set.
    public func isDuplicateSetDecided(containing id: String) -> Bool {
        duplicateSetIndex(containing: id).map { isDecided(duplicateSetAt: $0) } ?? false
    }

    /// Sets with an Unreviewed copy ("left"), and all sets ("total"), of one kind or of both.
    /// The Duplicates group's own count, `count(of: .duplicates)`, stays in photos.
    public func duplicateSetCounts(kind: DuplicateSet.Kind? = nil) -> GroupCount {
        var result = GroupCount(left: 0, total: 0)
        for (index, set) in duplicateSets.enumerated() where kind == nil || set.kind == kind {
            result.total += 1
            if setUnreviewed[index] > 0 { result.left += 1 }
        }
        return result
    }

    // MARK: - Moving between sets

    /// The set after the one holding `id`, or the first set that starts after the photo.
    public func nextDuplicateSet(after id: String) -> PhotoDuplicateSet? {
        nextIndex(after: id, owner: duplicateSetOf, firsts: setFirst, undecidedOnly: false, unreviewed: setUnreviewed)
            .map { duplicateSets[$0] }
    }

    /// The set before the one holding `id`, or the last set that starts before the photo.
    public func previousDuplicateSet(before id: String) -> PhotoDuplicateSet? {
        previousIndex(before: id, owner: duplicateSetOf, firsts: setFirst, undecidedOnly: false, unreviewed: setUnreviewed)
            .map { duplicateSets[$0] }
    }

    /// The next set with an Unreviewed copy; see `nextUndecidedStack(after:wrapping:)`.
    public func nextUndecidedDuplicateSet(after id: String? = nil, wrapping: Bool = false) -> PhotoDuplicateSet? {
        nextUndecidedIndex(after: id, wrapping: wrapping, owner: duplicateSetOf, firsts: setFirst, unreviewed: setUnreviewed)
            .map { duplicateSets[$0] }
    }

    // MARK: - Accepting

    /// Return in the Duplicates view, as one undo step. When some copy is Kept (the user pressed
    /// P on it), it stays kept and no other is. Otherwise the copy to keep (`duplicatePick`) is
    /// kept; if the user rejected that one, the next copy in its ranking that is Unreviewed.
    /// Then every copy still Unreviewed is rejected. Copies already Kept or Rejected keep their
    /// decision. `id` is any copy of the set. Empty when the photo is in no set or the set has no
    /// Unreviewed copy.
    @discardableResult
    public mutating func acceptDuplicateSet(containing id: String) -> SessionChange {
        guard let index = duplicateSetIndex(containing: id) else { return SessionChange() }
        let targets = acceptTargets(forSetAt: index)
        return commit(.acceptDuplicateSet(setID: duplicateSets[index].id), action: Self.decisionsAction(targets, photos), targets: targets)
    }

    /// Accept All Exact Duplicates: accepts every byte-identical set that still has an Unreviewed
    /// copy, by the rules of `acceptDuplicateSet(containing:)`, as one undo step. Near-duplicate
    /// sets are never touched.
    @discardableResult
    public mutating func acceptAllExactDuplicates() -> BulkAcceptResult {
        var targets: [Int: PhotoMark] = [:]
        var sets = 0
        for index in duplicateSets.indices where duplicateSets[index].kind == .exact && setUnreviewed[index] > 0 {
            let setTargets = acceptTargets(forSetAt: index)
            if setTargets.contains(where: { photos[$0.key].mark != $0.value }) { sets += 1 }
            targets.merge(setTargets) { _, new in new }
        }
        let change = commit(.acceptAllExactDuplicates(sets: sets), action: Self.decisionsAction(targets, photos), targets: targets)
        return BulkAcceptResult(change: change, sets: change.isEmpty ? 0 : sets)
    }

    private func acceptTargets(forSetAt index: Int) -> [Int: PhotoMark] {
        let set = duplicateSets[index]
        let members = set.members.compactMap { positions[$0] }
        let unreviewed = members.filter { photos[$0].decision == .unreviewed }
        guard !unreviewed.isEmpty else { return [:] }
        var keeper: Int?
        if !members.contains(where: { photos[$0].decision == .kept }) {
            let ranking = duplicatePick(forSetContaining: set.id)?.ranking ?? set.members
            keeper = ranking.lazy.compactMap { self.positions[$0] }.first { self.photos[$0].decision == .unreviewed }
        }
        return decisionTargets(keeping: keeper, rejecting: unreviewed)
    }
}
