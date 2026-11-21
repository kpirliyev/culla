/// The photos a view shows, in order, with constant-time lookup of a photo's position.
public struct PhotoOrder: Sendable, Equatable {
    public let ids: [String]
    private let positions: [String: Int]

    public init(_ ids: [String]) {
        self.ids = ids
        var positions: [String: Int] = [:]
        positions.reserveCapacity(ids.count)
        for (index, id) in ids.enumerated() where positions[id] == nil {
            positions[id] = index
        }
        self.positions = positions
    }

    public static let empty = PhotoOrder([])

    public var count: Int { ids.count }
    public var isEmpty: Bool { ids.isEmpty }
    public func position(of id: String) -> Int? { positions[id] }
    public func contains(_ id: String) -> Bool { positions[id] != nil }

    public static func == (lhs: PhotoOrder, rhs: PhotoOrder) -> Bool { lhs.ids == rhs.ids }
}

/// How a click on a photo changes the selection.
public enum ClickKind: Sendable, Hashable {
    /// A plain click: selects only that photo.
    case plain
    /// Shift-click: selects everything from the anchor to the photo.
    case extend
    /// Command-click: adds the photo to the selection, or takes it out.
    case toggle
}

/// The focused photo and the selection of a photo view, and how keys and clicks change them.
///
/// - The focus is the photo the keys act on and the inspector describes. It is always shown.
/// - The selection is what decisions apply to when it holds more than the focused photo.
/// - The anchor is where a Shift-extended range starts.
///
/// Pure logic over a `PhotoOrder`, so it is tested without a view.
public struct GridSelection: Sendable, Equatable {
    public private(set) var focus: String?
    public private(set) var anchor: String?
    public private(set) var selected: Set<String>

    public init(focus: String? = nil, selected: Set<String>? = nil) {
        self.focus = focus
        anchor = focus
        self.selected = selected ?? (focus.map { [$0] } ?? [])
    }

    /// The photos a decision applies to, in view order: the selection when it holds more than one
    /// photo, else the focused photo.
    public func targets(in order: PhotoOrder) -> [String] {
        if selected.count > 1 {
            return selected.compactMap { id in order.position(of: id).map { (id, $0) } }
                .sorted { $0.1 < $1.1 }
                .map(\.0)
        }
        if let focus, order.contains(focus) { return [focus] }
        if let only = selected.first, order.contains(only) { return [only] }
        return []
    }

    /// Focuses a photo and selects only it.
    public mutating func select(_ id: String?) {
        focus = id
        anchor = id
        selected = id.map { [$0] } ?? []
    }

    /// Focuses a photo; with `extend`, selects the range from the anchor to it, else selects
    /// only it.
    public mutating func focus(on id: String, extend: Bool, in order: PhotoOrder) {
        guard extend, let anchor, let from = order.position(of: anchor), let to = order.position(of: id) else {
            select(id)
            return
        }
        focus = id
        selected = Set(order.ids[min(from, to)...max(from, to)])
    }

    /// A click on a photo.
    public mutating func click(_ id: String, kind: ClickKind, in order: PhotoOrder) {
        switch kind {
        case .plain:
            select(id)
        case .extend:
            if anchor == nil || !order.contains(anchor!) { anchor = focus }
            focus(on: id, extend: true, in: order)
        case .toggle:
            if selected.contains(id) {
                selected.remove(id)
                if focus == id {
                    // The focus stays on the photo just clicked, unselected, as in the Finder.
                    anchor = id
                }
            } else {
                selected.insert(id)
                focus = id
                anchor = id
            }
        }
    }

    /// Moves the focus by `offset` places (a row is the column count), staying inside the
    /// order. Without a focus, the first photo (moving forward) or the last is focused.
    public mutating func move(by offset: Int, extend: Bool, in order: PhotoOrder) {
        guard !order.isEmpty else { return }
        guard let focus, let position = order.position(of: focus) else {
            select(offset >= 0 ? order.ids.first : order.ids.last)
            return
        }
        let target = min(max(position + offset, 0), order.count - 1)
        if target == position && !extend {
            // Nowhere to go; a plain arrow still collapses a multiple selection to the focus.
            select(focus)
            return
        }
        self.focus(on: order.ids[target], extend: extend, in: order)
    }

    /// Moves the focus to a position, such as the first or last photo.
    public mutating func move(to position: Int, extend: Bool, in order: PhotoOrder) {
        guard !order.isEmpty else { return }
        let target = min(max(position, 0), order.count - 1)
        focus(on: order.ids[target], extend: extend, in: order)
    }

    /// Selects every photo, keeping the focus (or focusing the first photo).
    public mutating func selectAll(in order: PhotoOrder) {
        guard !order.isEmpty else { return }
        selected = Set(order.ids)
        if focus == nil || !order.contains(focus!) { focus = order.ids.first }
        anchor = order.ids.first
    }

    /// Selects nothing more than the focused photo.
    public mutating func deselectAll() {
        selected = focus.map { [$0] } ?? []
        anchor = focus
    }

    /// Drops photos the view no longer shows. A focus that left is replaced by `fallback` when the
    /// view shows it, else by the first photo, and then selected alone.
    public mutating func prune(to order: PhotoOrder, fallback: String? = nil) {
        selected = selected.filter { order.contains($0) }
        if let anchor, !order.contains(anchor) { self.anchor = nil }
        if let focus, order.contains(focus) {
            if anchor == nil { anchor = focus }
            return
        }
        let next = fallback.flatMap { order.contains($0) ? $0 : nil } ?? order.ids.first
        if selected.isEmpty || focus != nil {
            select(next)
        } else {
            focus = next
        }
    }
}
