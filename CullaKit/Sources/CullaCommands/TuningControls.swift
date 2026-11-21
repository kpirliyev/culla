import CullaAnalysis
import CullaCore
import CullaSession
import Foundation

/// A `Tuning` value by name: what the tuning panel, the Settings window and automation scripts
/// change. The raw value is the property's name in `Tuning`.
public enum TuningKey: String, CaseIterable, Sendable, Hashable, Codable {
    case eyesClosedBelow
    case eyesClosedCertainBelow
    case blurryBelow
    case blurryCertainBelow
    case clippedHighlightsAbove
    case clippedShadowsAbove
    case lowAestheticsBelow
    case tiltedHorizonAboveDegrees
    case lensSmudgeAbove
    case flagTiltedHorizon
    case flagCutOffFaces
    case flagLensSmudge
    case flagUtility
    case flagLowAesthetics
    case flagExposure
    case stackGapSeconds
    case stackDistance
    case nearDuplicateDistance
    // Faces
    case minFaceFraction
    case ignoreBackgroundFaces
    case backgroundFaceRatio
    case groupPhotoRule
    case countWinkAsClosed
    case skipProfiles
    case maxYawDegrees
    // Blur
    case sharpnessArea
    case facesTakePriority
    // Stacks and duplicates
    case minStackSize
    case useBurstData
    case findExactDuplicates
    case findNearDuplicates
    // Best pick
    case bestPickSharpnessMargin
    case bestPickFaceQualityMargin

    /// How the value is chosen.
    public enum Kind: Sendable, Hashable {
        /// A number on a slider.
        case slider
        /// On (1) or off (0).
        case toggle
        /// One of several named options, by index.
        case choice
    }

    public var kind: Kind {
        switch self {
        case .flagTiltedHorizon, .flagCutOffFaces, .flagLensSmudge, .flagUtility, .flagLowAesthetics, .flagExposure,
             .ignoreBackgroundFaces, .countWinkAsClosed, .skipProfiles, .facesTakePriority, .useBurstData,
             .findExactDuplicates, .findNearDuplicates:
            .toggle
        case .groupPhotoRule, .sharpnessArea:
            .choice
        default:
            .slider
        }
    }

    public var isSwitch: Bool { kind == .toggle }

    /// The value in a tuning; switches read as 1 (on) or 0 (off), choices as the option's index.
    public func value(in tuning: Tuning) -> Double {
        switch self {
        case .eyesClosedBelow: tuning.eyesClosedBelow
        case .eyesClosedCertainBelow: tuning.eyesClosedCertainBelow
        case .blurryBelow: tuning.blurryBelow
        case .blurryCertainBelow: tuning.blurryCertainBelow
        case .clippedHighlightsAbove: tuning.clippedHighlightsAbove
        case .clippedShadowsAbove: tuning.clippedShadowsAbove
        case .lowAestheticsBelow: tuning.lowAestheticsBelow
        case .tiltedHorizonAboveDegrees: tuning.tiltedHorizonAboveDegrees
        case .lensSmudgeAbove: tuning.lensSmudgeAbove
        case .flagTiltedHorizon: tuning.flagTiltedHorizon ? 1 : 0
        case .flagCutOffFaces: tuning.flagCutOffFaces ? 1 : 0
        case .flagLensSmudge: tuning.flagLensSmudge ? 1 : 0
        case .flagUtility: tuning.flagUtility ? 1 : 0
        case .flagLowAesthetics: tuning.flagLowAesthetics ? 1 : 0
        case .flagExposure: tuning.flagExposure ? 1 : 0
        case .stackGapSeconds: tuning.stackGapSeconds
        case .stackDistance: tuning.stackDistance
        case .nearDuplicateDistance: tuning.nearDuplicateDistance
        case .minFaceFraction: tuning.minFaceFraction
        case .ignoreBackgroundFaces: tuning.ignoreBackgroundFaces ? 1 : 0
        case .backgroundFaceRatio: tuning.backgroundFaceRatio
        case .groupPhotoRule: Double(GroupPhotoRule.allCases.firstIndex(of: tuning.groupPhotoRule) ?? 0)
        case .countWinkAsClosed: tuning.countWinkAsClosed ? 1 : 0
        case .skipProfiles: tuning.skipProfiles ? 1 : 0
        case .maxYawDegrees: tuning.maxYawDegrees
        case .sharpnessArea: Double(SharpnessArea.allCases.firstIndex(of: tuning.sharpnessArea) ?? 0)
        case .facesTakePriority: tuning.facesTakePriority ? 1 : 0
        case .minStackSize: Double(tuning.minStackSize)
        case .useBurstData: tuning.useBurstData ? 1 : 0
        case .findExactDuplicates: tuning.findExactDuplicates ? 1 : 0
        case .findNearDuplicates: tuning.findNearDuplicates ? 1 : 0
        case .bestPickSharpnessMargin: tuning.bestPickSharpnessMargin
        case .bestPickFaceQualityMargin: tuning.bestPickFaceQualityMargin
        }
    }

