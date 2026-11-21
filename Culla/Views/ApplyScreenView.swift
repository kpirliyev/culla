import AppKit
import CullaCommands
import CullaCore
import CullaFiles
import CullaSession
import SwiftUI

/// Review and Apply: the one place where decisions become changes on disk.
///
/// On the left, the summary and every reject under its reason, most severe first; on the right,
/// what will happen, as an explicit choice with its consequences spelled out, and one button that
/// says exactly what it does. Nothing moves until that button (or ⇧⌘Return) is used.
struct ApplyScreenView: View {
    let model: SessionModel

    var body: some View {
        let apply = model.apply!
        ZStack {
            HStack(spacing: 0) {
                RejectListColumn(model: model, apply: apply)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Rectangle().fill(Palette.separatorColor).frame(width: 1)
                ActionPanel(model: model, apply: apply)
                    .frame(width: 372)
                    .frame(maxHeight: .infinity)
                    .background(Palette.panelBackgroundColor)
            }
            if apply.peekID != nil {
                PeekView(model: model, apply: apply)
                    .transition(.opacity)
            }
            if let run = apply.run, run.kind == .apply {
                RunProgressOverlay(run: run, cancel: { apply.cancelRun() }, cancelKey: model.keyName(.back))
            }
        }
        .background(Palette.windowBackgroundColor)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(localized("Review and Apply"))
    }
}

// MARK: - The rejects

private struct RejectListColumn: View {
    let model: SessionModel
    let apply: ApplyCoordinator

    static let tile: CGFloat = 132
    static let spacing: CGFloat = 12
    static let inset: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SummaryHeader(model: model, apply: apply)
                .padding(.horizontal, Self.inset)
                .padding(.top, 18)
                .padding(.bottom, 14)
            Rectangle().fill(Palette.separatorColor).frame(height: 1)
            if apply.isPreparing {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(localized("Reading the folder…")).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if apply.rejectOrder.isEmpty {
                NoRejectsView(rescued: apply.rescuedThisVisit, undoKey: model.keyName(.undo))
            } else {
                list
            }
            KeyHints(model: model)
        }
        .background(Palette.gridBackgroundColor)
    }

    private var list: some View {
        GeometryReader { geometry in
            let columns = max(1, Int((geometry.size.width - Self.inset * 2 + Self.spacing) / (Self.tile + Self.spacing)))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6, pinnedViews: [.sectionHeaders]) {
                        ForEach(apply.plan?.rejectGroups ?? []) { group in
                            Section {
                                LazyVGrid(columns: Array(repeating: GridItem(.fixed(Self.tile), spacing: Self.spacing, alignment: .top), count: columns), alignment: .leading, spacing: 14) {
                                    ForEach(group.photoIDs, id: \.self) { id in
                                        RejectTile(model: model, apply: apply, id: id)
                                            .id(id)
                                    }
                                }
                                .padding(.horizontal, Self.inset)
                                .padding(.bottom, 14)
                            } header: {
                                ReasonHeader(group: group)
                            }
                        }
                    }
                    .padding(.bottom, 12)
                }
                .onAppear { apply.columns = columns }
                .onChange(of: columns) { _, value in apply.columns = value }
                .onChange(of: apply.scrollRevision) { _, _ in
                    if let focus = apply.listSelection.focus { proxy.scrollTo(focus) }
                }
            }
        }
    }
}

