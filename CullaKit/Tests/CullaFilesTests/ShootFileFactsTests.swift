import CullaCore
@testable import CullaFiles
import Foundation
import Testing

@Suite("Shoot file facts")
struct ShootFileFactsTests {
    private func photo(_ folder: URL, _ id: String, companions: [String] = []) -> PhotoFile {
        let directory = (id as NSString).deletingLastPathComponent
        let url = folder.appendingPathComponent(id)
        return PhotoFile(
            id: id, url: url,
            companions: companions.map { folder.appendingPathComponent(directory).appendingPathComponent($0) },
            fileSize: 0, modificationDate: .distantPast, isRAW: false
        )
    }

    /// The slow, obviously right way: `SidecarFinder` over the whole listing for every photo.
    private func reference(_ photos: [PhotoFile], folder: URL, shared: Set<String>) throws -> ShootFileFacts {
        var facts = ShootFileFacts()
        for photo in photos {
            let directory = (photo.id as NSString).deletingLastPathComponent
            let absolute = directory.isEmpty ? folder : folder.appendingPathComponent(directory)
            let names = try FileManager.default.contentsOfDirectory(atPath: absolute.path)
            let join = { (name: String) in directory.isEmpty ? name : directory + "/" + name }
            let fileNames = [photo.url.lastPathComponent] + photo.companions.map(\.lastPathComponent)
            for name in fileNames where names.contains(name) {
                facts.sizes[join(name)] = FileOps.stamp(absolute.appendingPathComponent(name).path)?.size
            }
            let sidecars = SidecarFinder.sidecars(forFiles: fileNames, in: names, includeBaseSidecar: !shared.contains(photo.id))
            if !sidecars.isEmpty {
                facts.sidecars[photo.id] = sidecars.map(join)
                for name in sidecars { facts.sizes[join(name)] = FileOps.stamp(absolute.appendingPathComponent(name).path)?.size }
            }
        }
        return facts
    }

    @Test func findsWhatTheSidecarFinderFinds() throws {
        let temp = try TemporaryFolder()
        let folder = temp.url
        let bytes = { (count: Int) in Data(repeating: 1, count: count) }
        try temp.file("IMG_1.JPG", contents: bytes(10))
        try temp.file("IMG_1.CR3", contents: bytes(30))
        try temp.file("IMG_1.CR3.xmp", contents: bytes(3))
        try temp.file("img_1.XMP", contents: bytes(4))
        try temp.file("IMG_2.heic", contents: bytes(12))
        try temp.file("IMG_2.HEIC.XMP", contents: bytes(5))
        try temp.file("IMG_3.jpg", contents: bytes(7))
        try temp.file("IMG_3.tif", contents: bytes(8))
        try temp.file("IMG_3.xmp", contents: bytes(2))
        try temp.file("sub/A.jpg", contents: bytes(9))
        try temp.file("sub/a.xmp", contents: bytes(1))
        try temp.file("lonely.xmp", contents: bytes(6))
        let photos = [
            photo(folder, "IMG_1.JPG", companions: ["IMG_1.CR3"]),
            photo(folder, "IMG_2.heic"),
            photo(folder, "IMG_3.jpg"),
            photo(folder, "IMG_3.tif"),
            photo(folder, "sub/A.jpg"),
            photo(folder, "missing.jpg"),
        ]
        for shared in [Set<String>(), ["IMG_3.jpg", "IMG_3.tif"]] {
            let facts = ShootFileFacts.gather(for: photos, folder: folder, sharedSidecarIDs: shared)
            #expect(facts == (try reference(photos, folder: folder, shared: shared)))
        }
        let facts = ShootFileFacts.gather(for: photos, folder: folder)
        #expect(facts.sidecars["IMG_1.JPG"] == ["IMG_1.CR3.xmp", "img_1.XMP"])
        #expect(facts.sidecars["IMG_2.heic"] == ["IMG_2.HEIC.XMP"])
        #expect(facts.sidecars["sub/A.jpg"] == ["sub/a.xmp"])
        #expect(facts.sidecars["missing.jpg"] == nil)
        #expect(facts.sizes["IMG_1.CR3"] == 30)
        #expect(facts.sizes["img_1.XMP"] == 4)
        #expect(ShootFileFacts.gather(for: photos, folder: folder, sharedSidecarIDs: ["IMG_3.jpg"]).sidecars["IMG_3.jpg"] == nil)
    }

    /// Pins the complexity: one listing and an index per folder. The quadratic version took about
    /// 0.6 s for 2,000 photos in one folder, so about 4 s for 5,000.
    @Test func fiveThousandPhotosInOneFolderTakeWellUnderASecond() throws {
        let temp = try TemporaryFolder()
        let folder = temp.url
        var photos: [PhotoFile] = []
        for index in 0..<5000 {
            let name = String(format: "IMG_%05d", index)
            FileManager.default.createFile(atPath: folder.appendingPathComponent("\(name).JPG").path, contents: nil)
            FileManager.default.createFile(atPath: folder.appendingPathComponent("\(name).CR3").path, contents: nil)
            if index % 10 == 0 {
                FileManager.default.createFile(atPath: folder.appendingPathComponent("\(name).xmp").path, contents: nil)
            }
            photos.append(photo(folder, "\(name).JPG", companions: ["\(name).CR3"]))
        }
        let clock = ContinuousClock()
        var facts = ShootFileFacts()
        let elapsed = clock.measure { facts = ShootFileFacts.gather(for: photos, folder: folder) }
        #expect(facts.sidecars.count == 500)
        #expect(facts.sizes.count == 10_500)
        #expect(elapsed < .milliseconds(1000), "took \(elapsed)")
    }
}
