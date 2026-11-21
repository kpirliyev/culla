import Foundation

/// Every adjustable parameter for judging and grouping stored scores. None of them affects analysis.
/// The flag thresholds and stack settings were chosen by eye on a real shoot; the rest are
/// starting proposals.
///
/// Decoding is tolerant: a key that is missing, such as a setting added after the file was
/// written, takes its default, so settings saved by an older build still load.
public struct Tuning: Codable, Sendable, Hashable {
    // Faces
    /// Smallest face that is checked, as a share of the image's short side.
    public var minFaceFraction = 0.04
    /// Faces smaller than this share of the largest frontal face count as background, when
    /// `ignoreBackgroundFaces` is on.
    public var backgroundFaceRatio = 0.40
    /// Whether faces much smaller than the largest one are left out (Settings ▸ Eyes: "Ignore
    /// background faces"). Off: every face of at least `minFaceFraction` counts.
    public var ignoreBackgroundFaces = true
    /// Faces turned further than this are treated as profiles and skipped, when `skipProfiles`
    /// is on.
    public var maxYawDegrees = 40.0
    /// Whether faces turned away (profiles) are skipped. Sunglasses are skipped either way when
    /// Vision gives no eye reading for them: a face without one never raises Eyes Closed.
    public var skipProfiles = true
    public var countWinkAsClosed = false
    /// Which main faces must have closed eyes for a photo to be flagged.
    public var groupPhotoRule = GroupPhotoRule.anyMainFace

    // Blur
    public var facesTakePriority = true
    /// What sharpness is measured on when no main face decides it.
    public var sharpnessArea = SharpnessArea.subject

    // Flags
    /// A photo is flagged Eyes Closed when its eye openness (`PhotoSummary.eyeOpenness`, the
    /// most closed main face) is below this. A photo without an eye reading is never flagged.
    public var eyesClosedBelow = 0.26
    /// A photo is flagged Blurry when its blur score (`PhotoSummary.blurScore`) is below this.
    public var blurryBelow = 25.0
    /// A photo is flagged for clipped highlights when more than this share of the frame,
    /// 0 to 1, is at or near pure white.
    public var clippedHighlightsAbove = 0.30
    /// A photo is flagged for clipped shadows when more than this share of the frame, 0 to 1,
    /// is at or near pure black.
    public var clippedShadowsAbove = 0.50
    /// A photo is flagged for low aesthetics when Vision's aesthetics score, -1 to 1, is below
    /// this. A photo without a score is never flagged.
    public var lowAestheticsBelow = 0.30

    // Tiers
    /// An Eyes Closed flag is Certain, rather than Likely, when the eye openness is also below
    /// this. Provisional: chosen without looking at real shoots, to be tuned in milestone M7.
    public var eyesClosedCertainBelow = 0.20
    /// A Blurry flag is Certain, rather than Likely, when the blur score is also below this.
    /// Provisional: chosen without looking at real shoots, to be tuned in milestone M7.
    public var blurryCertainBelow = 15.0

    // Other issues
    /// A photo is flagged for a tilted horizon when Vision finds a horizon tilted by more than
    /// this many degrees either way. A photo without a horizon reading is never flagged.
    public var tiltedHorizonAboveDegrees = 3.0
    /// A photo is flagged for a smudged lens when Vision's lens smudge confidence, 0 to 1, is
    /// above this. Provisional: no shoot with a smudged lens has been looked at yet.
    public var lensSmudgeAbove = 0.5

    // Which flags are raised at all. A flag that is switched off is never raised, so its photos
    // leave its group; nothing else changes.
    /// Tilted Horizon. Off by default: many good photos are tilted on purpose.
    public var flagTiltedHorizon = false
    /// Face Cut Off: a main face touches the edge of the frame.
    public var flagCutOffFaces = true
    /// Lens Smudge.
    public var flagLensSmudge = true
    /// Utility: what Vision calls a utility image, such as a screenshot, a document or an
    /// accidental shot.
    public var flagUtility = true
    /// Low Aesthetics.
    public var flagLowAesthetics = true
    /// Clipped Highlights and Clipped Shadows together, the Exposure group.
    public var flagExposure = true

    // Similar stacks
    /// Two frames further apart than this never share a stack.
    public var stackGapSeconds = 10.0
    /// Largest feature-print distance between neighbouring frames of a stack.
    public var stackDistance = 0.60
    public var minStackSize = 2
    /// Frames the camera marked as one burst always share a stack, whatever the time gap or the
    /// distance between them.
    public var useBurstData = true

