import AppKit
import CullaAnalysis
import CullaCommands
import CullaCore
import CullaSession
import SwiftUI

/// Stack review (Design, "Stack review"; User Flows, Flow 2): one burst at a time. A header with
/// the stack's place, size, time span and the keys; the current frame on the left and the best
/// pick pinned on the right, both real loupes with linked zoom; the face strip; the stack's frames.
///
/// H hides the best pick (a setting, `AppSettings.showsBestPickPane`): the current frame then
/// fills the row. F hides the faces: the face strip and the boxes over both panes. A stack
/// without faces has no strip either; either way the frames take its height.
///
/// It follows the model: the focus is the current frame, `reviewZoom` the panes' shared zoom.
/// Moving between frames swaps the left pane's image only (the right keeps the pick), and moving
/// to another stack replaces both images in place: nothing is rebuilt, so nothing flashes or moves.
@MainActor
final class StackReviewController: NSViewController {
    let model: SessionModel
    private(set) var currentPane: PhotoPane!
    private(set) var pickPane: PhotoPane!
    private(set) var strip: FaceStripView!
    private(set) var filmstrip: StackFilmstripView!
    private var headerHost: NSHostingView<StackReviewHeader>!
    private var doneHost: NSHostingView<StackReviewDoneView>!
    private let panesRow = NSView()
    private var stripHeight: NSLayoutConstraint!
    private var stripSeparator = NSBox()
    private var stripSeparatorHeight: NSLayoutConstraint!
    private let divider = NSBox()
    /// The pick pane against the row's trailing edge (two panes), or the current pane (one).
    private var twoPaneConstraints: [NSLayoutConstraint] = []
    private var onePaneConstraints: [NSLayoutConstraint] = []
    /// What shows, as the last sync decided it.
    private(set) var screenLayout = StackReviewLayout(pickPaneWanted: true, faceStripWanted: true, stackHasFaces: false, faceBoxesOn: false)
    private var observation: ObservationToken?
    private var crops: FaceCropStore!
    private var isActive = false
    private var folderWasMissing = false
    private var shownZoomRevision = -1
    private var shownStackID: String?
    private var shownFrame: String?
    /// The pane the person last zoomed by hand: it already shows the zoom it reported.
    private weak var zoomSource: PhotoPane?

    // Timings, for the automation dump.
    private var pending: (kind: String, at: CFTimeInterval)?
    private(set) var lastStackShownMs: Double?
    private(set) var lastFrameShownMs: Double?
    private(set) var stackShownTimes: [Double] = []

    static let headerHeight: CGFloat = 36

