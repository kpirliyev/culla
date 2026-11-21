import CullaAnalysis
import CullaCore
import Foundation

// Stack review (User Flows, Flow 2): accepting a stack, moving between stacks, and the user's
// corrections to the stacks.
extension SessionState {
    // MARK: - Looking up stacks

    /// The position of the photo's stack in `stacks`, for "Stack 12 of 86" (add one).
    public func stackIndex(containing id: String) -> Int? {
        positions[id].flatMap { stackOf[$0] }
    }

    /// True when no frame of the stack is Unreviewed.
    public func isDecided(stackAt index: Int) -> Bool {
        stacks.indices.contains(index) && stackUnreviewed[index] == 0
    }

    /// True when no frame of the photo's stack is Unreviewed. False when the photo is in no stack.
    public func isStackDecided(containing id: String) -> Bool {
        stackIndex(containing: id).map { isDecided(stackAt: $0) } ?? false
    }

    /// How many frames of the stack are still Unreviewed.
    public func unreviewedCount(ofStackAt index: Int) -> Int {
        stacks.indices.contains(index) ? stackUnreviewed[index] : 0
    }

    /// Stacks with an Unreviewed frame ("left"), and all stacks ("total"). The Similar Stacks
    /// group's own count, `count(of: .similarStacks)`, stays in photos.
    public var stackCounts: GroupCount {
        GroupCount(left: stackUnreviewed.count { $0 > 0 }, total: stacks.count)
    }

    /// The decisions of a stack's frames, for a tile or a header.
    public func decisionSummary(ofStackAt index: Int) -> DecisionSummary {
        guard stacks.indices.contains(index) else { return DecisionSummary() }
        return DecisionSummary(stacks[index].members.compactMap { positions[$0].map { photos[$0].decision } })
    }

    // MARK: - Moving between stacks

    /// The stack after the one holding `id` in capture order. When `id` is in no stack, the first
    /// stack that starts after the photo. Nil at the end.
    public func nextStack(after id: String) -> PhotoStack? {
        nextIndex(after: id, owner: stackOf, firsts: stackFirst, undecidedOnly: false, unreviewed: stackUnreviewed)
            .map { stacks[$0] }
    }

    /// The stack before the one holding `id`, or the last stack that starts before the photo.
    public func previousStack(before id: String) -> PhotoStack? {
        previousIndex(before: id, owner: stackOf, firsts: stackFirst, undecidedOnly: false, unreviewed: stackUnreviewed)
            .map { stacks[$0] }
    }

    /// The first stack after the one holding `id` (or after the photo) with an Unreviewed frame.
    /// With `id` nil, the first undecided stack. With `wrapping`, the search goes on from the
    /// first stack, which brings back stacks skipped earlier, but never the stack of `id` itself.
    /// Nil when no other stack is undecided: time to offer the next group.
    public func nextUndecidedStack(after id: String? = nil, wrapping: Bool = false) -> PhotoStack? {
        nextUndecidedIndex(after: id, wrapping: wrapping, owner: stackOf, firsts: stackFirst, unreviewed: stackUnreviewed)
            .map { stacks[$0] }
    }

    // MARK: - Accepting a stack

    /// Return in stack review: keeps the pick and rejects the rest, as one undo step.
    ///
    /// When some frame of the stack is already Kept (the user pressed P on the frames worth
    /// keeping), no other frame is kept. Otherwise one frame is kept: the best pick when it is
    /// Unreviewed; when the pick was rejected or there is none, the frame `BestPick` ranks first
    /// among the Unreviewed frames with scores, else the first Unreviewed frame. Then every frame
    /// still Unreviewed is rejected. Frames already Kept or Rejected keep their decision, so
    /// accepting never undoes something the user did.
    ///
    /// `id` is any frame of the stack. Returns the photos whose decision changed; empty when the
    /// photo is in no stack or the stack has no Unreviewed frame.
    @discardableResult
    public mutating func acceptStack(containing id: String) -> SessionChange {
        guard let index = stackIndex(containing: id) else { return SessionChange() }
        let stack = stacks[index]
        let members = stack.members.compactMap { positions[$0] }
        let unreviewed = members.filter { photos[$0].decision == .unreviewed }
        var keeper: Int?
        if !members.contains(where: { photos[$0].decision == .kept }) {
            if let pick = stack.bestPick.flatMap({ positions[$0] }), photos[pick].decision == .unreviewed {
                keeper = pick
            } else {
                keeper = computedBestPick(of: unreviewed).flatMap { positions[$0] } ?? unreviewed.first
            }
        }
        let targets = decisionTargets(keeping: keeper, rejecting: unreviewed)
        return commit(.acceptStack(stackID: stack.id), action: Self.decisionsAction(targets, photos), targets: targets)
    }

