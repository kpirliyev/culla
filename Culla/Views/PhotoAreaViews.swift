import CullaAnalysis
import CullaCommands
import CullaSession
import SwiftUI

/// What the photo area says when the current group has nothing in it: one line saying why
/// (nothing analysed yet, still analysing, none found, everything decided), and a useful next step.
struct EmptyGroupView: View {
    let model: SessionModel

    var body: some View {
        let group = model.group
        let reason = model.emptyReason
        VStack(spacing: 12) {
            Image(systemName: reason == .noPhotos ? "photo.on.rectangle.angled" : icon(group, reason))
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 2)
            Text(title(group, reason))
                .font(.title3.weight(.semibold))
            if let detail = detail(group, reason) {
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            switch reason {
            case .noPhotos:
                Button(localized("Open Another Folder…")) { model.requestOpenFolder?() }
                    .controlSize(.large)
                    .padding(.top, 6)
            case .stillAnalysing(let done, let total):
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                    .frame(width: 220)
                    .padding(.top, 2)
                    .accessibilityLabel(Text(localized("Analysis progress")))
                nextButton
            case .analysisPaused, .notAnalysedYet:
                if let analysis = model.analysis, analysis.isPaused {
                    Button(localized("emptyGroup.resumeAnalysis", default: "Resume Analysis")) { analysis.resume() }
                        .controlSize(.large)
                        .padding(.top, 6)
                } else {
                    nextButton
                }
            default:
                nextButton
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 440)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.gridBackgroundColor)
    }

    @ViewBuilder private var nextButton: some View {
        if let next = nextGroup {
            Button(localized("emptyGroup.showGroup", default: "Show \(next.title)")) { model.selectGroup(next) }
                .controlSize(.large)
                .padding(.top, 6)
                .keyboardShortcut(.defaultAction)
        }
    }

    private func icon(_ group: GroupID, _ reason: EmptyReason) -> String {
        switch reason {
        case .stillAnalysing: "hourglass"
        case .analysisPaused: "pause.circle"
        case .allDecided: "checkmark.circle"
        default: SidebarView.icon(for: group)
        }
    }

    private func title(_ group: GroupID, _ reason: EmptyReason) -> String {
        switch reason {
        case .noPhotos: localized("No photos in this folder")
        case .notAnalysedYet: localized("emptyGroup.notAnalysedYet", default: "Not analysed yet")
        case .stillAnalysing: group.noneFoundYetMessage
        case .analysisPaused: group.noneFoundSoFarMessage
        case .noneFound, .allDecided, .nothingYet: group.emptyMessage
        }
    }

    private func detail(_ group: GroupID, _ reason: EmptyReason) -> String? {
        switch reason {
        case .noPhotos:
            return localized("Culla looks for JPEG, HEIC and RAW files, in subfolders too.")
        case .notAnalysedYet:
            return group.findsAfterAnalysisMessage
        case .stillAnalysing(let done, let total):
            return localized("Culla is still analysing: \(done) of \(total) photos checked. Photos appear here as they are found.")
        case .analysisPaused(let done, let total):
            return localized("Analysis is paused after \(done) of \(total) photos.")
        case .noneFound(let checked):
            return localized("Culla checked all \(checked) photos.")
        case .allDecided:
            return localized("Every photo is kept or rejected. Any decision can still be changed.")
        case .nothingYet:
            return nil
        }
    }

    /// The next group with something left to review, else the next with any photos.
    private var nextGroup: GroupID? {
        let session = model.session
        if let next = model.nextGroupToReview { return next }
        let others = GroupID.allCases.filter { $0 != model.group && $0 != .allPhotos }
        let after = others.filter { (GroupID.allCases.firstIndex(of: $0) ?? 0) > (GroupID.allCases.firstIndex(of: model.group) ?? 0) }
        if let any = (after + others).first(where: { session.count(of: $0).total > 0 }) { return any }
        return model.group == .allPhotos ? nil : .allPhotos
    }
}

/// Short notes along the bottom of the photo area: photos added or removed since last time, a
/// group just finished, a notice that goes away by itself. Notices that stay until dealt with are
/// docked at the top instead (`NoticeBarView`), so they never cover a photo.
struct PhotoAreaBanner: View {
    let model: SessionModel

    var body: some View {
        VStack(spacing: 8) {
            if let completed = model.completedGroup, completed == model.group {
                CompletionNote(model: model, group: completed)
            }
            if let notice = model.notice {
                HStack(spacing: 8) {
                    Image(systemName: notice.symbol).foregroundStyle(.secondary)
                    Text(notice.text)
                }
                .modifier(BannerStyle())
                .id(notice.id)
            }
            if let merge = model.mergeResult {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles").foregroundStyle(.secondary)
                    Text(Self.mergeText(merge))
                    Button {
                        model.dismissMergeNote()
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(localized("banner.dismiss", default: "Dismiss"))
                }
                .modifier(BannerStyle())
            }
        }
        .font(.callout)
    }

    static func mergeText(_ merge: MergeResult) -> String {
        var parts: [String] = []
        if !merge.added.isEmpty {
            parts.append(localized("\(merge.added.count) new photos since last time"))
        }
        if !merge.removed.isEmpty {
            parts.append(localized("\(merge.removed.count) photos no longer in the folder"))
        }
        if !merge.modified.isEmpty, parts.isEmpty {
            parts.append(localized("\(merge.modified.count) photos changed on disk"))
        }
        return parts.joined(separator: " · ")
    }
}

/// "Every photo in Blurry has a decision", with the next group to review.
private struct CompletionNote: View {
    let model: SessionModel
    let group: GroupID

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.keptColor)
            Text(localized("Every photo in \(group.title) has a decision."))
            if let next = model.nextGroupToReview {
                let left = model.session.count(of: next).left
                Button(localized("Next: \(next.title) (\(left) left)")) {
                    model.openNextGroupToReview()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            DismissButton { model.dismissCompletion() }
        }
        .modifier(BannerStyle())
    }
}

private struct DismissButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel(localized("banner.dismiss", default: "Dismiss"))
    }
}

private struct BannerStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color(white: 0.2)))
            .overlay(Capsule().strokeBorder(Color.black.opacity(0.4)))
            .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
    }
}