    init(model: SessionModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        view.wantsLayer = true
        view.layer?.backgroundColor = Palette.loupeBackground.cgColor
        self.view = view
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        crops = FaceCropStore(previews: model.previews, thumbnails: model.thumbnails, activity: model.activity)
        currentPane = PhotoPane(previews: model.previews, thumbnails: model.thumbnails, activity: model.activity)
        pickPane = PhotoPane(previews: model.previews, thumbnails: model.thumbnails, activity: model.activity)
        strip = FaceStripView(crops: crops)
        filmstrip = StackFilmstripView(frame: .zero)
        let model = model
        headerHost = NSHostingView(rootView: StackReviewHeader(model: model))
        headerHost.sizingOptions = []
        doneHost = NSHostingView(rootView: StackReviewDoneView(model: model))
        doneHost.sizingOptions = []
        doneHost.isHidden = true

        divider.boxType = .custom
        divider.borderWidth = 0
        divider.fillColor = Palette.separator
        stripSeparator.boxType = .custom
        stripSeparator.borderWidth = 0
        stripSeparator.fillColor = Palette.separator
        let filmSeparator = NSBox()
        filmSeparator.boxType = .custom
        filmSeparator.borderWidth = 0
        filmSeparator.fillColor = Palette.separator

        for subview in [currentPane!, divider, pickPane!] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            panesRow.addSubview(subview)
        }
        for subview in [headerHost!, panesRow, stripSeparator, strip!, filmSeparator, filmstrip!, doneHost!] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        stripHeight = strip.heightAnchor.constraint(equalToConstant: 0)
        stripSeparatorHeight = stripSeparator.heightAnchor.constraint(equalToConstant: 0)
        strip.isHidden = true
        stripSeparator.isHidden = true
        // With one pane, the pick pane and the divider sit past the row's trailing edge, hidden,
        // and the current pane reaches that edge.
        twoPaneConstraints = [pickPane.trailingAnchor.constraint(equalTo: panesRow.trailingAnchor)]
        onePaneConstraints = [currentPane.trailingAnchor.constraint(equalTo: panesRow.trailingAnchor)]
        panesRow.wantsLayer = true
        panesRow.layer?.masksToBounds = true
        NSLayoutConstraint.activate([
            headerHost.topAnchor.constraint(equalTo: view.topAnchor),
            headerHost.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerHost.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            headerHost.heightAnchor.constraint(equalToConstant: Self.headerHeight),

            panesRow.topAnchor.constraint(equalTo: headerHost.bottomAnchor),
            panesRow.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            panesRow.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            panesRow.bottomAnchor.constraint(equalTo: stripSeparator.topAnchor),

            currentPane.topAnchor.constraint(equalTo: panesRow.topAnchor),
            currentPane.bottomAnchor.constraint(equalTo: panesRow.bottomAnchor),
            currentPane.leadingAnchor.constraint(equalTo: panesRow.leadingAnchor),
            divider.leadingAnchor.constraint(equalTo: currentPane.trailingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.topAnchor.constraint(equalTo: panesRow.topAnchor),
            divider.bottomAnchor.constraint(equalTo: panesRow.bottomAnchor),
            pickPane.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            pickPane.topAnchor.constraint(equalTo: panesRow.topAnchor),
            pickPane.bottomAnchor.constraint(equalTo: panesRow.bottomAnchor),
            pickPane.widthAnchor.constraint(equalTo: currentPane.widthAnchor),

            stripSeparator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stripSeparator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stripSeparatorHeight,
            stripSeparator.bottomAnchor.constraint(equalTo: strip.topAnchor),
            strip.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            strip.bottomAnchor.constraint(equalTo: filmSeparator.topAnchor),
            stripHeight,
            filmSeparator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            filmSeparator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            filmSeparator.heightAnchor.constraint(equalToConstant: 1),
            filmSeparator.bottomAnchor.constraint(equalTo: filmstrip.topAnchor),
            filmstrip.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            filmstrip.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            filmstrip.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            filmstrip.heightAnchor.constraint(equalToConstant: StackFilmstripView.height),

            doneHost.topAnchor.constraint(equalTo: headerHost.bottomAnchor),
            doneHost.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            doneHost.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            doneHost.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ] + twoPaneConstraints)

        for pane in [currentPane!, pickPane!] {
            pane.onZoomChange = { [weak self, weak pane] zoom in
                guard let self, let pane else { return }
                self.zoomSource = pane
                self.model.reviewViewChanged(zoom)
            }
            pane.onSharp = { [weak self] in self?.checkTimings() }
        }
        currentPane.onClick = {}
        pickPane.onClick = {}
        strip.onCellClick = { [weak self] row, column in self?.model.selectFaceCell(row: row, column: column) }
        crops.onCrops = { [weak self] in
            self?.strip.cropsArrived()
            self?.checkTimings()
        }
        strip.onScroll = { [weak self] x in self?.filmstrip.setHorizontalOffset(x) }
        filmstrip.onScroll = { [weak self] x in self?.strip.setHorizontalOffset(x) }
        filmstrip.onClick = { [weak self] id in self?.model.selectFrame(id) }
        observation = observeChanges { [weak self] in self?.sync() }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateStripHeight()
        let scale = view.window?.backingScaleFactor ?? 2
        let longSide = Int(max(currentPane.imageView.contentSize.width, currentPane.imageView.contentSize.height) * scale)
        // Screen-size images are decoded for the larger of what the panes have needed: a pane
        // that grew past it (the current frame alone across the row, the strip hidden, a larger
        // window) has its photo decoded again at the new size.
        if longSide > 0, model.previews.setViewportLongSide(max(longSide, model.previews.pixelSize)), isActive {
            currentPane.screenSizeChanged()
            if screenLayout.showsPickPane { pickPane.screenSizeChanged() }
        }
    }

