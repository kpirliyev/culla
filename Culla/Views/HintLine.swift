import SwiftUI

/// A line of key hints, such as "↩ accept · P keep · X reject · ←→ frame".
///
/// The rule for every hint line (stack review, compare, duplicate review, Review and Apply):
/// hints are listed most important first and are never cut. When the line is narrower than all
/// of them, whole hints drop from the end until the rest fits; with no room for even the first,
/// the line is left empty.
/// The full line stays the tooltip and what VoiceOver reads, so nothing is lost for good.
struct HintLine: View {
    let hints: [String]

    /// The hints of a line joined by " · " (`KeyText.hintLine`).
    init(_ line: String) {
        hints = line.components(separatedBy: " · ").filter { !$0.isEmpty }
    }

    var body: some View {
        let full = hints.joined(separator: " · ")
        ViewThatFits(in: .horizontal) {
            ForEach(Array(stride(from: hints.count, through: 1, by: -1)), id: \.self) { count in
                Text(verbatim: hints.prefix(count).joined(separator: " · "))
                    .lineLimit(1)
                    .fixedSize()
            }
            // Narrower than even the first hint: none shows rather than a cut one.
            Color.clear.frame(width: 0, height: 0)
        }
        .help(full)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: full))
    }
}

/// The same rule for hints laid out as separate views (Review and Apply's key line): whole
/// items drop from the end when the row is too narrow.
struct DroppingRow<Item, Content: View>: View {
    let items: [Item]
    var spacing: CGFloat = 16
    @ViewBuilder let content: (Item) -> Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(Array(stride(from: items.count, through: 1, by: -1)), id: \.self) { count in
                HStack(spacing: spacing) {
                    ForEach(0..<count, id: \.self) { index in content(items[index]) }
                }
                .fixedSize()
            }
            Color.clear.frame(width: 0, height: 0)
        }
    }
}