/// The counts and what they mean, in plain words.
private struct SummaryHeader: View {
    let model: SessionModel
    let apply: ApplyCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(localized("Review and Apply")).font(.title2.weight(.semibold))
                Text(localized("quoted.name", default: "“\(model.name)”")).foregroundStyle(.secondary)
            }
            if let summary = apply.plan?.summary {
                HStack(spacing: 16) {
                    count(localized("apply.count.kept", default: "\(summary.kept) kept"), symbol: "checkmark.circle.fill", tint: Palette.keptColor)
                    count(localized("apply.count.rejected", default: "\(summary.rejected) rejected"), symbol: "xmark.circle.fill", tint: Palette.rejectedColor)
                    count(localized("apply.count.unreviewed", default: "\(summary.unreviewed) unreviewed"), symbol: "circle.dashed", tint: .secondary)
                    if summary.unreadable > 0 {
                        count(localized("apply.count.unreadable", default: "\(summary.unreadable) unreadable, never moved"), symbol: "exclamationmark.triangle.fill", tint: Palette.flaggedColor)
                    }
                }
                .font(.system(size: 13))
                .monospacedDigit()
                VStack(alignment: .leading, spacing: 3) {
                    if let space = ApplyText.rejectSpace(summary) { Text(space) }
                    if let note = ApplyText.unreviewedNote(summary, ratedWithSidecar: apply.sidecarCounts.ratedUnreviewed) { Text(note) }
                    if apply.rescuedThisVisit > 0 {
                        Text(localized("\(apply.rescuedThisVisit) photos rescued on this screen and now kept. \(model.keyName(.undo)) puts the last rescue back."))
                            .foregroundStyle(Palette.keptColor)
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(verbatim: " ").font(.system(size: 13))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func count(_ text: String, symbol: String, tint: some ShapeStyle) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ReasonHeader: View {
    let group: RejectGroup

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: Self.symbol(group.reason)).foregroundStyle(.secondary).frame(width: 18)
            Text(group.reason.title).font(.system(size: 13, weight: .semibold))
            Text(ApplyText.number(group.photoIDs.count)).foregroundStyle(.secondary).monospacedDigit()
            if group.reason == .noFlag {
                Text(localized("rejected by you, with nothing flagged")).foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .font(.system(size: 13))
        .padding(.horizontal, RejectListColumn.inset)
        .padding(.vertical, 8)
        .background(Palette.gridBackgroundColor.opacity(0.97))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    static func symbol(_ reason: RejectReason) -> String {
        switch reason {
        case .eyesClosed: "eye.slash"
        case .blurry: "camera.metering.unknown"
        case .clippedHighlights: "sun.max"
        case .clippedShadows: "moon"
        case .faceCutOff: "person.crop.rectangle"
        case .lensSmudge: "drop"
        case .tiltedHorizon: "level"
        case .utility: "hand.raised"
        case .lowAesthetics: "hand.thumbsdown"
        case .duplicate: "plus.square.on.square"
        case .similarStack: "square.stack.3d.up"
        case .noFlag: "hand.point.up.left"
        }
    }
}

/// One reject: its thumbnail and file name. Click selects (⇧ and ⌘ extend), double click looks
/// closer.
private struct RejectTile: View {
    let model: SessionModel
    let apply: ApplyCoordinator
    let id: String

    var body: some View {
        let focused = apply.listSelection.focus == id
        let selected = apply.listSelection.selected.contains(id) && apply.listSelection.selected.count > 1
        let item = model.state.photo(id)
        VStack(spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.045))
                if let item {
                    ThumbnailImage(file: item.file, cache: model.thumbnails, activity: model.activity)
                        .padding(4)
                }
            }
            .frame(width: RejectListColumn.tile, height: RejectListColumn.tile)
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(focused ? Color(white: 0.96) : (selected ? Palette.accentColor : .clear), lineWidth: focused ? 2.5 : 2)
            }
            Text(item?.file.name ?? id)
                .font(.system(size: 11))
                .foregroundStyle(focused ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: RejectListColumn.tile)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            apply.click(id, kind: .plain)
            apply.togglePeek()
        }
        .onTapGesture {
            let flags = NSEvent.modifierFlags
            apply.click(id, kind: flags.contains(.shift) ? .extend : flags.contains(.command) ? .toggle : .plain)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(localized("\(item?.file.name ?? id), rejected"))
        .accessibilityAddTraits(focused ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction(named: Text(localized("apply.rescueAction", default: "Rescue"))) {
            apply.click(id, kind: .plain)
            apply.rescue()
        }
    }
}

/// A thumbnail from the cache: at once when it is in memory, else when it arrives.
struct ThumbnailImage: View {
    let file: PhotoFile
    let cache: ThumbnailCache
    let activity: ActivityTracker
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            } else {
                Color.clear
            }
        }
        .task(id: file) {
            if let cached = cache.cachedThumbnail(for: file) {
                image = cached
                return
            }
            activity.begin(.thumbnail)
            defer { activity.end(.thumbnail) }
            image = try? await cache.thumbnail(for: file)
        }
    }
}

