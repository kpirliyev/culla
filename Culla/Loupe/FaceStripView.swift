import AppKit
import CullaAnalysis
import CullaCommands
import CullaCore
import CullaSession

/// What the face strip shows: a row per person and a column per frame, built from a `FaceStrip`.
struct FaceStripLayout: Equatable {
    struct Cell: Equatable {
        var photoID: String
        var face: Int
        var box: UnitRect
        var eyesClosed: Bool
        var help: String
    }

    var title: String
    var subtitle: String
    var rowLabels: [String]
    /// The photo of each column.
    var columns: [String]
    /// `cells[row][column]`, nil where the person is not found in that frame.
    var cells: [[Cell?]]
    var currentColumn: Int?
    var pickColumn: Int?
    /// True when the rows are faces by position, not people.
    var byPosition: Bool
    /// True for one photo's faces in a row (a photo in no stack): columns are faces, not frames.
    var singlePhoto = false

    var isEmpty: Bool { rowLabels.isEmpty }

    /// The strip of a stack (or of one photo, `single`), as the model's session has it.
    @MainActor
    static func make(model: SessionModel, for id: String) -> FaceStripLayout {
        let state = model.state
        let strip = model.faceStrip(forPhoto: id)
        let tuning = state.tuning
        let pick = state.stack(containing: id)?.bestPick
        let byPosition = strip.matching.method == .positionOrder
        func cell(_ photoID: String, _ face: Int?, person: String) -> Cell? {
            guard let face, let scores = state.photo(photoID)?.scores, scores.faces.indices.contains(face) else { return nil }
            let faceScores = scores.faces[face]
            let closed = LoupeTarget.eyesLookClosed(faceScores, tuning: tuning) == true
            let openness = faceScores.eyeOpenness(countWinkAsClosed: tuning.countWinkAsClosed)
            let eyes = openness.map { value in
                let number = Localization.decimal(value, fractionDigits: 2)
                return closed ? localized("eyes \(number), closed") : localized("eyes \(number)")
            } ?? localized("eyes not measured")
            let name = state.photo(photoID)?.file.name ?? photoID
            return Cell(photoID: photoID, face: face, box: faceScores.box, eyesClosed: closed, help: localized("\(person) in \(name): \(eyes)"))
        }
        if strip.frames.count == 1 {
            // A photo in no stack: its faces in one row.
            let frame = strip.frames[0]
            let faces = strip.matching.rows.compactMap { $0.faces.first ?? nil }
            let cells = faces.enumerated().map { index, face in cell(frame, face, person: localized("Face \(index + 1)")) }
            return FaceStripLayout(
                title: localized("Faces"),
                subtitle: faces.isEmpty ? localized("No faces found in this photo") : localized("Each face of this photo, closed eyes outlined in amber"),
                rowLabels: faces.isEmpty ? [] : [localized("Faces")], columns: faces.map { _ in frame }, cells: faces.isEmpty ? [] : [cells],
                currentColumn: nil, pickColumn: nil, byPosition: false, singlePhoto: true
            )
        }
        let labels = strip.matching.rows.indices.map { row in
            byPosition ? localized("\(Self.ordinal(row + 1)) from left") : localized("Person \(row + 1)")
        }
        let cells = strip.matching.rows.enumerated().map { row, faceRow in
            strip.frames.enumerated().map { column, frame in cell(frame, faceRow.faces[column], person: labels[row]) }
        }
        let subtitle: String
        if strip.matching.rows.isEmpty {
            subtitle = localized("No faces found in these frames")
        } else if byPosition {
            subtitle = localized("Faces in left-to-right order: Culla could not follow each person from frame to frame")
        } else {
            subtitle = localized("One row per person, one column per frame · white edge: this frame · star: Culla’s pick · amber: closed eyes")
        }
        return FaceStripLayout(
            title: localized("Face strip"), subtitle: subtitle, rowLabels: labels, columns: strip.frames, cells: cells,
            currentColumn: strip.frames.firstIndex(of: id), pickColumn: pick.flatMap { strip.frames.firstIndex(of: $0) },
            byPosition: byPosition
        )
    }

    /// "1st", "2nd" in English, "1-й" in Russian, "1-nji" in Turkmen. The system's ordinal
    /// formatter has no rules for Russian (it gives "1") or Turkmen (it gives "1th"), so those
    /// two are written here: Russian takes "-й" (the row is a person, masculine), Turkmen
    /// "-nji" or "-njy" by the vowel of the number's last word.
    static func ordinal(_ number: Int) -> String {
        switch Localization.language {
        case .english:
            let formatter = NumberFormatter()
            formatter.numberStyle = .ordinal
            formatter.locale = AppLanguage.english.locale
            return formatter.string(from: NSNumber(value: number)) ?? String(number)
        case .russian:
            return "\(number)-й"
        case .turkmen:
            return "\(number)-" + turkmenOrdinalSuffix(number)
        }
    }

