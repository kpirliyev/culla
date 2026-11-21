import CullaAnalysis
import CullaCore
import CullaSession
import Foundation

/// What stack review says about one frame beside the best pick: Flow 2's "badges the others with
/// what is wrong". Each note is either a flag of the frame or a comparison with the pick.
public enum FrameNote: Sendable, Hashable {
    /// A main face has closed eyes (the Eyes Closed flag).
    case eyesClosed
    /// The frame is flagged Blurry.
    case blurry
    /// Not flagged Blurry, but softer than the pick by more than `Tuning.bestPickSharpnessMargin`.
    case softerThanPick
    /// A person the face strip finds in the pick is not found in this frame.
    case missingFace
    /// The faces were rated lower than the pick's by more than `Tuning.bestPickFaceQualityMargin`.
    case weakerFaces
    /// Another flag the pick does not have, such as Blown highlights.
    case flag(PhotoFlag)
    /// The frame has no scores yet, so nothing can be said.
    case notAnalysed

    /// Lowercase words for a caption: "eyes closed", "softer than the pick".
    public var text: String {
        switch self {
        case .eyesClosed: localized("note.eyesClosed", default: "eyes closed")
        case .blurry: localized("note.blurry", default: "blurry")
        case .softerThanPick: localized("softer than the pick")
        case .missingFace: localized("a face is missing")
        case .weakerFaces: localized("weaker faces")
        case .flag(let flag): Self.flagText(flag)
        case .notAnalysed: localized("not analysed yet")
        }
    }

    /// The SF Symbol of the note's badge.
    public var symbol: String {
        switch self {
        case .eyesClosed: "eye.slash"
        case .blurry: "camera.metering.unknown"
        case .softerThanPick: "minus.magnifyingglass"
        case .missingFace: "person.fill.questionmark"
        case .weakerFaces: "face.dashed"
        case .flag(let flag): Self.flagSymbol(flag)
        case .notAnalysed: "hourglass"
        }
    }

    /// True for a note that is a comparison with the pick rather than a flag of the frame.
    public var isRelative: Bool {
        switch self {
        case .softerThanPick, .missingFace, .weakerFaces: true
        default: false
        }
    }

    static func flagText(_ flag: PhotoFlag) -> String {
        switch flag {
        case .eyesClosed: localized("note.eyesClosed", default: "eyes closed")
        case .blurry: localized("note.blurry", default: "blurry")
        case .clippedHighlights: localized("note.clippedHighlights", default: "blown highlights")
        case .clippedShadows: localized("note.clippedShadows", default: "crushed shadows")
        case .lowAesthetics: localized("note.lowAesthetics", default: "weak shot")
        case .tiltedHorizon: localized("note.tiltedHorizon", default: "tilted horizon")
        case .faceCutOff: localized("note.faceCutOff", default: "face cut off")
        case .lensSmudge: localized("note.lensSmudge", default: "lens smudge")
        case .utility: localized("note.utility", default: "accidental shot")
        }
    }

    static func flagSymbol(_ flag: PhotoFlag) -> String {
        switch flag {
        case .eyesClosed: "eye.slash"
        case .blurry: "camera.metering.unknown"
        case .clippedHighlights: "sun.max"
        case .clippedShadows: "moon"
        case .lowAesthetics: "hand.thumbsdown"
        case .tiltedHorizon: "level"
        case .faceCutOff: "person.crop.rectangle"
        case .lensSmudge: "drop"
        case .utility: "hand.raised"
        }
    }
}

/// The words and choices of stack review that do not depend on the screen: what each frame's
/// caption says, why the pick was chosen, which frame the right pane shows when the current frame
/// is the pick, and where a stack opens.
public enum StackReview {
    // MARK: - Notes