    /// Sets the value in a tuning. Switches are on for any value of 0.5 or more; choices take the
    /// nearest option's index.
    public func set(_ value: Double, in tuning: inout Tuning) {
        let on = value >= 0.5
        func option<T>(_ all: [T]) -> T { all[min(max(Int(value.rounded()), 0), all.count - 1)] }
        switch self {
        case .eyesClosedBelow: tuning.eyesClosedBelow = value
        case .eyesClosedCertainBelow: tuning.eyesClosedCertainBelow = value
        case .blurryBelow: tuning.blurryBelow = value
        case .blurryCertainBelow: tuning.blurryCertainBelow = value
        case .clippedHighlightsAbove: tuning.clippedHighlightsAbove = value
        case .clippedShadowsAbove: tuning.clippedShadowsAbove = value
        case .lowAestheticsBelow: tuning.lowAestheticsBelow = value
        case .tiltedHorizonAboveDegrees: tuning.tiltedHorizonAboveDegrees = value
        case .lensSmudgeAbove: tuning.lensSmudgeAbove = value
        case .flagTiltedHorizon: tuning.flagTiltedHorizon = on
        case .flagCutOffFaces: tuning.flagCutOffFaces = on
        case .flagLensSmudge: tuning.flagLensSmudge = on
        case .flagUtility: tuning.flagUtility = on
        case .flagLowAesthetics: tuning.flagLowAesthetics = on
        case .flagExposure: tuning.flagExposure = on
        case .stackGapSeconds: tuning.stackGapSeconds = value
        case .stackDistance: tuning.stackDistance = value
        case .nearDuplicateDistance: tuning.nearDuplicateDistance = value
        case .minFaceFraction: tuning.minFaceFraction = value
        case .ignoreBackgroundFaces: tuning.ignoreBackgroundFaces = on
        case .backgroundFaceRatio: tuning.backgroundFaceRatio = value
        case .groupPhotoRule: tuning.groupPhotoRule = option(GroupPhotoRule.allCases)
        case .countWinkAsClosed: tuning.countWinkAsClosed = on
        case .skipProfiles: tuning.skipProfiles = on
        case .maxYawDegrees: tuning.maxYawDegrees = value
        case .sharpnessArea: tuning.sharpnessArea = option(SharpnessArea.allCases)
        case .facesTakePriority: tuning.facesTakePriority = on
        case .minStackSize: tuning.minStackSize = Int(value.rounded())
        case .useBurstData: tuning.useBurstData = on
        case .findExactDuplicates: tuning.findExactDuplicates = on
        case .findNearDuplicates: tuning.findNearDuplicates = on
        case .bestPickSharpnessMargin: tuning.bestPickSharpnessMargin = value
        case .bestPickFaceQualityMargin: tuning.bestPickFaceQualityMargin = value
        }
    }

    /// True when changing this value changes the stacks, their best picks or the duplicate sets,
    /// which are computed off the main thread, rather than only the flags.
    public var affectsGrouping: Bool {
        switch self {
        case .stackGapSeconds, .stackDistance, .nearDuplicateDistance, .minStackSize, .useBurstData,
             .findExactDuplicates, .findNearDuplicates, .bestPickSharpnessMargin, .bestPickFaceQualityMargin:
            true
        default:
            false
        }
    }
}

/// One detection control of the tuning panel and the Settings window: a slider, a switch or a
/// choice over a `Tuning` value, with its words, range and the count it shows. Pure data, so any
/// view can draw it; the panel and Settings build their rows from the same values
/// (`TuningControl.control(for:)`), so the two never disagree.
public struct TuningControl: Sendable, Hashable, Identifiable {
    public enum Unit: Sendable, Hashable {
        /// A plain number with this many decimals.
        case number(decimals: Int)
        /// A share, 0 to 1, shown as a percentage.
        case percent
        case seconds
        case degrees
        /// A whole number of photos.
        case photos
    }