    // MARK: Following the model

    private func sync() {
        let active = model.viewMode == .stackReview
        _ = model.revision
        _ = model.selection
        _ = model.reviewZoomRevision
        _ = model.reviewFaceRow
        _ = model.loupeOverlays
        _ = model.stackReviewDone
        // Thumbnails that waited for a disconnected folder load again when it is back.
        _ = model.marksRevision
        let folderBack = folderWasMissing && !model.folderMissing
        folderWasMissing = model.folderMissing
        let stripShown = model.faceStripInStackReview
        if active != isActive {
            isActive = active
            if !active {
                deactivate()
                return
            }
        }
        guard active, let panes = model.stackPanes, let stack = model.currentStack else { return }
        let state = model.state
        if let action = model.reviewActionAt, pending?.at != action.at {
            pending = (action.kind, action.at)
        }
        let stackChanged = stack.id != shownStackID
        shownStackID = stack.id
        shownFrame = panes.current

        let layout = FaceStripLayout.make(model: model, for: panes.current)
        let screen = StackReviewLayout(
            pickPaneWanted: model.settings.showsBestPickPane, faceStripWanted: stripShown, stackHasFaces: !layout.isEmpty,
            faceBoxesOn: model.loupeOverlays.showsFaceBoxes(in: model.faceBoxGroup)
        )
        let showsPick = screen.showsPickPane
        if showsPick != screenLayout.showsPickPane { setPickPaneShown(showsPick) }
        screenLayout = screen
        let current = state.photo(panes.current)
        let other = panes.other.flatMap { state.photo($0) }
        let zoomChanged = model.reviewZoomRevision != shownZoomRevision
        shownZoomRevision = model.reviewZoomRevision
        let source = zoomChanged ? zoomSource : nil
        zoomSource = nil
        _ = source
        currentPane.show(current, zoom: zoom(for: panes.current))
        // A hidden pick pane holds no image and loads none.
        if showsPick { pickPane.show(other, zoom: zoom(for: panes.other)) }
        // While zoomed, the next frame's full-size image is decoded ahead.
        if let index = stack.members.firstIndex(of: panes.current), index + 1 < stack.members.count {
            currentPane.ahead = state.photo(stack.members[index + 1])
        } else {
            currentPane.ahead = nil
        }
        // F hides the boxes with the strip: faces on or off.
        let showsBoxes = screen.showsFaceBoxes
        currentPane.setFaces(showsBoxes ? faceBoxes(current, row: model.reviewFaceRow, layout: layout) : [])
        currentPane.setDecision(current?.decision)
        currentPane.setRing(NSColor(white: 0.96, alpha: 0.55))
        let strip = model.currentFaceStrip
        let currentIsPick = panes.role == .runnerUp
        var currentDetail = current.map { StackReview.caption(StackReview.notes(for: $0.id, in: stack, state: state, strip: strip)) } ?? ""
        // Alone on screen, the pick says why it is the pick, as its own pane would have.
        if currentIsPick, !showsPick, currentDetail.isEmpty { currentDetail = StackReview.pickReason(of: stack, state: state) ?? "" }
        currentPane.setCaption(PaneCaption(
            role: currentIsPick ? .currentIsPick : .current,
            name: current?.file.name ?? "",
            detail: currentDetail,
            handPicked: currentIsPick && state.isHandPicked(stack),
            decision: current?.decision
        ))
        if showsPick {
            showPick(other, stack: stack, role: panes.role, showsBoxes: showsBoxes, layout: layout)
        }

        // The face strip and the frames.
        self.strip.isHidden = !screen.showsFaceStrip
        stripSeparator.isHidden = !screen.showsFaceStrip
        if screen.showsFaceStrip {
            self.strip.show(layout) { state.photo($0) }
            if stackChanged { self.strip.setHorizontalOffset(0) }
            self.strip.scrollToCurrent()
        }
        updateStripHeight()
        filmstrip.show(stack.members.compactMap { id in tileContent(id, stack: stack, strip: strip) }, model: model)
        if let column = stack.members.firstIndex(of: panes.current) {
            if stackChanged { filmstrip.setHorizontalOffset(0) }
            filmstrip.scrollToColumn(column)
        }
        doneHost.isHidden = !model.stackReviewDone
        if folderBack {
            currentPane.retryIfBlank()
            if showsPick { pickPane.retryIfBlank() }
        }
        checkTimings()
    }

