import CoreGraphics
import CullaCore
import Foundation
import Vision

/// Runs every detector on one decoded image and returns raw scores.
///
/// Nothing here applies a threshold: scores are stored as measured, and flags are derived
/// from them later, so changing a setting never needs a second analysis.
///
/// Safe to call from many tasks at once. The synchronous, long-running parts (the pixel loops
/// and Core Image's face detector) run on Dispatch queues rather than on Swift's cooperative
/// pool, so any number of photos in flight cannot starve the Vision requests of threads.
/// Core Image calls are serialised per analyzer, so a caller that analyses several photos at
/// once gets the most out of one analyzer per concurrent photo.
public struct PhotoAnalyzer: Sendable {
    private let blinkDetector = BlinkDetector()

    public init() {}

    /// Analyses an upright image. Detectors that fail leave their scores empty rather than failing the photo.
    public func analyze(_ image: CGImage) async -> PhotoScores {
        var scores = PhotoScores(analysedWidth: image.width, analysedHeight: image.height)
        let clock = ContinuousClock()

        // Pixel measurements: exposure and the sharpness map. Timed on the thread that does the
        // work, so the time spent waiting for a free thread is not counted.
        let pixels = await BlockingQueue.shared.run { () -> PixelMeasurements in
            let start = clock.now
            var measured = PixelMeasurements()
            if let gray = GrayImage(image) {
                measured.clipping = ExposureMeter.measure(gray)
                measured.sharpness = SharpnessMeter.map(of: gray)
            }
            measured.seconds = (clock.now - start).seconds
            return measured
        }
        let sharpness = pixels.sharpness
        if let clipping = pixels.clipping {
            scores.clippedHighlights = clipping.highlights
            scores.clippedShadows = clipping.shadows
        }
        scores.timings.pixels = pixels.seconds

        // Vision requests run side by side on one handler, which decodes the image once.
        // Core Image's detector runs alongside them; it suspends this task rather than blocking.
        let visionStart = clock.now
        let handler = ImageRequestHandler(image)
        async let saliencyResult = Self.attempt(GenerateAttentionBasedSaliencyImageRequest(), on: handler)
        async let featureResult = Self.attempt(GenerateImageFeaturePrintRequest(), on: handler)
        async let aestheticsResult = Self.attempt(CalculateImageAestheticsScoresRequest(), on: handler)
        async let horizonResult = Self.attempt(DetectHorizonRequest(), on: handler)
        async let smudgeResult = Self.attempt(DetectLensSmudgeRequest(), on: handler)
        async let faceResult = Self.detectFaces(on: handler)
        async let blinkResult = blinkDetector.detect(in: image)

        let observedFaces = await faceResult
        let blinkFaces = await blinkResult
        if let saliency = await saliencyResult {
            scores.subjectBox = Self.subjectBox(from: saliency)
        }
        if let feature = await featureResult {
            scores.featurePrint = FeatureVector.encode(Self.floats(from: feature))
        }
        if let aesthetics = await aestheticsResult {
            scores.aesthetics = Double(aesthetics.overallScore)
            scores.isUtility = aesthetics.isUtility
        }
        if let horizon = (await horizonResult).flatMap({ $0 }) {
            scores.horizonDegrees = horizon.angle.converted(to: .degrees).value
        }
        if let smudge = await smudgeResult {
            scores.smudgeConfidence = Double(smudge.confidence)
        }
        let eyes = await eyeReadings(for: observedFaces, in: image)
        scores.timings.vision = (clock.now - visionStart).seconds

        scores.faces = faceScores(
            for: observedFaces, eyes: eyes, blinkFaces: blinkFaces, image: image, sharpness: sharpness
        )
        if let sharpness {
            let subject = sharpness.measure(in: scores.subjectBox ?? .full)
            scores.subjectSharpness = subject.score
            scores.subjectEdgeStrength = subject.edgeStrength
            scores.subjectPeak = subject.peak
            scores.frameSharpness = sharpness.measure(in: .full).score
        }
        return scores
    }

    /// What the pixel loops produce, handed back from the Dispatch queue in one piece.
    private struct PixelMeasurements: Sendable {
        var clipping: ExposureMeter.Clipping?
        var sharpness: SharpnessMap?
        var seconds = 0.0
    }

    // MARK: - Faces

