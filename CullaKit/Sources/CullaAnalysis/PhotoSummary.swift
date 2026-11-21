import CullaCore
import Foundation

/// A problem a photo is flagged for, decided from its stored scores and the thresholds in `Tuning`.
public enum PhotoFlag: String, Sendable, Hashable, Codable, CaseIterable {
    /// The most closed main face has eye openness below `Tuning.eyesClosedBelow`.
    case eyesClosed
    /// The blur score is below `Tuning.blurryBelow`.
    case blurry
    /// More of the frame than `Tuning.clippedHighlightsAbove` is clipped to white.
    case clippedHighlights
    /// More of the frame than `Tuning.clippedShadowsAbove` is clipped to black.
    case clippedShadows
    /// Vision's aesthetics score is below `Tuning.lowAestheticsBelow`.
    case lowAesthetics
    /// Vision finds a horizon tilted by more than `Tuning.tiltedHorizonAboveDegrees`.
    /// Only raised when `Tuning.flagTiltedHorizon` is on, which it is not by default.
    case tiltedHorizon
    /// A main face touches the edge of the frame.
    case faceCutOff
    /// Vision's lens smudge confidence is above `Tuning.lensSmudgeAbove`.
    case lensSmudge
    /// Vision calls the photo a utility image: a screenshot, a document or an accidental shot.
    case utility
}

/// How sure Culla is about a flag. Only Certain flags can be rejected in bulk.
public enum FlagTier: String, Sendable, Hashable, Codable, CaseIterable, Comparable {
    /// Far enough past the threshold to be trusted without a look: eye openness below
    /// `Tuning.eyesClosedCertainBelow`, or a blur score below `Tuning.blurryCertainBelow`.
    case certain
    /// Past the threshold, but worth a look. Every flag other than Eyes Closed and Blurry is
    /// always Likely.
    case likely

    public static func < (lhs: FlagTier, rhs: FlagTier) -> Bool {
        lhs == .certain && rhs == .likely
    }
}

/// What Culla concludes about one photo from its stored scores and the current settings.
/// Cheap to compute, so it is derived whenever it is needed and never stored.
public struct PhotoSummary: Sendable, Hashable {
    /// Indices into the photo's faces of those that count: frontal enough (within
    /// `Tuning.maxYawDegrees`), at least `Tuning.minFaceFraction` of the short side, and at least
    /// `Tuning.backgroundFaceRatio` of the largest frontal face. Profiles never set that scale.
    public var mainFaces: [Int] = []
    /// Eye openness of the main face the group photo rule picks: by default the most closed one,
    /// since one shut pair of eyes spoils a group shot.
    public var eyeOpenness: Double?
    /// The face that set `eyeOpenness`.
    public var worstEyesFace: Int?
    /// True when Core Image flags both eyes closed on some main face.
    public var blinkFlagged = false
    /// Sharpness of the sharpest main face.
    public var faceSharpness: Double?
    /// The value the Blurry group sorts by.
    public var blurScore: Double = 0
    /// `blurScore` without contrast normalisation, kept for comparison while tuning.
    public var edgeStrength: Double = 0
    /// Centre of the sharpest spot in the region that set `blurScore`.
    public var focusPoint = UnitPoint(x: 0.5, y: 0.5)
    public var hasFaceCutByEdge = false
    /// Every threshold the photo falls on the wrong side of, for flags that are switched on.
    public var flags: Set<PhotoFlag> = []
    /// The tier of each flag in `flags`; it holds exactly the same flags.
    public var tiers: [PhotoFlag: FlagTier] = [:]

    /// The tier of a flag, or nil when the photo is not flagged for it.
    public func tier(of flag: PhotoFlag) -> FlagTier? { tiers[flag] }

    mutating func raise(_ flag: PhotoFlag, _ tier: FlagTier = .likely) {
        flags.insert(flag)
        tiers[flag] = tier
    }
}

extension PhotoSummary {
    /// Indices of the faces that count (see `mainFaces`), in the order given.
    ///
    /// The background scale comes from the largest face that is frontal enough to check. A big
    /// profile close to the camera is skipped, and must not turn the people behind it into
    /// background. With no frontal face there are no main faces.
    /// With `Tuning.skipProfiles` off every face counts as frontal enough; with
    /// `Tuning.ignoreBackgroundFaces` off no face counts as background.
    public static func mainFaces(of faces: [FaceScores], tuning: Tuning) -> [Int] {
        let frontal = faces.indices.filter { !tuning.skipProfiles || abs(faces[$0].yawDegrees) <= tuning.maxYawDegrees }
        let largest = frontal.map { faces[$0].sizeFraction }.max() ?? 0
        let backgroundRatio = tuning.ignoreBackgroundFaces ? tuning.backgroundFaceRatio : 0
        return frontal.filter { index in
            let size = faces[index].sizeFraction
            return size >= tuning.minFaceFraction && size >= backgroundRatio * largest
        }
    }
}

