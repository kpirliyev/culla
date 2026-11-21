import CullaAnalysis
import CullaCore
import Foundation

/// Everything about one open shoot that is not a view concern: the photos in capture order, each
/// with its decision, rating and scores, the stacks and duplicate sets, the groups derived from
/// them, and the undo history.
///
/// A value type with no I/O. Decisions and ratings change only through `apply(_:)`, which records
/// how to undo the change. Scores, stacks, duplicate sets and `tuning` are set directly: they are
/// measurements and settings, not user decisions, and changing them never changes a decision.
///
/// Speed: every photo carries a small bit set of the groups it belongs to, and every group keeps
/// its "left / total" count. A change to one photo updates its bit set and the counts in constant
/// time, so `count(of:)` and `totals` cost nothing, and a decision on one photo costs the same in
/// a shoot of 10 or 100,000 photos. `members(of:)` and the navigation helpers walk the bit sets in
/// capture order, one integer test per photo. Changing `tuning`, the stacks or the duplicate sets
/// recomputes every photo once, which is linear in the number of photos.
public struct SessionState: Sendable {
    /// Every photo in capture order: capture date, else file modification date, ties broken by id.
    public private(set) var photos: [PhotoItem] = []

    /// The thresholds and switches that turn scores into flags. Changing it regroups at once and
    /// never changes a decision.
    public var tuning: Tuning {
        didSet {
            if tuning != oldValue { rederiveAll() }
        }
    }

    /// The stacks, in capture order of their first member: the automatic stacks with the user's
    /// `stackEdits` applied on top.
    public private(set) var stacks: [PhotoStack] = []
    /// The stacks as the last automatic grouping gave them (`setStacks(_:)`,
    /// `applyGrouping(_:)`), cleaned up but without the user's edits.
    public private(set) var automaticStacks: [PhotoStack] = []
    /// The user's corrections to the stacks: photos joined and split out, and hand-chosen best
    /// picks. Changed by `addToStack(_:)`, `splitFromStack(_:)`, `chooseBestPick` and
    /// `setBestPick`, and loaded with `setStackEdits(_:)`.
    public private(set) var stackEdits = StackEdits()
    /// The duplicate sets, in capture order of their first member.
    public private(set) var duplicateSets: [PhotoDuplicateSet] = []

    // Derived, kept in step with `photos`.
    var positions: [String: Int] = [:]
    var summaries: [PhotoSummary?] = []
    var masks: [UInt16] = []
    var stackOf: [Int?] = []
    var duplicateSetOf: [Int?] = []
    /// Unreviewed frames per stack, and unreviewed copies per duplicate set.
    var stackUnreviewed: [Int] = []
    var setUnreviewed: [Int] = []
    /// The position in `photos` of each stack's and each set's first member.
    var stackFirst: [Int] = []
    var setFirst: [Int] = []
    private var counts = [GroupCount](repeating: GroupCount(left: 0, total: 0), count: GroupID.allCases.count)
    private var unreadableCount = 0

    // Undo history.
    private var undoStack: [UndoStep] = []
    private var redoStack: [UndoStep] = []
    /// The most steps kept for undo; older steps are forgotten.
    public static let undoLimit = 10_000

    private struct UndoStep: Sendable {
        var edit: SessionEdit
        /// What `undoAction` reports: the action itself, or for an accept the decisions it set.
        var action: SessionAction?
        var before: [PhotoMark]
        var after: [PhotoMark]
        /// The stack edits before and after, for steps that changed them.
        var editsBefore: StackEdits?
        var editsAfter: StackEdits?
    }

    // MARK: - Creating

    /// A session holding these photos. They are put in capture order; duplicates of an id keep
    /// the first.
    public init(photos: [PhotoItem] = [], tuning: Tuning = Tuning()) {
        self.tuning = tuning
        self.photos = photos
        rebuild()
    }

    /// A session for a shoot opened for the first time: every photo Unreviewed and not new.
    public init(scanned: [ScannedPhoto], tuning: Tuning = Tuning()) {
        self.init(photos: scanned.map { PhotoItem(file: $0.file, metadata: $0.metadata) }, tuning: tuning)
    }

    // MARK: - Looking up photos

    public var count: Int { photos.count }

    /// The photo with this id, or nil when the session has none.
    public func photo(_ id: String) -> PhotoItem? {
        positions[id].map { photos[$0] }
    }

    /// The photo's position in `photos`.
    public func index(of id: String) -> Int? {
        positions[id]
    }

    public func contains(_ id: String) -> Bool {
        positions[id] != nil
    }

    /// The photo's summary under the current tuning: its main faces, scores and flags with tiers.
    /// Nil until the photo has scores.
    public func summary(for id: String) -> PhotoSummary? {
        positions[id].flatMap { summaries[$0] }
    }