    /// Eye openness of one face, and whether it was measured on a cut-out of the face.
    private struct EyeReading: Sendable {
        var left: Double?
        var right: Double?
        var fromCrop = false
    }

    /// Reads both eyes of every face from its landmarks. Faces that come back without a reading,
    /// because Vision gives no usable landmarks for faces small in the frame (see `FaceCrop`),
    /// are measured again on a cut-out, one at a time, when they are large enough to judge.
    private func eyeReadings(for faces: [FaceObservation], in image: CGImage) async -> [EyeReading] {
        let size = CGSize(width: image.width, height: image.height)
        let shortSide = min(image.width, image.height)
        var readings = faces.map { face -> EyeReading in
            guard let landmarks = face.landmarks else { return EyeReading() }
            return EyeReading(
                left: EyeGeometry.openness(of: landmarks.leftEye.pointsInImageCoordinates(size, origin: .upperLeft)),
                right: EyeGeometry.openness(of: landmarks.rightEye.pointsInImageCoordinates(size, origin: .upperLeft))
            )
        }
        for index in faces.indices {
            let box = faces[index].boundingBox.toImageCoordinates(size, origin: .upperLeft)
            guard FaceCrop.needsSecondPass(
                leftOpenness: readings[index].left,
                rightOpenness: readings[index].right,
                faceHeight: Double(box.height),
                imageShortSide: shortSide
            ), let again = await Self.eyesOnCrop(of: box, in: image) else { continue }
            // Only missing eyes are filled in, so a reading from the first pass never changes.
            if readings[index].left == nil { readings[index].left = again.left }
            if readings[index].right == nil { readings[index].right = again.right }
            readings[index].fromCrop = true
        }
        return readings
    }

    /// Measures the eyes of the face in `box` (pixels, origin at the top-left) on a cut-out of
    /// it, trying each padding in turn until one gives a reading. The face box is handed to
    /// Vision rather than detected again, so the cut-out always measures the same face.
    private static func eyesOnCrop(of box: CGRect, in image: CGImage) async -> EyeReading? {
        for padding in FaceCrop.paddings {
            guard let crop = FaceCrop(face: box, imageWidth: image.width, imageHeight: image.height, padding: padding),
                  let cut = await BlockingQueue.shared.run({ Self.cut(image, crop) })
            else { continue }
            var request = DetectFaceLandmarksRequest()
            request.inputFaceObservations = [FaceObservation(boundingBox: NormalizedRect(normalizedRect: crop.faceInCrop))]
            guard let face = (try? await ImageRequestHandler(cut).perform(request))?.first,
                  let landmarks = face.landmarks
            else { continue }
            // Points are mapped back to the analysed image's own pixels, which are square,
            // before they are measured.
            let cutSize = CGSize(width: cut.width, height: cut.height)
            let reading = EyeReading(
                left: EyeGeometry.openness(
                    of: landmarks.leftEye.pointsInImageCoordinates(cutSize, origin: .upperLeft).map(crop.imagePoint)
                ),
                right: EyeGeometry.openness(
                    of: landmarks.rightEye.pointsInImageCoordinates(cutSize, origin: .upperLeft).map(crop.imagePoint)
                ),
                fromCrop: true
            )
            if reading.left != nil || reading.right != nil { return reading }
        }
        return nil
    }