extension PhotoScores {
    public func summary(tuning: Tuning) -> PhotoSummary {
        var summary = PhotoSummary()
        summary.mainFaces = PhotoSummary.mainFaces(of: faces, tuning: tuning)

        var readings: [(face: Int, openness: Double)] = []
        for index in summary.mainFaces {
            let face = faces[index]
            if face.blinkFlagged { summary.blinkFlagged = true }
            if face.isCutByEdge { summary.hasFaceCutByEdge = true }
            guard let openness = face.eyeOpenness(countWinkAsClosed: tuning.countWinkAsClosed) else { continue }
            readings.append((index, openness))
        }
        // The group photo rule picks the face whose openness stands for the photo: the most
        // closed (any face), the one at the middle so that more than half are as closed or more
        // (most faces), or the most open (all faces). One threshold then decides the flag and tier.
        if !readings.isEmpty {
            let sorted = readings.sorted { $0.openness != $1.openness ? $0.openness < $1.openness : $0.face < $1.face }
            let position = switch tuning.groupPhotoRule {
            case .anyMainFace: 0
            case .mostFaces: sorted.count / 2
            case .allFaces: sorted.count - 1
            }
            summary.eyeOpenness = sorted[position].openness
            summary.worstEyesFace = sorted[position].face
        }

        // The whole frame has no separate edge strength or sharpest spot: the subject's stand in.
        summary.blurScore = tuning.sharpnessArea == .wholeFrame ? frameSharpness : subjectSharpness
        summary.edgeStrength = subjectEdgeStrength
        summary.focusPoint = subjectPeak

        // With people in the frame, focus is judged on the sharpest main face: a photo is soft
        // only when no main face is sharp, whatever the background looks like.
        let sharpest = summary.mainFaces
            .filter { faces[$0].sharpness != nil }
            .max { (faces[$0].sharpness ?? 0) < (faces[$1].sharpness ?? 0) }
        if let sharpest, let sharpness = faces[sharpest].sharpness {
            summary.faceSharpness = sharpness
            if tuning.facesTakePriority {
                summary.blurScore = sharpness
                summary.edgeStrength = faces[sharpest].edgeStrength ?? 0
                summary.focusPoint = faces[sharpest].sharpnessPeak ?? faces[sharpest].box.center
            }
        }

        // A missing reading never raises a flag: no eyes to judge, or no aesthetics score.
        if let openness = summary.eyeOpenness, openness < tuning.eyesClosedBelow {
            summary.raise(.eyesClosed, openness < tuning.eyesClosedCertainBelow ? .certain : .likely)
        }
        if summary.blurScore < tuning.blurryBelow {
            summary.raise(.blurry, summary.blurScore < tuning.blurryCertainBelow ? .certain : .likely)
        }
        if tuning.flagExposure {
            if clippedHighlights > tuning.clippedHighlightsAbove { summary.raise(.clippedHighlights) }
            if clippedShadows > tuning.clippedShadowsAbove { summary.raise(.clippedShadows) }
        }
        if tuning.flagLowAesthetics, let aesthetics, aesthetics < tuning.lowAestheticsBelow {
            summary.raise(.lowAesthetics)
        }
        // A horizon is a line, so 178 degrees is the same tilt as -2: fold into -90...90 first.
        if tuning.flagTiltedHorizon, let horizonDegrees,
           abs(Foundation.remainder(horizonDegrees, 180)) > tuning.tiltedHorizonAboveDegrees {
            summary.raise(.tiltedHorizon)
        }
        if tuning.flagCutOffFaces, summary.hasFaceCutByEdge { summary.raise(.faceCutOff) }
        if tuning.flagLensSmudge, let smudgeConfidence, smudgeConfidence > tuning.lensSmudgeAbove {
            summary.raise(.lensSmudge)
        }
        if tuning.flagUtility, isUtility == true { summary.raise(.utility) }
        return summary
    }
}