    /// What is wrong with a frame, compared with its stack's pick. For the pick itself (or a stack
    /// without one) only its own flags that matter for choosing: eyes closed and blurry. Flags the
    /// pick shares, such as a low aesthetics score across a whole burst, are left out: they do not
    /// tell the frames apart.
    public static func notes(for id: String, in stack: PhotoStack, state: SessionState, strip: FaceStrip? = nil) -> [FrameNote] {
        guard let item = state.photo(id) else { return [] }
        guard let scores = item.scores, let summary = state.summary(for: id) else { return [.notAnalysed] }
        let tuning = state.tuning
        var notes: [FrameNote] = []
        if summary.flags.contains(.eyesClosed) { notes.append(.eyesClosed) }
        let pick = stack.bestPick.flatMap { $0 == id ? nil : $0 }
        let pickSummary = pick.flatMap { state.summary(for: $0) }
        if summary.flags.contains(.blurry), pickSummary.map({ !$0.flags.contains(.blurry) }) ?? true {
            notes.append(.blurry)
        } else if let pickSummary, summary.blurScore < pickSummary.blurScore - tuning.bestPickSharpnessMargin {
            notes.append(.softerThanPick)
        }
        guard let pick, let pickSummary, let pickScores = state.photo(pick)?.scores else { return notes }
        if let strip, let column = strip.frames.firstIndex(of: id), let pickColumn = strip.frames.firstIndex(of: pick),
           strip.matching.rows.contains(where: { $0.faces[pickColumn] != nil && $0.faces[column] == nil }) {
            notes.append(.missingFace)
        }
        let quality = BestPickCandidate(scores: scores, tuning: tuning).faceQuality
        let pickQuality = BestPickCandidate(scores: pickScores, tuning: tuning).faceQuality
        if let quality, let pickQuality, quality < pickQuality - tuning.bestPickFaceQualityMargin {
            notes.append(.weakerFaces)
        }
        let others = summary.flags.subtracting(pickSummary.flags).subtracting([.eyesClosed, .blurry])
        for flag in PhotoFlag.allCases where others.contains(flag) {
            notes.append(.flag(flag))
        }
        return notes
    }

    /// The notes as a caption: "eyes closed, softer than the pick". Each note is a separate
    /// badge's words, so they are listed, not joined into a sentence.
    public static func caption(_ notes: [FrameNote]) -> String {
        notes.map(\.text).joined(separator: localized("caption.separator", default: ", "))
    }

    // MARK: - The pick

    /// Why the stack's pick is its pick, in a few words: "sharpest frame with all eyes open",
    /// "chosen by you". Nil when the stack has no pick.
    public static func pickReason(of stack: PhotoStack, state: SessionState) -> String? {
        guard let pick = stack.bestPick else { return nil }
        if state.isHandPicked(stack) { return localized("chosen by you") }
        let tuning = state.tuning
        var candidates: [String: BestPickCandidate] = [:]
        var hasFaces = false
        for member in stack.members {
            guard let scores = state.photo(member)?.scores else { continue }
            candidates[member] = BestPickCandidate(scores: scores, tuning: tuning)
            if !(state.summary(for: member)?.mainFaces.isEmpty ?? true) { hasFaces = true }
        }
        guard let chosen = candidates[pick] else { return localized("not analysed yet") }
        let pickHasFaces = !(state.summary(for: pick)?.mainFaces.isEmpty ?? true)
        // The frames the pick was compared with in the step that decided it.
        var pool = Array(candidates.values)
        let eyesMattered = !chosen.eyesClosed && pool.contains { $0.eyesClosed }
        if !chosen.eyesClosed { pool = pool.filter { !$0.eyesClosed } }
        let sharpest = pool.map(\.sharpness).max() ?? chosen.sharpness
        let bestQuality = pool.compactMap(\.faceQuality).max()
        let subject: PickSubject
        if candidates.count < 2 {
            subject = .onlyAnalysed
        } else if chosen.sharpness >= sharpest - 1e-9 {
            subject = .sharpest
        } else if let bestQuality, let quality = chosen.faceQuality, quality >= bestQuality - 1e-9 {
            subject = .bestFaces
        } else if let aesthetics = chosen.aesthetics, aesthetics >= (pool.compactMap(\.aesthetics).max() ?? aesthetics) {
            subject = .bestComposed
        } else {
            subject = .earliest
        }
        let eyes: PickEyes
        if hasFaces, pickHasFaces, !chosen.eyesClosed {
            eyes = eyesMattered ? .allOpen : .open
        } else if chosen.eyesClosed, hasFaces {
            eyes = .everyFrameClosed
        } else {
            eyes = .notApplicable
        }
        return pickReason(subject, eyes)
    }

    /// What set the pick apart, for `pickReason(of:state:)`.
    enum PickSubject {
        case onlyAnalysed, sharpest, bestFaces, bestComposed, earliest
    }

    /// What the pick's eyes add to the reason.
    enum PickEyes {
        case notApplicable, allOpen, open, everyFrameClosed
    }