    /// The right pane: the best pick, or the runner-up while the current frame is the pick.
    private func showPick(_ other: PhotoItem?, stack: PhotoStack, role: PickPaneRole, showsBoxes: Bool, layout: FaceStripLayout) {
        let state = model.state
        let strip = model.currentFaceStrip
        pickPane.setFaces(showsBoxes ? faceBoxes(other, row: model.reviewFaceRow, layout: layout) : [])
        pickPane.setDecision(other?.decision)
        pickPane.setRing(nil)
        let otherNotes = other.map { StackReview.notes(for: $0.id, in: stack, state: state, strip: strip) } ?? []
        pickPane.setCaption(PaneCaption(
            role: role == .runnerUp ? .runnerUp : .pick,
            name: other?.file.name ?? "",
            detail: role == .runnerUp
                ? (otherNotes.isEmpty ? localized("Culla’s next best frame") : localized("next best: \(StackReview.caption(otherNotes))"))
                : (StackReview.pickReason(of: stack, state: state) ?? localized("no pick yet")),
            handPicked: role == .bestPick && state.isHandPicked(stack),
            decision: other?.decision
        ))
    }

    /// Two panes, or the current frame alone across the row. The hidden pane lets its images go.
    private func setPickPaneShown(_ shown: Bool) {
        NSLayoutConstraint.deactivate(shown ? onePaneConstraints : twoPaneConstraints)
        NSLayoutConstraint.activate(shown ? twoPaneConstraints : onePaneConstraints)
        pickPane.isHidden = !shown
        divider.isHidden = !shown
        if !shown {
            pickPane.release()
            pickPane.setDecision(nil)
        }
        view.needsLayout = true
    }

    /// The pane's zoom: the shared one, centred on the targeted person's face in that pane's
    /// frame when the panes are zoomed to a face.
    private func zoom(for frame: String?) -> LoupeZoom {
        guard case .zoomed(let factor, _) = model.reviewZoom else { return .fit }
        if let row = model.reviewFaceRow, let frame, let strip = model.currentFaceStrip,
           let centre = model.faceCentre(row: row, in: strip, frame: frame) {
            return .zoomed(factor: factor, centre: centre)
        }
        return model.reviewZoom
    }

    private func faceBoxes(_ photo: PhotoItem?, row: Int?, layout: FaceStripLayout) -> [LoupeFaceBox] {
        guard let photo, let scores = photo.scores else { return [] }
        let state = model.state
        let main = Set(state.summary(for: photo.id)?.mainFaces ?? [])
        let column = layout.columns.firstIndex(of: photo.id)
        let targeted = row.flatMap { row in column.flatMap { layout.cells.indices.contains(row) ? layout.cells[row][$0]?.face : nil } }
        return scores.faces.enumerated().map { index, face in
            LoupeFaceBox(
                box: face.box, isMain: main.contains(index),
                eyesClosed: LoupeTarget.eyesLookClosed(face, tuning: state.tuning) == true,
                isTargeted: targeted == index && model.reviewZoom.isZoomed
            )
        }
    }

