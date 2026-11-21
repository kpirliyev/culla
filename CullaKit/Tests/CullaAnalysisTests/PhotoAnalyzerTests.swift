import CoreGraphics
import CullaAnalysis
import CullaCore
import Foundation
import Testing

/// These run the real Vision and Core Image detectors on synthetic images without faces.
@Suite("PhotoAnalyzer", .serialized)
struct PhotoAnalyzerTests {
    private func makeImages(count: Int) throws -> [CGImage] {
        try (0..<count).map { index in
            let gray = SyntheticImages.flat(
                width: 640,
                height: 480,
                texturedIn: (x: 160 + index * 4..<480, y: 120..<360),
                seed: UInt64(index + 1)
            )
            return try #require(SyntheticImages.cgImage(gray))
        }
    }

    @Test func analysesASyntheticImage() async throws {
        let image = try #require(try makeImages(count: 1).first)
        let scores = await PhotoAnalyzer().analyze(image)
        #expect(scores.analysedWidth == 640 && scores.analysedHeight == 480)
        #expect(scores.faces.isEmpty)
        #expect(scores.frameSharpness > 10)
        #expect(scores.clippedHighlights < 0.05)
        #expect(scores.featurePrint != nil)
        #expect(scores.timings.pixels > 0 && scores.timings.vision > 0)
    }

    /// A request this machine has no device for is not performed, so its score stays empty.
    /// Lens smudge runs only on the Neural Engine, which a virtual machine (GitHub's macOS
    /// runners) lacks; there the score must be nil rather than the process stopping in Vision.
    /// On a Mac with a Neural Engine, the request runs and the synthetic image gets a confidence.
    @Test func leavesTheScoreOfASkippedRequestEmpty() async throws {
        let image = try #require(try makeImages(count: 1).first)
        let available = await VisionAvailability.current()
        let scores = await PhotoAnalyzer().analyze(image)
        if available.isUsable(.lensSmudge) {
            #expect(scores.smudgeConfidence != nil)
        } else {
            #expect(scores.smudgeConfidence == nil)
        }
        if !available.isUsable(.horizon) { #expect(scores.horizonDegrees == nil) }
        if !available.isUsable(.aesthetics) { #expect(scores.aesthetics == nil) }
    }

    /// Many more photos in flight than the machine has cores. Before Core Image's detector was
    /// moved off the cooperative pool this stopped for good once every pool thread was waiting
    /// inside it.
    @Test(.timeLimit(.minutes(2)), arguments: [false, true])
    func manyPhotosAtOnceAllFinishWithTheSameScores(sharedAnalyzer: Bool) async throws {
        let count = max(16, ProcessInfo.processInfo.activeProcessorCount * 3)
        let images = try makeImages(count: 4)
        let shared = PhotoAnalyzer()
        let reference = await PhotoAnalyzer().analyze(images[0])

        let results = await withTaskGroup(of: (Int, PhotoScores).self, returning: [Int: PhotoScores].self) { group in
            for index in 0..<count {
                let analyzer = sharedAnalyzer ? shared : PhotoAnalyzer()
                let image = images[index % images.count]
                group.addTask { (index, await analyzer.analyze(image)) }
            }
            return await group.reduce(into: [:]) { $0[$1.0] = $1.1 }
        }

        #expect(results.count == count)
        for (index, scores) in results where index % images.count == 0 {
            #expect(scores.frameSharpness == reference.frameSharpness)
            #expect(scores.subjectSharpness == reference.subjectSharpness)
            #expect(scores.clippedShadows == reference.clippedShadows)
            #expect(scores.featurePrint == reference.featurePrint)
            #expect(scores.aesthetics == reference.aesthetics)
        }
    }
}
