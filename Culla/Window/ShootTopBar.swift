import AppKit
import CullaCommands
import CullaCore
import SwiftUI

/// The shoot window's top bar, left to right after the window buttons: the shoot's name and photo
/// count; Open; the view switch (Grid, Loupe, Compare); the analysis status; the thumbnail size
/// slider; Review and Apply; the inspector toggle. Every control sends a `Command` and is enabled
/// when the model says the command is available.
///
/// It is the app's own view, not an `NSToolbar`: from macOS 26 the system draws every toolbar
/// item in a glass capsule, and Culla's chrome is flat and opaque so nothing tints the photos.
/// The window keeps an empty toolbar only so the title bar is tall enough to centre the window
/// buttons on the bar (see `MainWindowController`).
///
/// The bar is laid out by hand (`layoutBar`), because what gives way when the window is narrow
/// depends on how long the text is in the interface's language. Open, the view switch, the size
/// slider, Review and Apply and the inspector toggle always keep their full size.
@MainActor
final class ShootTopBar: NSObject {
    private let app: AppModel
    let view = TopBarView()
    private var observation: ObservationToken?
    private var accessibilityObserver: NSObjectProtocol?

    private let titleLabel = TopBarLabel(size: 13, weight: .semibold, color: .labelColor)
    private let countLabel = TopBarLabel(size: 12, weight: .regular, color: .secondaryLabelColor)
    private let openButton = TopBarButton(style: .ghost)
    private let viewSwitch = ViewSwitchControl()
    private let sizeSlider = NSSlider()
    private let sizeControl = NSStackView()
    private let reviewButton = TopBarButton(style: .primary)
    private let inspectorButton = TopBarButton(style: .ghost)
    private let statusHost: NSHostingView<ToolbarStatusView>
    private let statusLayout = TopBarStatusLayout()
    private var leadingInset = TopBarStyle.sideMargin
    /// The analysis line the bar was last laid out for, and its phase.
    private var statusText = ""
    private var statusPhase: AnalysisStatusView.Shape = .none

    private static let modes: [(ViewMode, String, String, Command)] = [
        (.grid, "square.grid.2x2", localized("toolbar.grid", default: "Grid"), .showGrid),
        (.loupe, "rectangle", localized("toolbar.loupe", default: "Loupe"), .showLoupe),
        (.compare, "rectangle.split.2x1", localized("toolbar.compare", default: "Compare"), .showCompare),
    ]

    private static let sliderWidth: CGFloat = 96
    private static let sizeControlSpacing: CGFloat = 6
    /// The shoot's name is cut to this before the analysis line gives up any of its text.
    private static let titleMinimum: CGFloat = 80
    /// Below this the name is not worth showing; the window's title (read by the Window menu,
    /// Mission Control and VoiceOver) still carries it.
    private static let titleHiddenBelow: CGFloat = 24

