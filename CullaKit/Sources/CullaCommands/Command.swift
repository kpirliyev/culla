/// Every action a person can take in the app. Menu items, toolbar buttons and key presses all
/// send one of these, and the session model decides whether it is available right now.
///
/// Some commands arrive in later milestones (compare, faces, stacks, bulk reject, review and
/// apply). They exist now so the key map and the menus are complete; until their milestone the
/// model reports them as unavailable, so their menu items are disabled and their keys do nothing.
///
/// The raw value is the command's stable name, used in saved key bindings and automation scripts.
public enum Command: String, CaseIterable, Codable, Sendable, Hashable {
    // File
    case openFolder
    case closeShoot
    case reviewAndApply
    /// On the Review and Apply screen: carries out the plan (the screen's primary button).
    case applyDecisions
    /// Takes back the latest apply that the journal says can still be undone.
    case undoApply
    /// Looks at the shoot folder again for files added, removed or renamed outside Culla.
    case rescanFolder
    case openSettings

    // Edit
    case undo
    case redo
    case selectAll
    case deselectAll

    // Decisions and ratings
    case keep
    case reject
    case clearDecision
    case rate0
    case rate1
    case rate2
    case rate3
    case rate4
    case rate5
    case rejectCertain
    /// Return: accepts the stack or duplicate set on screen, or opens the focused photo's stack
    /// in stack review from the grid and the loupe.
    case acceptStack
    case addToStack
    case splitFromStack
    /// Makes the focused frame its stack's best pick, by hand; on the hand-chosen pick itself,
    /// goes back to Culla's pick.
    case chooseBestPick
    /// Accepts every exact duplicate set still undecided, as one undo step.
    case acceptAllExactDuplicates

    // Moving the focus
    case nextPhoto
    case previousPhoto
    case nextRow
    case previousRow
    case extendNext
    case extendPrevious
    case extendNextRow
    case extendPreviousRow
    case firstPhoto
    case lastPhoto
    case pageDown
    case pageUp
    case nextGroup
    case previousGroup
    /// Opens the first group, in the order Culla recommends, that still has photos to review.
    case startReviewing

    // Analysis
    case toggleAnalysis
    case showTuning

    // Views
    case toggleLoupe
    case showGrid
    case showLoupe
    case showCompare
    case zoomToggle
    case nextFace
    case previousFace
    case toggleFaceBoxes
    case toggleClippingOverlay
    case toggleFaceStrip
    /// Shows or hides stack review's best-pick pane; the current frame takes its place. A
    /// preference (Settings ▸ General), not a decision: it never enters the undo history.
    case toggleBestPickPane
    /// Shows every frame of the stacks in All Photos, or collapses them again.
    case toggleStacks
    /// Escape: leaves compare, stack review or duplicate review for where the person came from,
    /// and the loupe for the grid.
    case back
    case toggleInspector
    case largerThumbnails
    case smallerThumbnails

    /// The rating a rating command sets, 0 to 5, or nil for other commands.
    public var rating: Int? {
        switch self {
        case .rate0: 0
        case .rate1: 1
        case .rate2: 2
        case .rate3: 3
        case .rate4: 4
        case .rate5: 5
        default: nil
        }
    }

    /// The command that sets this rating, 0 to 5 (values outside are clamped).
    public static func rate(_ stars: Int) -> Command {
        switch min(max(stars, 0), 5) {
        case 0: .rate0
        case 1: .rate1
        case 2: .rate2
        case 3: .rate3
        case 4: .rate4
        default: .rate5
        }
    }

    /// The menu title, in title case as macOS menus use it.
    public var title: String {
        switch self {
        case .openFolder: localized("Open…")
        case .closeShoot: localized("Close Shoot")
        case .reviewAndApply: localized("Review and Apply…")
        case .applyDecisions: localized("Apply")
        case .undoApply: localized("Undo Apply…")
        case .rescanFolder: localized("Rescan Folder")
        case .openSettings: localized("Settings…")
        case .undo: localized("Undo")
        case .redo: localized("Redo")
        case .selectAll: localized("Select All")
        case .deselectAll: localized("Deselect All")
        case .keep: localized("Keep")
        case .reject: localized("Reject")
        case .clearDecision: localized("Clear Decision")
        case .rate0: localized("No Rating")
        case .rate1, .rate2, .rate3, .rate4, .rate5: localized("\(rating ?? 0) Stars")
        case .rejectCertain: localized("Reject All Certain in Group…")
        case .acceptStack: localized("Accept Stack")
        case .addToStack: localized("Add Selection to Stack")
        case .splitFromStack: localized("Split from Stack")
        case .chooseBestPick: localized("Make Best Pick")
        case .acceptAllExactDuplicates: localized("Accept All Exact Duplicates")
        case .nextPhoto: localized("Next Photo")
        case .previousPhoto: localized("Previous Photo")
        case .nextRow: localized("Next Row")
        case .previousRow: localized("Previous Row")
        case .extendNext: localized("Extend Selection to Next")
        case .extendPrevious: localized("Extend Selection to Previous")
        case .extendNextRow: localized("Extend Selection Down")
        case .extendPreviousRow: localized("Extend Selection Up")
        case .firstPhoto: localized("First Photo")
        case .lastPhoto: localized("Last Photo")
        case .pageDown: localized("Page Down")
        case .pageUp: localized("Page Up")
        case .nextGroup: localized("Next Group")
        case .previousGroup: localized("Previous Group")
        case .startReviewing: localized("Start Reviewing")
        case .toggleAnalysis: localized("Pause Analysis")
        case .showTuning: localized("Adjust Detection…")
        case .toggleLoupe: localized("Switch Grid and Loupe")
        case .showGrid: localized("Grid")
        case .showLoupe: localized("Loupe")
        case .showCompare: localized("Compare")
        case .zoomToggle: localized("Zoom to 100%")
        case .nextFace: localized("Next Face")
        case .previousFace: localized("Previous Face")
        case .toggleFaceBoxes: localized("Show Face Boxes")
        case .toggleClippingOverlay: localized("Show Clipping")
        case .toggleFaceStrip: localized("Show Face Strip")
        case .toggleBestPickPane: localized("Show Best Pick Pane")
        case .toggleStacks: localized("Expand All Stacks")
        case .back: localized("Back")
        case .toggleInspector: localized("Show Inspector")
        case .largerThumbnails: localized("Larger Thumbnails")
        case .smallerThumbnails: localized("Smaller Thumbnails")
        }
    }