    /// One whole phrase for each reason, so a translation can word each its own way.
    static func pickReason(_ subject: PickSubject, _ eyes: PickEyes) -> String {
        switch (subject, eyes) {
        case (.onlyAnalysed, .notApplicable): localized("the only analysed frame")
        case (.onlyAnalysed, .allOpen): localized("the only analysed frame with all eyes open")
        case (.onlyAnalysed, .open): localized("the only analysed frame, eyes open")
        case (.onlyAnalysed, .everyFrameClosed): localized("the only analysed frame; every frame has closed eyes")
        case (.sharpest, .notApplicable): localized("sharpest frame")
        case (.sharpest, .allOpen): localized("sharpest frame with all eyes open")
        case (.sharpest, .open): localized("sharpest frame, eyes open")
        case (.sharpest, .everyFrameClosed): localized("sharpest frame; every frame has closed eyes")
        case (.bestFaces, .notApplicable): localized("best faces among the sharpest")
        case (.bestFaces, .allOpen): localized("best faces among the sharpest with all eyes open")
        case (.bestFaces, .open): localized("best faces among the sharpest, eyes open")
        case (.bestFaces, .everyFrameClosed): localized("best faces among the sharpest; every frame has closed eyes")
        case (.bestComposed, .notApplicable): localized("best composed of the sharpest")
        case (.bestComposed, .allOpen): localized("best composed of the sharpest with all eyes open")
        case (.bestComposed, .open): localized("best composed of the sharpest, eyes open")
        case (.bestComposed, .everyFrameClosed): localized("best composed of the sharpest; every frame has closed eyes")
        case (.earliest, .notApplicable): localized("earliest of the sharpest")
        case (.earliest, .allOpen): localized("earliest of the sharpest with all eyes open")
        case (.earliest, .open): localized("earliest of the sharpest, eyes open")
        case (.earliest, .everyFrameClosed): localized("earliest of the sharpest; every frame has closed eyes")
        }
    }

    /// The frame the right pane shows when the current frame is the pick, so the same picture is
    /// never shown twice: the frame Culla ranks next after the pick, so the pane answers "what is
    /// the alternative?". Without scores, the frame after the pick (the one before, for the last).
    public static func runnerUp(of stack: PhotoStack, state: SessionState) -> String? {
        let members = stack.members
        guard members.count >= 2 else { return nil }
        let pick = stack.bestPick ?? members[0]
        let others = members.filter { $0 != pick }
        let scored = others.compactMap { id in state.photo(id)?.scores.map { (id, BestPickCandidate(scores: $0, tuning: state.tuning)) } }
        if let first = BestPick.ranking(scored.map(\.1), tuning: state.tuning).first {
            return scored[first].0
        }
        guard let index = members.firstIndex(of: pick) else { return others.first }
        return index + 1 < members.count ? members[index + 1] : members[index - 1]
    }

    /// The frame stack review opens a stack on: the first Unreviewed frame that is not the pick,
    /// so the left pane starts on a frame worth comparing; else the first frame that is not the
    /// pick; else the pick.
    public static func openingFrame(of stack: PhotoStack, state: SessionState) -> String? {
        let others = stack.members.filter { $0 != stack.bestPick }
        return others.first { state.photo($0)?.decision == .unreviewed } ?? others.first ?? stack.members.first
    }

    /// The stack to open after Return accepted the one holding `id`: the next with an Unreviewed
    /// frame, coming round to stacks skipped earlier. Nil when every stack is decided, which is
    /// when Culla offers the next group.
    public static func stackAfterAccepting(_ id: String, state: SessionState) -> PhotoStack? {
        state.nextUndecidedStack(after: id, wrapping: true)
    }

    // MARK: - Header

    /// "Stack 12 of 86 · 7 frames"
    public static func title(index: Int, count: Int, frames: Int) -> String {
        localized("Stack \(index + 1) of \(count) · \(frames) frames")
    }

    /// The capture time span of the stack: its first capture time and how long it lasted, or nil
    /// when no frame has a capture time.
    public static func timeSpan(of stack: PhotoStack, state: SessionState) -> (start: Date, duration: TimeInterval)? {
        let dates = stack.members.compactMap { state.photo($0)?.metadata.captureDate }
        guard let start = dates.min(), let end = dates.max() else { return nil }
        return (start, end.timeIntervalSince(start))
    }

    /// "in 1.8 s", "in 12 s", "in 2 min 5 s"
    public static func durationText(_ seconds: TimeInterval) -> String {
        if seconds < 0.05 { return localized("at once") }
        if seconds < 10 { return localized("in \(Localization.decimal(seconds, fractionDigits: 1)) s") }
        if seconds < 60 { return localized("in \(Int(seconds.rounded())) s") }
        let minutes = Int(seconds) / 60
        let rest = Int(seconds.rounded()) % 60
        return rest == 0 ? localized("in \(minutes) min") : localized("in \(minutes) min \(rest) s")
    }
}

