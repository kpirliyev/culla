import AppKit
import CullaAnalysis
import CullaCommands
import CullaCore
import CullaSession
import SwiftUI

/// Compare (C): two to four photos side by side, real loupes with linked zoom and pan. One pane
/// has the focus, ringed in white and named in its caption; ← → move the focus, and P, X, U and the
/// ratings apply to it. Escape or C goes back to where compare was opened from.
@MainActor
final class CompareController: NSViewController {
    let model: SessionModel
    private var headerHost: NSHostingView<CompareHeader>!
    private let row = NSStackView()
    private(set) var panes: [PhotoPane] = []
    private var observation: ObservationToken?
    private var isActive = false
    private var folderWasMissing = false
    private var shownZoomRevision = -1
    private weak var zoomSource: PhotoPane?

    init(model: SessionModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        view.wantsLayer = true
        view.layer?.backgroundColor = Palette.separator.blended(withFraction: 0.5, of: Palette.loupeBackground)?.cgColor
        self.view = view
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        headerHost = NSHostingView(rootView: CompareHeader(model: model))
        headerHost.sizingOptions = []
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.spacing = 1
        for subview in [headerHost!, row] as [NSView] {
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
        ])
        observation = observeChanges { [weak self] in self?.sync() }
    }

    private func sync() {
        let active = model.viewMode == .compare
        _ = model.revision
        _ = model.compareFocus
        _ = model.reviewZoomRevision
        _ = model.loupeOverlays
        let ids = model.compareIDs
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
        guard active else { return }
        while panes.count < ids.count {
            let pane = PhotoPane(previews: model.previews, thumbnails: model.thumbnails, activity: model.activity)
            let index = panes.count
            pane.onClick = { [weak self] in self?.model.focusComparePane(index) }
            pane.onZoomChange = { [weak self, weak pane] zoom in
                guard let self, let pane else { return }
                self.zoomSource = pane
                self.model.reviewViewChanged(zoom)
            }
            panes.append(pane)
        }
        for (index, pane) in panes.enumerated() {
            let shown = index < ids.count
            if shown, pane.superview == nil { row.addArrangedSubview(pane) }
            if !shown, pane.superview != nil {
                row.removeArrangedSubview(pane)
                pane.removeFromSuperview()
                pane.release()
            }
        }
        let state = model.state
        let zoomChanged = model.reviewZoomRevision != shownZoomRevision
        shownZoomRevision = model.reviewZoomRevision
        let source = zoomChanged ? zoomSource : nil
        zoomSource = nil
        let showsBoxes = model.loupeOverlays.showsFaceBoxes(in: model.faceBoxGroup)
        for (index, id) in ids.enumerated() {
            let pane = panes[index]
            let photo = state.photo(id)
            _ = source
            pane.show(photo, zoom: model.reviewZoom)
            if folderBack { pane.retryIfBlank() }
            let focused = index == model.compareFocus
            pane.setRing(focused ? NSColor(white: 0.96, alpha: 0.9) : nil)
            pane.setDecision(photo?.decision)
            pane.setFaces(showsBoxes ? faces(photo) : [])
            pane.setCaption(CompareCaption(
                position: index + 1, name: photo?.file.name ?? id, isFocused: focused,
                isPick: state.stack(containing: id)?.bestPick == id, rating: photo?.rating ?? 0, decision: photo?.decision
            ))
        }
    }

    private func faces(_ photo: PhotoItem?) -> [LoupeFaceBox] {
        guard let photo, let scores = photo.scores else { return [] }
        let state = model.state
        let main = Set(state.summary(for: photo.id)?.mainFaces ?? [])
        return scores.faces.enumerated().map { index, face in
            LoupeFaceBox(box: face.box, isMain: main.contains(index), eyesClosed: LoupeTarget.eyesLookClosed(face, tuning: state.tuning) == true, isTargeted: false)
        }
    }

    var isSettled: Bool {
        !isActive || panes.prefix(model.compareIDs.count).allSatisfy(\.isSettled)
    }

    func dumpState() -> [String: Any] {
        [
            "photos": model.compareIDs,
            "focusedPane": model.compareFocus,
            "focused": model.compareFocusedID ?? NSNull(),
            "origin": model.compareOrigin.map { $0.viewMode.rawValue } ?? NSNull(),
            "zoom": model.reviewZoom.factor.map { ["factor": $0] as [String: Any] } ?? "fit",
            "panes": panes.prefix(model.compareIDs.count).map { $0.dumpState() },
        ]
    }

    /// A click on a pane, for the automation harness.
    func click(pane index: Int) -> Bool {
        guard panes.indices.contains(index), index < model.compareIDs.count else { return false }
        panes[index].onClick?()
        return true
    }
}

/// A compare pane's caption: its number, the file, the star of a stack's pick, the rating and the
/// decision; the focused pane says so.
struct CompareCaption: View {
    let position: Int
    let name: String
    let isFocused: Bool
    let isPick: Bool
    let rating: Int
    let decision: Decision?

    var body: some View {
        HStack(spacing: 7) {
            Text(Formatting.count(position))
                .font(.system(size: 10, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(isFocused ? Color.black : Color.secondary)
                .frame(width: 16, height: 16)
                .background(Circle().fill(isFocused ? Color(white: 0.95) : Color.white.opacity(0.1)))
            if isPick {
                Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(Palette.flaggedColor)
                    .help(localized("The best pick of its stack"))
            }
            Text(name)
                .font(.system(size: 12, weight: isFocused ? .semibold : .regular))
                .foregroundStyle(isFocused ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if isFocused {
                Text(localized("keys act here")).font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize()
            }
            Spacer(minLength: 4)
            if rating > 0 { StarsView(rating: rating, size: 9) }
            if let decision, decision != .unreviewed { DecisionChip(decision: decision) }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isFocused ? Color(white: 0.2) : Palette.windowBackgroundColor)
    }
}

struct CompareHeader: View {
    let model: SessionModel

    var body: some View {
        HStack(spacing: 10) {
            Button {
                model.perform(.back)
            } label: {
                Label(localized("button.back", default: "Back"), systemImage: "chevron.left").font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help(KeyText.backHelp(to: .previousView, commands: [.back, .showCompare], in: model.settings.keyBindings))
            Text(localized("Compare \(model.compareIDs.count) photos"))
                .font(.system(size: 13, weight: .semibold))
            Text(localized("zoom and pan are linked"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            HintLine(KeyText.compareHints(model.settings.keyBindings))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .layoutPriority(-1)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.panelBackgroundColor)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.separatorColor).frame(height: 1) }
    }
}