    init(app: AppModel) {
        self.app = app
        statusHost = NSHostingView(rootView: ToolbarStatusView(app: app, layout: statusLayout))
        super.init()
        configureControls()
        for control in [titleLabel, countLabel, openButton, viewSwitch, statusHost, sizeControl, reviewButton, inspectorButton] as [NSView] {
            // Placed by `layoutBar`, not by constraints.
            control.translatesAutoresizingMaskIntoConstraints = true
            view.addSubview(control)
        }
        view.onLayout = { [weak self] in self?.layoutBar() }
        observation = observeChanges { [weak self] in self?.update() }
        accessibilityObserver = NotificationCenter.default.addObserver(forName: SystemAccessibility.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.view.redrawAll() }
        }
    }

    private func configureControls() {
        let open = localized("toolbar.open", default: "Open")
        openButton.image = NSImage(systemSymbolName: "folder", accessibilityDescription: open)
        openButton.setAccessibilityLabel(open)
        openButton.toolTip = Self.toolTip(localized("Open a shoot folder"), .openFolder, app: app)
        openButton.target = self
        openButton.action = #selector(openFolder)

        viewSwitch.segmentCount = Self.modes.count
        viewSwitch.trackingMode = .selectOne
        viewSwitch.segmentStyle = .automatic
        for (index, mode) in Self.modes.enumerated() {
            let image = NSImage(systemSymbolName: mode.1, accessibilityDescription: mode.2)
            viewSwitch.setImage(image, forSegment: index)
            viewSwitch.setWidth(ViewSwitchControl.segmentWidth, forSegment: index)
            viewSwitch.setToolTip(Self.toolTip(mode.2, mode.3, app: app), forSegment: index)
        }
        viewSwitch.target = self
        viewSwitch.action = #selector(viewSwitchChanged(_:))
        let viewName = localized("toolbar.view", default: "View")
        viewSwitch.setAccessibilityLabel(viewName)
        viewSwitch.cell?.setAccessibilityLabel(viewName)
        viewSwitch.setAccessibilityHelp(localized("Grid, Loupe or Compare"))

        let sizeName = localized("toolbar.thumbnailSizeDescription", default: "Thumbnail size")
        sizeSlider.cell = TopBarSliderCell()
        sizeSlider.minValue = AppSettings.thumbnailSizeRange.lowerBound
        sizeSlider.maxValue = AppSettings.thumbnailSizeRange.upperBound
        sizeSlider.controlSize = .small
        sizeSlider.isContinuous = true
        sizeSlider.target = self
        sizeSlider.action = #selector(sizeChanged(_:))
        sizeSlider.setAccessibilityLabel(sizeName)
        sizeSlider.cell?.setAccessibilityLabel(sizeName)
        sizeSlider.toolTip = sizeName
        sizeSlider.translatesAutoresizingMaskIntoConstraints = false
        sizeSlider.widthAnchor.constraint(equalToConstant: Self.sliderWidth).isActive = true
        sizeControl.setViews([Self.glyph(pointSize: 9), sizeSlider, Self.glyph(pointSize: 13)], in: .leading)
        sizeControl.orientation = .horizontal
        sizeControl.alignment = .centerY
        sizeControl.spacing = Self.sizeControlSpacing
        sizeControl.setHuggingPriority(.required, for: .horizontal)

        reviewButton.title = localized("toolbar.reviewAndApply", default: "Review and Apply")
        reviewButton.toolTip = Self.toolTip(localized("Review the rejects, then move or mark them"), .reviewAndApply, app: app)
        reviewButton.target = self
        reviewButton.action = #selector(reviewAndApply)

        let showHide = localized("Show or hide the inspector")
        inspectorButton.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: showHide)
        let inspector = localized("toolbar.inspector", default: "Inspector")
        inspectorButton.setAccessibilityLabel(inspector)
        inspectorButton.cell?.setAccessibilityLabel(inspector)
        inspectorButton.toolTip = Self.toolTip(showHide, .toggleInspector, app: app)
        inspectorButton.target = self
        inspectorButton.action = #selector(toggleInspector)

        statusHost.sizingOptions = []
        // It sits where the title bar is: no safe area to keep clear of.
        statusHost.safeAreaRegions = []
    }

    /// Where the bar's content starts: after the window buttons, or at the margin when they are
    /// not there (full screen).
    func setLeadingInset(_ inset: CGFloat) {
        guard leadingInset != inset else { return }
        leadingInset = inset
        view.needsLayout = true
    }

    /// A photo glyph beside the size slider, at the symbol's own size, hidden from VoiceOver (it
    /// only says "small" or "large").
    private static func glyph(pointSize: CGFloat) -> NSImageView {
        let symbol = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular))!
        let view = NSImageView(image: symbol)
        view.imageScaling = .scaleNone
        view.contentTintColor = .secondaryLabelColor
        view.translatesAutoresizingMaskIntoConstraints = false
        let size = symbol.size
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: size.width.rounded(.up)),
            view.heightAnchor.constraint(equalToConstant: size.height.rounded(.up)),
        ])
        for orientation in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            view.setContentHuggingPriority(.required, for: orientation)
            view.setContentCompressionResistancePriority(.required, for: orientation)
        }
        view.setAccessibilityElement(false)
        view.cell?.setAccessibilityElement(false)
        return view
    }

    private static func toolTip(_ title: String, _ command: Command, app: AppModel) -> String {
        guard let chord = app.settings.keyBindings.primaryChord(for: command) else { return title }
        let key = chord.displayString
        return localized("tooltip.withKey", default: "\(title) (\(key))")
    }

    // MARK: Layout

    /// Places every control. From the trailing edge: the inspector toggle, Review and Apply and
    /// the size slider, always whole. From the leading edge: the shoot's name and photo count,
    /// then Open and the view switch, always whole. The analysis line sits in the middle of the
    /// bar when there is room, or as near the middle as the controls on either side allow.
    ///
    /// When the window is too narrow for everything, things give way in this order:
    /// 1. the analysis line leaves the middle of the bar (it moves, but keeps all its text);
    /// 2. the photo count goes;
    /// 3. the shoot's name is cut short, down to `titleMinimum`;
    /// 4. the analysis line's text is cut short, down to `AnalysisStatusView.textMinimum`;
    /// 5. the analysis line drops its text and keeps only its icon and the pause or resume
    ///    button; the text moves into its tooltip and to VoiceOver;
    /// 6. the shoot's name is cut further, and goes when it would be too short to read.
    private func layoutBar() {
        let bounds = view.bounds
        let height = TopBarStyle.controlHeight
        let midY = bounds.midY
        func centred(_ x: CGFloat, _ width: CGFloat, _ h: CGFloat = height) -> NSRect {
            view.backingAlignedRect(NSRect(x: x, y: midY - h / 2, width: width, height: h), options: .alignAllEdgesNearest)
        }
        let spacing = TopBarStyle.controlSpacing
        let group = TopBarStyle.groupSpacing

        // Trailing: always whole.
        let inspectorX = bounds.maxX - TopBarStyle.sideMargin - height
        let reviewWidth = reviewButton.intrinsicContentSize.width
        let reviewX = inspectorX - spacing - reviewWidth
        let sizeWidth = sizeControl.fittingSize.width.rounded(.up)
        let sizeX = reviewX - group - sizeWidth
        inspectorButton.frame = centred(inspectorX, height)
        reviewButton.frame = centred(reviewX, reviewWidth)
        sizeControl.frame = centred(sizeX, sizeWidth, sizeControl.fittingSize.height.rounded(.up))

        // What the leading text and the analysis line share.
        let switchWidth = viewSwitch.intrinsicContentSize.width
        let fixedLeading = group + height + spacing + switchWidth
        let showsStatus = statusPhase != .none
        let statusGaps = showsStatus ? group * 2 : group
        let free = max(0, sizeX - leadingInset - fixedLeading - statusGaps)

        let titleNatural = Self.naturalWidth(of: titleLabel)
        let countNatural = Self.naturalWidth(of: countLabel)
        let countBlock = countNatural > 0 ? spacing + countNatural : 0
        let titleMinimum = min(titleNatural, Self.titleMinimum)
        let widths = showsStatus ? AnalysisStatusView.widths(text: statusText, shape: statusPhase) : (natural: 0, minimum: 0, compact: 0)

        var titleWidth = titleNatural
        var showsCount = countNatural > 0
        var statusWidth = widths.natural
        var compact = false
        if titleNatural + countBlock + widths.natural <= free {
            // Everything whole.
        } else if titleNatural + widths.natural <= free {
            showsCount = false
        } else if titleMinimum + widths.natural <= free {
            showsCount = false
            titleWidth = free - widths.natural
        } else if titleMinimum + widths.minimum <= free {
            showsCount = false
            titleWidth = titleMinimum
            statusWidth = free - titleMinimum
        } else {
            showsCount = false
            compact = true
            statusWidth = widths.compact
            titleWidth = max(0, min(titleNatural, free - widths.compact))
        }
        let showsTitle = titleWidth >= min(titleNatural, Self.titleHiddenBelow) && titleNatural > 0

        // Leading: the name, the count, Open and the view switch.
        var x = leadingInset
        titleLabel.isHidden = !showsTitle
        if showsTitle {
            let titleHeight = titleLabel.cell?.cellSize.height ?? 16
            titleLabel.frame = centred(x, titleWidth, titleHeight)
            x = titleLabel.frame.maxX
        }
        countLabel.isHidden = !showsCount || !showsTitle
        if !countLabel.isHidden {
            // On the name's baseline.
            let baseline = titleLabel.frame.maxY - titleLabel.firstBaselineOffsetFromTop
            let countHeight = countLabel.cell?.cellSize.height ?? 15
            let y = baseline + countLabel.firstBaselineOffsetFromTop - countHeight
            countLabel.frame = view.backingAlignedRect(NSRect(x: x + spacing, y: y, width: countNatural, height: countHeight), options: .alignAllEdgesNearest)
            x = countLabel.frame.maxX
        }
        if showsTitle { x += group }
        openButton.frame = centred(x, height)
        viewSwitch.frame = centred(openButton.frame.maxX + spacing, switchWidth)

        // The analysis line: centred on the bar when it fits there, else as near as it can be.
        if statusLayout.compact != compact { statusLayout.compact = compact }
        let lower = viewSwitch.frame.maxX + group
        let upper = sizeX - group
        statusWidth = max(0, min(statusWidth, upper - lower))
        let statusX = min(max(bounds.midX - statusWidth / 2, lower), upper - statusWidth)
        statusHost.frame = centred(statusX, statusWidth)
    }

    /// A label's width with all its text on one line. (A truncating label's intrinsic size
    /// follows its current frame, so it cannot say how much room the text wants.)
    private static func naturalWidth(of label: NSTextField) -> CGFloat {
        guard !label.stringValue.isEmpty, let cell = label.cell else { return 0 }
        return cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: 100_000, height: 100)).width.rounded(.up)
    }

    // MARK: Following the model

    private func update() {
        switch app.screen {
        case .welcome:
            titleLabel.stringValue = ""
            countLabel.stringValue = ""
        case .loading(let info):
            titleLabel.stringValue = info.name
            countLabel.stringValue = ""
        case .shoot(let session):
            titleLabel.stringValue = session.name
            countLabel.stringValue = Formatting.photos(session.session.count)
        }
        openButton.isEnabled = app.isEnabled(.openFolder)
        reviewButton.isEnabled = app.isEnabled(.reviewAndApply)
        inspectorButton.isEnabled = app.isEnabled(.toggleInspector)
        defer { view.needsLayout = true }
        guard let session = app.session else {
            statusHost.isHidden = true
            statusText = ""
            statusPhase = .none
            viewSwitch.selectedSegment = -1
            for index in Self.modes.indices { viewSwitch.setEnabled(false, forSegment: index) }
            sizeSlider.isEnabled = false
            inspectorButton.isOn = false
            viewSwitch.needsDisplay = true
            return
        }
        statusHost.isHidden = false
        if let analysis = session.analysis {
            statusText = analysis.statusText
            statusPhase = AnalysisStatusView.Shape(analysis.phase)
        } else {
            statusText = ""
            statusPhase = .none
        }
        let mode = session.viewMode
        if let index = Self.modes.firstIndex(where: { $0.0 == mode }) {
            viewSwitch.selectedSegment = index
        } else {
            // Stack and duplicate review are the group's own view, none of the three.
            viewSwitch.selectedSegment = -1
        }
        _ = session.selection
        _ = session.compareIDs
        for (index, entry) in Self.modes.enumerated() {
            viewSwitch.setEnabled(entry.0 == mode || app.isEnabled(entry.3), forSegment: index)
        }
        viewSwitch.needsDisplay = true
        sizeSlider.doubleValue = app.settings.thumbnailSize
        sizeSlider.isEnabled = mode == .grid
        inspectorButton.isOn = session.inspectorVisible
        _ = session.revision
    }

    // MARK: Actions

    @objc private func viewSwitchChanged(_ sender: NSSegmentedControl) {
        let index = sender.selectedSegment
        guard Self.modes.indices.contains(index) else { return }
        app.perform(Self.modes[index].3)
        update()
    }

    @objc private func sizeChanged(_ sender: NSSlider) {
        app.settings.thumbnailSize = sender.doubleValue.rounded()
    }

    @objc private func openFolder() { app.perform(.openFolder) }
    @objc private func reviewAndApply() { app.perform(.reviewAndApply) }
    @objc private func toggleInspector() { app.perform(.toggleInspector) }
}