private struct NoRejectsView: View {
    let rescued: Int
    let undoKey: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle").font(.system(size: 40, weight: .light)).foregroundStyle(.tertiary)
            Text(localized("No rejects")).font(.title3.weight(.semibold))
            Text(rescued > 0
                ? localized("You rescued every reject on this screen. Nothing will be moved. \(undoKey) puts the last rescue back.")
                : localized("No photo is rejected, so nothing will be moved or marked as rejected."))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct KeyHints: View {
    let model: SessionModel

    var body: some View {
        let move = localized("apply.hint.move", default: "move")
        let items: [(String, String)] = [
            (KeyText.keyNames(.init(.previousPhoto, .nextPhoto, .previousRow, .nextRow, label: move, spaced: true), in: model.settings.keyBindings) ?? "", move),
            (model.keyName(.keep), localized("apply.hint.rescue", default: "rescue (keep)")),
            (model.keyName(.toggleLoupe), localized("apply.hint.lookCloser", default: "look closer")),
            (model.keyName(.undo), localized("apply.hint.undoRescue", default: "undo a rescue")),
            (model.keyName(.back), localized("apply.hint.leave", default: "leave without applying")),
        ]
        // Hints drop whole from the end when the row is too narrow (HintLine's rule).
        HStack(spacing: 0) {
            DroppingRow(items: items) { item in hint(item.0, item.1) }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, RejectListColumn.inset)
        .padding(.vertical, 8)
        .background(Palette.panelBackgroundColor)
        .overlay(alignment: .top) { Rectangle().fill(Palette.separatorColor).frame(height: 1) }
    }

    private func hint(_ key: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Text(key).font(.system(size: 11, weight: .semibold)).foregroundStyle(.primary.opacity(0.85))
            Text(text)
        }
    }
}

// MARK: - What happens

private struct ActionPanel: View {
    let model: SessionModel
    let apply: ApplyCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if apply.isReadOnly {
                        ReadOnlySection(model: model, apply: apply)
                    } else {
                        InPlaceSection(model: model, apply: apply)
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Rectangle().fill(Palette.separatorColor).frame(height: 1)
            PrimaryButtons(model: model, apply: apply)
                .padding(18)
        }
    }
}

private struct InPlaceSection: View {
    let model: SessionModel
    let apply: ApplyCoordinator