    private func tileContent(_ id: String, stack: PhotoStack, strip: FaceStrip?) -> TileContent? {
        let state = model.state
        guard let photo = state.photo(id) else { return nil }
        var content = TileContent(
            item: photo, badges: state.badges(for: id), stackSize: nil, duplicate: nil,
            isSelected: false, isFocused: model.focus == id
        )
        content.notes = StackReview.notes(for: id, in: stack, state: state, strip: strip)
            .filter(\.isRelative).map { TileReason(note: $0) }
        return content
    }

    /// The height of the strip and the frames under the panes, so notes float above them.
    var bottomHeight: CGFloat {
        StackFilmstripView.height + 1 + stripHeight.constant + stripSeparatorHeight.constant
    }

    /// Called when `bottomHeight` changes.
    var onBottomHeightChange: ((CGFloat) -> Void)?

    private func updateStripHeight() {
        defer { onBottomHeightChange?(bottomHeight) }
        guard let strip else { return }
        // At most about a third of the screen, at least one row: the photos keep the rest. A
        // hidden strip and its separator take no height, so the frames grow into it.
        let available = view.bounds.height - Self.headerHeight - StackFilmstripView.height
        let shown = screenLayout.showsFaceStrip && !strip.isHidden
        let height = shown
            ? CGFloat(screenLayout.faceStripHeight(ideal: strip.idealHeight, minimum: strip.minimumHeight, available: available))
            : 0
        if abs(stripHeight.constant - height) > 0.5 { stripHeight.constant = height }
        let separator: CGFloat = shown ? 1 : 0
        if stripSeparatorHeight.constant != separator { stripSeparatorHeight.constant = separator }
    }

    private func deactivate() {
        currentPane.release()
        pickPane.release()
        crops.want([])
        shownStackID = nil
        shownFrame = nil
        pending = nil
    }

    /// Notes how long the last Return or step took to show everything sharp.
    private func checkTimings() {
        guard let pending, isActive else { return }
        guard currentPane.isSharp, !screenLayout.showsPickPane || pickPane.isSharp, filmstrip.tilesWithoutImage(model: model) == 0 else { return }
        if !strip.isHidden, strip.layout.cells.contains(where: { $0.contains { $0 != nil } }), strip.firstCropsMs == nil { return }
        let ms = (CACurrentMediaTime() - pending.at) * 1000
        if pending.kind == "stack" {
            lastStackShownMs = ms
            stackShownTimes.append(ms)
            if stackShownTimes.count > 200 { stackShownTimes.removeFirst() }
        } else {
            lastFrameShownMs = ms
        }
        self.pending = nil
    }

    // MARK: Automation

    var isSettled: Bool {
        guard isActive else { return true }
        if model.stackReviewDone { return true }
        return currentPane.isSettled && (!screenLayout.showsPickPane || pickPane.isSettled) && filmstrip.tilesWithoutImage(model: model) == 0 && (strip.isHidden || !crops.isBusy)
    }