    /// The Turkmen ordinal suffix follows the vowels of the number's last word: alty (6),
    /// dokuz (9), on (10), otuz (30), kyrk (40), altmyş (60) and togsan (90) take "-njy"; the
    /// others, ýüz (100) among them, "-nji".
    static func turkmenOrdinalSuffix(_ number: Int) -> String {
        let back: Set<Int> = [6, 9, 10, 30, 40, 60, 90]
        let units = number % 10
        let tens = (number / 10 % 10) * 10
        let last = units != 0 ? units : (tens != 0 ? tens : 100)
        return back.contains(last) ? "njy" : "nji"
    }
}

/// The face strip: a header line, the row labels on the left, and the cells in a scroll view, so
/// many people or many frames scroll instead of pushing the photos off the screen. Columns are
/// `columnWidth` apart, the same as the stack's filmstrip below, so each column sits above its frame.
@MainActor
final class FaceStripView: NSView {
    static let columnWidth: CGFloat = 92
    static let cellSize: CGFloat = 64
    static let rowHeight: CGFloat = 72
    static let labelWidth: CGFloat = 100
    static let headerHeight: CGFloat = 22
    static let gridInset: CGFloat = 4

    let scrollView = NSScrollView()
    private let grid = FaceGridView()
    private let labels = FaceLabelsView()
    private let labelsClip = NSClipView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private(set) var layout = FaceStripLayout(title: "", subtitle: "", rowLabels: [], columns: [], cells: [], currentColumn: nil, pickColumn: nil, byPosition: false)
    let crops: FaceCropStore
    private var shownAt: CFTimeInterval = 0
    private(set) var firstCropsMs: Double?
    private(set) var sharpCropsMs: Double?

    var onCellClick: ((Int, Int) -> Void)? {
        get { grid.onClick }
        set { grid.onClick = newValue }
    }

    /// The height the strip needs to show every row.
    var idealHeight: CGFloat {
        Self.headerHeight + (layout.isEmpty ? 0 : CGFloat(layout.rowLabels.count) * Self.rowHeight + Self.gridInset * 2)
    }

    /// The height of the header and one row: the least the strip is given.
    var minimumHeight: CGFloat {
        Self.headerHeight + (layout.isEmpty ? 0 : Self.rowHeight + Self.gridInset * 2)
    }