/// Whether the bar's analysis line has room for its text, set by the bar's layout.
@MainActor
@Observable
final class TopBarStatusLayout {
    var compact = false
}

/// The bar's middle slot: analysis progress. "Analysing 420 of 1,240 · about 2 min left" with a
/// pause button right after it while it runs, "Paused" with a resume button, and a quiet
/// "Analysed" when it is done. Plain text on the bar, its digits monospaced so it never jitters.
/// The bar gives it the width its text needs (`AnalysisStatusView.widths`) and centres it; when
/// the window is narrow the text is cut short, and then left out (`compact`), its words moving
/// into the tooltip.
struct ToolbarStatusView: View {
    let app: AppModel
    let layout: TopBarStatusLayout

    var body: some View {
        Group {
            if let analysis = app.session?.analysis {
                AnalysisStatusView(analysis: analysis, shortcut: app.settings.keyBindings.primaryChord(for: .toggleAnalysis)?.displayString, compact: layout.compact)
            } else {
                Color.clear.accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: TopBarStyle.controlHeight)
    }
}

struct AnalysisStatusView: View {
    let analysis: AnalysisController
    let shortcut: String?
    var compact = false

    /// The parts of the line, measured by the bar to lay it out.
    static let horizontalPadding: CGFloat = 4
    static let iconSize: CGFloat = 13
    static let iconSpacing: CGFloat = 7
    /// Between the text and the pause or resume button.
    static let buttonSpacing: CGFloat = 8
    static let buttonSize: CGFloat = 24
    static let fontSize: CGFloat = 12
    /// The text is cut no shorter than this before it is left out.
    static let textMinimum: CGFloat = 90