    // Duplicates
    /// Files with identical content form a duplicate set.
    public var findExactDuplicates = true
    /// Files whose images match (resized or re-saved copies) form a duplicate set.
    public var findNearDuplicates = true
    /// Largest feature-print distance at which two files count as the same image.
    public var nearDuplicateDistance = 0.08

    // Best pick of a stack (see `BestPick`)
    /// Frames whose blur scores lie within this of the sharpest frame's count as equally sharp,
    /// so face quality and aesthetics decide between them. Provisional, to be tuned in M7.
    public var bestPickSharpnessMargin = 3.0
    /// Frames whose face capture quality, 0 to 1, lies within this of the best frame's count as
    /// equally good, so aesthetics decides between them. Provisional, to be tuned in M7.
    public var bestPickFaceQualityMargin = 0.05

    public init() {}

    public init(from decoder: any Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func read<Value: Decodable>(_ key: CodingKeys, into value: inout Value) throws {
            if let decoded = try container.decodeIfPresent(Value.self, forKey: key) { value = decoded }
        }
        try read(.minFaceFraction, into: &minFaceFraction)
        try read(.backgroundFaceRatio, into: &backgroundFaceRatio)
        try read(.ignoreBackgroundFaces, into: &ignoreBackgroundFaces)
        try read(.maxYawDegrees, into: &maxYawDegrees)
        try read(.skipProfiles, into: &skipProfiles)
        try read(.countWinkAsClosed, into: &countWinkAsClosed)
        // A rule or area a later version added reads as the default, not as a failure.
        try? read(.groupPhotoRule, into: &groupPhotoRule)
        try read(.facesTakePriority, into: &facesTakePriority)
        try? read(.sharpnessArea, into: &sharpnessArea)
        try read(.eyesClosedBelow, into: &eyesClosedBelow)
        try read(.blurryBelow, into: &blurryBelow)
        try read(.clippedHighlightsAbove, into: &clippedHighlightsAbove)
        try read(.clippedShadowsAbove, into: &clippedShadowsAbove)
        try read(.lowAestheticsBelow, into: &lowAestheticsBelow)
        try read(.eyesClosedCertainBelow, into: &eyesClosedCertainBelow)
        try read(.blurryCertainBelow, into: &blurryCertainBelow)
        try read(.tiltedHorizonAboveDegrees, into: &tiltedHorizonAboveDegrees)
        try read(.lensSmudgeAbove, into: &lensSmudgeAbove)
        try read(.flagTiltedHorizon, into: &flagTiltedHorizon)
        try read(.flagCutOffFaces, into: &flagCutOffFaces)
        try read(.flagLensSmudge, into: &flagLensSmudge)
        try read(.flagUtility, into: &flagUtility)
        try read(.flagLowAesthetics, into: &flagLowAesthetics)
        try read(.flagExposure, into: &flagExposure)
        try read(.stackGapSeconds, into: &stackGapSeconds)
        try read(.stackDistance, into: &stackDistance)
        try read(.minStackSize, into: &minStackSize)
        try read(.useBurstData, into: &useBurstData)
        try read(.findExactDuplicates, into: &findExactDuplicates)
        try read(.findNearDuplicates, into: &findNearDuplicates)
        try read(.nearDuplicateDistance, into: &nearDuplicateDistance)
        try read(.bestPickSharpnessMargin, into: &bestPickSharpnessMargin)
        try read(.bestPickFaceQualityMargin, into: &bestPickFaceQualityMargin)
    }
}

/// Which main faces must have closed eyes for a photo to be flagged Eyes Closed (Settings ▸
/// Eyes: "Group photo rule").
public enum GroupPhotoRule: String, Codable, Sendable, Hashable, CaseIterable {
    /// Any one main face with closed eyes spoils the photo.
    case anyMainFace
    /// More than half of the main faces have closed eyes.
    case mostFaces
    /// Every main face has closed eyes.
    case allFaces
}

/// What blur is measured on when no main face decides it (Settings ▸ Blur: "Measure sharpness on").
public enum SharpnessArea: String, Codable, Sendable, Hashable, CaseIterable {
    /// The region Vision's attention saliency marks as the subject.
    case subject
    /// The whole frame.
    case wholeFrame
}