    init(crops: FaceCropStore) {
        self.crops = crops
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 120))
        wantsLayer = true
        layer?.backgroundColor = Palette.panelBackground.cgColor
        for field in [title, subtitle] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.lineBreakMode = .byTruncatingTail
            addSubview(field)
        }
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .labelColor
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        scrollView.documentView = grid
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .none
        scrollView.contentView.postsBoundsChangedNotifications = true
        labelsClip.documentView = labels
        labelsClip.drawsBackground = false
        for view in [scrollView, labelsClip] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            subtitle.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 10),
            subtitle.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            labelsClip.leadingAnchor.constraint(equalTo: leadingAnchor),
            labelsClip.widthAnchor.constraint(equalToConstant: Self.labelWidth),
            labelsClip.topAnchor.constraint(equalTo: topAnchor, constant: Self.headerHeight),
            labelsClip.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: labelsClip.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: Self.headerHeight),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled(_:)), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        grid.crops = crops
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(localized("Face strip"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// Shows a layout. Cells keep their crops where the same face stays; new faces show the crop
    /// held for them, or are asked for.
    func show(_ layout: FaceStripLayout, photos: @escaping (String) -> PhotoItem?) {
        let changedFrames = layout.columns != self.layout.columns || layout.cells.map { $0.map { $0?.face } } != self.layout.cells.map { $0.map { $0?.face } }
        self.layout = layout
        title.stringValue = layout.title
        subtitle.stringValue = layout.subtitle
        labels.labels = layout.rowLabels
        grid.photos = photos
        grid.layoutModel = layout
        let width = CGFloat(layout.columns.count) * Self.columnWidth + Self.gridInset * 2
        let height = CGFloat(layout.rowLabels.count) * Self.rowHeight + Self.gridInset * 2
        grid.frame.size = NSSize(width: width, height: height)
        labels.frame.size = NSSize(width: Self.labelWidth, height: height)
        if changedFrames {
            shownAt = CACurrentMediaTime()
            firstCropsMs = nil
            sharpCropsMs = nil
        }
        requestCrops()
        grid.refresh()
        noteTimings()
    }

    /// Asks the crop store for the faces of the columns on screen first, then the rest.
    func requestCrops() {
        let visible = scrollView.contentView.bounds
        var first: [FaceCropStore.Request] = []
        var rest: [FaceCropStore.Request] = []
        let current = layout.currentColumn
        for column in layout.columns.indices {
            let x = Self.gridInset + CGFloat(column) * Self.columnWidth
            let onScreen = x + Self.columnWidth >= visible.minX && x <= visible.maxX
            for row in layout.cells.indices {
                guard let cell = layout.cells[row][column], let request = grid.request(for: cell) else { continue }
                if column == current { first.insert(request, at: 0) } else if onScreen { first.append(request) } else { rest.append(request) }
            }
        }
        // Columns out of view are cut from memory but not decoded: scrolling to them asks again.
        crops.want(first + rest.filter { crops.crop(for: $0) == nil })
    }

    /// Crops arrived: redraw, and note the first and the sharp moments.
    func cropsArrived() {
        grid.refresh()
        noteTimings()
    }

    private func noteTimings() {
        let requests = grid.allRequests
        guard !requests.isEmpty else { return }
        let held = requests.compactMap { crops.crop(for: $0) }
        if firstCropsMs == nil, held.count == requests.count {
            firstCropsMs = (CACurrentMediaTime() - shownAt) * 1000
        }
        if sharpCropsMs == nil, held.count == requests.count, held.allSatisfy(\.sharp) {
            sharpCropsMs = (CACurrentMediaTime() - shownAt) * 1000
        }
    }

    /// Keeps the current column in view.
    func scrollToCurrent() {
        guard let column = layout.currentColumn else { return }
        let x = Self.gridInset + CGFloat(column) * Self.columnWidth
        let visible = scrollView.contentView.bounds
        guard x < visible.minX || x + Self.columnWidth > visible.maxX else { return }
        let target = max(0, min(x + Self.columnWidth / 2 - visible.width / 2, grid.frame.width - visible.width))
        scrollView.contentView.scroll(to: NSPoint(x: target, y: visible.minY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Follows another scroll view's horizontal position (the filmstrip's).
    func setHorizontalOffset(_ x: CGFloat) {
        let clip = scrollView.contentView
        guard abs(clip.bounds.minX - x) > 0.5 else { return }
        clip.scroll(to: NSPoint(x: x, y: clip.bounds.minY))
        scrollView.reflectScrolledClipView(clip)
    }

    var onScroll: ((CGFloat) -> Void)?

    @objc private func scrolled(_ notification: Notification) {
        let bounds = scrollView.contentView.bounds
        labelsClip.scroll(to: NSPoint(x: 0, y: bounds.minY))
        onScroll?(bounds.minX)
        requestCrops()
    }

    // MARK: Automation

    func dumpState() -> [String: Any] {
        let requests = grid.allRequests
        let held = requests.compactMap { crops.crop(for: $0) }
        var state: [String: Any] = [
            "rows": layout.rowLabels.count,
            "rowLabels": layout.rowLabels,
            "columns": layout.columns,
            "filled": layout.cells.map { $0.map { $0 != nil } },
            "outlined": layout.cells.map { $0.map { $0?.eyesClosed == true } },
            "currentColumn": layout.currentColumn ?? NSNull(),
            "pickColumn": layout.pickColumn ?? NSNull(),
            "byPosition": layout.byPosition,
            "subtitle": layout.subtitle,
            "crops": requests.count,
            "cropsShown": held.count,
            "sharpCrops": held.filter(\.sharp).count,
            "decodes": crops.decodes,
            "fullSizeDecodes": crops.fullSizeDecodes,
            "decodeMs": crops.decodeMs.map { ($0 * 10).rounded() / 10 },
            "cropMemoryKB": crops.memoryBytes / 1024,
            "cropsHeld": crops.count,
            "visibleHeight": Int(scrollView.frame.height),
            "contentHeight": Int(grid.frame.height),
        ]
        if let firstCropsMs { state["firstCropsMs"] = (firstCropsMs * 10).rounded() / 10 }
        if let sharpCropsMs { state["sharpCropsMs"] = (sharpCropsMs * 10).rounded() / 10 }
        return state
    }

    /// The frame of a cell in the strip's own coordinates, for clicks by the automation harness.
    func click(row: Int, column: Int) -> Bool {
        guard layout.cells.indices.contains(row), layout.columns.indices.contains(column), layout.cells[row][column] != nil else { return false }
        grid.onClick?(row, column)
        return true
    }
}

/// The row labels: "Person 1", or "1st from left" when faces are matched by position only.
private final class FaceLabelsView: NSView {
    var labels: [String] = [] { didSet { if labels != oldValue { needsDisplay = true } } }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        for (row, label) in labels.enumerated() {
            let y = FaceStripView.gridInset + CGFloat(row) * FaceStripView.rowHeight
            let string = NSAttributedString(string: label, attributes: attributes)
            let size = string.size()
            string.draw(at: NSPoint(x: 14, y: y + (FaceStripView.rowHeight - size.height) / 2))
        }
    }
}

/// The cells, drawn with layers: column backgrounds for the current frame and the pick, each
/// crop with its outline, and a faint empty square where a person is not found.
@MainActor
private final class FaceGridView: NSView {
    var layoutModel = FaceStripLayout(title: "", subtitle: "", rowLabels: [], columns: [], cells: [], currentColumn: nil, pickColumn: nil, byPosition: false)
    var photos: (String) -> PhotoItem? = { _ in nil }
    weak var crops: FaceCropStore?
    var onClick: ((Int, Int) -> Void)?
    private var cellLayers: [CALayer] = []
    private let currentColumnLayer = CALayer()
    private let pickColumnLayer = CALayer()
    /// The best pick's star, at the top of its column, as on the pick's tile.
    private let pickStarLayer = CALayer()
    private var trackingArea: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        for column in [pickColumnLayer, currentColumnLayer] {
            column.actions = LoupeDocumentView.noActions
            column.cornerRadius = 8
            layer?.addSublayer(column)
        }
        // The current frame: a bright column with a solid white edge, readable at a glance.
        currentColumnLayer.backgroundColor = NSColor(white: 1, alpha: 0.14).cgColor
        currentColumnLayer.borderColor = NSColor(white: 0.97, alpha: 1).cgColor
        currentColumnLayer.borderWidth = 2.5
        // The pick: a lighter column with a clear edge and the pick's star.
        pickColumnLayer.backgroundColor = NSColor(white: 1, alpha: 0.07).cgColor
        pickColumnLayer.borderColor = NSColor(white: 1, alpha: 0.4).cgColor
        pickColumnLayer.borderWidth = 1.5
        pickStarLayer.actions = LoupeDocumentView.noActions
        pickStarLayer.zPosition = 10
        layer?.addSublayer(pickStarLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func request(for cell: FaceStripLayout.Cell) -> FaceCropStore.Request? {
        guard let photo = photos(cell.photoID), !photo.isUnreadable else { return nil }
        return FaceCropStore.Request(
            photoID: cell.photoID, file: photo.file, face: cell.face, box: cell.box,
            pixelWidth: photo.metadata.pixelWidth ?? 1000, pixelHeight: photo.metadata.pixelHeight ?? 1000
        )
    }

    var allRequests: [FaceCropStore.Request] {
        layoutModel.cells.flatMap { $0.compactMap { $0.flatMap(request(for:)) } }
    }

    func cellRect(row: Int, column: Int) -> CGRect {
        let x = FaceStripView.gridInset + CGFloat(column) * FaceStripView.columnWidth + (FaceStripView.columnWidth - FaceStripView.cellSize) / 2
        let y = FaceStripView.gridInset + CGFloat(row) * FaceStripView.rowHeight + (FaceStripView.rowHeight - FaceStripView.cellSize) / 2
        return CGRect(x: x, y: y, width: FaceStripView.cellSize, height: FaceStripView.cellSize)
    }

    private func columnRect(_ column: Int) -> CGRect {
        CGRect(
            x: FaceStripView.gridInset + CGFloat(column) * FaceStripView.columnWidth + 6, y: 1,
            width: FaceStripView.columnWidth - 12, height: bounds.height - 2
        )
    }

    func refresh() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let model = layoutModel
        let scale = window?.backingScaleFactor ?? 2
        if let column = model.currentColumn, !model.rowLabels.isEmpty {
            currentColumnLayer.isHidden = false
            currentColumnLayer.frame = columnRect(column)
        } else {
            currentColumnLayer.isHidden = true
        }
        if let column = model.pickColumn, column != model.currentColumn, !model.rowLabels.isEmpty {
            pickColumnLayer.isHidden = false
            pickColumnLayer.frame = columnRect(column)
        } else {
            pickColumnLayer.isHidden = true
        }
        if let column = model.pickColumn, !model.rowLabels.isEmpty {
            // In the top-left corner of the column's first cell, as the star sits on a tile.
            let size: CGFloat = 18
            let cell = cellRect(row: 0, column: column)
            pickStarLayer.isHidden = false
            pickStarLayer.contents = TileArtwork.image(.bestPick, size: size, scale: scale)
            pickStarLayer.contentsScale = scale
            pickStarLayer.frame = CGRect(x: cell.minX + 3, y: cell.minY + 3, width: size, height: size)
        } else {
            pickStarLayer.isHidden = true
        }
        var index = 0
        for (row, cells) in model.cells.enumerated() {
            for (column, cell) in cells.enumerated() {
                if index == cellLayers.count {
                    let layer = CALayer()
                    layer.actions = LoupeDocumentView.noActions
                    layer.contentsGravity = .resizeAspectFill
                    layer.masksToBounds = true
                    layer.cornerRadius = 6
                    self.layer?.addSublayer(layer)
                    cellLayers.append(layer)
                }
                let layer = cellLayers[index]
                index += 1
                layer.isHidden = false
                layer.contentsScale = scale
                layer.frame = cellRect(row: row, column: column)
                guard let cell else {
                    layer.contents = nil
                    layer.backgroundColor = nil
                    layer.borderColor = NSColor(white: 1, alpha: 0.12).cgColor
                    layer.borderWidth = 1
                    continue
                }
                let crop = request(for: cell).flatMap { crops?.crop(for: $0) }
                layer.contents = crop?.image
                layer.backgroundColor = Palette.placeholder.cgColor
                if cell.eyesClosed {
                    layer.borderColor = Palette.flagged.cgColor
                    layer.borderWidth = 2.5
                } else {
                    layer.borderColor = NSColor(white: 0, alpha: 0.5).cgColor
                    layer.borderWidth = 0.5
                }
            }
        }
        for layer in cellLayers[index...] { layer.isHidden = true }
        // Above the cells, also where layers are drawn in order (snapshots ignore zPosition).
        if pickStarLayer.superlayer?.sublayers?.last !== pickStarLayer { layer?.addSublayer(pickStarLayer) }
        updateToolTips()
    }

    /// One element per face for VoiceOver: "Person 1, frame 3 of 6, closed eyes", pressed to
    /// zoom both panes to that face, as a click does. Rebuilt with the tooltips.
    private var cellElements: [DrawnAccessibilityElement] = []

    override func accessibilityChildren() -> [Any]? {
        cellElements
    }

    override func isAccessibilityElement() -> Bool { false }

    private func updateAccessibilityElements() {
        var elements: [DrawnAccessibilityElement] = []
        let model = layoutModel
        for (row, cells) in model.cells.enumerated() {
            for (column, cell) in cells.enumerated() {
                guard let cell else { continue }
                let person = model.rowLabels.indices.contains(row) ? model.rowLabels[row] : localized("Face \(row + 1)")
                // Independent facts read one after another, each a whole phrase.
                var parts = [person, localized("frame \(column + 1) of \(model.columns.count)")]
                if cell.eyesClosed { parts.append(localized("eyes closed, outlined")) }
                if column == model.pickColumn { parts.append(localized("faceCell.bestPick", default: "best pick")) }
                if column == model.currentColumn { parts.append(localized("faceCell.currentFrame", default: "current frame")) }
                elements.append(DrawnAccessibilityElement(
                    in: self, role: .image, label: parts.joined(separator: localized("faceCell.separator", default: ", ")), help: cell.help,
                    selected: column == model.currentColumn,
                    rect: { [weak self] in self?.cellRect(row: row, column: column) ?? .zero },
                    press: { [weak self] in self?.onClick?(row, column) }
                ))
            }
        }
        cellElements = elements
    }

    private func updateToolTips() {
        updateAccessibilityElements()
        removeAllToolTips()
        for (row, cells) in layoutModel.cells.enumerated() {
            for (column, cell) in cells.enumerated() {
                guard let cell else { continue }
                addToolTip(cellRect(row: row, column: column), owner: cell.help as NSString, userData: nil)
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        for (row, cells) in layoutModel.cells.enumerated() {
            for (column, cell) in cells.enumerated() where cell != nil && cellRect(row: row, column: column).insetBy(dx: -4, dy: -4).contains(point) {
                onClick?(row, column)
                return
            }
        }
    }

    override func resetCursorRects() {
        for (row, cells) in layoutModel.cells.enumerated() {
            for (column, cell) in cells.enumerated() where cell != nil {
                addCursorRect(cellRect(row: row, column: column), cursor: .pointingHand)
            }
        }
    }
}