    func dumpState() -> [String: Any] {
        let state = model.state
        var dump: [String: Any] = ["active": isActive, "done": model.stackReviewDone]
        if let stack = model.currentStack, let index = state.stackIndex(containing: stack.id) {
            dump["stackIndex"] = index
            dump["stackCount"] = state.stacks.count
            dump["stacksLeft"] = state.stackCounts.left
            dump["frames"] = stack.members
            dump["current"] = model.focus ?? NSNull()
            dump["pick"] = stack.bestPick ?? NSNull()
            dump["handPicked"] = state.isHandPicked(stack)
            if let panes = model.stackPanes {
                dump["rightPane"] = panes.other ?? NSNull()
                dump["rightPaneRole"] = panes.role == .runnerUp ? "runnerUp" : "bestPick"
            }
            dump["currentNotes"] = model.focus.map { StackReview.notes(for: $0, in: stack, state: state, strip: model.currentFaceStrip).map(\.text) } ?? []
            dump["pickReason"] = StackReview.pickReason(of: stack, state: state) ?? NSNull()
            dump["title"] = StackReview.title(index: index, count: state.stacks.count, frames: stack.members.count)
        }
        dump["origin"] = model.reviewOrigin.map { $0.viewMode.rawValue } ?? NSNull()
        dump["zoom"] = model.reviewZoom.factor.map { ["factor": $0, "centre": [model.reviewZoom.centre!.x, model.reviewZoom.centre!.y]] as [String: Any] } ?? "fit"
        dump["faceRow"] = model.reviewFaceRow ?? NSNull()
        dump["currentPane"] = currentPane.dumpState()
        dump["pickPane"] = pickPane.dumpState()
        dump["hints"] = KeyText.stackReviewHints(
            model.settings.keyBindings, pickPaneShown: model.settings.showsBestPickPane, facesShown: model.faceStripInStackReview
        )
        dump["faceStripShown"] = !strip.isHidden
        dump["faceStripWanted"] = model.faceStripInStackReview
        dump["faceBoxesShown"] = screenLayout.showsFaceBoxes
        dump["faceBoxesEnabled"] = model.isEnabled(.toggleFaceBoxes)
        dump["currentPaneFaceBoxes"] = currentPane.imageView.document.faceCount
        dump["pickPaneFaceBoxes"] = pickPane.isHidden ? 0 : pickPane.imageView.document.faceCount
        dump["faceStripHeight"] = Int(strip.frame.height.rounded())
        dump["faceStripSeparatorHeight"] = Int(stripSeparator.frame.height.rounded())
        dump["panesHeight"] = Int(panesRow.frame.height.rounded())
        dump["panesWidth"] = Int(panesRow.frame.width.rounded())
        dump["pickPaneShown"] = !pickPane.isHidden
        dump["currentPaneSize"] = [Int(currentPane.frame.width.rounded()), Int(currentPane.frame.height.rounded())]
        dump["pickPaneSize"] = pickPane.isHidden ? [0, 0] : [Int(pickPane.frame.width.rounded()), Int(pickPane.frame.height.rounded())]
        dump["currentPaneFillsRow"] = abs(currentPane.frame.width - panesRow.frame.width) < 0.5
        dump["bottomHeight"] = Int(bottomHeight.rounded())
        // The header, the panes and what is under them fill the screen exactly: nothing hidden
        // holds space.
        dump["spaceAccounted"] = abs(Self.headerHeight + panesRow.frame.height + bottomHeight - view.bounds.height) < 0.5
        dump["filmstrip"] = filmstrip.ids
        if let value = lastStackShownMs { dump["lastStackShownMs"] = (value * 10).rounded() / 10 }
        if let value = lastFrameShownMs { dump["lastFrameShownMs"] = (value * 10).rounded() / 10 }
        if !stackShownTimes.isEmpty {
            let sorted = stackShownTimes.sorted()
            dump["stackShownMedianMs"] = (sorted[sorted.count / 2] * 10).rounded() / 10
            dump["stackShownMaxMs"] = ((sorted.last ?? 0) * 10).rounded() / 10
            dump["stackShownCount"] = sorted.count
        }
        return dump
    }
}

/// What a pane's caption says.
struct PaneCaption: View {
    enum Role {
        case current, currentIsPick, pick, runnerUp, compare, compareFocused
    }

    let role: Role
    let name: String
    let detail: String
    var handPicked = false
    var decision: Decision?
    var detailIsReason = false