    /// What a tile needs for its badges. Nil when the session has no such photo.
    public func badges(for id: String) -> PhotoBadges? {
        guard let index = positions[id] else { return nil }
        let summary = summaries[index]
        let flags = PhotoFlag.allCases.compactMap { flag in
            summary?.tier(of: flag).map { FlagBadge(flag: flag, tier: $0) }
        }
        let stack = stackOf[index].map { stacks[$0] }
        return PhotoBadges(
            flags: flags,
            isBestPick: stack?.bestPick == id,
            stackID: stack?.id,
            duplicateSetID: duplicateSetOf[index].map { duplicateSets[$0].id },
            isNew: photos[index].isNew,
            isUnreadable: photos[index].isUnreadable
        )
    }

    /// The stack the photo belongs to, if any.
    public func stack(containing id: String) -> PhotoStack? {
        positions[id].flatMap { stackOf[$0] }.map { stacks[$0] }
    }

    /// The duplicate set the photo belongs to, if any.
    public func duplicateSet(containing id: String) -> PhotoDuplicateSet? {
        positions[id].flatMap { duplicateSetOf[$0] }.map { duplicateSets[$0] }
    }

    /// Decisions and ratings of these photos, for saving. Unknown ids are skipped.
    public func marks(for ids: some Sequence<String>) -> [PhotoMark] {
        ids.compactMap { photo($0)?.mark }
    }

    // MARK: - Groups

    /// The photo ids in a group, in capture order. Linear in the number of photos.
    public func members(of group: GroupID) -> [String] {
        let bit = group.bit
        var result: [String] = []
        result.reserveCapacity(counts[group.slot].total)
        for index in masks.indices where masks[index] & bit != 0 {
            result.append(photos[index].id)
        }
        return result
    }

    /// "Left to review / total" for a group. Constant time.
    public func count(of group: GroupID) -> GroupCount {
        counts[group.slot]
    }

    /// True when the photo is in the group.
    public func isMember(_ id: String, of group: GroupID) -> Bool {
        guard let index = positions[id] else { return false }
        return masks[index] & group.bit != 0
    }

    /// Every group the photo is in, in sidebar order.
    public func groups(of id: String) -> [GroupID] {
        guard let index = positions[id] else { return [] }
        return GroupID.allCases.filter { masks[index] & $0.bit != 0 }
    }

    /// The status bar numbers. Constant time.
    public var totals: SessionTotals {
        SessionTotals(
            photos: photos.count,
            kept: counts[GroupID.kept.slot].total,
            rejected: counts[GroupID.rejected.slot].total,
            left: counts[GroupID.allPhotos.slot].left,
            unreadable: unreadableCount
        )
    }

    /// Unreviewed members of a defect group whose flag for that group is Certain: what ⇧X rejects.
    /// Empty for groups that are not about a defect.
    public func undecidedCertainMembers(of group: GroupID) -> [String] {
        let flags = group.flags
        guard !flags.isEmpty else { return [] }
        let bit = group.bit
        var result: [String] = []
        for index in masks.indices where masks[index] & bit != 0 && photos[index].decision == .unreviewed {
            if let summary = summaries[index], flags.contains(where: { summary.tier(of: $0) == .certain }) {
                result.append(photos[index].id)
            }
        }
        return result
    }

    // MARK: - Navigation

    /// The first member of the group after the photo in capture order. The photo itself need not
    /// be a member. With `undecidedOnly`, members with a decision are skipped.
    public func next(after id: String, in group: GroupID, undecidedOnly: Bool = false) -> String? {
        guard let start = positions[id] else { return nil }
        return firstMember(of: group, in: (start + 1)..<photos.count, undecidedOnly: undecidedOnly)
    }

    /// The last member of the group before the photo in capture order.
    public func previous(before id: String, in group: GroupID, undecidedOnly: Bool = false) -> String? {
        guard let start = positions[id] else { return nil }
        return lastMember(of: group, in: 0..<start, undecidedOnly: undecidedOnly)
    }

    /// The first member of the group whose decision is still Unreviewed.
    public func firstUndecided(in group: GroupID) -> String? {
        firstMember(of: group, in: 0..<photos.count, undecidedOnly: true)
    }

    /// The first member of the group, decided or not.
    public func first(in group: GroupID) -> String? {
        firstMember(of: group, in: 0..<photos.count, undecidedOnly: false)
    }

