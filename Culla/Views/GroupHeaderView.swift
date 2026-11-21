import CullaCommands
import CullaSession
import SwiftUI

/// The bar along the top of the photo area: which group is open and how much of it is left,
/// whether analysis may still add to it, and the group's own actions: ⇧X for the Certain photos
/// of a defect group, and the slider button that opens the tuning panel.
struct GroupHeaderView: View {
    let model: SessionModel
    /// Opens or closes the tuning panel; the photo area anchors the popover to this bar.
    var toggleTuning: () -> Void = {}
    /// Reports where the slider button is, in the bar's coordinates (origin top left), so the
    /// popover points at it.
    var tuningButtonMoved: (CGRect) -> Void = { _ in }

    static let height: CGFloat = 32

    var body: some View {
        let group = model.group
        let session = model.session
        let count = session.count(of: group)
        HStack(spacing: 10) {
            Image(systemName: SidebarView.icon(for: group))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(group.title)
                .font(.system(size: 13, weight: .semibold))
                .fixedSize()
            Text(countText(group, count))
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
            // The slider button sits beside the group's name: it adjusts this group, and its
            // popover then opens over the photos rather than past the window's edge.
            if group.hasTuning {
                Button(action: toggleTuning) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12))
                        .foregroundStyle(model.tuningPanelGroup == group ? Color.accentColor : .secondary)
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(shortcut(.showTuning).map { localized("Adjust how \(group.title) is detected (\($0))") }
                      ?? localized("Adjust how \(group.title) is detected"))
                .accessibilityLabel(Text(localized("Adjust detection for \(group.title)")))
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("groupHeader")) } action: { tuningButtonMoved($0) }
            }
            if group.needsAnalysis, let analysis = model.analysis, analysis.isRunning || analysis.isPaused {
                StillAnalysingNote(analysis: analysis)
            }
            Spacer(minLength: 8)
            if group.isDefectGroup, group.canBeCertain {
                let certain = session.undecidedCertainMembers(of: group).count
                if certain > 0 {
                    Button {
                        model.perform(.rejectCertain)
                    } label: {
                        Label(localized("Reject \(certain) Certain…"), systemImage: "xmark.circle")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                    // Never cut: the count line beside the name gives way first.
                    .fixedSize()
                    .layoutPriority(1)
                    .help(shortcut(.rejectCertain).map { localized("Reject every undecided photo flagged Certain in \(group.title) (\($0))") }
                          ?? localized("Reject every undecided photo flagged Certain in \(group.title)"))
                }
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .coordinateSpace(.named("groupHeader"))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.panelBackgroundColor)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.separatorColor).frame(height: 1)
        }
    }

    private func shortcut(_ command: Command) -> String? {
        model.settings.keyBindings.primaryChord(for: command)?.displayString
    }

    private func countText(_ group: GroupID, _ count: GroupCount) -> String {
        if count.total == 0 { return "" }
        let session = model.session
        // Stacks and duplicate sets are counted as stacks and sets, as their review screens go.
        if group == .similarStacks || group == .duplicates {
            let sets = group == .similarStacks ? session.stackCounts : session.duplicateSetCounts()
            let stacks = group == .similarStacks
            let progress = switch (stacks, sets.left == 0) {
            case (true, true): localized("All \(sets.total) stacks decided")
            case (true, false): localized("\(sets.left) of \(sets.total) stacks left")
            case (false, true): localized("All \(sets.total) sets decided")
            case (false, false): localized("\(sets.left) of \(sets.total) sets left")
            }
            return localized("header.progressAndPhotos", default: "\(progress) · \(Formatting.photos(count.total))")
        }
        if !group.showsLeftCount { return Formatting.photos(count.total) }
        if count.left == 0 { return localized("All \(count.total) decided") }
        if count.left == count.total { return localized("\(count.total) photos to review") }
        return localized("\(count.left) left of \(count.total)")
    }
}

/// "Still analysing": the group may grow while analysis runs.
struct StillAnalysingNote: View {
    let analysis: AnalysisController

    var body: some View {
        HStack(spacing: 5) {
            if analysis.isPaused {
                Image(systemName: "pause.circle").font(.system(size: 11))
            } else {
                ProgressRing(fraction: analysis.checkedFraction)
                    .frame(width: 11, height: 11)
            }
            Text(analysis.isPaused ? localized("Analysis paused") : localized("Still analysing · may grow"))
                .font(.system(size: 11))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.white.opacity(0.06)))
        .fixedSize()
        .help(localized("Culla is still analysing this shoot, so more photos may join this group."))
    }
}

/// A small determinate ring for analysis progress. Static, so it never animates.
struct ProgressRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.18), lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(0.02, min(1, fraction)))
                .stroke(Color.secondary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .accessibilityHidden(true)
    }
}
