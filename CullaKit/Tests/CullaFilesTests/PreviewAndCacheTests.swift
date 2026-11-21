import CoreGraphics
import CullaCore
import CullaFiles
import Foundation
import ImageIO
import Synchronization
import Testing
import UniformTypeIdentifiers

/// Test images written in code.
enum TestImages {
    /// A gradient, `width` by `height` pixels as stored.
    static func image(width: Int, height: Int) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        for x in stride(from: 0, to: width, by: 4) {
            let shade = CGFloat(x) / CGFloat(max(width - 1, 1))
            context.setFillColor(red: shade, green: 0.4, blue: 1 - shade, alpha: 1)
            context.fill(CGRect(x: x, y: 0, width: 4, height: height))
        }
        return try #require(context.makeImage())
    }

    /// Writes a JPEG, optionally with an EXIF orientation and an embedded thumbnail.
    @discardableResult
    static func writeJPEG(
        to url: URL,
        width: Int,
        height: Int,
        orientation: Int = 1,
        embedThumbnail: Bool = false,
        captureDate: String? = nil
    ) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        var properties: [CFString: Any] = [
            kCGImagePropertyOrientation: orientation,
            kCGImageDestinationLossyCompressionQuality: 0.8,
            kCGImageDestinationEmbedThumbnail: embedThumbnail,
        ]
        if let captureDate {
            properties[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: captureDate]
        }
        CGImageDestinationAddImage(destination, try image(width: width, height: height), properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    static func photoFile(_ url: URL, id: String? = nil) throws -> PhotoFile {
        // URLs remember resource values once read; a file rewritten since must be read afresh.
        var url = url
        url.removeAllCachedResourceValues()
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return PhotoFile(
            id: id ?? url.lastPathComponent,
            url: url,
            fileSize: Int64(values.fileSize ?? 0),
            modificationDate: values.contentModificationDate ?? .distantPast,
            isRAW: false
        )
    }
}

@Suite("PreviewLoader")
struct PreviewLoaderTests {
    @Test func thumbnailsAreDecodedWhenThereIsNoLargeEnoughPreview() throws {
        let folder = try TemporaryFolder()
        let url = try TestImages.writeJPEG(to: folder.url.appendingPathComponent("plain.jpg"), width: 1200, height: 800)
        let preview = try PreviewLoader.load(url, size: .thumbnail())
        #expect(preview.image.width == 512 && preview.image.height == 341)
        #expect(!preview.usedEmbeddedPreview)
    }

    @Test func aLargeEnoughEmbeddedPreviewIsUsed() throws {
        let folder = try TemporaryFolder()
        let url = try TestImages.writeJPEG(
            to: folder.url.appendingPathComponent("thumb.jpg"), width: 1200, height: 800, embedThumbnail: true
        )
        // ImageIO cannot write RAW files, so the RAW path is checked on a JPEG with the policy
        // that looks for embedded previews in every file. ImageIO embeds a thumbnail of about
        // 160 px: enough for a 100 px request, not for 512.
        let small = try PreviewLoader.load(url, size: .thumbnail(maxPixelSize: 100), embeddedPreview: .always)
        #expect(small.usedEmbeddedPreview)
        #expect(max(small.image.width, small.image.height) == 100)
        let large = try PreviewLoader.load(url, size: .thumbnail(maxPixelSize: 512), embeddedPreview: .always)
        #expect(!large.usedEmbeddedPreview)
        #expect(large.image.width == 512)
        // By default a JPEG is decoded.
        #expect(!(try PreviewLoader.load(url, size: .thumbnail(maxPixelSize: 100))).usedEmbeddedPreview)
    }

    @Test func previewsComeOutUpright() throws {
        let folder = try TemporaryFolder()
        // Stored landscape, shown portrait: orientation 6 turns it a quarter.
        let url = try TestImages.writeJPEG(
            to: folder.url.appendingPathComponent("turned.jpg"), width: 1200, height: 800, orientation: 6, embedThumbnail: true
        )
        for size in [PreviewSize.thumbnail(maxPixelSize: 100), .thumbnail(), .screen(maxPixelSize: 1000), .full] {
            for policy in [EmbeddedPreviewPolicy.always, .never] {
                let image = try PreviewLoader.load(url, size: size, embeddedPreview: policy).image
                #expect(image.height > image.width, "\(size) \(policy)")
            }
        }
        let full = try PreviewLoader.load(url, size: .full).image
        #expect(full.width == 800 && full.height == 1200)
    }