    /// Where to go after deciding these photos while looking at a group: the member that followed
    /// the last of them in the group as it was before the decision, even when the decided photos
    /// then leave the group. When none follows, the nearest member before the first of them.
    /// Nil when the group holds nothing else.
    ///
    /// Gives the same answer whether it is asked before or after the decision is applied, since a
    /// decision changes the groups of the decided photos only.
    public func nextAfterDecision(on ids: some Collection<String>, in group: GroupID, undecidedOnly: Bool = false) -> String? {
        let decided = Set(ids.compactMap { positions[$0] })
        guard let first = decided.min(), let last = decided.max() else { return nil }
        let bit = group.bit
        for index in (last + 1)..<photos.count where masks[index] & bit != 0 && !decided.contains(index) {
            if !undecidedOnly || photos[index].decision == .unreviewed { return photos[index].id }
        }
        // Members between the decided photos come next, then the ones before them.
        for index in (first..<last).reversed() where masks[index] & bit != 0 && !decided.contains(index) {
            if !undecidedOnly || photos[index].decision == .unreviewed { return photos[index].id }
        }
        return lastMember(of: group, in: 0..<first, undecidedOnly: undecidedOnly)
    }

    private func firstMember(of group: GroupID, in range: Range<Int>, undecidedOnly: Bool) -> String? {
        let bit = group.bit
        for index in range where masks[index] & bit != 0 {
            if !undecidedOnly || photos[index].decision == .unreviewed { return photos[index].id }
        }
        return nil
    }

    private func lastMember(of group: GroupID, in range: Range<Int>, undecidedOnly: Bool) -> String? {
        let bit = group.bit
        for index in range.reversed() where masks[index] & bit != 0 {
            if !undecidedOnly || photos[index].decision == .unreviewed { return photos[index].id }
        }
        return nil
    }

    // MARK: - Decisions, ratings and undo

    /// Applies a change to decisions or ratings and records how to undo it, as one step however
    /// many photos it touches. Unknown ids are ignored. A change that changes nothing records no
    /// step. Clears the redo history.
    @discardableResult
    public mutating func apply(_ action: SessionAction) -> SessionChange {
        var targets: [Int: PhotoMark] = [:]
        switch action {
        case let .setDecision(decision, ids):
            for id in ids {
                guard let index = positions[id] else { continue }
                var mark = photos[index].mark
                mark.decision = decision
                targets[index] = mark
            }
        case let .setDecisions(decisions):
            for (id, decision) in decisions {
                guard let index = positions[id] else { continue }
                var mark = photos[index].mark
                mark.decision = decision
                targets[index] = mark
            }
        case let .setRating(rating, ids):
            let clamped = min(max(rating, 0), 5)
            for id in ids {
                guard let index = positions[id] else { continue }
                var mark = photos[index].mark
                mark.rating = clamped
                targets[index] = mark
            }
        }

        return commit(.action(action), action: action, targets: targets)
    }