    var body: some View {
        HStack(spacing: 7) {
            switch role {
            case .current:
                Text(localized("Current frame")).font(.system(size: 12, weight: .semibold))
            case .currentIsPick:
                Label(handPicked ? localized("Current frame · best pick · yours") : localized("Current frame · best pick"), systemImage: "star.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .labelStyle(StarLabelStyle())
            case .pick:
                Label(handPicked ? localized("Best pick · yours") : localized("caption.bestPick", default: "Best pick"), systemImage: "star.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .labelStyle(StarLabelStyle())
            case .runnerUp:
                Text(localized("Runner-up")).font(.system(size: 12, weight: .semibold))
            case .compare, .compareFocused:
                EmptyView()
            }
            Text(name)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(-1)
            if !detail.isEmpty {
                HStack(spacing: 4) {
                    if role == .current || role == .runnerUp {
                        Circle().fill(Palette.flaggedColor).frame(width: 6, height: 6)
                    }
                    Text(detail)
                        .font(.system(size: 11, weight: role == .current || role == .runnerUp ? .medium : .regular))
                        .foregroundStyle(role == .current || role == .runnerUp ? AnyShapeStyle(Palette.flaggedColor) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
                .help(detail)
            }
            Spacer(minLength: 4)
            if let decision, decision != .unreviewed {
                DecisionChip(decision: decision)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.windowBackgroundColor)
    }
}

/// A star in amber before the title, as on the tiles.
struct StarLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.foregroundStyle(Palette.flaggedColor).font(.system(size: 10))
            configuration.title
        }
    }
}

/// The bar along the top of stack review: "Stack 12 of 86 · 7 frames", the capture time span,
/// how many stacks are left (quietly), and the keys.
struct StackReviewHeader: View {
    let model: SessionModel

    var body: some View {
        let session = model.session
        HStack(spacing: 10) {
            if let origin = model.reviewOrigin {
                Button {
                    model.perform(.back)
                } label: {
                    Label(origin.viewMode == .grid ? model.group.title : localized("button.back", default: "Back"), systemImage: "chevron.left")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderless)
                .help(KeyText.backHelp(to: .group(model.group), commands: [.back], in: model.settings.keyBindings))
            }
            if model.stackReviewDone {
                Text(localized("All \(session.stacks.count) stacks decided"))
                    .font(.system(size: 13, weight: .semibold))
            } else if let stack = model.currentStack, let index = session.stackIndex(containing: stack.id) {
                Text(StackReview.title(index: index, count: session.stacks.count, frames: stack.members.count))
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .fixedSize()
                if let span = StackReview.timeSpan(of: stack, state: session) {
                    Text(verbatim: span.start.formatted(Date.FormatStyle(date: .omitted, time: .standard).locale(Localization.locale))
                         + " · " + StackReview.durationText(span.duration))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                let counts = session.stackCounts
                HStack(spacing: 6) {
                    ProgressView(value: Double(counts.total - counts.left), total: Double(max(counts.total, 1)))
                        .progressViewStyle(.linear)
                        .controlSize(.mini)
                        .frame(width: 54)
                    Text(counts.left == 0 ? localized("all decided") : localized("stacks.left", default: "\(counts.left) left"))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                .fixedSize()
                .help(localized("\(counts.total - counts.left) of \(counts.total) stacks decided"))
            }
            Spacer(minLength: 8)
            HintLine(hints)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .layoutPriority(-1)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.panelBackgroundColor)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.separatorColor).frame(height: 1) }
    }

    /// The keys, from the live key map.
    private var hints: String {
        KeyText.stackReviewHints(
            model.settings.keyBindings, pickPaneShown: model.settings.showsBestPickPane, facesShown: model.faceStripInStackReview
        )
    }
}

/// Over the panes once every stack has a decision: says so, and offers the next group.
struct StackReviewDoneView: View {
    let model: SessionModel

    var body: some View {
        let session = model.session
        let counts = session.stackCounts
        let frames = session.count(of: .similarStacks)
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Palette.keptColor)
            Text(localized("Every stack has a decision"))
                .font(.title3.weight(.semibold))
            Text(localized("\(counts.total) stacks · \(frames.total) photos. Any decision can still be changed."))
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
                Button(localized("Review Stacks Again")) {
                    if let first = session.stacks.first { model.showStack(first) }
                }
                .controlSize(.large)
            }
            .padding(.top, 4)
            if model.nextGroupToReview == nil {
                Text(localized("Nothing is left to review in any group."))
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
        .multilineTextAlignment(.center)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.gridBackgroundColor)
    }
}
