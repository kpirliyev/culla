import CullaCore
import Foundation

/// What best-pick ranking looks at in one frame of a stack.
public struct BestPickCandidate: Sendable, Hashable {
    /// True when some main face has eyes below `Tuning.eyesClosedBelow`: the Eyes Closed flag.
    public var eyesClosed: Bool
    /// The blur score (`PhotoSummary.blurScore`): higher is sharper.
    public var sharpness: Double
    /// Mean Vision face capture quality of the main faces, 0 to 1. Nil without a rated main face.
    public var faceQuality: Double?
    /// Vision's aesthetics score, -1 to 1.
    public var aesthetics: Double?

    public init(eyesClosed: Bool, sharpness: Double, faceQuality: Double? = nil, aesthetics: Double? = nil) {
        self.eyesClosed = eyesClosed
        self.sharpness = sharpness
        self.faceQuality = faceQuality
        self.aesthetics = aesthetics
    }

    /// The candidate a frame's scores give under the current tuning.
    public init(scores: PhotoScores, tuning: Tuning) {
        let summary = scores.summary(tuning: tuning)
        let qualities = summary.mainFaces.compactMap { scores.faces[$0].captureQuality }
        self.init(
            eyesClosed: summary.flags.contains(.eyesClosed),
            sharpness: summary.blurScore,
            faceQuality: qualities.isEmpty ? nil : qualities.reduce(0, +) / Double(qualities.count),
            aesthetics: scores.aesthetics
        )
    }
}

/// Chooses the best frame of a stack. The whole rule lives here; its margins are in `Tuning`.
///
/// The frames are narrowed down in four steps, each applied only to the frames left by the one
/// before:
///
/// 1. **Eyes.** Frames with no main face below the eyes-closed threshold
///    (`Tuning.eyesClosedBelow`) beat every frame with one. When all frames have closed eyes,
///    all stay.
/// 2. **Sharpness.** Frames whose blur score lies within `Tuning.bestPickSharpnessMargin` of the
///    sharpest remaining frame stay.
/// 3. **Face quality.** Frames whose mean face capture quality lies within
///    `Tuning.bestPickFaceQualityMargin` of the best remaining frame's stay. A frame without a
///    rating drops out when another has one.
/// 4. **Aesthetics.** The frames with the highest aesthetics score stay; a frame without a score
///    drops out when another has one.
///
/// Of what is left, the earliest frame wins. Narrowing within a margin of the best, rather than
/// comparing two frames at a time, keeps the result the same whatever order the frames are
/// compared in.
public enum BestPick {
    /// The index of the best frame. Frames are given in capture order. Nil when there are none.
    public static func best(_ frames: [BestPickCandidate], tuning: Tuning) -> Int? {
        best(among: Array(frames.indices), of: frames, tuning: tuning)
    }

    /// Every frame's index, best first: the best frame, then the best of the rest, and so on.
    public static func ranking(_ frames: [BestPickCandidate], tuning: Tuning) -> [Int] {
        var remaining = Array(frames.indices)
        var result: [Int] = []
        while let next = best(among: remaining, of: frames, tuning: tuning) {
            result.append(next)
            remaining.removeAll { $0 == next }
        }
        return result
    }

    private static func best(among indices: [Int], of frames: [BestPickCandidate], tuning: Tuning) -> Int? {
        var pool = indices
        guard !pool.isEmpty else { return nil }

        let openEyes = pool.filter { !frames[$0].eyesClosed }
        if !openEyes.isEmpty { pool = openEyes }

        if let sharpest = pool.map({ frames[$0].sharpness }).max() {
            pool = pool.filter { frames[$0].sharpness >= sharpest - tuning.bestPickSharpnessMargin }
        }
        if let bestQuality = pool.compactMap({ frames[$0].faceQuality }).max() {
            pool = pool.filter { frames[$0].faceQuality.map { $0 >= bestQuality - tuning.bestPickFaceQualityMargin } ?? false }
        }
        if let bestAesthetics = pool.compactMap({ frames[$0].aesthetics }).max() {
            pool = pool.filter { frames[$0].aesthetics.map { $0 >= bestAesthetics } ?? false }
        }
        return pool.min()
    }
}
