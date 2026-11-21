import Foundation

/// A stack shown as one grid tile.
public struct CollapsedStack: Sendable, Hashable, Identifiable {
    /// The stack's id (`PhotoStack.id`, its first frame).
    public var id: String
    /// The photo the tile shows: the best pick, else the first frame.
    public var representative: String
    /// True when `representative` is the best pick, so the tile shows its star.
    public var representativeIsBestPick: Bool
    public var frameCount: Int
    /// The frames' decisions, so the tile can show a mixed state.
    public var decisions: DecisionSummary

    /// Frames still Unreviewed.
    public var unreviewedCount: Int { decisions.unreviewed }
    /// True when no frame is Unreviewed.
    public var isDecided: Bool { decisions.unreviewed == 0 }
}

/// One tile of the grid: a photo, or a collapsed stack.
public enum GridEntry: Sendable, Hashable, Identifiable {
    case photo(String)
    case stack(CollapsedStack)

    /// The photo's id, or the stack's id. Unique within one `GridEntries`.
    public var id: String {
        switch self {
        case .photo(let id): id
        case .stack(let stack): stack.id
        }
    }

    /// The photo the tile shows.
    public var representative: String {
        switch self {
        case .photo(let id): id
        case .stack(let stack): stack.representative
        }
    }

    public var collapsedStack: CollapsedStack? {
        if case .stack(let stack) = self { stack } else { nil }
    }
}

/// The tiles of a group, in capture order, with stacks collapsed where asked.
///
/// A snapshot: build a new one after any change to decisions, stacks or groups. Its navigation
/// helpers take the session it was built from.
public struct GridEntries: Sendable, Hashable {
    public let group: GroupID
    /// True when stacks are collapsed in this list.
    public let collapsesStacks: Bool
    /// Stacks listed frame by frame although stacks are collapsed.
    public let expanded: Set<String>
    public let entries: [GridEntry]
    /// For each entry, the session position of the photo it sits at: the photo itself, or the
    /// first frame of the stack that is in the group. Ascending.
    let anchors: [Int]

    init(group: GroupID, collapsesStacks: Bool, expanded: Set<String>, entries: [GridEntry], anchors: [Int]) {
        self.group = group
        self.collapsesStacks = collapsesStacks
        self.expanded = expanded
        self.entries = entries
        self.anchors = anchors
    }

    public var count: Int { entries.count }
    public var isEmpty: Bool { entries.isEmpty }
    public subscript(index: Int) -> GridEntry { entries[index] }
}

extension SessionState {
    /// True for the groups whose grid collapses stacks by default: All Photos only, as the
    /// Design says. Every other group lists each photo: Similar Stacks opens in stack review, the
    /// defect groups are about single frames, and Unreviewed, Kept and Rejected must show each
    /// decision.
    public static func collapsesStacks(in group: GroupID) -> Bool {
        group == .allPhotos
    }

    /// The grid's tiles for a group, in capture order. With stacks collapsed, the stack's tile
    /// sits where its first frame in the group would be, and stands for every frame of the stack
    /// (its counts cover the whole stack, even frames outside the group). Stacks named in
    /// `expanded` are listed frame by frame. Linear in the number of photos, like
    /// `members(of:)`.
    ///
    /// - Parameter collapsingStacks: nil follows `collapsesStacks(in:)`.
    public func gridEntries(of group: GroupID, collapsingStacks: Bool? = nil, expanded: Set<String> = []) -> GridEntries {
        let collapse = collapsingStacks ?? Self.collapsesStacks(in: group)
        let bit = group.bit
        var entries: [GridEntry] = []
        var anchors: [Int] = []
        entries.reserveCapacity(count(of: group).total)
        anchors.reserveCapacity(count(of: group).total)
        guard collapse, !stacks.isEmpty else {
            for index in masks.indices where masks[index] & bit != 0 {
                entries.append(.photo(photos[index].id))
                anchors.append(index)
            }
            return GridEntries(group: group, collapsesStacks: collapse, expanded: expanded, entries: entries, anchors: anchors)
        }
        // Each stack's decisions, from one pass over the photos without looking up ids.
        var summaries = [DecisionSummary](repeating: DecisionSummary(), count: stacks.count)
        for index in stackOf.indices {
            if let number = stackOf[index] { summaries[number].add(photos[index].decision) }
        }
        var shown = [Bool](repeating: false, count: stacks.count)
        var isExpanded = [Bool](repeating: false, count: stacks.count)
        if !expanded.isEmpty {
            for (number, stack) in stacks.enumerated() where expanded.contains(stack.id) {
                isExpanded[number] = true
            }
        }
        for index in masks.indices where masks[index] & bit != 0 {
            guard let number = stackOf[index], !isExpanded[number] else {
                entries.append(.photo(photos[index].id))
                anchors.append(index)
                continue
            }
            guard !shown[number] else { continue }
            shown[number] = true
            entries.append(.stack(collapsedStack(at: number, decisions: summaries[number])))
            anchors.append(index)
        }
        return GridEntries(group: group, collapsesStacks: collapse, expanded: expanded, entries: entries, anchors: anchors)
    }

