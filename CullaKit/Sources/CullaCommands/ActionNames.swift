import CullaSession

extension SessionAction {
    /// The action's name for the Undo and Redo menu items, such as "Keep", "Reject 3 Photos" or
    /// "Rate 4 Stars". `SessionEdit.undoMenuTitle` puts it into "Undo Keep".
    public var menuName: String {
        switch self {
        case let .setDecision(decision, ids):
            let many = ids.count > 1
            switch decision {
            case .kept: return many ? localized("Keep \(ids.count) Photos") : localized("Keep")
            case .rejected: return many ? localized("Reject \(ids.count) Photos") : localized("Reject")
            case .unreviewed: return many ? localized("Clear \(ids.count) Decisions") : localized("Clear Decision")
            }
        case let .setDecisions(decisions):
            // One or several, with no number shown: a choice of word, not a plural form.
            return decisions.count == 1 ? localized("Decision") : localized("Decisions")
        case let .setRating(rating, ids):
            let many = ids.count > 1
            if rating == 0 { return many ? localized("Clear \(ids.count) Ratings") : localized("Clear Rating") }
            return many ? localized("Rate \(ids.count) Photos \(rating) Stars") : localized("Rate \(rating) Stars")
        }
    }
}

extension SessionEdit {
    /// The step's name for the Undo and Redo menu items: "Accept Stack", "Split from Stack",
    /// "Accept All Exact Duplicates", or the action's own name for a decision or rating.
    public var menuName: String {
        switch self {
        case .action(let action): action.menuName
        case .acceptStack: localized("Accept Stack")
        case .acceptDuplicateSet: localized("Accept Duplicate Set")
        case .acceptAllExactDuplicates(let sets): sets == 1 ? localized("Accept 1 Exact Duplicate Set") : localized("Accept All Exact Duplicates")
        case .addToStack: localized("Add to Stack")
        case .splitFromStack: localized("Split from Stack")
        case .chooseBestPick(let id, _): id == nil ? localized("Use Culla’s Best Pick") : localized("Make Best Pick")
        }
    }

    /// The Undo menu item for this step: "Undo Keep", "Undo Reject 3 Photos".
    public var undoMenuTitle: String { localized("Undo \(menuName)") }

    /// The Redo menu item for this step: "Redo Keep".
    public var redoMenuTitle: String { localized("Redo \(menuName)") }

    /// The Undo menu item when there is nothing to undo.
    public static var undoMenuTitle: String { localized("Undo") }

    /// The Redo menu item when there is nothing to redo.
    public static var redoMenuTitle: String { localized("Redo") }
}

extension GroupID {
    /// One line for a group with nothing in it, such as "No closed eyes found".
    public var emptyMessage: String {
        switch self {
        case .allPhotos: localized("No photos in this folder")
        case .duplicates: localized("No duplicates found")
        case .similarStacks: localized("No similar stacks found")
        case .eyesClosed: localized("No closed eyes found")
        case .blurry: localized("No blurry photos found")
        case .exposure: localized("No exposure problems found")
        case .otherIssues: localized("No other issues found")
        case .unreviewed: localized("Every photo has a decision")
        case .kept: localized("No kept photos yet")
        case .rejected: localized("No rejected photos yet")
        }
    }

    /// True for groups whose members are found by analysis rather than by decisions.
    public var needsAnalysis: Bool {
        switch self {
        case .duplicates, .similarStacks, .eyesClosed, .blurry, .exposure, .otherIssues: true
        case .allPhotos, .unreviewed, .kept, .rejected: false
        }
    }

    /// True when the sidebar shows "left / total" for the group; false when it shows one number,
    /// because "left" means nothing there (Kept and Rejected have none left, and every photo in
    /// Unreviewed is left).
    public var showsLeftCount: Bool {
        switch self {
        case .unreviewed, .kept, .rejected: false
        default: true
        }
    }
}
