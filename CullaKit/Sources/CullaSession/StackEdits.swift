import CullaAnalysis
import Foundation

/// The user's corrections to the automatic stacks, kept apart from them so they can be applied
/// again on top of every new automatic grouping (`SessionState.applyGrouping(_:)`), and saved per
/// session (`CullaDatabase.saveStackEdits`).
///
/// How they are applied on top of the automatic stacks:
///
/// 1. Every photo in `splitOut` is taken out of the automatic stacks. The rest of each
///    automatic stack stays one stack (if two or more frames are left).
/// 2. The photos of each group in `joined` are put in one stack, together with the stacks any of
///    them are in. Groups and stacks that share a photo become one stack.
/// 3. A stack's best pick is the photo of `bestPicks` among its members (the earliest when there
///    are several). Without one, it is the automatic stack's pick when the stack is exactly an
///    automatic stack, or one with frames split out, as long as the pick is still in it. Any
///    other stack, such as one the user joined, gets the pick `BestPick` chooses from its
///    frames' scores, or none without scores.
///
/// So a photo the user split out stays out of every automatic stack, however the automatic
/// stacks change shape later, until the user adds it to a stack again. Photos the user joined
/// stay in one stack even when the automatic grouping separates them. Ids the session does not
/// have are ignored but kept, so a photo that comes back after a rescan keeps its edits.
public struct StackEdits: Codable, Sendable, Hashable {
    /// Groups of photos the user put in one stack with Add to Stack. No photo is in two groups.
    public var joined: [[String]]
    /// Photos the user split out of their stack.
    public var splitOut: Set<String>
    /// Best picks the user chose by hand. Automatic grouping never replaces them; hand them to
    /// `ShootAnalysis.setManualBestPicks(_:)`.
    public var bestPicks: Set<String>

    public init(joined: [[String]] = [], splitOut: Set<String> = [], bestPicks: Set<String> = []) {
        self.joined = joined
        self.splitOut = splitOut
        self.bestPicks = bestPicks
    }

    public var isEmpty: Bool { joined.isEmpty && splitOut.isEmpty && bestPicks.isEmpty }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        joined = try container.decodeIfPresent([[String]].self, forKey: .joined) ?? []
        splitOut = try container.decodeIfPresent(Set<String>.self, forKey: .splitOut) ?? []
        bestPicks = try container.decodeIfPresent(Set<String>.self, forKey: .bestPicks) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        // Sorted, so the same edits always encode to the same bytes (with sorted keys).
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(joined.map { $0.sorted() }.sorted { $0.lexicographicallyPrecedes($1) }, forKey: .joined)
        try container.encode(splitOut.sorted(), forKey: .splitOut)
        try container.encode(bestPicks.sorted(), forKey: .bestPicks)
    }

    private enum CodingKeys: String, CodingKey {
        case joined, splitOut, bestPicks
    }

    /// Adds a group to `joined`, merging it with every group it shares a photo with.
    mutating func join(_ ids: Set<String>) {
        var merged = ids
        joined.removeAll { group in
            guard group.contains(where: merged.contains) else { return false }
            merged.formUnion(group)
            return true
        }
        joined.append(merged.sorted())
        splitOut.subtract(merged)
    }

    /// The same edits with photo ids replaced, for photos renamed outside Culla.
    public func renaming(_ ids: [String: String]) -> StackEdits {
        let rename = { (id: String) in ids[id] ?? id }
        return StackEdits(
            joined: joined.map { $0.map(rename) },
            splitOut: Set(splitOut.map(rename)),
            bestPicks: Set(bestPicks.map(rename))
        )
    }

    /// Takes a photo out of every joined group, dropping groups left with one photo.
    mutating func removeFromJoined(_ id: String) {
        joined = joined.compactMap { group in
            let rest = group.filter { $0 != id }
            return rest.count >= 2 ? rest : nil
        }
    }
}

/// A step of the undo history, for naming the Undo and Redo menu items.
public enum SessionEdit: Sendable, Hashable {
    /// A change made with `SessionState.apply(_:)`.
    case action(SessionAction)
    /// `SessionState.acceptStack(containing:)` on the stack with this id.
    case acceptStack(stackID: String)
    /// `SessionState.acceptDuplicateSet(containing:)` on the set with this id.
    case acceptDuplicateSet(setID: String)
    /// `SessionState.acceptAllExactDuplicates()`, which changed this many sets.
    case acceptAllExactDuplicates(sets: Int)
    /// `SessionState.addToStack(_:)` with these photos.
    case addToStack(ids: [String])
    /// `SessionState.splitFromStack(_:)` on this photo.
    case splitFromStack(id: String)
    /// `SessionState.chooseBestPick(_:inStackContaining:)`: a hand-chosen pick, or nil for back
    /// to Culla's pick.
    case chooseBestPick(id: String?, stackID: String)
}
