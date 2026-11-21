import CullaSession
import SwiftUI

/// The bottom line of the shoot window: how much is kept, rejected and left, unreadable files,
/// and what is selected.
struct StatusBarView: View {
    let model: SessionModel

    var body: some View {
        let totals = model.session.totals
        HStack(spacing: 14) {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.keptColor)
                Text(localized("status.kept", default: "\(totals.kept) kept"))
            }
            HStack(spacing: 5) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.rejectedColor)
                Text(localized("status.rejected", default: "\(totals.rejected) rejected"))
            }
            HStack(spacing: 5) {
                Image(systemName: "circle.dashed").foregroundStyle(.secondary)
                Text(localized("status.left", default: "\(totals.left) left"))
            }
            if totals.unreadable > 0 {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.flaggedColor)
                    Text(localized("status.unreadable", default: "\(totals.unreadable) unreadable"))
                }
                .help(localized("Files Culla can’t read are left out of every group and never moved."))
            }
            if let error = model.saver.lastError.map(Formatting.embedded) {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(Palette.rejectedColor)
                    Text(localized("Decisions not saved"))
                }
                .help(localized("\(error). Culla keeps trying with every change; your decisions stay on screen. Check that the startup disk has free space."))
            }
            Spacer(minLength: 12)
            Text(selectionText)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: 12))
        .monospacedDigit()
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.panelBackgroundColor)
        .overlay(alignment: .top) {
            Rectangle().fill(Palette.separatorColor).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private var selectionText: String {
        let selected = model.selection.selected.count
        if selected > 1 {
            return localized("status.selected", default: "\(selected) selected")
        }
        // With stacks collapsed, the grid shows tiles, not photos: count what is on screen, and
        // say how many photos a stack's tile holds.
        _ = model.orderRevision
        let tiles = model.viewMode == .grid && model.gridEntries != nil
        let order = tiles ? model.gridOrder : model.order
        guard let focus = model.focus, let photo = model.session.photo(focus) else {
            return model.order.isEmpty ? "" : Formatting.photos(model.order.count)
        }
        guard let position = order.position(of: focus) else { return photo.file.name }
        let place = tiles
            ? localized("status.positionOfTiles", default: "\(position + 1) of \(order.count) tiles")
            : localized("status.position", default: "\(position + 1) of \(order.count)")
        if tiles, let stack = model.collapsedStacks[focus] {
            return localized("status.stackTile", default: "\(photo.file.name) · stack of \(stack.frameCount) · \(place)")
        }
        return "\(photo.file.name) · \(place)"
    }
}