    /// Applies new marks and, when given, new stack edits as one undo step. Records nothing and
    /// returns an empty change when nothing would change. Clears the redo history otherwise.
    mutating func commit(
        _ edit: SessionEdit,
        action: SessionAction?,
        targets: [Int: PhotoMark],
        edits newEdits: StackEdits? = nil
    ) -> SessionChange {
        let changed = targets.keys.sorted().filter { photos[$0].mark != targets[$0] }
        let editsChange = newEdits.flatMap { $0 != stackEdits ? $0 : nil }
        guard !changed.isEmpty || editsChange != nil else { return SessionChange() }
        let before = changed.map { photos[$0].mark }
        let after = changed.map { targets[$0]! }
        let editsBefore = editsChange.map { _ in stackEdits }
        if let editsChange {
            stackEdits = editsChange
            resolveStacks()
        }
        for (index, mark) in zip(changed, after) {
            setMark(mark, at: index)
        }
        undoStack.append(UndoStep(
            edit: edit, action: action, before: before, after: after,
            editsBefore: editsBefore, editsAfter: editsChange
        ))
        if undoStack.count > Self.undoLimit { undoStack.removeFirst(undoStack.count - Self.undoLimit) }
        redoStack.removeAll()
        return SessionChange(changedIDs: changed.map { photos[$0].id }, stackEditsChanged: editsChange != nil)
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    /// The action `undo()` would take back, for naming the menu item. For an accept (stack or
    /// duplicates) it is the `.setDecisions` the accept made; for a stack edit (add to stack,
    /// split out, best pick) it is nil: name those from `undoEdit`.
    public var undoAction: SessionAction? { undoStack.last?.action }
    /// The action `redo()` would apply again; see `undoAction`.
    public var redoAction: SessionAction? { redoStack.last?.action }
    /// The step `undo()` would take back, whatever kind it is.
    public var undoEdit: SessionEdit? { undoStack.last?.edit }
    /// The step `redo()` would apply again.
    public var redoEdit: SessionEdit? { redoStack.last?.edit }

    /// Takes back the last step exactly. Photos that have since left the session are skipped.
    /// Nil when there is nothing to undo.
    @discardableResult
    public mutating func undo() -> SessionChange? {
        guard let step = undoStack.popLast() else { return nil }
        redoStack.append(step)
        return restore(step.before, edits: step.editsBefore)
    }

    /// Applies the last undone step again. Nil when there is nothing to redo.
    @discardableResult
    public mutating func redo() -> SessionChange? {
        guard let step = redoStack.popLast() else { return nil }
        undoStack.append(step)
        return restore(step.after, edits: step.editsAfter)
    }

    private mutating func restore(_ marks: [PhotoMark], edits: StackEdits?) -> SessionChange {
        var editsChanged = false
        if let edits, edits != stackEdits {
            stackEdits = edits
            resolveStacks()
            editsChanged = true
        }
        var changed: [Int] = []
        for mark in marks {
            guard let index = positions[mark.id], photos[index].mark != mark else { continue }
            setMark(mark, at: index)
            changed.append(index)
        }
        return SessionChange(changedIDs: changed.sorted().map { photos[$0].id }, stackEditsChanged: editsChanged)
    }

    private mutating func setMark(_ mark: PhotoMark, at index: Int) {
        update(index) { item in
            item.decision = mark.decision
            item.rating = mark.rating
        }
    }

    // MARK: - Scores

    /// Stores a photo's scores as they arrive from analysis, and clears any unreadable mark.
    /// Returns false when the session has no such photo.
    @discardableResult
    public mutating func setScores(_ scores: PhotoScores?, for id: String) -> Bool {
        guard let index = positions[id] else { return false }
        update(index) { item in
            item.scores = scores
            item.unreadableReason = nil
        }
        return true
    }

    /// Stores many photos' scores at once, such as those found in the score cache.
    public mutating func setScores(_ scores: [String: PhotoScores]) {
        for (id, value) in scores {
            setScores(value, for: id)
        }
    }

    /// Marks a photo as unreadable: it stays in All Photos and leaves every other group.
    @discardableResult
    public mutating func markUnreadable(_ id: String, reason: String) -> Bool {
        guard let index = positions[id] else { return false }
        update(index) { item in
            item.scores = nil
            item.unreadableReason = reason
        }
        return true
    }

    /// Changes one photo and keeps its summary, groups and the counts in step.
    private mutating func update(_ index: Int, _ change: (inout PhotoItem) -> Void) {
        account(index, sign: -1)
        change(&photos[index])
        summaries[index] = photos[index].scores?.summary(tuning: tuning)
        masks[index] = mask(for: index)
        account(index, sign: 1)
    }

    // MARK: - Stacks and duplicates

    /// Replaces the automatic stacks, then applies the user's `stackEdits` on top of them to give
    /// `stacks`. Ids the session does not have are dropped, a photo already in an earlier stack
    /// is dropped from later ones, members are put in capture order, stacks left with fewer than
    /// two members are dropped, and a best pick that is not a member is cleared. Unreadable
    /// photos are never shown in a stack.
    public mutating func setStacks(_ newStacks: [PhotoStack]) {
        var used = Set<Int>()
        var result: [(first: Int, stack: PhotoStack)] = []
        for stack in newStacks {
            let members = normalizedMembers(stack.members, used: &used)
            guard members.count >= 2 else { continue }
            let ids = members.map { photos[$0].id }
            let pick = stack.bestPick.flatMap { ids.contains($0) ? $0 : nil }
            result.append((members[0], PhotoStack(members: ids, bestPick: pick)))
        }
        automaticStacks = result.sorted { $0.first < $1.first }.map(\.stack)
        resolveStacks()
    }

    /// Replaces the user's stack edits, such as those loaded from the store when a shoot is
    /// reopened, and applies them to the automatic stacks. Not an undo step.
    public mutating func setStackEdits(_ edits: StackEdits) {
        guard edits != stackEdits else { return }
        stackEdits = edits
        resolveStacks()
    }

    /// The best picks the user chose by hand, for `ShootAnalysis.setManualBestPicks(_:)`.
    public var handPickedBestPicks: Set<String> { stackEdits.bestPicks }

    /// True when the stack's best pick was chosen by hand.
    public func isHandPicked(_ stack: PhotoStack) -> Bool {
        stack.bestPick.map { stackEdits.bestPicks.contains($0) } ?? false
    }

    /// Computes `stacks` from `automaticStacks` and `stackEdits` (see `StackEdits` for the rules),
    /// then every membership and count.
    mutating func resolveStacks() {
        guard !stackEdits.isEmpty else {
            stacks = automaticStacks
            rebuildMemberships()
            return
        }
        let split = Set(stackEdits.splitOut.compactMap { positions[$0] })
        // Union-find over photo positions; -1 marks a photo in no stack or group.
        var parent = [Int](repeating: -1, count: photos.count)
        var touched: [Int] = []
        func find(_ item: Int) -> Int {
            var root = item
            while parent[root] != root { root = parent[root] }
            var node = item
            while parent[node] != root {
                let next = parent[node]
                parent[node] = root
                node = next
            }
            return root
        }
        func union(_ a: Int, _ b: Int) {
            for item in [a, b] where parent[item] == -1 {
                parent[item] = item
                touched.append(item)
            }
            let rootA = find(a)
            let rootB = find(b)
            if rootA != rootB { parent[max(rootA, rootB)] = min(rootA, rootB) }
        }

        // Where each photo's automatic stack is, after the split-out photos left it.
        var automaticOf = [Int](repeating: -1, count: photos.count)
        var automaticMembers: [[Int]] = []
        for (number, stack) in automaticStacks.enumerated() {
            let members = stack.members.compactMap { positions[$0] }.filter { !split.contains($0) }
            automaticMembers.append(members)
            for member in members {
                automaticOf[member] = number
                union(members[0], member)
            }
        }
        for group in stackEdits.joined {
            let members = group.compactMap { positions[$0] }.filter { !photos[$0].isUnreadable }
            for member in members {
                union(members[0], member)
            }
        }

        var components: [Int: [Int]] = [:]
        for item in touched {
            components[find(item), default: []].append(item)
        }
        var result: [(first: Int, stack: PhotoStack)] = []
        for var members in components.values where members.count >= 2 {
            members.sort()
            let ids = members.map { photos[$0].id }
            var pick = stackEdits.bestPicks.isEmpty ? nil : ids.first { stackEdits.bestPicks.contains($0) }
            if pick == nil {
                // Exactly one automatic stack, less any frames split out, and nothing added.
                let source = automaticOf[members[0]]
                if source >= 0, automaticMembers[source] == members,
                   let automatic = automaticStacks[source].bestPick, ids.contains(automatic) {
                    pick = automatic
                } else {
                    pick = computedBestPick(of: members)
                }
            }
            result.append((members[0], PhotoStack(members: ids, bestPick: pick)))
        }
        stacks = result.sorted { $0.first < $1.first }.map(\.stack)
        rebuildMemberships()
    }

    /// The frame `BestPick` chooses among these photos (positions) from their scores, or nil
    /// when none has scores.
    func computedBestPick(of members: [Int]) -> String? {
        let scored = members.filter { photos[$0].scores != nil }
        let candidates = scored.map { BestPickCandidate(scores: photos[$0].scores!, tuning: tuning) }
        return BestPick.best(candidates, tuning: tuning).map { photos[scored[$0]].id }
    }

    /// Replaces the duplicate sets, cleaned up the same way as `setStacks(_:)`.
    public mutating func setDuplicateSets(_ sets: [PhotoDuplicateSet]) {
        var used = Set<Int>()
        var result: [(first: Int, set: PhotoDuplicateSet)] = []
        for set in sets {
            let members = normalizedMembers(set.members, used: &used)
            guard members.count >= 2 else { continue }
            result.append((members[0], PhotoDuplicateSet(kind: set.kind, members: members.map { photos[$0].id })))
        }
        duplicateSets = result.sorted { $0.first < $1.first }.map(\.set)
        rebuildMemberships()
    }

    /// Makes a photo its stack's best pick, remembered as chosen by hand (`stackEdits.bestPicks`)
    /// so automatic grouping never replaces it. Nil forgets the hand-chosen pick and goes back to
    /// Culla's. Not an undo step; `chooseBestPick(_:inStackContaining:)` is the undoable form.
    /// Returns false when the photo is in no stack, or `pick` is not a member of it.
    ///
    /// Before M3 nil cleared the pick outright; it now restores the automatic pick.
    @discardableResult
    public mutating func setBestPick(_ pick: String?, ofStackContaining memberID: String) -> Bool {
        guard let edits = editsChoosingBestPick(pick, inStackContaining: memberID) else { return false }
        setStackEdits(edits)
        return true
    }

    /// The stack edits with `pick` as the hand-chosen pick of the stack holding `memberID`, or
    /// nil when the photo is in no stack or `pick` is not a member of it.
    func editsChoosingBestPick(_ pick: String?, inStackContaining memberID: String) -> StackEdits? {
        guard let index = positions[memberID], let stackIndex = stackOf[index] else { return nil }
        let members = stacks[stackIndex].members
        if let pick, !members.contains(pick) { return nil }
        var edits = stackEdits
        edits.bestPicks.subtract(members)
        if let pick { edits.bestPicks.insert(pick) }
        return edits
    }

    /// Computes stacks and duplicate sets from the current scores, metadata and tuning with
    /// `StackGrouper` and `DuplicateFinder`, without changing the state. Unreadable photos are
    /// left out. Best picks of the current stacks are carried over to the new stack that holds
    /// them.
    ///
    /// - Parameter contentHash: a hash of a photo's file content, or nil when it cannot be read.
    ///   It reads the file, so call this away from the main thread. It is only asked about files
    ///   that share their size with another file.
    public func computeGrouping(contentHash: (PhotoItem) -> String?) -> SessionGrouping {
        let readable = photos.indices.filter { !photos[$0].isUnreadable }
        let features = readable.map { photos[$0].scores?.featureVector }

        let stacking = StackGrouper.group(
            readable.indices.map { slot in
                let item = photos[readable[slot]]
                return StackCandidate(
                    date: item.sortDate,
                    hasCaptureDate: item.metadata.captureDate != nil,
                    burstID: item.metadata.burstID,
                    feature: features[slot]
                )
            },
            tuning: tuning
        )
        let picks = Set(stacks.compactMap(\.bestPick))
        let newStacks = stacking.stacks.map { slots in
            let ids = slots.map { readable[$0] }.sorted().map { photos[$0].id }
            return PhotoStack(members: ids, bestPick: ids.first { picks.contains($0) })
        }

        let duplicates = DuplicateFinder.find(
            readable.indices.map { slot in
                let item = photos[readable[slot]]
                return DuplicateCandidate(
                    fileSize: item.file.fileSize,
                    captureDate: item.metadata.captureDate,
                    feature: features[slot]
                )
            },
            tuning: tuning,
            contentHash: { contentHash(photos[readable[$0]]) }
        )
        let newSets = duplicates.map { set in
            PhotoDuplicateSet(kind: set.kind, members: set.members.map { readable[$0] }.sorted().map { photos[$0].id })
        }
        return SessionGrouping(stacks: newStacks, duplicateSets: newSets)
    }

    /// Replaces the stacks and duplicate sets with a computed grouping.
    public mutating func applyGrouping(_ grouping: SessionGrouping) {
        setStacks(grouping.stacks)
        setDuplicateSets(grouping.duplicateSets)
    }

    /// Recomputes the stacks and duplicate sets from the current scores and tuning.
    /// `contentHash` reads files; see `computeGrouping(contentHash:)`.
    public mutating func regroup(contentHash: (PhotoItem) -> String?) {
        applyGrouping(computeGrouping(contentHash: contentHash))
    }

    private func normalizedMembers(_ ids: [String], used: inout Set<Int>) -> [Int] {
        var members: [Int] = []
        for id in ids {
            guard let index = positions[id], !photos[index].isUnreadable, !used.contains(index) else { continue }
            used.insert(index)
            members.append(index)
        }
        return members.sorted()
    }

    // MARK: - Rescans

    /// Brings the session in line with a fresh scan of the folder. Photos still there keep their
    /// decision, rating and new mark; when a file's size or modification date changed, its scores
    /// are dropped so it is analysed again. Photos not seen before are added and marked new.
    /// Photos that are gone are dropped from the session, its stacks and its duplicate sets.
    ///
    /// Use `init(scanned:)` for a shoot opened for the first time, so its photos are not all new.
    ///
    /// Renames and moves made outside Culla are recognised: when a photo's id is gone and exactly
    /// one new photo has the same file size and modification date (and the same capture time,
    /// when both have one), and that new photo matches no other gone photo either, it is taken to
    /// be the same photo under a new path. It keeps its decision, rating, scores and new mark
    /// under the new id, and its id is updated in the stacks, duplicate sets, stack edits and undo
    /// history; `MergeResult.renamed` lists it. Ambiguous cases (two gone photos or two new ones
    /// with the same size and date) are not matched: the gone ones are removed and the new ones
    /// added.
    @discardableResult
    public mutating func merge(scanned: [ScannedPhoto]) -> MergeResult {
        var result = MergeResult()
        var seen = Set<String>()
        let unique = scanned.filter { seen.insert($0.id).inserted }
        let renames = Self.matchRenames(
            gone: photos.filter { !seen.contains($0.id) },
            fresh: unique.filter { positions[$0.id] == nil }
        )
        var renamedFrom: [String: Int] = [:]
        var renamedIDs: [String: String] = [:]
        for (oldID, new) in renames {
            renamedFrom[new.id] = positions[oldID]!
            renamedIDs[oldID] = new.id
        }

        var merged: [PhotoItem] = []
        merged.reserveCapacity(unique.count)
        for photo in unique {
            if let index = positions[photo.id] {
                var item = photos[index]
                if item.file.fileSize != photo.file.fileSize || item.file.modificationDate != photo.file.modificationDate {
                    item.scores = nil
                    item.unreadableReason = nil
                    result.modified.append(photo.id)
                }
                item.file = photo.file
                item.metadata = photo.metadata
                merged.append(item)
            } else if let index = renamedFrom[photo.id] {
                var item = photos[index]
                result.renamed.append(PhotoRename(from: item.id, to: photo.id, oldURL: item.file.url, newURL: photo.file.url))
                item.file = photo.file
                item.metadata = photo.metadata
                merged.append(item)
            } else {
                merged.append(PhotoItem(file: photo.file, metadata: photo.metadata, isNew: true))
                result.added.append(photo.id)
            }
        }
        result.removed = photos.map(\.id).filter { !seen.contains($0) && renamedIDs[$0] == nil }
        photos = merged
        var keptStacks = automaticStacks
        var keptSets = duplicateSets
        if !renamedIDs.isEmpty {
            let rename = { (id: String) in renamedIDs[id] ?? id }
            keptStacks = keptStacks.map { PhotoStack(members: $0.members.map(rename), bestPick: $0.bestPick.map(rename)) }
            keptSets = keptSets.map { PhotoDuplicateSet(kind: $0.kind, members: $0.members.map(rename)) }
            stackEdits = stackEdits.renaming(renamedIDs)
            renameInHistory(renamedIDs)
        }
        rebuild()
        setStacks(keptStacks)
        setDuplicateSets(keptSets)

        let positions = self.positions
        let order = { (ids: [String]) in ids.sorted { positions[$0]! < positions[$1]! } }
        result.added = order(result.added)
        result.modified = order(result.modified)
        result.renamed.sort { positions[$0.to]! < positions[$1.to]! }
        return result
    }

    /// Pairs gone photos with new ones that are the same file under another path: same size and
    /// modification date, the same capture time when both have one, and no other candidate on
    /// either side. Returns new photos by old id.
    private static func matchRenames(gone: [PhotoItem], fresh: [ScannedPhoto]) -> [String: ScannedPhoto] {
        guard !gone.isEmpty, !fresh.isEmpty else { return [:] }
        struct Key: Hashable {
            var size: Int64
            var date: Date
        }
        func compatible(_ a: Date?, _ b: Date?) -> Bool {
            guard let a, let b else { return true }
            return a == b
        }
        let freshByKey = Dictionary(grouping: fresh) { Key(size: $0.file.fileSize, date: $0.file.modificationDate) }
        let goneByKey = Dictionary(grouping: gone) { Key(size: $0.file.fileSize, date: $0.file.modificationDate) }
        var matches: [String: ScannedPhoto] = [:]
        for (key, olds) in goneByKey {
            guard let news = freshByKey[key] else { continue }
            for old in olds {
                let candidates = news.filter { compatible(old.metadata.captureDate, $0.metadata.captureDate) }
                guard candidates.count == 1, let new = candidates.first else { continue }
                let rivals = olds.filter { compatible($0.metadata.captureDate, new.metadata.captureDate) }
                guard rivals.count == 1 else { continue }
                matches[old.id] = new
            }
        }
        return matches
    }

    /// Replaces old ids with new ones in the undo and redo history.
    private mutating func renameInHistory(_ ids: [String: String]) {
        func renamed(_ step: UndoStep) -> UndoStep {
            var step = step
            step.before = step.before.map { PhotoMark(id: ids[$0.id] ?? $0.id, decision: $0.decision, rating: $0.rating) }
            step.after = step.after.map { PhotoMark(id: ids[$0.id] ?? $0.id, decision: $0.decision, rating: $0.rating) }
            step.editsBefore = step.editsBefore?.renaming(ids)
            step.editsAfter = step.editsAfter?.renaming(ids)
            return step
        }
        undoStack = undoStack.map(renamed)
        redoStack = redoStack.map(renamed)
    }

    // MARK: - Applying to disk

    /// Forgets the undo and redo history of decisions. Called when an apply wrote decisions to
    /// disk; see `removeAppliedPhotos(_:)`.
    public mutating func clearHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
    }

