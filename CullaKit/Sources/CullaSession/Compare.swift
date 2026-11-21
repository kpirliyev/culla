import Foundation

// Choosing the photos for the compare view (C).
extension SessionState {
    /// The most photos the compare view shows at once.
    public static let compareLimit = 4

    /// The photos to compare, left to right, or an empty list when there is nothing to compare.
    ///
    /// - Two to four photos selected: those, in capture order.
    /// - More than four: four of them in capture order, starting at the focused photo and going
    ///   on with the next ones selected; when fewer than three follow it, the ones just before it
    ///   fill up. Without a focused photo among them, the first four.
    /// - One photo or none selected: the focused photo (else the selected one) against its
    ///   stack's best pick, as in `compareWithBestPick(_:)`.
    ///
    /// Unknown ids are ignored, and an id selected twice counts once.
    public func comparePhotos(selection: some Collection<String>, focused: String?) -> [String] {
        let chosen = Set(selection.filter { positions[$0] != nil })
        let ordered = chosen.sorted { positions[$0]! < positions[$1]! }
        switch ordered.count {
        case 2...Self.compareLimit:
            return ordered
        case (Self.compareLimit + 1)...:
            let start = focused.flatMap { ordered.firstIndex(of: $0) } ?? 0
            let first = min(start, ordered.count - Self.compareLimit)
            return Array(ordered[first..<(first + Self.compareLimit)])
        default:
            guard let current = focused ?? ordered.first else { return [] }
            return compareWithBestPick(current)
        }
    }

    /// "Current frame versus best pick": the photo, then its stack's best pick, so the pick sits
    /// on the right as in stack review. When the photo is the pick itself, or the stack has no
    /// pick, the photo and the frame after it in the stack (the frame before it for the last
    /// frame). Empty when the photo is in no stack.
    public func compareWithBestPick(_ id: String) -> [String] {
        guard let stack = stack(containing: id) else { return [] }
        if let pick = stack.bestPick, pick != id { return [id, pick] }
        guard let index = stack.members.firstIndex(of: id) else { return [] }
        let other = index + 1 < stack.members.count ? stack.members[index + 1] : stack.members[index - 1]
        return [id, other]
    }
}