    var body: some View {
        let rejected = apply.plan?.summary.rejected ?? 0
        VStack(alignment: .leading, spacing: 14) {
            Text(rejected > 0 ? localized("What happens to the \(rejected) photos you rejected") : localized("What happens"))
                .font(.headline)
            VStack(spacing: 4) {
                ForEach(RejectAction.allCases, id: \.self) { action in
                    ActionRow(
                        action: action, selected: apply.options.rejectAction == action,
                        isDefault: model.settings.rejectAction == action
                    ) { apply.setRejectAction(action) }
                }
            }
            Toggle(isOn: Binding(get: { apply.options.writeSidecars }, set: { apply.setWriteSidecars($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(localized("Write XMP sidecars"))
                    Text(localized("A small .xmp file beside each decided or rated photo, for Lightroom, Capture One and other editors."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)
            ConsequenceBox(lines: consequences)
            if apply.differsFromDefault {
                Button(localized("Use These Choices by Default")) { apply.makeDefault() }
                    .buttonStyle(.link)
                    .font(.callout)
                    .help(localized("New applies start with this action and sidecar choice. Settings ▸ General holds them too."))
            }
        }
    }

    private var consequences: [String] {
        guard let plan = apply.plan else { return [] }
        let counts = apply.sidecarCounts
        var lines = ApplyText.consequences(
            action: apply.options.rejectAction, summary: plan.summary, writeSidecars: apply.options.writeSidecars,
            shootName: model.name, sidecarsForKept: counts.kept, sidecarsForRejected: counts.rejected,
            mapping: apply.options.sidecarMapping
        )
        if plan.isEmpty {
            if !(apply.options.rejectAction == .markOnly && plan.summary.rejected > 0) { lines.append(localized("Nothing would change on disk.")) }
        } else {
            lines.append(localized("Undo Apply takes all of it back afterwards."))
        }
        return lines
    }
}

private struct ActionRow: View {
    let action: RejectAction
    let selected: Bool
    let isDefault: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(selected ? Palette.accentColor : Color.secondary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(ApplyText.actionLabel(action)).fontWeight(selected ? .semibold : .regular)
                        if isDefault {
                            Text(localized("apply.defaultBadge", default: "Default")).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.5)))
                        }
                    }
                    Text(Self.short(action)).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(selected ? 0.07 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(ApplyText.actionLabel(action)))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    static func short(_ action: RejectAction) -> String {
        switch action {
        case .moveToRejectedFolder: localized("Rejects go into a folder inside the shoot. Easy to look through, easy to put back.")
        case .markOnly: localized("Files stay where they are; only their sidecars mark them as rejected, so sidecars must be on.")
        case .moveToTrash: localized("Rejects go to the Trash until you empty it.")
        }
    }
}

private struct ConsequenceBox: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(verbatim: "•").foregroundStyle(.secondary)
                    Text(line).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.callout)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.07)))
    }
}

private struct ReadOnlySection: View {
    let model: SessionModel
    let apply: ApplyCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill").foregroundStyle(Palette.flaggedColor)
                Text(localized("Apply is unavailable for this shoot")).font(.headline)
            }
            Text(ApplyText.readOnlyExplanation(shootName: model.name, volumeIsReadOnly: apply.writability == .readOnlyVolume))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let destination = apply.copyDestination {
                VStack(alignment: .leading, spacing: 4) {
                    Text(localized("Copy keepers to")).font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        Text(AppEnvironment.displayPath(destination.path)).lineLimit(2).truncationMode(.middle)
                    }
                    Button(localized("Choose Another Folder…")) { apply.chooseCopyDestination() }
                        .buttonStyle(.link)
                        .font(.callout)
                }
                Toggle(localized("Write XMP sidecars beside the copies"), isOn: Binding(get: { apply.options.writeSidecars }, set: { apply.setWriteSidecars($0) }))
                    .toggleStyle(.checkbox)
                if let plan = apply.copyPlan {
                    if let blocker = plan.blocker {
                        Label(ApplyText.blockerText(blocker, destinationName: destination.lastPathComponent), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Palette.flaggedColor)
                    }
                    ConsequenceBox(lines: copyLines(plan))
                }
            } else {
                ConsequenceBox(lines: [
                    localized("Kept and unreviewed photos are copied, with their RAW files and sidecars, into a folder you choose, keeping their subfolders."),
                    localized("Rejects are not copied. Nothing in “\(model.name)” changes."),
                ])
            }
        }
    }

    private func copyLines(_ plan: ApplyPlan) -> [String] {
        let summary = plan.summary
        var lines = [
            localized("Copies \(plan.photos.count) photos (\(summary.filesToCopy) files, \(ApplyText.bytes(summary.bytesToCopy))), keeping their subfolders. Nothing is overwritten: a name already taken gets a number."),
        ]
        if summary.rejected > 0 { lines.append(localized("The \(summary.rejected) photos you rejected are not copied.")) }
        if plan.options.writeSidecars, summary.sidecarsToWrite > 0 {
            lines.append(localized("\(summary.sidecarsToWrite) sidecars written beside the copies."))
        }
        lines.append(localized("“\(model.name)” is only read. Undo Apply removes the copies again."))
        return lines
    }
}

private struct PrimaryButtons: View {
    let model: SessionModel
    let apply: ApplyCoordinator