    /// The photos as they are now, for keeping until an apply is undone. Unknown ids are skipped.
    public func appliedPhotos(_ ids: some Sequence<String>) -> [AppliedPhoto] {
        ids.compactMap { photo($0).map(AppliedPhoto.init) }
    }

    /// Takes photos an apply moved out of the shoot (to `_Rejected` or the Trash) out of the
    /// session, and returns them as they were so `restoreAppliedPhotos(_:)` can bring them back if
    /// the apply is undone. They leave the stacks and duplicate sets; their stack edits are kept.
    ///
    /// The decision undo history is cleared, and should be cleared (`clearHistory()`) after
    /// every apply that wrote to the shoot folder, Mark Only included: the sidecars and the
    /// files on disk now record the decisions as they were at apply, so undoing a decision made
    /// before it would leave the session disagreeing with the disk (a moved photo would silently
    /// not come back; a marked one would keep its written sidecar). The way back is Undo Apply.
    @discardableResult
    public mutating func removeAppliedPhotos(_ ids: some Collection<String>) -> [AppliedPhoto] {
        clearHistory()
        let removing = Set(ids)
        let removed = photos.filter { removing.contains($0.id) }.map(AppliedPhoto.init)
        guard !removed.isEmpty else { return [] }
        photos.removeAll { removing.contains($0.id) }
        let keptStacks = automaticStacks
        let keptSets = duplicateSets
        rebuild()
        setStacks(keptStacks)
        setDuplicateSets(keptSets)
        return removed
    }

