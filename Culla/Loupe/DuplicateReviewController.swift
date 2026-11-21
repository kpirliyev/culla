import AppKit
import CullaAnalysis
import CullaCommands
import CullaCore
import CullaSession
import SwiftUI

/// Duplicates (User Flows, Flow 4): one set at a time, its copies side by side, each with its file
/// name, folder, size, format and pixel dimensions; what differs between the copies is set off.
/// The copy Culla proposes to keep is starred with the reason in words. Return accepts the set;
/// P on another copy first keeps that one instead. Exact and near-duplicate sets are told apart in
/// the header and on every card.
@MainActor
final class DuplicateReviewController: NSViewController {
    let model: SessionModel
    private var headerHost: NSHostingView<DuplicateHeader>!
    private var doneHost: NSHostingView<DuplicateDoneView>!
    private let row = NSStackView()
    private(set) var panes: [PhotoPane] = []
    private var cards: [NSHostingView<CopyCard>] = []
    private var columns: [NSView] = []
    private var observation: ObservationToken?
    private var isActive = false
    private var folderWasMissing = false
    private var shownZoomRevision = -1
    private weak var zoomSource: PhotoPane?

    static let cardHeight: CGFloat = 112

    init(model: SessionModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(white: 0.06, alpha: 1).cgColor
        self.view = view
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        headerHost = NSHostingView(rootView: DuplicateHeader(model: model))
        headerHost.sizingOptions = []
        doneHost = NSHostingView(rootView: DuplicateDoneView(model: model))
        doneHost.sizingOptions = []
        doneHost.isHidden = true
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.spacing = 1
        for subview in [headerHost!, row, doneHost!] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            headerHost.topAnchor.constraint(equalTo: view.topAnchor),
            headerHost.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerHost.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            headerHost.heightAnchor.constraint(equalToConstant: StackReviewController.headerHeight),
            row.topAnchor.constraint(equalTo: headerHost.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            row.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            doneHost.topAnchor.constraint(equalTo: headerHost.bottomAnchor),
            doneHost.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            doneHost.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            doneHost.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        observation = observeChanges { [weak self] in self?.sync() }
    }

    private func makeColumn() {
        let pane = PhotoPane(previews: model.previews, thumbnails: model.thumbnails, activity: model.activity)
        let card = NSHostingView(rootView: CopyCard.empty)
        card.sizingOptions = []
        let column = NSView()
        for view in [pane, card] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            column.addSubview(view)
        }
        NSLayoutConstraint.activate([
            pane.topAnchor.constraint(equalTo: column.topAnchor),
            pane.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            pane.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            pane.bottomAnchor.constraint(equalTo: card.topAnchor),
            card.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            card.bottomAnchor.constraint(equalTo: column.bottomAnchor),
            card.heightAnchor.constraint(equalToConstant: Self.cardHeight),
        ])
        let index = panes.count
        pane.onClick = { [weak self] in self?.model.selectCopy(at: index) }
        pane.onZoomChange = { [weak self, weak pane] zoom in
            guard let self, let pane else { return }
            self.zoomSource = pane
            self.model.reviewViewChanged(zoom)
        }
        panes.append(pane)
        cards.append(card)
        columns.append(column)
    }

    private func sync() {
        let active = model.viewMode == .duplicateReview
        _ = model.revision
        _ = model.selection
        _ = model.reviewZoomRevision
        _ = model.duplicateReviewDone
        // Panes left blank while the folder could not be reached load again when it is back.
        let folderBack = folderWasMissing && !model.folderMissing
        folderWasMissing = model.folderMissing
        if active != isActive {
            isActive = active
            if !active {
                for pane in panes { pane.release() }
                return
            }
        }
        guard active, let set = model.currentSet else { return }
        let state = model.state
        let members = set.members
        while panes.count < members.count { makeColumn() }
        for (index, column) in columns.enumerated() {
            let shown = index < members.count
            if shown, column.superview == nil { row.addArrangedSubview(column) }
            if !shown, column.superview != nil {
                row.removeArrangedSubview(column)
                column.removeFromSuperview()
                panes[index].release()
            }
        }
        let pick = state.duplicatePick(forSetContaining: set.id)
        let copies = members.map { id -> DuplicateReview.Copy in
            let item = state.photo(id)
            return DuplicateReview.Copy(
                name: item?.file.name ?? id, folder: item.map { Formatting.folder(of: $0, shootName: model.name) } ?? "",
                bytes: item?.file.fileSize ?? 0, format: item.map { Formatting.format($0.file) } ?? "",
                width: item?.metadata.pixelWidth, height: item?.metadata.pixelHeight
            )
        }
        let differing = DuplicateReview.differingFields(copies)
        let zoomChanged = model.reviewZoomRevision != shownZoomRevision
        shownZoomRevision = model.reviewZoomRevision
        let source = zoomChanged ? zoomSource : nil
        zoomSource = nil
        for (index, id) in members.enumerated() {
            let pane = panes[index]
            let photo = state.photo(id)
            _ = source
            pane.show(photo, zoom: model.reviewZoom)
            if folderBack { pane.retryIfBlank() }
            let focused = model.focus == id
            pane.setRing(focused ? NSColor(white: 0.96, alpha: 0.9) : nil)
            pane.setDecision(photo?.decision)
            pane.setCaption(CopyCaption(
                name: copies[index].name, isPick: pick?.id == id, reason: pick.map { DuplicateReview.pickCaption($0.reason) } ?? "",
                isFocused: focused, decision: photo?.decision
            ))
            cards[index].rootView = CopyCard(copy: copies[index], kind: set.kind, differing: differing, isPick: pick?.id == id, isFocused: focused)
        }
        doneHost.isHidden = !model.duplicateReviewDone
    }