    /// What the line holds, for measuring it.
    enum Shape: Equatable {
        case none, withButton, iconOnly

        init(_ phase: AnalysisController.Phase) {
            switch phase {
            case .starting, .running, .paused: self = .withButton
            case .finished: self = .iconOnly
            case .cancelled: self = .none
            }
        }
    }

    /// The line's width with its whole text, with its text cut to `textMinimum`, and without
    /// text. The text is measured with the font the line draws it in, plus a point or two so
    /// rounding never cuts it.
    @MainActor static func widths(text: String, shape: Shape) -> (natural: CGFloat, minimum: CGFloat, compact: CGFloat) {
        guard shape != .none else { return (0, 0, 0) }
        let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
        let textWidth = text.isEmpty ? 0 : ((text as NSString).size(withAttributes: [.font: font]).width + 2).rounded(.up)
        let button = shape == .withButton ? buttonSpacing + buttonSize : 0
        let compact = horizontalPadding * 2 + iconSize + button
        let withText = compact + iconSpacing
        return (withText + textWidth, withText + min(textWidth, textMinimum), compact)
    }

    var body: some View {
        HStack(spacing: 0) {
            switch analysis.phase {
            case .starting, .running:
                icon(ProgressRing(fraction: analysis.checkedFraction).frame(width: 12, height: 12))
                line
                toggleButton(symbol: "pause.fill", title: localized("Pause analysis"))
            case .paused:
                icon(Image(systemName: "pause.circle").font(.system(size: Self.fontSize)).foregroundStyle(.secondary))
                line
                toggleButton(symbol: "play.fill", title: localized("Resume analysis"))
            case .finished:
                icon(Image(systemName: "checkmark.circle").font(.system(size: Self.fontSize)).foregroundStyle(.tertiary))
                line
            case .cancelled:
                EmptyView()
            }
        }
        .padding(.horizontal, Self.horizontalPadding)
        .frame(maxWidth: .infinity)
        .help(helpText)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(localized("toolbar.analysis", default: "Analysis")))
    }