    /// How a slider is presented.
    public enum Scale: Sendable, Hashable {
        /// The value itself.
        case direct
        /// A 0 to 100 sensitivity, with 50 at the Balanced value and the two halves spread
        /// evenly over the value's range either side of it. Higher always means more photos
        /// flagged or joined: `rising` is true when that takes a higher value.
        case sensitivity(rising: Bool)
    }

    /// Which way the value moves for more photos flagged (or joined into stacks and sets): what
    /// the presets follow. `none` for values that do not trade fewer flags for more.
    public enum Direction: Sendable, Hashable {
        case higherFlagsMore
        case lowerFlagsMore
        case none
    }

    /// What the control's live count counts.
    public enum Counted: Sendable, Hashable {
        /// Photos with this flag raised, any tier.
        case flag(PhotoFlag)
        /// Photos with this flag raised as Certain.
        case certain(PhotoFlag)
        /// Photos with clipped highlights or clipped shadows.
        case exposure
        /// Photos in stacks.
        case stackedPhotos
        /// Photos in exact duplicate sets.
        case exactDuplicatePhotos
        /// Photos in near-duplicate sets.
        case nearDuplicatePhotos
    }

    public var key: TuningKey
    public var range: ClosedRange<Double>
    public var step: Double
    public var unit: Unit
    public var scale: Scale
    public var direction: Direction
    /// What the live count counts; nil for values that only change which frame is a stack's pick.
    public var counted: Counted?
    /// The switch that must be on for this value to matter, such as the Lens Smudge switch for
    /// its confidence.
    public var dependsOn: TuningKey?
    /// True for values chosen without looking at real shoots, to be tuned in milestone M7.
    public var isProvisional: Bool

    public var id: TuningKey { key }

    /// The control's words (`title`, `help`, `countName`, `choices`) follow from its key and what
    /// it counts, in the language of the moment.
    public init(
        key: TuningKey, range: ClosedRange<Double> = 0...1, step: Double = 0.01,
        unit: Unit = .number(decimals: 2), scale: Scale = .direct, direction: Direction = .none,
        counted: Counted?, dependsOn: TuningKey? = nil, isProvisional: Bool = false
    ) {
        self.key = key
        self.range = range
        self.step = step
        self.unit = unit
        self.scale = scale
        self.direction = direction
        self.counted = counted
        self.dependsOn = dependsOn
        self.isProvisional = isProvisional
    }

    // MARK: Words

    /// The control's label, such as "Sensitivity".
    public var title: String {
        switch key {
        case .eyesClosedBelow: localized("Sensitivity")
        case .eyesClosedCertainBelow: localized("Certain below")
        case .groupPhotoRule: localized("Group photo rule")
        case .countWinkAsClosed: localized("Count a wink as closed")
        case .minFaceFraction: localized("Smallest face to check")
        case .ignoreBackgroundFaces: localized("Ignore background faces")
        case .backgroundFaceRatio: localized("Background below")
        case .skipProfiles: localized("Skip profiles and sunglasses")
        case .maxYawDegrees: localized("Profile beyond")
        case .blurryBelow: localized("Sensitivity")
        case .blurryCertainBelow: localized("Certain below")
        case .sharpnessArea: localized("Measure sharpness on")
        case .facesTakePriority: localized("Faces take priority")
        case .stackGapSeconds: localized("Time gap that splits a stack")
        case .stackDistance: localized("Visual similarity")
        case .minStackSize: localized("Smallest stack")
        case .useBurstData: localized("Use the camera's burst data")
        case .bestPickSharpnessMargin: localized("Equally sharp within")
        case .bestPickFaceQualityMargin: localized("Equally good faces within")
        case .findExactDuplicates: localized("Exact copies")
        case .findNearDuplicates: localized("Near-duplicates")
        case .nearDuplicateDistance: localized("Near-duplicate distance up to")
        case .flagExposure: localized("Flag clipped exposure")
        case .clippedHighlightsAbove: localized("Blown highlights above")
        case .clippedShadowsAbove: localized("Crushed shadows above")
        case .flagLowAesthetics: localized("Weak shots")
        case .lowAestheticsBelow: localized("Aesthetics below")
        case .flagUtility: localized("Accidental shots")
        case .flagCutOffFaces: localized("Cut-off faces")
        case .flagLensSmudge: localized("Lens smudge")
        case .lensSmudgeAbove: localized("Smudge confidence above")
        case .flagTiltedHorizon: localized("Tilted horizons")
        case .tiltedHorizonAboveDegrees: localized("Tilt above")
        }
    }