    /// Brings back photos an undone apply returned to the shoot, with their decisions, ratings and
    /// scores, not marked new. A photo a rescan already found again under its id is given its old
    /// decision, rating and new mark, and its old scores when it has none. Clears the undo
    /// history. They rejoin stacks and duplicate sets at the next grouping. Returns the ids
    /// brought back or updated.
    @discardableResult
    public mutating func restoreAppliedPhotos(_ restored: [AppliedPhoto]) -> [String] {
        clearHistory()
        guard !restored.isEmpty else { return [] }
        var ids: [String] = []
        var additions: [PhotoItem] = []
        for photo in restored {
            if let index = positions[photo.id] {
                update(index) { item in
                    item.decision = photo.decision
                    item.rating = photo.rating
                    item.isNew = photo.isNew
                    if item.scores == nil, item.unreadableReason == nil {
                        item.scores = photo.scores
                        item.unreadableReason = photo.unreadableReason
                    }
                }
            } else {
                additions.append(photo.item)
            }
            ids.append(photo.id)
        }
        if !additions.isEmpty {
            photos.append(contentsOf: additions)
            let keptStacks = automaticStacks
            let keptSets = duplicateSets
            rebuild()
            setStacks(keptStacks)
            setDuplicateSets(keptSets)
        }
        let positions = self.positions
        return Array(Set(ids)).sorted { positions[$0] ?? .max < positions[$1] ?? .max }
    }

