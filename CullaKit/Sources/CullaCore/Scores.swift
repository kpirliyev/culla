import Foundation

/// Raw measurements for one detected face. Thresholds are applied later, never stored.
public struct FaceScores: Codable, Sendable, Hashable {
    public var box: UnitRect
    /// Face height as a share of the image's short side.
    public var sizeFraction: Double
    /// Eye height divided by eye width, from Vision landmarks. Lower means more closed.
    public var leftEyeOpenness: Double?
    public var rightEyeOpenness: Double?
    /// True when the eyes were measured on a cut-out of the face, because Vision gave no usable
    /// landmarks for it in the whole image. Nil when they were not.
    public var eyesFromCrop: Bool?
    /// Core Image's own closed-eye flags, when it found the same face.
    public var blinkLeft: Bool?
    public var blinkRight: Bool?
    public var yawDegrees: Double
    public var pitchDegrees: Double
    public var rollDegrees: Double
    /// Vision's face capture quality, 0 to 1.
    public var captureQuality: Double?
    /// Sharpness of the face region, the same measurement without contrast normalisation,
    /// and the centre of the sharpest spot on the face.
    public var sharpness: Double?
    public var edgeStrength: Double?
    public var sharpnessPeak: UnitPoint?
    public var confidence: Double
    public var isCutByEdge: Bool

    public init(
        box: UnitRect,
        sizeFraction: Double,
        leftEyeOpenness: Double? = nil,
        rightEyeOpenness: Double? = nil,
        eyesFromCrop: Bool? = nil,
        blinkLeft: Bool? = nil,
        blinkRight: Bool? = nil,
        yawDegrees: Double = 0,
        pitchDegrees: Double = 0,
        rollDegrees: Double = 0,
        captureQuality: Double? = nil,
        sharpness: Double? = nil,
        edgeStrength: Double? = nil,
        sharpnessPeak: UnitPoint? = nil,
        confidence: Double = 1,
        isCutByEdge: Bool = false
    ) {
        self.box = box
        self.sizeFraction = sizeFraction
        self.leftEyeOpenness = leftEyeOpenness
        self.rightEyeOpenness = rightEyeOpenness
        self.eyesFromCrop = eyesFromCrop
        self.blinkLeft = blinkLeft
        self.blinkRight = blinkRight
        self.yawDegrees = yawDegrees
        self.pitchDegrees = pitchDegrees
        self.rollDegrees = rollDegrees
        self.captureQuality = captureQuality
        self.sharpness = sharpness
        self.edgeStrength = edgeStrength
        self.sharpnessPeak = sharpnessPeak
        self.confidence = confidence
        self.isCutByEdge = isCutByEdge
    }

    /// One openness value for the face. A wink only counts as closed when asked to:
    /// otherwise the more open eye decides, so both eyes must be shut for a low value.
    public func eyeOpenness(countWinkAsClosed: Bool) -> Double? {
        switch (leftEyeOpenness, rightEyeOpenness) {
        case let (left?, right?):
            return countWinkAsClosed ? min(left, right) : max(left, right)
        case let (left?, nil):
            return left
        case let (nil, right?):
            return right
        case (nil, nil):
            return nil
        }
    }

    /// True when Core Image flags both eyes closed.
    public var blinkFlagged: Bool { blinkLeft == true && blinkRight == true }
}

/// Seconds spent in each stage for one photo.
public struct StageTimings: Codable, Sendable, Hashable {
    public var decode: Double = 0
    public var pixels: Double = 0
    public var vision: Double = 0

    public init(decode: Double = 0, pixels: Double = 0, vision: Double = 0) {
        self.decode = decode
        self.pixels = pixels
        self.vision = vision
    }

    public var total: Double { decode + pixels + vision }
}

/// Raw measurements for one photo. Which faces matter, and every flag and tier, are derived
/// from these at view time, so changing a setting never needs a second analysis.
public struct PhotoScores: Codable, Sendable {
    /// Bumped whenever a detector changes, so cached scores are recomputed.
    /// 2: faces that Vision gave no usable eye landmarks for are measured again on a cut-out.
    /// 3: RAW files are analysed on the camera's embedded preview when it is large enough
    ///    (`AnalysisImageLoader` in CullaFiles), so culla-eval and the app measure the same pixels.
    public static let currentVersion = 3

    public var version: Int = PhotoScores.currentVersion
    public var analysedWidth: Int
    public var analysedHeight: Int

    public var faces: [FaceScores] = []

    /// Where Vision's attention saliency puts the subject.
    public var subjectBox: UnitRect?
    /// Sharpness of the subject region, the same measurement without contrast normalisation,
    /// and the centre of its sharpest spot.
    public var subjectSharpness: Double = 0
    public var subjectEdgeStrength: Double = 0
    public var subjectPeak: UnitPoint = UnitPoint(x: 0.5, y: 0.5)
    public var frameSharpness: Double = 0

    /// Share of pixels at or near pure white, and at or near pure black.
    public var clippedHighlights: Double = 0
    public var clippedShadows: Double = 0

    /// Vision's aesthetics score, -1 to 1, and its "utility image" flag.
    public var aesthetics: Double?
    public var isUtility: Bool?
    public var smudgeConfidence: Double?
    public var horizonDegrees: Double?

    /// Vision's feature print as raw 32-bit floats.
    public var featurePrint: Data?

    public var timings = StageTimings()

    public init(analysedWidth: Int, analysedHeight: Int) {
        self.analysedWidth = analysedWidth
        self.analysedHeight = analysedHeight
    }

    public var featureVector: [Float]? {
        featurePrint.map(FeatureVector.decode)
    }
}

/// Packs a feature vector into compact binary so score files stay small.
public enum FeatureVector {
    public static func encode(_ values: [Float]) -> Data {
        values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    public static func decode(_ data: Data) -> [Float] {
        let count = data.count / MemoryLayout<Float>.stride
        var values = [Float](repeating: 0, count: count)
        _ = values.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return values
    }
}