    /// One line saying what the value means.
    public var help: String {
        switch key {
        case .eyesClosedBelow: localized("How shut the eyes must be to flag a photo. Higher flags more.")
        case .eyesClosedCertainBelow: localized("Below this the flag is Certain, and ⇧X can reject it.")
        case .groupPhotoRule: localized("Which of the main faces must have closed eyes.")
        case .countWinkAsClosed: localized("Off: both eyes must be shut. On: one is enough.")
        case .minFaceFraction: localized("Smaller faces, as a share of the short side, are skipped.")
        case .ignoreBackgroundFaces: localized("Skips faces much smaller than the largest, such as passers-by.")
        case .backgroundFaceRatio: localized("Faces smaller than this share of the largest are background.")
        case .skipProfiles: localized("Faces turned away, or without an eye reading, are skipped.")
        case .maxYawDegrees: localized("Faces turned further than this count as profiles.")
        case .blurryBelow: localized("How soft the subject or a face must be to flag. Higher flags more.")
        case .blurryCertainBelow: localized("Below this the flag is Certain, and ⇧X can reject it.")
        case .sharpnessArea: localized("The subject Vision picks out, or the whole frame.")
        case .facesTakePriority: localized("With people in the frame, the sharpest main face decides.")
        case .stackGapSeconds: localized("Frames further apart than this never share a stack.")
        case .stackDistance: localized("How alike neighbouring frames must look. Higher joins more.")
        case .minStackSize: localized("Fewer similar frames than this stay single photos.")
        case .useBurstData: localized("Frames the camera marked as one burst always share a stack.")
        case .bestPickSharpnessMargin: localized("Frames this close to the sharpest count as equally sharp.")
        case .bestPickFaceQualityMargin: localized("Faces this close in quality count as equally good.")
        case .findExactDuplicates: localized("Files with identical content.")
        case .findNearDuplicates: localized("Resized or re-saved copies of the same image.")
        case .nearDuplicateDistance: localized("How different two copies may look and still match.")
        case .flagExposure: localized("Highlights blown to white or shadows crushed to black.")
        case .clippedHighlightsAbove: localized("Share of the frame at or near pure white.")
        case .clippedShadowsAbove: localized("Share of the frame at or near pure black.")
        case .flagLowAesthetics: localized("Vision's aesthetics score is low.")
        case .lowAestheticsBelow: localized("Vision's score, from -1 to 1.")
        case .flagUtility: localized("Screenshots, documents, a pocket.")
        case .flagCutOffFaces: localized("A main face touches the frame's edge.")
        case .flagLensSmudge: localized("Vision thinks the lens was dirty.")
        case .lensSmudgeAbove: localized("How sure Vision must be, from 0 to 1.")
        case .flagTiltedHorizon: localized("Off by default: many tilts are intended.")
        case .tiltedHorizonAboveDegrees: localized("Degrees either way.")
        }
    }

    /// The name of what is counted, for the count line: "Eyes closed". Empty when nothing is.
    public var countName: String {
        switch counted {
        case .flag(.eyesClosed): localized("count.eyesClosed", default: "Eyes closed")
        case .flag(.blurry): localized("count.blurry", default: "Blurry")
        case .flag(.clippedHighlights): localized("count.clippedHighlights", default: "Blown highlights")
        case .flag(.clippedShadows): localized("count.clippedShadows", default: "Crushed shadows")
        case .flag(.lowAesthetics): localized("count.lowAesthetics", default: "Weak shot")
        case .flag(.utility): localized("count.utility", default: "Accidental shot")
        case .flag(.faceCutOff): localized("count.faceCutOff", default: "Face cut off")
        case .flag(.lensSmudge): localized("count.lensSmudge", default: "Lens smudge")
        case .flag(.tiltedHorizon): localized("count.tiltedHorizon", default: "Tilted horizon")
        case .certain: localized("count.certain", default: "Certain")
        case .exposure: localized("count.exposure", default: "Exposure")
        case .stackedPhotos: localized("count.stackedPhotos", default: "In stacks")
        case .exactDuplicatePhotos: localized("count.exactDuplicates", default: "Exact copies")
        case .nearDuplicatePhotos: localized("count.nearDuplicates", default: "Near-duplicates")
        case nil: ""
        }
    }

    /// For a choice: the options' names, in the order of their index.
    public var choices: [String] {
        switch key {
        case .groupPhotoRule: [localized("Any main face"), localized("Most faces"), localized("All faces")]
        case .sharpnessArea: [localized("Subject only"), localized("Whole frame")]
        default: []
        }
    }

    /// How many options a choice has, without looking up their names.
    var choiceCount: Int {
        switch key {
        case .groupPhotoRule: 3
        case .sharpnessArea: 2
        default: 0
        }
    }