/// The copies of a duplicate set side by side: which file details differ between them, so the
/// duplicate review screen can point them out.
public enum DuplicateReview {
    public enum Field: String, Sendable, Hashable, CaseIterable {
        case name, folder, size, format, dimensions
    }

    /// One copy's details as the screen shows them.
    public struct Copy: Sendable, Hashable {
        public var name: String
        public var folder: String
        public var bytes: Int64
        public var format: String
        public var width: Int?
        public var height: Int?

        public init(name: String, folder: String, bytes: Int64, format: String, width: Int?, height: Int?) {
            self.name = name
            self.folder = folder
            self.bytes = bytes
            self.format = format
            self.width = width
            self.height = height
        }
    }

    /// The fields whose values are not the same in every copy. File names always differ within a
    /// folder, so a name counts only when the copies sit in different folders and still differ.
    public static func differingFields(_ copies: [Copy]) -> Set<Field> {
        guard copies.count >= 2 else { return [] }
        var result = Set<Field>()
        if Set(copies.map(\.folder)).count > 1 { result.insert(.folder) }
        if Set(copies.map(\.bytes)).count > 1 { result.insert(.size) }
        if Set(copies.map(\.format)).count > 1 { result.insert(.format) }
        if Set(copies.map { "\($0.width ?? 0)x\($0.height ?? 0)" }).count > 1 { result.insert(.dimensions) }
        if result.contains(.folder), Set(copies.map(\.name)).count > 1 { result.insert(.name) }
        return result
    }

    /// "Keep: highest resolution"
    public static func pickCaption(_ reason: DuplicatePickReason) -> String {
        switch reason {
        case .highestResolution: localized("Keep: highest resolution")
        case .rawFile: localized("Keep: RAW file")
        case .originalName: localized("Keep: original name")
        case .shorterName: localized("Keep: shorter name")
        case .firstByName: localized("Keep: first by name")
        }
    }

    /// "Set 2 of 3"
    public static func title(index: Int, count: Int) -> String {
        localized("Set \(index + 1) of \(count)")
    }

    /// The notice after Accept All Exact Duplicates: "Cleared 12 sets, rejected 14 photos.", a whole sentence.
    public static func bulkResult(sets: Int, rejected: Int) -> String {
        localized("Cleared \(sets) sets, rejected \(rejected) photos.")
    }
}

// MARK: - Stack review's layout

/// How stack review shares its space: the current frame beside the best pick, or alone across
/// the whole row; the face strip under them, or none, its height given to the frames.
public struct StackReviewLayout: Equatable, Sendable {
    /// The best pick shows on the right. Otherwise the current frame fills the row.
    public var showsPickPane: Bool
    /// The face strip shows under the frames. Otherwise it takes no height at all.
    public var showsFaceStrip: Bool
    /// The panes draw boxes over the faces.
    public var showsFaceBoxes: Bool

    /// The strip shows only when the person wants it and the stack has faces to show: a stack
    /// with none gives the strip's height to the frames instead of a "no faces" line. The face
    /// boxes follow `showsFaceBoxes(faceStripWanted:faceBoxesOn:)`.
    public init(pickPaneWanted: Bool, faceStripWanted: Bool, stackHasFaces: Bool, faceBoxesOn: Bool) {
        showsPickPane = pickPaneWanted
        showsFaceStrip = faceStripWanted && stackHasFaces
        showsFaceBoxes = Self.showsFaceBoxes(faceStripWanted: faceStripWanted, faceBoxesOn: faceBoxesOn)
    }

    /// F in stack review means faces on or off: the strip and the boxes over the panes together.
    /// The boxes show only while the person wants faces shown (F) and the face-box overlay (B)
    /// is on. It follows what the person wants, not whether the stack has faces: a stack without
    /// any has no boxes to draw either way.
    public static func showsFaceBoxes(faceStripWanted: Bool, faceBoxesOn: Bool) -> Bool {
        faceStripWanted && faceBoxesOn
    }

    /// The share of the room under the header the strip may take at most.
    public static let faceStripShare = 0.36

    /// The face strip's height in points: every row it has, at most a share of the room under the
    /// header (`available`) but never less than one row (`minimum`); 0 when it does not show.
    public func faceStripHeight(ideal: Double, minimum: Double, available: Double) -> Double {
        guard showsFaceStrip else { return 0 }
        let cap = max(minimum, (available * Self.faceStripShare).rounded())
        return min(ideal, cap)
    }
}