    /// The name the Keys pane of Settings lists the command by: the menu title without its
    /// ellipsis, or a fuller name where the menu title changes with the state.
    public var settingsTitle: String {
        switch self {
        case .toggleAnalysis: localized("Pause or Resume Analysis")
        case .toggleLoupe: localized("Switch Grid and Loupe")
        case .toggleFaceBoxes: localized("Show or Hide Face Boxes")
        case .toggleClippingOverlay: localized("Show or Hide Clipping")
        case .toggleFaceStrip: localized("Show or Hide Face Strip")
        case .toggleBestPickPane: localized("Show or Hide Best Pick Pane")
        case .toggleStacks: localized("Expand or Collapse Stacks")
        case .toggleInspector: localized("Show or Hide Inspector")
        case .zoomToggle: localized("Zoom to 100% or Fit")
        case .reviewAndApply: localized("Review and Apply")
        case .acceptStack: localized("Accept Stack or Set")
        case .chooseBestPick: localized("Make Best Pick")
        case .nextRow: localized("Next Row or Stack")
        case .previousRow: localized("Previous Row or Stack")
        case .applyDecisions: localized("Apply (on Review and Apply)")
        case .rejectCertain: localized("Reject All Certain in Group")
        default: title.replacingOccurrences(of: "…", with: "")
        }
    }

    /// The heading the Keys pane lists the command under.
    public var settingsSection: String {
        switch self {
        case .keep, .reject, .clearDecision, .rate0, .rate1, .rate2, .rate3, .rate4, .rate5, .rejectCertain,
             .acceptStack, .addToStack, .splitFromStack, .chooseBestPick, .acceptAllExactDuplicates:
            localized("keys.section.decisions", default: "Decisions")
        case .nextPhoto, .previousPhoto, .nextRow, .previousRow, .extendNext, .extendPrevious, .extendNextRow,
             .extendPreviousRow, .firstPhoto, .lastPhoto, .pageDown, .pageUp, .nextGroup, .previousGroup, .startReviewing,
             .nextFace, .previousFace:
            localized("keys.section.moving", default: "Moving")
        case .toggleLoupe, .showGrid, .showLoupe, .showCompare, .zoomToggle, .toggleFaceBoxes, .toggleClippingOverlay,
             .toggleFaceStrip, .toggleBestPickPane, .toggleStacks, .back, .toggleInspector, .largerThumbnails, .smallerThumbnails:
            localized("keys.section.views", default: "Views")
        case .toggleAnalysis, .showTuning:
            localized("keys.section.analysis", default: "Analysis")
        case .openFolder, .closeShoot, .reviewAndApply, .applyDecisions, .undoApply, .rescanFolder, .openSettings,
             .undo, .redo, .selectAll, .deselectAll:
            localized("keys.section.fileAndEdit", default: "File and Edit")
        }
    }

    /// The Keys pane's headings, in order.
    public static var settingsSections: [String] {
        [
            localized("keys.section.decisions", default: "Decisions"), localized("keys.section.moving", default: "Moving"),
            localized("keys.section.views", default: "Views"), localized("keys.section.analysis", default: "Analysis"),
            localized("keys.section.fileAndEdit", default: "File and Edit"),
        ]
    }

    /// True when the command changes what the user set on photos, and so can be undone.
    public var isDecision: Bool {
        switch self {
        case .keep, .reject, .clearDecision, .rejectCertain, .acceptStack, .acceptAllExactDuplicates,
             .rate0, .rate1, .rate2, .rate3, .rate4, .rate5:
            true
        default:
            false
        }
    }
}