    // MARK: - Derived state

    /// Puts the photos in capture order and recomputes everything derived from them.
    private mutating func rebuild() {
        var seen = Set<String>()
        photos = photos.filter { seen.insert($0.id).inserted }
        // Sort positions by precomputed keys, then move each photo once.
        let keys = photos.map { ($0.sortDate, $0.id) }
        let order = photos.indices.sorted { keys[$0] < keys[$1] }
        photos = order.map { photos[$0] }
        positions = Dictionary(uniqueKeysWithValues: photos.enumerated().map { ($1.id, $0) })
        stacks = []
        automaticStacks = []
        duplicateSets = []
        rederiveAll()
    }

    /// Recomputes every summary, then every group membership and count.
    private mutating func rederiveAll() {
        summaries = photos.map { $0.scores?.summary(tuning: tuning) }
        // Best picks of stacks the user changed come from the tuning, so they are chosen again.
        if stackEdits.isEmpty { rebuildMemberships() } else { resolveStacks() }
    }

    /// Recomputes which stack and set each photo is in, every bit set and every count.
    mutating func rebuildMemberships() {
        stackOf = Array(repeating: nil, count: photos.count)
        for (stackIndex, stack) in stacks.enumerated() {
            for id in stack.members { stackOf[positions[id]!] = stackIndex }
        }
        duplicateSetOf = Array(repeating: nil, count: photos.count)
        for (setIndex, set) in duplicateSets.enumerated() {
            for id in set.members { duplicateSetOf[positions[id]!] = setIndex }
        }
        stackUnreviewed = Array(repeating: 0, count: stacks.count)
        setUnreviewed = Array(repeating: 0, count: duplicateSets.count)
        stackFirst = stacks.map { positions[$0.id]! }
        setFirst = duplicateSets.map { positions[$0.id]! }
        counts = Array(repeating: GroupCount(left: 0, total: 0), count: GroupID.allCases.count)
        unreadableCount = 0
        masks = Array(repeating: 0, count: photos.count)
        for index in photos.indices {
            masks[index] = mask(for: index)
            account(index, sign: 1)
        }
    }