    public var isSwitch: Bool { key.kind == .toggle }
    public var isChoice: Bool { key.kind == .choice }
    public var isSlider: Bool { key.kind == .slider }
    public var isSensitivity: Bool { if case .sensitivity = scale { true } else { false } }

    /// The value as the control shows it: "0.26", "30%", "10 s", "3.0°", "On", "Any main face".
    public func format(_ value: Double) -> String {
        if isSwitch { return value >= 0.5 ? localized("On") : localized("Off") }
        if isChoice {
            let names = choices
            let index = min(max(Int(value.rounded()), 0), max(names.count - 1, 0))
            return names.isEmpty ? Localization.number(index) : names[index]
        }
        let whole = value.rounded() == value
        switch unit {
        case .number(let decimals): return Localization.decimal(value, fractionDigits: decimals)
        case .percent: return Localization.percent(value)
        case .seconds:
            return whole ? localized("\(Int(value)) s") : localized("\(Localization.decimal(value, fractionDigits: 1)) s")
        case .degrees: return Localization.decimal(value, fractionDigits: whole ? 0 : 1) + "°"
        case .photos: return Localization.number(Int(value.rounded()))
        }
    }

    /// What the slider shows as its number: the value itself, or the sensitivity, 0 to 100.
    public func shownValue(_ value: Double) -> String {
        guard isSensitivity else { return format(value) }
        return Localization.number(Int(sensitivity(of: value).rounded()))
    }

    /// For a sensitivity slider, the value it stands for: "Flags eye openness below 0.26".
    public func valueNote(_ value: Double) -> String? {
        guard isSensitivity else { return nil }
        let shown = format(value)
        switch key {
        case .eyesClosedBelow: return localized("Flags eye openness below \(shown)")
        case .blurryBelow: return localized("Flags sharpness below \(shown)")
        case .stackDistance: return localized("Joins frames up to a distance of \(shown)")
        default: return shown
        }
    }

    /// A value snapped to the step and kept in range.
    public func snapped(_ value: Double) -> Double {
        if isSwitch { return value >= 0.5 ? 1 : 0 }
        if isChoice { return min(max(value.rounded(), 0), Double(max(choiceCount - 1, 0))) }
        let stepped = step > 0 ? (value / step).rounded() * step : value
        // Rounding the step away keeps 0.26 from becoming 0.26000000000000001.
        let clean = (stepped * 1_000_000).rounded() / 1_000_000
        return min(max(clean, range.lowerBound), range.upperBound)
    }

    /// The Balanced value: today's default in `Tuning`.
    public var balancedValue: Double { key.value(in: Tuning()) }

    // MARK: Sensitivity

    /// The sensitivity, 0 to 100, of a value. 50 is the Balanced value.
    public func sensitivity(of value: Double) -> Double {
        guard case .sensitivity(let rising) = scale else { return value }
        let balanced = balancedValue
        if abs(value - balanced) < 1e-9 { return 50 }
        let (low, high) = (range.lowerBound, range.upperBound)
        let result: Double
        if rising {
            result = value <= balanced
                ? 50 * (value - low) / max(balanced - low, .ulpOfOne)
                : 50 + 50 * (value - balanced) / max(high - balanced, .ulpOfOne)
        } else {
            result = value >= balanced
                ? 50 * (high - value) / max(high - balanced, .ulpOfOne)
                : 50 + 50 * (balanced - value) / max(balanced - low, .ulpOfOne)
        }
        return min(max(result, 0), 100)
    }

    /// The value a sensitivity, 0 to 100, stands for, snapped to the step.
    public func value(atSensitivity sensitivity: Double) -> Double {
        guard case .sensitivity(let rising) = scale else { return snapped(sensitivity) }
        let s = min(max(sensitivity, 0), 100)
        let balanced = balancedValue
        let (low, high) = (range.lowerBound, range.upperBound)
        let raw: Double = if rising {
            s <= 50 ? low + (balanced - low) * s / 50 : balanced + (high - balanced) * (s - 50) / 50
        } else {
            s <= 50 ? high - (high - balanced) * s / 50 : balanced - (balanced - low) * (s - 50) / 50
        }
        return snapped(raw)
    }

    // MARK: Count lines

    /// The count line: "Eyes closed: 41 → 28 photos", or "Eyes closed: 41 photos" when unchanged.
    public func countLine(before: Int, after: Int) -> String {
        let name = countName
        if before == after { return localized("\(name): \(after) photos") }
        return localized("\(name): \(before) → \(after) photos")
    }