    /// The cut-out an image gives for a crop, scaled when the crop asks for it.
    private static func cut(_ image: CGImage, _ crop: FaceCrop) -> CGImage? {
        guard let cropped = image.cropping(to: crop.source) else { return nil }
        guard crop.isScaled else { return cropped }
        guard let context = CGContext(
            data: nil,
            width: crop.width,
            height: crop.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        return context.makeImage()
    }

    private func faceScores(
        for faces: [FaceObservation],
        eyes: [EyeReading],
        blinkFaces: [BlinkDetector.Face],
        image: CGImage,
        sharpness: SharpnessMap?
    ) -> [FaceScores] {
        let size = CGSize(width: image.width, height: image.height)
        let shortSide = Double(min(image.width, image.height))
        let edgeMargin = 0.005

        return zip(faces, eyes).map { face, eyes -> FaceScores in
            let pixelBox = face.boundingBox.toImageCoordinates(size, origin: .upperLeft)
            let box = UnitRect(pixelRect: pixelBox, imageWidth: image.width, imageHeight: image.height)
            var score = FaceScores(box: box, sizeFraction: Double(pixelBox.height) / shortSide)

            score.leftEyeOpenness = eyes.left
            score.rightEyeOpenness = eyes.right
            if eyes.fromCrop { score.eyesFromCrop = true }
            score.yawDegrees = face.yaw.converted(to: .degrees).value
            score.pitchDegrees = face.pitch.converted(to: .degrees).value
            score.rollDegrees = face.roll.converted(to: .degrees).value
            score.captureQuality = face.captureQuality.map { Double($0.score) }
            score.confidence = Double(face.confidence)

            if let match = Self.bestMatch(for: box, in: blinkFaces.map(\.box), minimumOverlap: 0.3) {
                score.blinkLeft = blinkFaces[match].leftClosed
                score.blinkRight = blinkFaces[match].rightClosed
            }
            score.isCutByEdge = box.x <= edgeMargin || box.y <= edgeMargin
                || box.maxX >= 1 - edgeMargin || box.maxY >= 1 - edgeMargin
            // The outer tenth of a face box is mostly hair and background, so it is left out.
            if let measured = sharpness?.measure(in: box.inset(byFraction: 0.1)) {
                score.sharpness = measured.score
                score.edgeStrength = measured.edgeStrength
                score.sharpnessPeak = measured.peak
            }
            return score
        }
    }

    // MARK: - Vision helpers

    private static func attempt<Request: VisionRequest>(
        _ request: Request,
        on handler: ImageRequestHandler
    ) async -> Request.Result? where Request.Result: Sendable {
        try? await handler.perform(request)
    }

    /// Finds faces with landmarks, then asks Vision to rate the capture quality of those same faces.
    private static func detectFaces(on handler: ImageRequestHandler) async -> [FaceObservation] {
        guard let faces = try? await handler.perform(DetectFaceLandmarksRequest()), !faces.isEmpty else {
            return []
        }
        var qualityRequest = DetectFaceCaptureQualityRequest()
        qualityRequest.inputFaceObservations = faces
        let rated = (try? await handler.perform(qualityRequest)) ?? []
        let ratedBoxes = rated.map { unitRect($0.boundingBox) }

        return faces.map { face in
            guard face.captureQuality == nil,
                  let match = bestMatch(for: unitRect(face.boundingBox), in: ratedBoxes, minimumOverlap: 0.5)
            else { return face }
            var face = face
            face.captureQuality = rated[match].captureQuality
            return face
        }
    }

    /// Vision's normalised rectangles have their origin at the bottom-left; flip to top-left.
    private static func unitRect(_ rect: NormalizedRect) -> UnitRect {
        UnitRect(
            x: Double(rect.origin.x),
            y: 1 - Double(rect.origin.y) - Double(rect.height),
            width: Double(rect.width),
            height: Double(rect.height)
        )
    }

    private static func subjectBox(from saliency: SaliencyImageObservation) -> UnitRect? {
        let boxes = saliency.salientObjects.map { unitRect($0.boundingBox).clamped() }.filter { $0.area > 0 }
        guard var combined = boxes.first else { return nil }
        for box in boxes.dropFirst() {
            combined = combined.union(box)
        }
        return combined
    }

    private static func bestMatch(for box: UnitRect, in candidates: [UnitRect], minimumOverlap: Double) -> Int? {
        var bestIndex: Int?
        var bestOverlap = minimumOverlap
        for (index, candidate) in candidates.enumerated() {
            let overlap = box.intersectionOverUnion(with: candidate)
            if overlap >= bestOverlap {
                bestOverlap = overlap
                bestIndex = index
            }
        }
        return bestIndex
    }

    private static func floats(from observation: FeaturePrintObservation) -> [Float] {
        let count = observation.elementCount
        switch observation.elementType {
        case .float:
            var values = [Float](repeating: 0, count: count)
            _ = values.withUnsafeMutableBytes { observation.data.copyBytes(to: $0) }
            return values
        case .double:
            var values = [Double](repeating: 0, count: count)
            _ = values.withUnsafeMutableBytes { observation.data.copyBytes(to: $0) }
            return values.map(Float.init)
        @unknown default:
            return []
        }
    }
}

private extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
