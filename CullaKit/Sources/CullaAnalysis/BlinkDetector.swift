import CoreGraphics
import CoreImage
import CullaCore
import Foundation

/// Core Image's face detector, used only for its closed-eye flags as a second opinion
/// beside the openness measured from Vision landmarks.
final class BlinkDetector: Sendable {
    struct Face: Sendable {
        var box: UnitRect
        var leftClosed: Bool?
        var rightClosed: Bool?
    }

    /// CIDetector is not documented as safe to call from several threads at once, so calls go
    /// through a serial queue. The queue also keeps them off Swift's cooperative pool: the
    /// detector is built on Vision and blocks its thread until Vision is done, which on the pool
    /// can starve the very Vision requests it waits behind (see `BlockingQueue`).
    private let queue = BlockingQueue(label: "Culla.blink-detector", concurrent: false)
    // Only touched on `queue`, one call at a time.
    nonisolated(unsafe) private let detector: CIDetector?

    init() {
        detector = CIDetector(
            ofType: CIDetectorTypeFace,
            context: nil,
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        )
    }

    func detect(in image: CGImage) async -> [Face] {
        await queue.run { self.detectNow(in: image) }
    }

    private func detectNow(in image: CGImage) -> [Face] {
        guard let detector else { return [] }
        let features = detector.features(in: CIImage(cgImage: image), options: [CIDetectorEyeBlink: true])
        let height = Double(image.height)
        return features.compactMap { feature in
            guard let face = feature as? CIFaceFeature else { return nil }
            // Core Image puts the origin at the bottom-left; flip to top-left.
            let bounds = face.bounds
            let flipped = CGRect(
                x: bounds.minX,
                y: height - Double(bounds.maxY),
                width: bounds.width,
                height: bounds.height
            )
            return Face(
                box: UnitRect(pixelRect: flipped, imageWidth: image.width, imageHeight: image.height),
                leftClosed: face.hasLeftEyePosition ? face.leftEyeClosed : nil,
                rightClosed: face.hasRightEyePosition ? face.rightEyeClosed : nil
            )
        }
    }
}