    /// True when the control's switch (or the switch it depends on) is off, so it flags nothing.
    public func isOff(in tuning: Tuning) -> Bool {
        if isSwitch { return key.value(in: tuning) < 0.5 }
        if let dependsOn { return dependsOn.value(in: tuning) < 0.5 }
        return false
    }

    // MARK: - The controls

    /// The one description of each tuning value. The panel and Settings both read it.
    public static func control(for key: TuningKey) -> TuningControl {
        catalog[key]!
    }

    private static let catalog: [TuningKey: TuningControl] = {
        var all: [TuningKey: TuningControl] = [:]
        for control in definitions { all[control.key] = control }
        precondition(all.count == TuningKey.allCases.count, "Every TuningKey needs a control")
        return all
    }()

    private static let definitions: [TuningControl] = [
        // Eyes
        TuningControl(
            key: .eyesClosedBelow, range: 0.05...0.50, step: 0.01, scale: .sensitivity(rising: true), direction: .higherFlagsMore,
            counted: .flag(.eyesClosed)
        ),
        TuningControl(
            key: .eyesClosedCertainBelow, range: 0.02...0.50, step: 0.01, direction: .higherFlagsMore,
            counted: .certain(.eyesClosed), isProvisional: true
        ),
        TuningControl(
            key: .groupPhotoRule, counted: .flag(.eyesClosed)
        ),
        TuningControl(
            key: .countWinkAsClosed, counted: .flag(.eyesClosed)
        ),
        TuningControl(
            key: .minFaceFraction, range: 0.01...0.20, step: 0.01, unit: .percent, direction: .lowerFlagsMore,
            counted: .flag(.eyesClosed)
        ),
        TuningControl(
            key: .ignoreBackgroundFaces, counted: .flag(.eyesClosed)
        ),
        TuningControl(
            key: .backgroundFaceRatio, range: 0.20...0.80, step: 0.05, unit: .percent, direction: .lowerFlagsMore,
            counted: .flag(.eyesClosed), dependsOn: .ignoreBackgroundFaces
        ),
        TuningControl(
            key: .skipProfiles, counted: .flag(.eyesClosed)
        ),
        TuningControl(
            key: .maxYawDegrees, range: 15...90, step: 5, unit: .degrees, direction: .higherFlagsMore,
            counted: .flag(.eyesClosed), dependsOn: .skipProfiles
        ),

        // Blur
        TuningControl(
            key: .blurryBelow, range: 2...80, step: 1, unit: .number(decimals: 0), scale: .sensitivity(rising: true), direction: .higherFlagsMore,
            counted: .flag(.blurry)
        ),
        TuningControl(
            key: .blurryCertainBelow, range: 1...80, step: 1, unit: .number(decimals: 0), direction: .higherFlagsMore,
            counted: .certain(.blurry), isProvisional: true
        ),
        TuningControl(
            key: .sharpnessArea, counted: .flag(.blurry)
        ),
        TuningControl(
            key: .facesTakePriority, counted: .flag(.blurry)
        ),

        // Similar stacks
        TuningControl(
            key: .stackGapSeconds, range: 1...60, step: 1, unit: .seconds, direction: .higherFlagsMore,
            counted: .stackedPhotos
        ),
        TuningControl(
            key: .stackDistance, range: 0.10...1.00, step: 0.01, scale: .sensitivity(rising: true), direction: .higherFlagsMore,
            counted: .stackedPhotos
        ),
        TuningControl(
            key: .minStackSize, range: 2...5, step: 1, unit: .photos, direction: .lowerFlagsMore,
            counted: .stackedPhotos
        ),
        TuningControl(
            key: .useBurstData, counted: .stackedPhotos
        ),
        TuningControl(
            key: .bestPickSharpnessMargin, range: 0...15, step: 0.5, unit: .number(decimals: 1), counted: nil, isProvisional: true
        ),
        TuningControl(
            key: .bestPickFaceQualityMargin, range: 0...0.30, step: 0.01, counted: nil, isProvisional: true
        ),

        // Duplicates
        TuningControl(
            key: .findExactDuplicates, counted: .exactDuplicatePhotos
        ),
        TuningControl(
            key: .findNearDuplicates, counted: .nearDuplicatePhotos
        ),
        TuningControl(
            key: .nearDuplicateDistance, range: 0.01...0.30, step: 0.01, direction: .higherFlagsMore,
            counted: .nearDuplicatePhotos, dependsOn: .findNearDuplicates
        ),

        // Exposure
        TuningControl(
            key: .flagExposure, counted: .exposure
        ),
        TuningControl(
            key: .clippedHighlightsAbove, range: 0.05...0.90, step: 0.01, unit: .percent, direction: .lowerFlagsMore,
            counted: .flag(.clippedHighlights), dependsOn: .flagExposure
        ),
        TuningControl(
            key: .clippedShadowsAbove, range: 0.05...0.90, step: 0.01, unit: .percent, direction: .lowerFlagsMore,
            counted: .flag(.clippedShadows), dependsOn: .flagExposure
        ),

        // Other issues
        TuningControl(
            key: .flagLowAesthetics, counted: .flag(.lowAesthetics)
        ),
        TuningControl(
            key: .lowAestheticsBelow, range: -1...1, step: 0.05, direction: .higherFlagsMore,
            counted: .flag(.lowAesthetics), dependsOn: .flagLowAesthetics
        ),
        TuningControl(
            key: .flagUtility, counted: .flag(.utility)
        ),
        TuningControl(
            key: .flagCutOffFaces, counted: .flag(.faceCutOff)
        ),
        TuningControl(
            key: .flagLensSmudge, counted: .flag(.lensSmudge)
        ),
        TuningControl(
            key: .lensSmudgeAbove, range: 0.05...0.95, step: 0.05, direction: .lowerFlagsMore,
            counted: .flag(.lensSmudge), dependsOn: .flagLensSmudge, isProvisional: true
        ),
        TuningControl(
            key: .flagTiltedHorizon, counted: .flag(.tiltedHorizon)
        ),
        TuningControl(
            key: .tiltedHorizonAboveDegrees, range: 0.5...15, step: 0.5, unit: .degrees, direction: .lowerFlagsMore,
            counted: .flag(.tiltedHorizon), dependsOn: .flagTiltedHorizon
        ),
    ]