    /// The groups a photo is in, as a bit set.
    private func mask(for index: Int) -> UInt16 {
        var mask = GroupID.allPhotos.bit
        let item = photos[index]
        guard !item.isUnreadable else { return mask }
        switch item.decision {
        case .unreviewed: mask |= GroupID.unreviewed.bit
        case .kept: mask |= GroupID.kept.bit
        case .rejected: mask |= GroupID.rejected.bit
        }
        if stackOf[index] != nil { mask |= GroupID.similarStacks.bit }
        if duplicateSetOf[index] != nil { mask |= GroupID.duplicates.bit }
        if let flags = summaries[index]?.flags {
            for flag in flags { mask |= GroupID.group(for: flag).bit }
        }
        return mask
    }

    /// Adds (sign 1) or removes (sign -1) a photo's share of every group count.
    private mutating func account(_ index: Int, sign: Int) {
        let mask = masks[index]
        let item = photos[index]
        if item.isUnreadable { unreadableCount += sign }
        let isLeft = item.decision == .unreviewed && !item.isUnreadable
        if isLeft {
            if let stack = stackOf[index] { stackUnreviewed[stack] += sign }
            if let set = duplicateSetOf[index] { setUnreviewed[set] += sign }
        }
        var bits = mask
        while bits != 0 {
            let slot = bits.trailingZeroBitCount
            bits &= bits - 1
            counts[slot].total += sign
            if isLeft { counts[slot].left += sign }
        }
    }
}