    var isSettled: Bool {
        guard isActive, let set = model.currentSet else { return true }
        if model.duplicateReviewDone { return true }
        return panes.prefix(set.members.count).allSatisfy(\.isSettled)
    }

    func dumpState() -> [String: Any] {
        let state = model.state
        var dump: [String: Any] = ["active": isActive, "done": model.duplicateReviewDone]
        if let set = model.currentSet, let index = state.duplicateSetIndex(containing: set.id) {
            let pick = state.duplicatePick(forSetContaining: set.id)
            dump["setIndex"] = index
            dump["setCount"] = state.duplicateSets.count
            dump["kind"] = set.kind.rawValue
            dump["members"] = set.members
            dump["current"] = model.focus ?? NSNull()
            dump["pick"] = pick?.id ?? NSNull()
            dump["reason"] = pick.map { DuplicateReview.pickCaption($0.reason) } ?? NSNull()
        }
        dump["exactLeft"] = state.duplicateSetCounts(kind: .exact).left
        dump["nearLeft"] = state.duplicateSetCounts(kind: .near).left
        dump["lastBulkAccept"] = model.lastBulkAccept.map { ["sets": $0.sets, "rejected": $0.rejected] } ?? NSNull()
        dump["panes"] = panes.prefix(model.currentSet?.members.count ?? 0).map { $0.dumpState() }
        return dump
    }
}

struct CopyCaption: View {
    let name: String
    let isPick: Bool
    let reason: String
    let isFocused: Bool
    let decision: Decision?

    var body: some View {
        HStack(spacing: 7) {
            if isPick {
                Label(reason, systemImage: "star.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .labelStyle(StarLabelStyle())
                    .lineLimit(1)
            } else {
                Text(localized("caption.copy", default: "Copy")).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if let decision, decision != .unreviewed { DecisionChip(decision: decision) }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isFocused ? Color(white: 0.2) : Palette.windowBackgroundColor)
    }
}

/// A copy's file details. Values that differ between the copies are bright and marked "≠"; the
/// rest are quiet, so a near-duplicate's smaller size or other format stands out at once.
struct CopyCard: View {
    let copy: DuplicateReview.Copy
    let kind: DuplicateSet.Kind
    let differing: Set<DuplicateReview.Field>
    let isPick: Bool
    let isFocused: Bool

    static let empty = CopyCard(
        copy: DuplicateReview.Copy(name: "", folder: "", bytes: 0, format: "", width: nil, height: nil),
        kind: .exact, differing: [], isPick: false, isFocused: false
    )

    var body: some View {
        // A grid, so the label column is as wide as its longest label in any language.
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 3) {
            row(localized("copyCard.name", default: "Name"), copy.name, .name)
            row(localized("copyCard.folder", default: "Folder"), copy.folder, .folder)
            row(localized("copyCard.size", default: "Size"), Formatting.bytes(copy.bytes), .size)
            row(localized("copyCard.format", default: "Format"), copy.format, .format)
            row(localized("copyCard.pixels", default: "Pixels"),
                copy.width.map { w in copy.height.map { "\(w) × \($0)" } ?? "\(w)" } ?? localized("copyCard.unknown", default: "unknown"),
                .dimensions)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(isFocused ? Color(white: 0.17) : Palette.panelBackgroundColor)
    }

    private func row(_ title: String, _ value: String, _ field: DuplicateReview.Field) -> some View {
        let differs = differing.contains(field)
        return GridRow {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize()
                .frame(minWidth: 44, alignment: .leading)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(value)
                    .font(.system(size: 12, weight: differs ? .semibold : .regular))
                    .foregroundStyle(differs ? .primary : .secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.middle)
                if differs {
                    Text(verbatim: "≠")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .help(localized("Differs between the copies"))
                }
            }
            .gridColumnAlignment(.leading)
        }
    }
}

/// "Set 2 of 3 · Exact copies", the sets left of each kind, Accept All Exact Duplicates, the keys.
struct DuplicateHeader: View {
    let model: SessionModel

