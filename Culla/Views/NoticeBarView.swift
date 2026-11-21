import CullaCommands
import CullaSession
import SwiftUI

/// The notices that stay until dealt with, docked at the top of the photo area so they never
/// cover a photo: the shoot cannot be reached, Culla quit while applying, an undo under way, the
/// result of an apply or an undo, and the analysis summary (in the grid only).
/// The width the notice bar is laid out at, set by the photo area. The hosting view sizes itself
/// from the bar's ideal size, which is measured without a width; with this the ideal size is the
/// size at the real width, so wrapped words and actions moved under them get their height and
/// a wide notice never widens the window.
@MainActor
@Observable
final class NoticeBarWidth {
    var value: CGFloat = 0
}

struct NoticeBarView: View {
    let model: SessionModel
    var width = NoticeBarWidth()

    var body: some View {
        let apply = model.apply!
        VStack(spacing: 0) {
            if model.folderMissing {
                NoticeCard(tint: Palette.flaggedColor, symbol: "externaldrive.badge.xmark") {
                    Text(ApplyText.disconnected(shootName: model.name))
                        .fixedSize(horizontal: false, vertical: true)
                } actions: { EmptyView() }
            }
            if let run = apply.run, run.kind == .undo {
                NoticeCard(tint: Color.secondary, symbol: "arrow.uturn.backward.circle") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(localized("progress.title", default: "\(run.title)…")).fontWeight(.semibold)
                        ProgressView(value: run.fraction).frame(maxWidth: 360)
                        Text(localized("\(run.done) of \(run.total) changes taken back")).foregroundStyle(.secondary).monospacedDigit()
                    }
                } actions: { EmptyView() }
            }
            switch apply.banner {
            case .recovery(let title, let done, let total):
                NoticeCard(tint: Palette.flaggedColor, symbol: "exclamationmark.arrow.circlepath") {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(localized("Culla quit while applying “\(title)”. Undo what was done?")).fontWeight(.semibold)
                        Text(localized("\(done) of \(total) changes had been made when it stopped. Undo puts those files and sidecars back; nothing else is touched."))
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                } actions: {
                    Button(localized("Undo What Was Done")) { apply.undoRecovered() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!apply.canUndoApply)
                    Button(localized("Keep as Is")) { apply.dismissBanner() }
                        .help(localized("The changes stay. Undo Apply in the Edit menu can still take them back."))
                }
            case .result(let info):
                ResultCard(model: model, apply: apply, info: info)
            case .undo(let info):
                NoticeCard(tint: info.isWarning ? Palette.flaggedColor : Palette.keptColor, symbol: info.isWarning ? "exclamationmark.triangle.fill" : "arrow.uturn.backward.circle.fill") {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(info.headline).fontWeight(.semibold)
                        LinesList(lines: info.lines)
                    }
                } actions: {
                    if info.canRetry, apply.canUndoApply {
                        Button(localized("Try Undo Again")) { apply.undoLatest() }
                    }
                    Button(localized("Done")) { apply.dismissBanner() }
                        .buttonStyle(.borderedProminent)
                }
            case .error(let text):
                NoticeCard(tint: Palette.flaggedColor, symbol: "exclamationmark.triangle.fill") {
                    Text(text).fixedSize(horizontal: false, vertical: true)
                } actions: {
                    Button(localized("OK")) { apply.dismissBanner() }
                }
            case nil:
                EmptyView()
            }
            if let summary = model.summaryBanner, model.viewMode == .grid, !apply.isOpen {
                NoticeCard(tint: Palette.flaggedColor, symbol: "sparkles") {
                    HStack(spacing: 8) {
                        Text(localized("Analysis finished")).fontWeight(.semibold)
                        Text(AnalysisText.summary(summary)).foregroundStyle(.secondary).monospacedDigit()
                    }
                } actions: {
                    if model.isEnabled(.startReviewing) {
                        Button(localized("Start Reviewing")) { model.startReviewing() }
                            .buttonStyle(.borderedProminent)
                            .help(localized("Open the first group with photos to review (\(model.keyName(.startReviewing)))"))
                    }
                    Button {
                        model.dismissSummary()
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(localized("Dismiss"))
                }
            }
        }
        .font(.callout)
        .controlSize(.small)
        .environment(width)
    }
}

/// After Apply or Copy Keepers: what happened in numbers, and the next steps.
private struct ResultCard: View {
    let model: SessionModel
    let apply: ApplyCoordinator
    let info: ApplyResultInfo

    var body: some View {
        NoticeCard(tint: info.isProblem ? Palette.flaggedColor : Palette.keptColor, symbol: info.isProblem ? "exclamationmark.triangle.fill" : "checkmark.circle.fill") {
            VStack(alignment: .leading, spacing: 3) {
                Text(info.headline).fontWeight(.semibold)
                LinesList(lines: info.details)
                if !info.skippedSidecars.isEmpty {
                    LinesList(lines: Array(info.skippedSidecars.prefix(5)).map { "  " + $0 } + (info.skippedSidecars.count > 5 ? ["  " + localized("and \(info.skippedSidecars.count - 5) more")] : []))
                }
                if info.isProblem, apply.undoable?.id == info.runID {
                    Text(localized("Undo takes back the part that ran, so you can start again.")).foregroundStyle(.secondary)
                }
            }
        } actions: {
            let canUndo = apply.undoable?.id == info.runID && apply.canUndoApply
            if info.isProblem {
                if canUndo {
                    Button(localized("Undo What Was Done")) { apply.undoLatest() }.buttonStyle(.borderedProminent)
                }
                Button(localized("Done")) { apply.dismissBanner() }
            } else {
                if canUndo {
                    Button(localized("banner.undo", default: "Undo")) { apply.undoLatest() }
                        .help(localized("Put everything back as it was (\(model.keyName(.undoApply)))"))
                }
                Button(localized("Reveal Keepers in Finder")) { apply.revealKeepers(info) }
                if let editor = apply.editorName {
                    Menu(localized("Open Keepers in \(editor)")) {
                        Button(localized("Choose Another Application…")) { apply.chooseEditor() }
                    } primaryAction: {
                        apply.openKeepers(info)
                    }
                    .fixedSize()
                } else {
                    Button(localized("Open Keepers In…")) { apply.openKeepers(info) }
                        .help(localized("Choose an application, such as Photomator. Culla remembers it."))
                }
                Button(localized("Done")) { apply.dismissBanner() }.buttonStyle(.borderedProminent)
            }
        }
    }
}