    /// Marks for keeping one photo and rejecting the others, all given as positions.
    func decisionTargets(keeping keeper: Int?, rejecting others: [Int]) -> [Int: PhotoMark] {
        var targets: [Int: PhotoMark] = [:]
        for index in others where index != keeper {
            var mark = photos[index].mark
            mark.decision = .rejected
            targets[index] = mark
        }
        if let keeper {
            var mark = photos[keeper].mark
            mark.decision = .kept
            targets[keeper] = mark
        }
        return targets
    }

    /// The `.setDecisions` action that sets these marks' decisions, for `undoAction`.
    static func decisionsAction(_ targets: [Int: PhotoMark], _ photos: [PhotoItem]) -> SessionAction {
        .setDecisions(Dictionary(uniqueKeysWithValues: targets.map { (photos[$0.key].id, $0.value.decision) }))
    }

    // MARK: - Correcting stacks

    /// G: puts these photos in one stack, together with every frame of the stacks any of them
    /// are in, as one undo step. Remembered as a stack edit (`StackEdits.joined`), so it survives
    /// automatic regrouping. Photos split out earlier come back. When the joined stacks carry
    /// several hand-chosen picks, the earliest stays. Decisions do not change.
    ///
    /// Unknown and unreadable photos are ignored. Nothing happens (an empty change) when fewer
    /// than two photos would be in the stack, or they already are one stack.
    @discardableResult
    public mutating func addToStack(_ ids: some Collection<String>) -> SessionChange {
        let given = Set(ids.compactMap { positions[$0] }.filter { !photos[$0].isUnreadable })
        var members = given
        var stacksTouched = Set<Int>()
        for index in given {
            if let stack = stackOf[index] {
                stacksTouched.insert(stack)
                members.formUnion(stacks[stack].members.compactMap { positions[$0] })
            }
        }
        guard members.count >= 2 else { return SessionChange() }
        if stacksTouched.count == 1, let only = stacksTouched.first, stacks[only].members.count == members.count {
            return SessionChange()
        }
        let ordered = members.sorted()
        let memberIDs = ordered.map { photos[$0].id }
        var edits = stackEdits
        edits.join(Set(memberIDs))
        // One hand-chosen pick per stack: the earliest.
        let picks = memberIDs.filter { edits.bestPicks.contains($0) }
        if picks.count > 1 { edits.bestPicks.subtract(picks.dropFirst()) }
        let givenIDs = given.sorted().map { photos[$0].id }
        return commit(.addToStack(ids: givenIDs), action: nil, targets: [:], edits: edits)
    }

    /// ⇧G: takes a frame out of its stack and back to Unreviewed, as one undo step. Remembered
    /// as a stack edit (`StackEdits.splitOut`): the photo stays out of every automatic stack
    /// until it is added to one with `addToStack(_:)`. A stack left with one frame stops being a
    /// stack. A hand-chosen pick on the frame is forgotten.
    ///
    /// Nothing happens (an empty change) when the photo is in no stack.
    @discardableResult
    public mutating func splitFromStack(_ id: String) -> SessionChange {
        guard let index = positions[id], stackOf[index] != nil else { return SessionChange() }
        var edits = stackEdits
        edits.removeFromJoined(id)
        edits.splitOut.insert(id)
        edits.bestPicks.remove(id)
        var targets: [Int: PhotoMark] = [:]
        var mark = photos[index].mark
        mark.decision = .unreviewed
        targets[index] = mark
        return commit(.splitFromStack(id: id), action: nil, targets: targets, edits: edits)
    }

    /// Makes `pick` the best pick of the stack holding `memberID`, chosen by hand, as one undo
    /// step; nil goes back to Culla's pick. See `setBestPick(_:ofStackContaining:)`. Empty when
    /// the photo is in no stack, `pick` is not a member, or nothing changes.
    @discardableResult
    public mutating func chooseBestPick(_ pick: String?, inStackContaining memberID: String) -> SessionChange {
        guard let edits = editsChoosingBestPick(pick, inStackContaining: memberID),
              let stack = stack(containing: memberID)
        else { return SessionChange() }
        return commit(.chooseBestPick(id: pick, stackID: stack.id), action: nil, targets: [:], edits: edits)
    }