    @Test func screenSizeNeverScalesUp() throws {
        let folder = try TemporaryFolder()
        let url = try TestImages.writeJPEG(to: folder.url.appendingPathComponent("small.jpg"), width: 300, height: 200)
        let image = try PreviewLoader.load(url, size: .screen(maxPixelSize: 2000)).image
        #expect(image.width == 300 && image.height == 200)
    }

    @Test func unreadableFilesThrow() async throws {
        let folder = try TemporaryFolder()
        let url = try folder.file("broken.jpg", contents: Data("not an image".utf8))
        await #expect(throws: ImageLoaderError.self) { try await PreviewLoader.preview(url, size: .thumbnail()) }
    }
}

@Suite("ThumbnailCache")
struct ThumbnailCacheTests {
    @Test func memoryThenDiskThenDecode() async throws {
        let folder = try TemporaryFolder()
        let cacheFolder = folder.url.appendingPathComponent("cache")
        let url = try TestImages.writeJPEG(to: folder.url.appendingPathComponent("shoot/a.jpg"), width: 1500, height: 1000)
        let file = try TestImages.photoFile(url)

        let cache = try ThumbnailCache(folder: cacheFolder)
        #expect(cache.cachedThumbnail(for: file) == nil)
        let first = try await cache.thumbnail(for: file)
        #expect(first.width == 512)
        _ = try await cache.thumbnail(for: file)
        #expect(cache.cachedThumbnail(for: file) != nil)
        #expect(cache.statistics.decodes == 1)
        #expect(cache.statistics.memoryHits == 2)

        // A new cache on the same folder finds it on disk.
        let reopened = try ThumbnailCache(folder: cacheFolder)
        let fromDisk = try await reopened.thumbnail(for: file)
        #expect(fromDisk.width == 512)
        #expect(reopened.statistics.diskHits == 1)
        #expect(reopened.statistics.decodes == 0)

        // A changed file gets a new thumbnail.
        try await Task.sleep(for: .milliseconds(20))
        try TestImages.writeJPEG(to: url, width: 1000, height: 1500)
        let changed = try TestImages.photoFile(url)
        let redone = try await reopened.thumbnail(for: changed)
        #expect(redone.height == 512)
        #expect(reopened.statistics.decodes == 1)
    }