    var body: some View {
        let enabled = model.isEnabled(.applyDecisions)
        VStack(spacing: 10) {
            Button {
                model.perform(.applyDecisions)
            } label: {
                Text(apply.primaryTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(apply.options.rejectAction == .moveToTrash && !apply.isReadOnly ? Palette.rejectedColor : Palette.accentColor)
            .controlSize(.large)
            .disabled(!enabled)
            .help(enabled ? localized("help.titleWithKey", default: "\(apply.primaryTitle) (\(model.keyName(.applyDecisions)))") : localized("Nothing would change on disk"))
            HStack {
                Button(localized("Keep Culling")) { model.perform(.back) }
                    .help(localized("Leave without applying (\(model.keyName(.back)) or \(model.keyName(.reviewAndApply)))"))
                Spacer()
                Text(enabled ? localized("\(model.keyName(.applyDecisions)) applies") : "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Looking closer

/// A reject shown large over the list, without leaving the screen.
private struct PeekView: View {
    let model: SessionModel
    let apply: ApplyCoordinator
    @State private var image: CGImage?
    @State private var shownID: String?

    var body: some View {
        let id = apply.peekID
        let item = id.flatMap { model.state.photo($0) }
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.92)
                .onTapGesture { apply.closePeek() }
                // A click on the dark surround closes it, as Space and Escape do; not a control.
                .accessibilityHidden(true)
            if let image, shownID == id {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(.horizontal, 28)
                    .padding(.top, 24)
                    .padding(.bottom, 72)
            } else if let item {
                ThumbnailImage(file: item.file, cache: model.thumbnails, activity: model.activity)
                    .padding(.horizontal, 28)
                    .padding(.top, 24)
                    .padding(.bottom, 72)
            }
            if let item, let id {
                HStack(spacing: 14) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.rejectedColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.file.name).font(.system(size: 13, weight: .semibold))
                        Text(reasons(id)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(KeyText.keyNames(.init(.previousPhoto, .nextPhoto, label: "", spaced: true), in: model.settings.keyBindings).map { localized("\($0) next reject") } ?? "").font(.caption).foregroundStyle(.secondary)
                    Button(localized("Rescue (\(model.keyName(.keep)))")) { apply.rescue() }
                    Button(localized("Close (\(model.keyName(.toggleLoupe)))")) { apply.closePeek() }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(Palette.panelBackgroundColor)
            }
        }
        .task(id: id) {
            guard let item else { return }
            if let cached = model.previews.cached(item.file) {
                image = cached
                shownID = id
                return
            }
            if let decoded = try? await model.previews.image(for: item.file), apply.peekID == id {
                image = decoded
                shownID = id
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(localized("Closer look"))
    }

    private func reasons(_ id: String) -> String {
        let reasons = model.state.rejectReasons(for: id).map(\.title)
        let list = reasons.joined(separator: localized("list.separator", default: ", "))
        return localized("Rejected · \(list)")
    }
}

// MARK: - Progress

/// The run under way: how far it is, and Cancel, which stops between files.
struct RunProgressOverlay: View {
    let run: ApplyRunProgress
    let cancel: () -> Void
    let cancelKey: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
            VStack(alignment: .leading, spacing: 12) {
                Text(localized("progress.title", default: "\(run.title)…")).font(.headline)
                ProgressView(value: run.fraction)
                    .progressViewStyle(.linear)
                HStack {
                    Text(localized("\(run.done) of \(run.total) changes"))
                        .monospacedDigit()
                    if let name = run.currentName {
                        Text(verbatim: "·")
                        Text(name).lineLimit(1).truncationMode(.middle)
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                Text(run.cancelling
                    ? localized("Stopping after the current file…")
                    : localized("Every change is recorded as it is made, so whatever is done can be undone."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button(localized("Cancel")) { cancel() }
                        .disabled(run.cancelling)
                        .help(localized("Stop after the current file (\(cancelKey))"))
                }
            }
            .padding(20)
            .frame(width: 440)
            .background(RoundedRectangle(cornerRadius: 12).fill(Palette.panelBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.08)))
            .shadow(color: .black.opacity(0.5), radius: 20, y: 6)
        }
        .accessibilityElement(children: .contain)
    }
}
