import CoreGraphics
import CullaCore
import CullaFiles
import CullaPipeline
import CullaSession
import CullaStore
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// Writes a JPEG of stripes and squares, so the detectors have edges to measure.
private func writePattern(to url: URL, width: Int, height: Int, seed: Int, captureDate: String) throws {
    let context = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ))
    context.setFillColor(red: 0.9, green: 0.85, blue: 0.7, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    for index in 0..<40 {
        let shade = CGFloat((index * 37 + seed * 11) % 100) / 100
        context.setFillColor(red: shade, green: 1 - shade, blue: 0.3, alpha: 1)
        let x = (index * 53 + seed * 17) % width
        let y = (index * 29 + seed * 7) % height
        context.fill(CGRect(x: x, y: y, width: 40 + index % 30, height: 30 + index % 20))
    }
    let image = try #require(context.makeImage())
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
    let properties: [CFString: Any] = [
        kCGImageDestinationLossyCompressionQuality: 0.9,
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: captureDate],
    ]
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
}

@Suite("Pipeline end to end", .timeLimit(.minutes(2)))
struct EndToEndTests {
    @Test func theRealAnalyzerRunsThroughTheCoordinator() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CullaPipelineTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for index in 0..<4 {
            try writePattern(to: folder.appendingPathComponent("IMG_\(index).jpg"), width: 900, height: 600,
                             seed: index, captureDate: "2026:11:01 10:00:0\(index * 2)")
        }
        // An exact copy, and a file that is not an image.
        try FileManager.default.copyItem(at: folder.appendingPathComponent("IMG_0.jpg"), to: folder.appendingPathComponent("IMG_0 copy.jpg"))
        try Data("not a photo".utf8).write(to: folder.appendingPathComponent("broken.jpg"))

        let scanned = try await ShootLoader.load(folder: folder)
        #expect(scanned.count == 6)
        var session = SessionState(scanned: scanned)
        let database = try CullaDatabase.inMemory()
        let analysis = ShootAnalysis(database: database, analyze: StandardAnalysis.function(maxPixelSize: 512))
        let reader = EventReader(analysis)
        await analysis.start(photos: session.photos)
        let events = await reader.untilFinished()
        await analysis.cancel()

        for event in events {
            switch event {
            case .cachedScores(let scores): session.setScores(scores)
            case .analysed(let batch):
                session.setScores(batch.scores)
                for (id, reason) in batch.unreadable { session.markUnreadable(id, reason: reason) }
            case .grouping(let grouping): session.applyGrouping(grouping)
            default: break
            }
        }
        #expect(Set(events.analysedIDs).count == 5)
        #expect(events.unreadableIDs == ["broken.jpg"])
        #expect(session.totals.unreadable == 1)
        let scores = try #require(session.photo("IMG_1.jpg")?.scores)
        #expect(scores.analysedWidth == 512 && scores.analysedHeight == 341)
        #expect(scores.version == PhotoScores.currentVersion)
        #expect(scores.featurePrint != nil)
        #expect(scores.frameSharpness > 0)
        #expect(session.duplicateSets.contains { $0.kind == .exact && Set($0.members) == ["IMG_0.jpg", "IMG_0 copy.jpg"] })
        #expect(try await database.cachedScoreCount() == 5)

        // Reopening analyses nothing.
        let again = ShootAnalysis(database: database, analyze: { file, _ in
            // Only scores are cached, so the unreadable file is tried again; nothing else is.
            #expect(file.id == "broken.jpg")
            return .unreadable("Cannot decode broken.jpg")
        })
        let againReader = EventReader(again)
        await again.start(photos: SessionState(scanned: scanned).photos)
        let second = await againReader.untilFinished()
        #expect(second.cachedScores.count == 5)
        #expect(second.unreadableIDs == ["broken.jpg"])
        await again.cancel()
    }
}

@Suite("Pipeline stress", .timeLimit(.minutes(2)))
struct StressTests {
    @Test func fiveThousandPhotosThroughTheScheduler() async {
        let fake = FakeAnalyzer(delay: .milliseconds(1))
        let scheduler = AnalysisScheduler(concurrency: 8, analyze: fake.function)
        await scheduler.enqueue(fakeJobs(5000))
        var ids = Set<String>()
        var results = 0
        for await event in scheduler.events {
            if case .result(let result) = event {
                ids.insert(result.id)
                results += 1
                if results % 500 == 0 { await scheduler.setPriority(["p4999", "p4998"]) }
            }
            if case .idle = event { break }
        }
        #expect(results == 5000 && ids.count == 5000)
        #expect(fake.snapshot.maxRunning <= 8)
        let progress = await scheduler.progress()
        #expect(progress.done == 5000 && progress.total == 5000)
    }

    @Test func fiveThousandPhotosThroughTheCoordinator() async throws {
        let database = try CullaDatabase.inMemory()
        let fake = FakeAnalyzer(delay: .milliseconds(1)) { id in
            // Neighbouring frames in tens look alike, so stacks form.
            let group = Float(Int(id.dropFirst()) ?? 0) / 10
            return fakeScores(feature: [group.rounded(.down) * 10, 0, 0])
        }
        let jobs = fakeJobs(5000)
        let photos = jobs.map { PhotoItem(file: $0.file, metadata: PhotoMetadata(captureDate: $0.sortDate)) }
        var session = SessionState(photos: photos)
        let analysis = ShootAnalysis(database: database, analyze: fake.function)
        let reader = EventReader(analysis)
        let clock = ContinuousClock()
        let start = clock.now
        await analysis.start(photos: session.photos)
        let events = await reader.untilFinished()
        let elapsed = clock.now - start
        await analysis.cancel()

        var delivered: [String] = []
        for event in events {
            if case .analysed(let batch) = event {
                delivered += batch.scores.keys
                session.setScores(batch.scores)
            }
            if case .grouping(let grouping) = event { session.applyGrouping(grouping) }
        }
        #expect(delivered.count == 5000, "every photo is delivered once")
        #expect(Set(delivered).count == 5000)
        #expect(fake.snapshot.calls.count == 5000 && fake.snapshot.calls.values.allSatisfy { $0 == 1 })
        #expect(try await database.cachedScoreCount() == 5000)
        #expect(session.photos.allSatisfy { $0.scores != nil })
        #expect(session.stacks.count == 500 && session.stacks.allSatisfy { $0.members.count == 10 && $0.bestPick != nil })
        // Results are batched: a few events per second of work, not one per photo.
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        #expect(events.count < 30 + Int(seconds * 12), "\(events.count) events in \(seconds) s")
        #expect(events.count < 500)
    }
}
