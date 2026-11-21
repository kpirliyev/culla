import CullaCommands
import CullaSession
import AppKit
import SwiftUI

/// The groups, in the order Culla recommends clearing them, each with how many photos are left
/// to review. Groups with nothing in them are dimmed but can still be opened.
struct SidebarView: View {
    let model: SessionModel

    private static let analysisGroups: [GroupID] = [.duplicates, .similarStacks, .eyesClosed, .blurry, .exposure, .otherIssues]
    private static let decisionGroups: [GroupID] = [.unreviewed, .kept, .rejected]

    var body: some View {
        let session = model.session
        let current = model.group
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                GroupRow(group: .allPhotos, count: session.count(of: .allPhotos), isCurrent: current == .allPhotos) {
                    model.selectGroup(.allPhotos)
                }
                SectionHeader(title: localized("sidebar.foundByCulla", default: "Found by Culla"), analysis: model.analysis)
                ForEach(Self.analysisGroups) { group in
                    GroupRow(group: group, count: session.count(of: group), isCurrent: current == group) {
                        model.selectGroup(group)
                    }
                }
                SectionHeader(title: localized("sidebar.decisions", default: "Decisions"))
                ForEach(Self.decisionGroups) { group in
                    GroupRow(group: group, count: session.count(of: group), isCurrent: current == group) {
                        model.selectGroup(group)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 12)
        }
        .scrollIndicators(.never)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.panelBackgroundColor)
        .accessibilityLabel(localized("sidebar.accessibilityLabel", default: "Groups"))
    }

    /// The width the sidebar needs so no group name is cut, in the language of the interface:
    /// the widest row (icon, name in the current-row weight, count as wide as this shoot's
    /// largest) or section header, with the rows' padding.
    static func naturalWidth(photoCount: Int) -> CGFloat {
        let nameFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let countFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let total = Formatting.count(max(photoCount, 1))
        let pair = width("\(total) / \(total)", countFont)
        let single = width(total, countFont)
        let rows = ([.allPhotos] + analysisGroups + decisionGroups).map { group in
            width(group.title, nameFont) + (group.showsLeftCount ? pair : single)
        }
        // Everything else in a row: the list's and the row's padding, the icon, the spacing,
        // the button's insets (measured: English fits 220 points exactly).
        let row = (rows.max() ?? 0) + 89
        let headerFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let statusFont = NSFont.systemFont(ofSize: 10, weight: .medium)
        let status = max(width(localized("sidebar.paused", default: "Paused"), statusFont),
                         width(localized("sidebar.analysing", default: "Analysing"), statusFont))
        let header = width(localized("sidebar.foundByCulla", default: "Found by Culla"), headerFont) + 4 + 9 + 4 + status + 50
        return max(row, header).rounded(.up)
    }

    private static func width(_ text: String, _ font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    static func icon(for group: GroupID) -> String {
        switch group {
        case .allPhotos: "photo.on.rectangle"
        case .duplicates: "plus.square.on.square"
        case .similarStacks: "square.stack.3d.up"
        case .eyesClosed: "eye.slash"
        case .blurry: "camera.metering.unknown"
        case .exposure: "sun.max"
        case .otherIssues: "exclamationmark.triangle"
        case .unreviewed: "circle.dashed"
        case .kept: "checkmark.circle"
        case .rejected: "xmark.circle"
        }
    }

    /// Kept and Rejected carry their meaning's colour beside their icon; everything else is neutral.
    static func iconTint(for group: GroupID) -> Color? {
        switch group {
        case .kept: Palette.keptColor
        case .rejected: Palette.rejectedColor
        default: nil
        }
    }
}

/// A section's title. Over the groups analysis finds, it also says while analysis is still
/// running, so a count that is still rising reads as "not final yet".
private struct SectionHeader: View {
    let title: String
    var analysis: AnalysisController?

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 4)
            if let analysis, analysis.isRunning || analysis.isPaused {
                HStack(spacing: 4) {
                    if analysis.isPaused {
                        Image(systemName: "pause.circle")
                    } else {
                        ProgressRing(fraction: analysis.checkedFraction).frame(width: 9, height: 9)
                    }
                    Text(analysis.isPaused ? localized("sidebar.paused", default: "Paused") : localized("sidebar.analysing", default: "Analysing"))
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .help(localized("Counts can still rise while Culla analyses the shoot."))
                .accessibilityElement(children: .combine)
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }
}

private struct GroupRow: View {
    let group: GroupID
    let count: GroupCount
    let isCurrent: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        let isEmpty = count.total == 0
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: SidebarView.icon(for: group))
                    .font(.system(size: 13))
                    .frame(width: 18)
                    .foregroundStyle(iconStyle(isEmpty: isEmpty))
                Text(group.title)
                    .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                    .lineLimit(1)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.white) : AnyShapeStyle(isEmpty ? .tertiary : .primary))
                Spacer(minLength: 6)
                Text(countText)
                    .font(.system(size: 12))
                    .monospacedDigit()
                    // Counts never truncate; a long group name gives way first.
                    .fixedSize()
                    .layoutPriority(1)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(Color.white.opacity(0.85)) : AnyShapeStyle(isEmpty ? .quaternary : .secondary))
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isCurrent ? Color.accentColor : (isHovered ? Color.white.opacity(0.06) : .clear))
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(Text(accessibilityText))
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    private func iconStyle(isEmpty: Bool) -> AnyShapeStyle {
        if isCurrent { return AnyShapeStyle(.white) }
        if let tint = SidebarView.iconTint(for: group), !isEmpty { return AnyShapeStyle(tint) }
        return AnyShapeStyle(isEmpty ? .tertiary : .secondary)
    }

    private var countText: String {
        if group.showsLeftCount {
            return "\(Formatting.count(count.left)) / \(Formatting.count(count.total))"
        }
        return Formatting.count(count.total)
    }

    private var accessibilityText: String {
        if group.showsLeftCount {
            return localized("\(group.title), \(count.left) of \(count.total) left to review")
        }
        return localized("\(group.title), \(count.total) photos")
    }
}