    /// The phase's icon; without the text, it carries the text for VoiceOver.
    @ViewBuilder private func icon(_ content: some View) -> some View {
        let framed = content.frame(width: Self.iconSize, height: Self.iconSize)
        if compact {
            framed.accessibilityElement().accessibilityLabel(Text(analysis.statusText))
        } else {
            framed
        }
    }

    @ViewBuilder private var line: some View {
        if !compact {
            Text(analysis.statusText)
                .font(.system(size: Self.fontSize))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, Self.iconSpacing)
        }
    }

    private func toggleButton(symbol: String, title: String) -> some View {
        Button {
            analysis.togglePause()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: Self.buttonSize, height: Self.buttonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(GhostIconButtonStyle())
        .help(shortcut.map { localized("tooltip.withKey", default: "\(title) (\($0))") } ?? title)
        .accessibilityLabel(Text(title))
        .padding(.leading, Self.buttonSpacing)
    }

    private var helpText: String {
        let progress = analysis.progress
        var parts: [String] = []
        // Without its text, the line's words are here.
        if compact { parts.append(analysis.statusText) }
        if progress.cached > 0 { parts.append(localized("\(progress.cached) from earlier")) }
        if progress.total > 0 { parts.append(localized("\(progress.done) of \(progress.total) analysed now")) }
        parts.append(localized("\(analysis.concurrency) at a time"))
        return parts.joined(separator: " · ")
    }
}

/// The SwiftUI form of the bar's ghost button: no border or fill at rest, a soft fill under the
/// pointer and while pressed, and a 1 pt outline with Increase Contrast.
struct GhostIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        GhostIconButton(configuration: configuration)
    }

    private struct GhostIconButton: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.colorSchemeContrast) private var contrast

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: TopBarStyle.buttonRadius, style: .continuous)
            configuration.label
                .foregroundStyle(isEnabled ? (hovering || configuration.isPressed ? .primary : .secondary) : .tertiary)
                .background(shape.fill(fill))
                .overlay(shape.strokeBorder(Color(nsColor: TopBarStyle.contrastBorder), lineWidth: contrast == .increased || SystemAccessibility.increaseContrast ? 1 : 0))
                .onHover { hovering = $0 }
        }

        private var fill: Color {
            guard isEnabled else { return .clear }
            if configuration.isPressed { return Color(nsColor: TopBarStyle.pressedFill) }
            if hovering { return Color(nsColor: TopBarStyle.hoverFill) }
            return .clear
        }
    }
}