    @Test func concurrentRequestsShareOneDecode() async throws {
        let folder = try TemporaryFolder()
        let url = try TestImages.writeJPEG(to: folder.url.appendingPathComponent("a.jpg"), width: 3000, height: 2000)
        let file = try TestImages.photoFile(url)
        let cache = try ThumbnailCache(folder: folder.url.appendingPathComponent("cache"))
        let sizes = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<20 {
                group.addTask { try await cache.thumbnail(for: file).width }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(sizes == Array(repeating: 512, count: 20))
        #expect(cache.statistics.decodes == 1)
    }

    @Test func aCancelledRequestNeverDecodes() async throws {
        let folder = try TemporaryFolder()
        let cacheFolder = folder.url.appendingPathComponent("cache")
        let big = try TestImages.photoFile(
            TestImages.writeJPEG(to: folder.url.appendingPathComponent("big.jpg"), width: 6000, height: 4000)
        )
        let other = try TestImages.photoFile(
            TestImages.writeJPEG(to: folder.url.appendingPathComponent("other.jpg"), width: 800, height: 600)
        )
        // One decode at a time: the second request waits for the first, and is cancelled while it waits.
        let cache = try ThumbnailCache(folder: cacheFolder, maxConcurrentDecodes: 1)
        let first = Task { try await cache.thumbnail(for: big) }
        try await Task.sleep(for: .milliseconds(5))
        let second = Task { try await cache.thumbnail(for: other) }
        second.cancel()
        await #expect(throws: CancellationError.self) { try await second.value }
        _ = try await first.value
        // Give a wrongly started decode time to finish before counting.
        try await Task.sleep(for: .milliseconds(200))
        #expect(cache.statistics.decodes == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: cacheFolder.path).count == 1)

        // Asked again, it is made as usual.
        #expect(try await cache.thumbnail(for: other).width == 512)
    }

    @Test func unreadableFilesThrowAndAreNotCached() async throws {
        let folder = try TemporaryFolder()
        let file = try TestImages.photoFile(try folder.file("broken.jpg", contents: Data("nope".utf8)))
        let cache = try ThumbnailCache(folder: folder.url.appendingPathComponent("cache"))
        await #expect(throws: ImageLoaderError.self) { try await cache.thumbnail(for: file) }
        #expect(cache.cachedThumbnail(for: file) == nil)
    }

    @Test func memoryStaysWithinItsLimit() async throws {
        let folder = try TemporaryFolder()
        // About 0.7 MB per thumbnail, so a 2 MB limit keeps two.
        let cache = try ThumbnailCache(folder: folder.url.appendingPathComponent("cache"), memoryLimit: 2 << 20)
        var files: [PhotoFile] = []
        for index in 0..<5 {
            let url = try TestImages.writeJPEG(to: folder.url.appendingPathComponent("\(index).jpg"), width: 1200, height: 800)
            files.append(try TestImages.photoFile(url))
            _ = try await cache.thumbnail(for: files[index])
        }
        #expect(cache.memoryUsage <= 2 << 20)
        #expect(cache.cachedThumbnail(for: files[4]) != nil)
        #expect(cache.cachedThumbnail(for: files[0]) == nil)
        cache.clearMemory()
        #expect(cache.memoryUsage == 0)
    }

    @Test func pruningRemovesTheLeastRecentlyUsedFirst() async throws {
        let folder = try TemporaryFolder()
        let cacheFolder = folder.url.appendingPathComponent("cache")
        let cache = try ThumbnailCache(folder: cacheFolder)
        var files: [PhotoFile] = []
        for index in 0..<4 {
            let url = try TestImages.writeJPEG(to: folder.url.appendingPathComponent("\(index).jpg"), width: 1200, height: 800)
            files.append(try TestImages.photoFile(url))
            _ = try await cache.thumbnail(for: files[index])
            try await Task.sleep(for: .milliseconds(20))
        }
        // Reading the first one from disk makes it the most recently used.
        let reader = try ThumbnailCache(folder: cacheFolder)
        _ = try await reader.thumbnail(for: files[0])

        let total = try await cache.diskUsage()
        #expect(total > 0)
        let deleted = try await cache.pruneDisk(toBytes: total / 2)
        #expect(deleted == 2)
        #expect(try await cache.diskUsage() <= total / 2)

        let after = try ThumbnailCache(folder: cacheFolder)
        _ = try await after.thumbnail(for: files[0])
        _ = try await after.thumbnail(for: files[3])
        #expect(after.statistics.diskHits == 2)
        _ = try await after.thumbnail(for: files[1])
        #expect(after.statistics.decodes == 1)
        #expect(try await cache.pruneDisk(toBytes: .max) == 0)
    }
}

@Suite("AsyncLimiter")
struct AsyncLimiterTests {
    @Test func neverRunsMoreThanTheLimit() async throws {
        let limiter = AsyncLimiter(limit: 3)
        let counter = Counter()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<30 {
                group.addTask {
                    try await limiter.run {
                        await counter.enter()
                        try await Task.sleep(for: .milliseconds(2))
                        await counter.leave()
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(await counter.peak == 3)
    }

    actor Counter {
        var current = 0
        var peak = 0
        func enter() {
            current += 1
            peak = max(peak, current)
        }
        func leave() { current -= 1 }
    }
}

@Suite("ShootLoader")
struct ShootLoaderTests {
    @Test func loadsPhotosWithMetadataAndReportsProgress() async throws {
        let folder = try TemporaryFolder()
        for index in 0..<300 {
            try TestImages.writeJPEG(
                to: folder.url.appendingPathComponent(String(format: "IMG_%04d.jpg", index)), width: 64, height: 48,
                captureDate: String(format: "2026:11:01 10:%02d:%02d", index / 60, index % 60)
            )
        }
        try folder.file("IMG_0000.NEF", contents: Data("raw".utf8))
        try folder.file("clip.mov", contents: Data("video".utf8))
        let updates = Updates()
        let photos = try await ShootLoader.load(folder: folder.url) { updates.append($0) }

        #expect(photos.count == 300)
        #expect(photos[0].file.companions.map(\.lastPathComponent) == ["IMG_0000.NEF"])
        #expect(photos.allSatisfy { $0.metadata.pixelWidth == 64 && $0.metadata.captureDate != nil })
        let seen = updates.all
        #expect(seen.first?.phase == .scanning)
        #expect(seen.last == ShootLoadProgress(phase: .finished, done: 300, total: 300))
        #expect(seen.filter { $0.phase == .readingMetadata }.map(\.done) == [0, 256, 300])
    }

    @Test func knownMetadataIsReusedForUnchangedFiles() async throws {
        let folder = try TemporaryFolder()
        try TestImages.writeJPEG(to: folder.url.appendingPathComponent("a.jpg"), width: 64, height: 48)
        try TestImages.writeJPEG(to: folder.url.appendingPathComponent("b.jpg"), width: 64, height: 48)
        let first = try await ShootLoader.load(folder: folder.url)

        // Pretend the store remembered different metadata, and that b.jpg changed size since.
        let known = first.map { photo in
            var photo = photo
            photo.metadata.cameraModel = "from the store"
            if photo.id == "b.jpg" { photo.file.fileSize += 1 }
            return photo
        }
        let second = try await ShootLoader.load(folder: folder.url, known: known)
        #expect(second.map(\.metadata.cameraModel) == ["from the store", nil])
    }

    @Test func aMissingFolderThrows() async {
        await #expect(throws: (any Error).self) {
            try await ShootLoader.load(folder: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"))
        }
    }

    @Test func cancellationStopsTheLoad() async throws {
        let folder = try TemporaryFolder()
        for index in 0..<10 {
            try TestImages.writeJPEG(to: folder.url.appendingPathComponent("\(index).jpg"), width: 16, height: 16)
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ShootLoader.load(folder: folder.url)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    final class Updates: Sendable {
        private let storage = Mutex<[ShootLoadProgress]>([])
        func append(_ update: ShootLoadProgress) { storage.withLock { $0.append(update) } }
        var all: [ShootLoadProgress] { storage.withLock { $0 } }
    }
}

@Suite("FolderBookmark")
struct FolderBookmarkTests {
    @Test func aBookmarkResolvesToTheFolder() throws {
        let folder = try TemporaryFolder()
        let shoot = folder.url.appendingPathComponent("Shoot", isDirectory: true)
        try FileManager.default.createDirectory(at: shoot, withIntermediateDirectories: true)
        let data = try FolderBookmark.create(for: shoot, securityScoped: false)
        let resolved = try FolderBookmark.resolve(data, securityScoped: false)
        #expect(resolved.url.resolvingSymlinksInPath().path == shoot.resolvingSymlinksInPath().path)
        #expect(!resolved.isStale)
    }

    @Test func aBookmarkFollowsAMovedFolder() throws {
        let folder = try TemporaryFolder()
        let shoot = folder.url.appendingPathComponent("Before", isDirectory: true)
        try FileManager.default.createDirectory(at: shoot, withIntermediateDirectories: true)
        let data = try FolderBookmark.create(for: shoot, securityScoped: false)
        let moved = folder.url.appendingPathComponent("After", isDirectory: true)
        try FileManager.default.moveItem(at: shoot, to: moved)
        let resolved = try FolderBookmark.resolve(data, securityScoped: false)
        #expect(resolved.url.lastPathComponent == "After")
        let access = FolderAccess(url: resolved.url)
        access.stop()
        access.stop()
        #expect(FolderBookmark.withAccess(to: resolved.url) { 42 } == 42)
    }

    @Test func aBookmarkToAFolderThatIsGoneThrows() throws {
        let folder = try TemporaryFolder()
        let shoot = folder.url.appendingPathComponent("Gone", isDirectory: true)
        try FileManager.default.createDirectory(at: shoot, withIntermediateDirectories: true)
        let data = try FolderBookmark.create(for: shoot, securityScoped: false)
        try FileManager.default.removeItem(at: shoot)
        #expect(throws: (any Error).self) { try FolderBookmark.resolve(data, securityScoped: false) }
    }

    @Test func securityScopedBookmarksCanBeMadeUnsandboxed() throws {
        let folder = try TemporaryFolder()
        let data = try FolderBookmark.create(for: folder.url, securityScoped: true)
        let resolved = try FolderBookmark.resolve(data, securityScoped: true)
        #expect(resolved.url.lastPathComponent == folder.url.lastPathComponent)
    }
}