    /// The main controls of a group, for its tuning panel. Empty for groups without any.
    public static func controls(for group: GroupID) -> [TuningControl] {
        let keys: [TuningKey] = switch group {
        case .eyesClosed: [.eyesClosedBelow, .eyesClosedCertainBelow]
        case .blurry: [.blurryBelow, .blurryCertainBelow]
        case .exposure: [.clippedHighlightsAbove, .clippedShadowsAbove]
        case .otherIssues:
            [.flagLowAesthetics, .lowAestheticsBelow, .flagUtility, .flagCutOffFaces, .flagLensSmudge, .lensSmudgeAbove,
             .flagTiltedHorizon, .tiltedHorizonAboveDegrees]
        case .similarStacks: [.stackGapSeconds, .stackDistance]
        case .duplicates: [.nearDuplicateDistance]
        case .allPhotos, .unreviewed, .kept, .rejected: []
        }
        return keys.map(control(for:))
    }

    /// The defaults of a group's controls, applied over a tuning: what resetting a group does.
    /// `defaults` is the tuning to take the values from: Balanced unless given.
    public static func resetting(_ group: GroupID, in tuning: Tuning, to defaults: Tuning = Tuning()) -> Tuning {
        var result = tuning
        for control in controls(for: group) {
            control.key.set(control.key.value(in: defaults), in: &result)
        }
        return result
    }
}

/// A detection pane of the Settings window: its controls in sections, in the Design doc's order.
public enum TuningPane: String, CaseIterable, Sendable, Hashable {
    case eyes
    case blur
    case similarity
    case duplicates
    case exposure
    case other

    public struct Section: Sendable, Hashable {
        /// Nil for the pane's first, untitled section.
        public var title: String?
        /// One line under the title, if any.
        public var note: String?
        public var controls: [TuningControl]

        /// Whether a control shows its live count: every slider does; a switch or a choice only
        /// when no slider of the section counts the same thing, so a section never repeats a count.
        public func showsCount(_ control: TuningControl) -> Bool {
            guard let counted = control.counted else { return false }
            if control.isSlider { return true }
            return !controls.contains { $0.isSlider && $0.counted == counted }
        }
    }

    public var title: String {
        switch self {
        case .eyes: localized("pane.eyes", default: "Eyes")
        case .blur: localized("pane.blur", default: "Blur")
        case .similarity: localized("pane.similarity", default: "Similarity")
        case .duplicates: localized("pane.duplicates", default: "Duplicates")
        case .exposure: localized("pane.exposure", default: "Exposure")
        case .other: localized("pane.other", default: "Other")
        }
    }