    // MARK: - Face strip

    /// The face strip of the photo's stack: its frames and the people matched across them
    /// (`FaceMatcher`). Frames without scores have no faces. Nil when the photo is in no stack.
    public func faceStrip(forStackContaining id: String, includeAllFaces: Bool = false) -> FaceStrip? {
        guard let stack = stack(containing: id) else { return nil }
        return faceStrip(frames: stack.members, includeAllFaces: includeAllFaces)
    }

    /// The face strip of any photos, in the order given (capture order for a stack). Unknown ids
    /// count as frames without faces.
    public func faceStrip(frames ids: [String], includeAllFaces: Bool = false) -> FaceStrip {
        let frames = ids.map { FaceFrame(scores: photo($0)?.scores) }
        return FaceStrip(
            frames: ids,
            matching: FaceMatcher.match(frames, tuning: tuning, includeAllFaces: includeAllFaces)
        )
    }

    // MARK: - Shared navigation over stacks and duplicate sets

    func nextIndex(after id: String, owner: [Int?], firsts: [Int], undecidedOnly: Bool, unreviewed: [Int]) -> Int? {
        guard let position = positions[id] else { return nil }
        let start: Int = if let own = owner[position] {
            own + 1
        } else {
            firsts.firstIndex { $0 > position } ?? firsts.count
        }
        return (start..<firsts.count).first { !undecidedOnly || unreviewed[$0] > 0 }
    }

    func previousIndex(before id: String, owner: [Int?], firsts: [Int], undecidedOnly: Bool, unreviewed: [Int]) -> Int? {
        guard let position = positions[id] else { return nil }
        let end: Int = if let own = owner[position] {
            own
        } else {
            (firsts.lastIndex { $0 < position }).map { $0 + 1 } ?? 0
        }
        return (0..<end).reversed().first { !undecidedOnly || unreviewed[$0] > 0 }
    }

    func nextUndecidedIndex(after id: String?, wrapping: Bool, owner: [Int?], firsts: [Int], unreviewed: [Int]) -> Int? {
        guard let id else { return unreviewed.firstIndex { $0 > 0 } }
        if let next = nextIndex(after: id, owner: owner, firsts: firsts, undecidedOnly: true, unreviewed: unreviewed) {
            return next
        }
        guard wrapping else { return nil }
        let own = positions[id].flatMap { owner[$0] }
        return unreviewed.indices.first { unreviewed[$0] > 0 && $0 != own }
    }
}

/// How many photos of a stack or set have each decision.
public struct DecisionSummary: Sendable, Hashable {
    public var unreviewed: Int
    public var kept: Int
    public var rejected: Int

    public init(unreviewed: Int = 0, kept: Int = 0, rejected: Int = 0) {
        self.unreviewed = unreviewed
        self.kept = kept
        self.rejected = rejected
    }

    public init(_ decisions: some Sequence<Decision>) {
        self.init()
        for decision in decisions { add(decision) }
    }

    mutating func add(_ decision: Decision) {
        switch decision {
        case .unreviewed: unreviewed += 1
        case .kept: kept += 1
        case .rejected: rejected += 1
        }
    }

    public var total: Int { unreviewed + kept + rejected }
    /// The decision every photo shares, or nil when they differ (or there are none).
    public var uniform: Decision? {
        if total == 0 { return nil }
        if unreviewed == total { return .unreviewed }
        if kept == total { return .kept }
        if rejected == total { return .rejected }
        return nil
    }
    /// True when the photos do not all share one decision.
    public var isMixed: Bool { total > 0 && uniform == nil }
}

/// The face strip of a stack: a column per frame, a row per person.
public struct FaceStrip: Sendable, Hashable {
    /// The frames' photo ids, one per column.
    public var frames: [String]
    /// The rows; `matching.rows[r].faces[c]` is the index of the face in `frames[c]`'s
    /// `PhotoScores.faces`, or nil.
    public var matching: FaceMatching

    public init(frames: [String], matching: FaceMatching) {
        self.frames = frames
        self.matching = matching
    }
}