    /// The stack at this position in `stacks` as one tile.
    public func collapsedStack(at number: Int) -> CollapsedStack {
        collapsedStack(at: number, decisions: decisionSummary(ofStackAt: number))
    }

    private func collapsedStack(at number: Int, decisions: DecisionSummary) -> CollapsedStack {
        let stack = stacks[number]
        let representative = stack.bestPick ?? stack.id
        return CollapsedStack(
            id: stack.id,
            representative: representative,
            representativeIsBestPick: stack.bestPick != nil,
            frameCount: stack.members.count,
            decisions: decisions
        )
    }

    /// The index of the entry that shows the photo: its own tile, or its collapsed stack's.
    /// Nil when the list does not show it.
    public func entryIndex(containing id: String, in grid: GridEntries) -> Int? {
        guard let position = positions[id] else { return nil }
        let anchor = anchor(of: position, in: grid)
        let found = lowerBound(anchor, in: grid.anchors)
        guard found < grid.anchors.count, grid.anchors[found] == anchor else { return nil }
        return found
    }

    /// The entry after the one showing the photo. When the list does not show the photo, the
    /// first entry after where it would be.
    public func entry(after id: String, in grid: GridEntries) -> GridEntry? {
        guard let position = positions[id] else { return nil }
        let next: Int = if let own = entryIndex(containing: id, in: grid) {
            own + 1
        } else {
            upperBound(position, in: grid.anchors)
        }
        return next < grid.count ? grid.entries[next] : nil
    }

    /// The entry before the one showing the photo, or the last entry before where it would be.
    public func entry(before id: String, in grid: GridEntries) -> GridEntry? {
        guard let position = positions[id] else { return nil }
        let previous: Int = if let own = entryIndex(containing: id, in: grid) {
            own - 1
        } else {
            lowerBound(position, in: grid.anchors) - 1
        }
        return previous >= 0 ? grid.entries[previous] : nil
    }

    /// Where the photo's tile sits: its stack's first frame in the group when its stack is
    /// collapsed, else the photo itself.
    private func anchor(of position: Int, in grid: GridEntries) -> Int {
        guard grid.collapsesStacks, let number = stackOf[position], !grid.expanded.contains(stacks[number].id) else { return position }
        let bit = grid.group.bit
        for member in stacks[number].members {
            if let index = positions[member], masks[index] & bit != 0 { return index }
        }
        return position
    }

    /// The first index whose anchor is not below `value`.
    private func lowerBound(_ value: Int, in anchors: [Int]) -> Int {
        var low = 0
        var high = anchors.count
        while low < high {
            let middle = (low + high) / 2
            if anchors[middle] < value { low = middle + 1 } else { high = middle }
        }
        return low
    }

    /// The first index whose anchor is above `value`.
    private func upperBound(_ value: Int, in anchors: [Int]) -> Int {
        var low = 0
        var high = anchors.count
        while low < high {
            let middle = (low + high) / 2
            if anchors[middle] <= value { low = middle + 1 } else { high = middle }
        }
        return low
    }
}