    /// The sidebar group the pane's controls fill.
    public var group: GroupID {
        switch self {
        case .eyes: .eyesClosed
        case .blur: .blurry
        case .similarity: .similarStacks
        case .duplicates: .duplicates
        case .exposure: .exposure
        case .other: .otherIssues
        }
    }

    public var sections: [Section] {
        func section(_ title: String?, note: String? = nil, _ keys: [TuningKey]) -> Section {
            Section(title: title, note: note, controls: keys.map(TuningControl.control(for:)))
        }
        switch self {
        case .eyes:
            return [
                section(nil, [.eyesClosedBelow, .eyesClosedCertainBelow, .groupPhotoRule, .countWinkAsClosed]),
                section(localized("Faces that count"), [.minFaceFraction, .ignoreBackgroundFaces, .backgroundFaceRatio, .skipProfiles, .maxYawDegrees]),
            ]
        case .blur:
            return [section(nil, [.blurryBelow, .blurryCertainBelow, .sharpnessArea, .facesTakePriority])]
        case .similarity:
            return [
                section(nil, [.stackGapSeconds, .stackDistance, .minStackSize, .useBurstData]),
                section(
                    localized("section.bestPick", default: "Best pick"),
                    note: localized("How a stack's best frame is chosen. Ties on sharpness go to faces, then to aesthetics."),
                    [.bestPickSharpnessMargin, .bestPickFaceQualityMargin]
                ),
            ]
        case .duplicates:
            return [section(nil, [.findExactDuplicates, .findNearDuplicates, .nearDuplicateDistance])]
        case .exposure:
            return [section(nil, [.flagExposure, .clippedHighlightsAbove, .clippedShadowsAbove])]
        case .other:
            return [
                // One box per kind of issue, each switch above its threshold.
                section(nil, [.flagCutOffFaces, .flagUtility]),
                section(nil, [.flagLensSmudge, .lensSmudgeAbove]),
                section(nil, [.flagTiltedHorizon, .tiltedHorizonAboveDegrees]),
                section(nil, [.flagLowAesthetics, .lowAestheticsBelow]),
            ]
        }
    }

    public var controls: [TuningControl] { sections.flatMap(\.controls) }

    /// The pane's values set back to Balanced, leaving every other value as it is.
    public func resetting(_ tuning: Tuning) -> Tuning {
        var result = tuning
        let balanced = Tuning()
        for control in controls { control.key.set(control.key.value(in: balanced), in: &result) }
        return result
    }
}

/// The numbers the tuning panel's and Settings' count lines read, measured on a session.
public struct TuningCounts: Sendable, Hashable {
    public var flags: [PhotoFlag: Int] = [:]
    public var certain: [PhotoFlag: Int] = [:]
    /// Photos with clipped highlights or shadows.
    public var exposurePhotos = 0
    public var stacks = 0
    public var stackedPhotos = 0
    public var nearDuplicateSets = 0
    public var nearDuplicatePhotos = 0
    public var exactDuplicateSets = 0
    public var exactDuplicatePhotos = 0

    public init() {}

    /// Counts every readable photo once. Linear in the number of photos.
    public init(_ state: SessionState) {
        for item in state.photos where !item.isUnreadable {
            guard let summary = state.summary(for: item.id) else { continue }
            for flag in summary.flags {
                flags[flag, default: 0] += 1
                if summary.tier(of: flag) == .certain { certain[flag, default: 0] += 1 }
            }
            if summary.flags.contains(.clippedHighlights) || summary.flags.contains(.clippedShadows) { exposurePhotos += 1 }
        }
        stacks = state.stacks.count
        stackedPhotos = state.stacks.reduce(0) { $0 + $1.members.count }
        for set in state.duplicateSets {
            switch set.kind {
            case .exact:
                exactDuplicateSets += 1
                exactDuplicatePhotos += set.members.count
            case .near:
                nearDuplicateSets += 1
                nearDuplicatePhotos += set.members.count
            }
        }
    }

    public func count(_ counted: TuningControl.Counted) -> Int {
        switch counted {
        case .flag(let flag): flags[flag] ?? 0
        case .certain(let flag): certain[flag] ?? 0
        case .exposure: exposurePhotos
        case .stackedPhotos: stackedPhotos
        case .exactDuplicatePhotos: exactDuplicatePhotos
        case .nearDuplicatePhotos: nearDuplicatePhotos
        }
    }

    /// The flag counts by name, for the automation dump.
    public var flagCountsByName: [String: Int] {
        Dictionary(uniqueKeysWithValues: PhotoFlag.allCases.map { ($0.rawValue, flags[$0] ?? 0) })
    }
}