private struct LinesList: View {
    let lines: [String]

    var body: some View {
        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
            Text(line).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One docked notice: a coloured edge and icon carrying its meaning, the words, the actions.
private struct NoticeCard<Content: View, Actions: View>: View {
    let tint: Color
    let symbol: String
    @ViewBuilder let content: Content
    @ViewBuilder let actions: Actions
    @Environment(NoticeBarWidth.self) private var barWidth: NoticeBarWidth?

    init(tint: Color, symbol: String, @ViewBuilder content: () -> Content, @ViewBuilder actions: () -> Actions) {
        self.tint = tint
        self.symbol = symbol
        self.content = content()
        self.actions = actions()
    }

    var body: some View {
        // The actions sit beside the words while the words keep a readable width, else under
        // them: buttons are never cut.
        // The card's own horizontal padding (14 each side) is not the layout's to fill.
        NoticeCardLayout(availableWidth: barWidth.map { $0.value > 0 ? $0.value - 28 : nil } ?? nil) {
            icon
            content
            HStack(spacing: 8) { actions }.fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Palette.panelBackgroundColor)
        .overlay(alignment: .leading) { Rectangle().fill(tint).frame(width: 3) }
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.separatorColor).frame(height: 1) }
    }

    private var icon: some View {
        Image(systemName: symbol)
            .font(.system(size: 16))
            .foregroundStyle(tint)
            .frame(width: 20)
    }
}

/// Lays out a notice: icon, words, actions in one row while the words keep at least
/// `minimumTextWidth`; otherwise the actions go on a row of their own under the words, at the
/// trailing edge. A layout rather than `ViewThatFits`, so the height the hosting view asks for
/// is the height of the arrangement actually drawn at that width.
private struct NoticeCardLayout: Layout {
    /// The width to lay out at when the proposal has none (the hosting view's ideal size).
    var availableWidth: CGFloat?
    var spacing: CGFloat = 12
    var rowSpacing: CGFloat = 8
    var minimumTextWidth: CGFloat = 240

    private struct Arrangement {
        var stacked: Bool
        var textWidth: CGFloat
        var size: CGSize
    }

    private func arrange(_ proposed: CGFloat?, _ subviews: Subviews) -> Arrangement {
        let width = proposed ?? availableWidth
        guard subviews.count == 3 else { return Arrangement(stacked: false, textWidth: 0, size: .zero) }
        let icon = subviews[0].sizeThatFits(.unspecified)
        let actions = subviews[2].sizeThatFits(.unspecified)
        let idealText = subviews[1].sizeThatFits(.unspecified)
        let total = width ?? (icon.width + spacing + idealText.width + spacing + actions.width)
        let besideWidth = total - icon.width - spacing - spacing - actions.width
        if besideWidth >= minimumTextWidth || width == nil {
            let textWidth = max(0, besideWidth)
            let text = subviews[1].sizeThatFits(ProposedViewSize(width: textWidth, height: nil))
            return Arrangement(stacked: false, textWidth: textWidth, size: CGSize(width: total, height: max(icon.height, text.height, actions.height)))
        }
        let textWidth = max(0, total - icon.width - spacing)
        let text = subviews[1].sizeThatFits(ProposedViewSize(width: textWidth, height: nil))
        let top = max(icon.height, text.height)
        return Arrangement(stacked: true, textWidth: textWidth, size: CGSize(width: total, height: top + rowSpacing + actions.height))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal.width, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let arrangement = arrange(bounds.width, subviews)
        let icon = subviews[0].sizeThatFits(.unspecified)
        let text = subviews[1].sizeThatFits(ProposedViewSize(width: arrangement.textWidth, height: nil))
        if arrangement.stacked {
            let top = max(icon.height, text.height)
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY + top / 2), anchor: .leading, proposal: .unspecified)
            subviews[1].place(at: CGPoint(x: bounds.minX + icon.width + spacing, y: bounds.minY + (top - text.height) / 2),
                              proposal: ProposedViewSize(width: arrangement.textWidth, height: text.height))
            subviews[2].place(at: CGPoint(x: bounds.maxX, y: bounds.minY + top + rowSpacing), anchor: .topTrailing, proposal: .unspecified)
        } else {
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: .unspecified)
            subviews[1].place(at: CGPoint(x: bounds.minX + icon.width + spacing, y: bounds.midY), anchor: .leading,
                              proposal: ProposedViewSize(width: arrangement.textWidth, height: text.height))
            subviews[2].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: .unspecified)
        }
    }
}