    private func setSummary(_ set: PhotoDuplicateSet, index: Int, tag: KindTag.Style, files: Bool) -> some View {
        HStack(spacing: 10) {
            Text(DuplicateReview.title(index: index, count: model.session.duplicateSets.count))
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
            KindTag(kind: set.kind, style: tag)
            if files {
                Text(localized("\(set.members.count) files"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize()
    }

    var body: some View {
        let session = model.session
        let exact = session.duplicateSetCounts(kind: .exact)
        HStack(spacing: 10) {
            if let set = model.currentSet, let index = session.duplicateSetIndex(containing: set.id) {
                // When the bar is narrow the tag gives up its explanation, then the file count
                // goes, then the tag shows only its icon: nothing is cut.
                ViewThatFits(in: .horizontal) {
                    setSummary(set, index: index, tag: .full, files: true)
                    setSummary(set, index: index, tag: .short, files: true)
                    setSummary(set, index: index, tag: .short, files: false)
                    setSummary(set, index: index, tag: .icon, files: false)
                }
            }
            Spacer(minLength: 8)
            HintLine(KeyText.duplicateReviewHints(model.settings.keyBindings))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .layoutPriority(-1)
            Button {
                model.perform(.acceptAllExactDuplicates)
            } label: {
                Text(exact.left > 0 ? localized("Accept All Exact Duplicates (\(exact.left))") : localized("No Exact Duplicates Left"))
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
            }
            .controlSize(.small)
            .fixedSize()
            .disabled(exact.left == 0)
            .help(KeyText.key(.acceptAllExactDuplicates, in: model.settings.keyBindings).map {
                localized("Keeps one copy of every byte-identical set still undecided and rejects the rest, in one step (\($0)). Near-duplicates are never accepted in bulk.")
            } ?? localized("Keeps one copy of every byte-identical set still undecided and rejects the rest, in one step. Near-duplicates are never accepted in bulk."))
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.panelBackgroundColor)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.separatorColor).frame(height: 1) }
    }
}

/// Exact copies (solid, "=") and near-duplicates (outlined, "≈") look different everywhere.
struct KindTag: View {
    let kind: DuplicateSet.Kind
    var style = Style.full

    /// `full`: "Exact copies · identical files"; `short`: the part before " · ", "Exact copies";
    /// `icon`: the symbol alone, the words its tooltip and spoken label.
    enum Style { case full, short, icon }

    var body: some View {
        let exact = kind == .exact
        let text = exact ? localized("Exact copies · identical files") : localized("Near-duplicates · same picture, different files")
        let symbol = exact ? "equal.square.fill" : "approximately.equal"
        Group {
            switch style {
            case .full: Label(text, systemImage: symbol)
            case .short: Label(text.components(separatedBy: " · ").first ?? text, systemImage: symbol)
            case .icon: Image(systemName: symbol)
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(exact ? Color.black.opacity(0.85) : Color.primary)
        .padding(.horizontal, 8)
        .padding(.vertical, 2.5)
        .background(Capsule().fill(exact ? Color(white: 0.85) : Color.clear))
        .overlay(Capsule().strokeBorder(Color(white: 0.85), lineWidth: exact ? 0 : 1))
        .fixedSize()
        .help(text)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

struct DuplicateDoneView: View {
    let model: SessionModel

    var body: some View {
        let session = model.session
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Palette.keptColor)
            Text(localized("Every duplicate set has a decision"))
                .font(.title3.weight(.semibold))
            Text(localized("\(session.duplicateSets.count) sets. Any decision can still be changed."))
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                if let next = model.nextGroupToReview {
                    Button(localized("Next: \(next.title) (\(session.count(of: next).left) left)")) {
                        model.openNextGroupToReview()
                    }
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                }
                Button(localized("Review Sets Again")) {
                    if let first = session.duplicateSets.first { model.showSet(first) }
                }
                .controlSize(.large)
            }
            .padding(.top, 4)
        }
        .multilineTextAlignment(.center)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.gridBackgroundColor)
    }
}
