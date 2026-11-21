import CullaCore
import CullaFiles
import Foundation
import Testing

@Suite("PhotoScanner")
struct PhotoScannerTests {
    private func scan(_ names: [String], includeSubfolders: Bool = true) throws -> [PhotoFile] {
        let folder = try TemporaryFolder()
        for name in names { try folder.file(name) }
        return try withExtendedLifetime(folder) {
            try PhotoScanner.scan(folder: folder.url, includeSubfolders: includeSubfolders)
        }
    }

    @Test func pairsRawWithJPEGOfTheSameName() throws {
        let photos = try scan(["IMG_0001.JPG", "IMG_0001.dng", "IMG_0002.jpg"])
        #expect(photos.map(\.id) == ["IMG_0001.JPG", "IMG_0002.jpg"])
        #expect(photos[0].companions.map(\.lastPathComponent) == ["IMG_0001.dng"])
        #expect(!photos[0].isRAW)
        #expect(photos[1].companions.isEmpty)
    }

    /// Settings ▸ Duplicates: "Treat RAW+JPEG as one photo" off makes each file a photo.
    @Test func pairingCanBeSwitchedOff() throws {
        let folder = try TemporaryFolder()
        for name in ["IMG_0001.JPG", "IMG_0001.dng", "IMG_0002.jpg"] { try folder.file(name) }
        let photos = try PhotoScanner.scan(folder: folder.url, pairRAWWithRendered: false)
        #expect(photos.map(\.id) == ["IMG_0001.dng", "IMG_0001.JPG", "IMG_0002.jpg"])
        #expect(photos.allSatisfy { $0.companions.isEmpty })
        #expect(photos.map(\.isRAW) == [true, false, false])
    }

    @Test func pairingIgnoresCase() throws {
        let photos = try scan(["img_0003.jpg", "IMG_0003.CR3"])
        #expect(photos.count == 1)
        #expect(photos.first?.name == "img_0003.jpg")
        #expect(photos.first?.companions.map(\.lastPathComponent) == ["IMG_0003.CR3"])
    }

    @Test func filesInDifferentFoldersDoNotPair() throws {
        let photos = try scan(["a/IMG_1.jpg", "b/IMG_1.dng"])
        #expect(photos.map(\.id) == ["a/IMG_1.jpg", "b/IMG_1.dng"])
        #expect(photos.allSatisfy { $0.companions.isEmpty })
        #expect(photos.map(\.isRAW) == [false, true])
    }

    @Test func rawAloneIsAPhotoOfItsOwn() throws {
        let photos = try scan(["DSC_9.NEF"])
        #expect(photos.count == 1)
        #expect(photos.first?.isRAW == true)
        #expect(photos.first?.companions.isEmpty == true)
    }

    @Test func jpegLeadsWhenJPEGHEICAndRAWShareAName() throws {
        let photos = try scan(["IMG_5.HEIC", "IMG_5.dng", "IMG_5.jpg"])
        #expect(photos.map(\.id) == ["IMG_5.HEIC", "IMG_5.jpg"])
        let jpeg = try #require(photos.first { $0.name == "IMG_5.jpg" })
        let heic = try #require(photos.first { $0.name == "IMG_5.HEIC" })
        #expect(jpeg.companions.map(\.lastPathComponent) == ["IMG_5.dng"])
        #expect(heic.companions.isEmpty)
        #expect(!heic.isRAW)
    }

    @Test func videosAndOtherFilesAreIgnored() throws {
        let photos = try scan(["clip.mov", "clip.mp4", "notes.txt", "logo.gif", "doc.pdf", "noextension", "photo.png"])
        #expect(photos.map(\.id) == ["photo.png"])
    }

    @Test func hiddenFilesAreIgnored() throws {
        let photos = try scan([".hidden.jpg", "._IMG_1.jpg", "IMG_1.jpg", ".cache/inside.jpg"])
        #expect(photos.map(\.id) == ["IMG_1.jpg"])
    }

    @Test func rejectedFolderIsSkipped() throws {
        let photos = try scan(["keep.jpg", "_Rejected/gone.jpg", "_Rejected/deeper/gone.dng"])
        #expect(photos.map(\.id) == ["keep.jpg"])
    }

    @Test func subfoldersCanBeLeftOut() throws {
        let names = ["top.jpg", "sub/inner.jpg", "sub/deeper/inner.jpg"]
        #expect(try scan(names, includeSubfolders: false).map(\.id) == ["top.jpg"])
        #expect(try scan(names).map(\.id) == ["sub/deeper/inner.jpg", "sub/inner.jpg", "top.jpg"])
    }

    @Test func idsAreRelativeToTheRootAndSortedNaturally() throws {
        let photos = try scan(["a10.jpg", "a2.jpg", "B/x.jpg", "a1.jpg"])
        #expect(photos.map(\.id) == ["a1.jpg", "a2.jpg", "a10.jpg", "B/x.jpg"])
        for photo in photos {
            #expect(photo.url.path.hasSuffix("/" + photo.id))
        }
    }

    @Test func fileSizeAndDateAreRead() throws {
        let folder = try TemporaryFolder()
        let url = try folder.file("one.jpg", contents: Data(count: 1234))
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        let photos = try PhotoScanner.scan(folder: folder.url)
        #expect(photos.first?.fileSize == 1234)
        #expect(photos.first?.modificationDate == date)
    }

    @Test func missingFolderThrows() {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        #expect(throws: (any Error).self) { try PhotoScanner.scan(folder: missing) }
    }

    @Test func kindJudgesByExtension() {
        #expect(PhotoScanner.kind(of: URL(fileURLWithPath: "/x/a.ARW")) == .raw)
        #expect(PhotoScanner.kind(of: URL(fileURLWithPath: "/x/a.jpeg")) == .rendered)
        #expect(PhotoScanner.kind(of: URL(fileURLWithPath: "/x/a.heic")) == .rendered)
        #expect(PhotoScanner.kind(of: URL(fileURLWithPath: "/x/a.mov")) == nil)
        #expect(PhotoScanner.kind(of: URL(fileURLWithPath: "/x/a.zzzz")) == nil)
        #expect(PhotoScanner.kind(of: URL(fileURLWithPath: "/x/a")) == nil)
    }
}
