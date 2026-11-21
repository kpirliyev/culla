import CullaCore
import CullaFiles
import CullaPipeline
import CullaSession
import CullaStore
import Foundation
import Testing

/// A fresh folder under the system's temporary directory, removed when the value goes away.
final class Scratch: @unchecked Sendable {
    let url: URL

    init(_ name: String = "CullaApplyTests") throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

/// One file of a listing: its content hash and its size and modification time to the nanosecond.
struct ListedFile: Hashable, CustomStringConvertible {
    var sha256: String
    var stamp: FileStamp

    var description: String { "\(sha256.prefix(8)) \(stamp.size)B @\(stamp.seconds).\(stamp.nanoseconds)" }
}

/// Every file and folder under a folder, hidden ones included.
struct Listing: Equatable, CustomStringConvertible {
    var files: [String: ListedFile]
    var folders: Set<String>

    init(_ root: URL) {
        files = [:]
        folders = []
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [])!
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        for case let url as URL in enumerator {
            let path = url.resolvingSymlinksInPath().path
            let relative = path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count)) : path
            if FileOps.isDirectory(path) {
                folders.insert(relative)
            } else {
                files[relative] = ListedFile(sha256: (try? FileHasher.sha256(of: url)) ?? "?", stamp: FileOps.stamp(path)!)
            }
        }
    }

    var description: String {
        (files.keys.sorted().map { "\($0): \(files[$0]!)" } + folders.sorted().map { "\($0)/" }).joined(separator: "\n")
    }

    /// Paths that differ from `other`, for readable failures.
    func difference(from other: Listing) -> [String] {
        var result: [String] = []
        for path in Set(files.keys).union(other.files.keys).sorted() where files[path] != other.files[path] {
            result.append("\(path): \(other.files[path].map(\.description) ?? "absent") -> \(files[path].map(\.description) ?? "absent")")
        }
        for folder in folders.symmetricDifference(other.folders).sorted() {
            result.append("folder \(folder): \(other.folders.contains(folder) ? "present" : "absent") -> \(folders.contains(folder) ? "present" : "absent")")
        }
        return result
    }

    /// Content hashes of every file, with how many times each occurs.
    var contentCounts: [String: Int] {
        files.values.reduce(into: [:]) { $0[$1.sha256, default: 0] += 1 }
    }
}

/// A sidecar shaped like Lightroom's, for the existing sidecar of a RAW+JPEG pair.
let lightroomSidecar = """
    <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 7.0-c000 1.000000, 0000/00/00-00:00:00        ">
     <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
      <rdf:Description rdf:about=""
        xmlns:xmp="http://ns.adobe.com/xap/1.0/"
        xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
       xmp:Rating="3"
       xmp:Label="Blue"
       crs:Version="17.0"
       crs:Exposure2012="+0.35">
       <crs:ToneCurvePV2012>
        <rdf:Seq>
         <rdf:li>0, 0</rdf:li>
         <rdf:li>255, 255</rdf:li>
        </rdf:Seq>
       </crs:ToneCurvePV2012>
      </rdf:Description>
     </rdf:RDF>
    </x:xmpmeta>

    """

/// A sidecar in element form inside an xpacket wrapper, like Capture One's.
let elementSidecar = "<?xpacket begin=\"\u{FEFF}\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>\n" + """
    <x:xmpmeta xmlns:x="adobe:ns:meta/">
     <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
      <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/">
       <xmp:Rating>1</xmp:Rating>
       <photoshop:City>Lisbon</photoshop:City>
      </rdf:Description>
     </rdf:RDF>
    </x:xmpmeta>
    <?xpacket end="w"?>
    """

/// A shoot folder built in a temporary directory, with a session made from scanning it.
final class ShootFixture: @unchecked Sendable {
    private let scratch: Scratch?
    let root: URL
    private var counter: Int64 = 0

    init() throws {
        let scratch = try Scratch("CullaShoot")
        self.scratch = scratch
        root = scratch.url
    }

    /// A shoot in an existing folder, which the caller removes.
    init(root: URL) {
        scratch = nil
        self.root = root.resolvingSymlinksInPath()
    }

    /// Writes a file with distinct content and an old modification time with nanoseconds, so
    /// a file that is touched shows it.
    @discardableResult
    func write(_ relative: String, _ text: String? = nil, bytes: Int = 300) throws -> URL {
        counter += 1
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data: Data
        if let text {
            data = Data(text.utf8)
        } else {
            let seed = "\(relative)#\(counter)#"
            data = Data(String(repeating: seed, count: max(1, bytes / seed.utf8.count)).utf8)
        }
        try data.write(to: url)
        try FileOps.setModificationTime(
            FileStamp(size: 0, seconds: 1_600_000_000 + counter * 37, nanoseconds: 100_000_007 * (counter % 9) + 13),
            of: url.path
        )
        return url
    }

    /// Scans the folder as the app does and makes a session of it.
    func session(
        decisions: [String: Decision] = [:],
        ratings: [String: Int] = [:],
        unreadable: Set<String> = []
    ) throws -> SessionState {
        let files = try PhotoScanner.scan(folder: root)
        var state = SessionState(scanned: files.map { ScannedPhoto(file: $0, metadata: PhotoMetadata()) })
        for (id, decision) in decisions {
            precondition(state.contains(id), "no photo \(id)")
            state.apply(.setDecision(decision, ids: [id]))
        }
        for (id, rating) in ratings { state.apply(.setRating(rating, ids: [id])) }
        for id in unreadable { state.markUnreadable(id, reason: "test") }
        return state
    }

    var listing: Listing { Listing(root) }

    /// Paths of Culla's temporary files left anywhere under the folder.
    var leftoverTemporaryFiles: [String] {
        listing.files.keys.filter { ($0 as NSString).lastPathComponent.hasPrefix(".culla-") }
    }
}

/// The standard shoot of the apply tests:
///
/// - `IMG_0001.jpg` + `IMG_0001.CR3`, rejected, with a Lightroom sidecar `IMG_0001.xmp`.
/// - `IMG_0002.jpg` kept with 3 stars; `IMG_0003.jpg` unreviewed; `IMG_0004.jpg` unreviewed
///   with 2 stars.
/// - `day2/IMG_0005.jpg` + `day2/IMG_0005.NEF`, rejected with 4 stars.
/// - `day2/deeper/IMG_0006.heic`, rejected, with a darktable-style `IMG_0006.heic.xmp`.
/// - `day2/IMG_0007.jpg`, kept, with an element-form sidecar.
/// - `IMG_0008.jpg`, rejected, while `_Rejected/IMG_0008.jpg` and `_Rejected/IMG_0008 2.xmp`
///   are already taken.
/// - `IMG_0009.jpg`, rejected but unreadable; `IMG_0010.jpg`, unreviewed and unreadable.
/// - `notes.txt`, not a photo.
func standardShoot(in folder: URL? = nil) throws -> (ShootFixture, SessionState) {
    let shoot = try folder.map(ShootFixture.init(root:)) ?? ShootFixture()
    try shoot.write("IMG_0001.jpg")
    try shoot.write("IMG_0001.CR3", bytes: 900)
    try shoot.write("IMG_0001.xmp", lightroomSidecar)
    try shoot.write("IMG_0002.jpg")
    try shoot.write("IMG_0003.jpg")
    try shoot.write("IMG_0004.jpg")
    try shoot.write("day2/IMG_0005.jpg")
    try shoot.write("day2/IMG_0005.NEF", bytes: 800)
    try shoot.write("day2/deeper/IMG_0006.heic")
    try shoot.write("day2/deeper/IMG_0006.heic.xmp", "<darktable sidecar, not XMP Culla edits>")
    try shoot.write("day2/IMG_0007.jpg")
    try shoot.write("day2/IMG_0007.xmp", elementSidecar)
    try shoot.write("IMG_0008.jpg")
    try shoot.write("_Rejected/IMG_0008.jpg", "an earlier reject")
    try shoot.write("_Rejected/IMG_0008 2.xmp", "an earlier sidecar")
    try shoot.write("IMG_0009.jpg")
    try shoot.write("IMG_0010.jpg")
    try shoot.write("notes.txt", "not a photo")
    let state = try shoot.session(
        decisions: [
            "IMG_0001.jpg": .rejected, "IMG_0002.jpg": .kept, "day2/IMG_0005.jpg": .rejected,
            "day2/deeper/IMG_0006.heic": .rejected, "day2/IMG_0007.jpg": .kept, "IMG_0008.jpg": .rejected,
            "IMG_0009.jpg": .rejected,
        ],
        ratings: ["IMG_0002.jpg": 3, "IMG_0004.jpg": 2, "day2/IMG_0005.jpg": 4],
        unreadable: ["IMG_0009.jpg", "IMG_0010.jpg"]
    )
    return (shoot, state)
}

/// A database with a session for the folder, and an applier for it.
func applier(for folder: URL, faultInjector: ApplyExecutor.FaultInjector? = nil) async throws -> ShootApplier {
    let database = try CullaDatabase.inMemory()
    let session = try await database.openSession(folder: folder)
    return ShootApplier(database: database, sessionID: session.id, faultInjector: faultInjector)
}

/// Removes from the Trash whatever a run put there and undo did not bring back. Only paths the
/// run itself recorded, which are files the test created.
func removeTrashedFiles(of steps: [ApplyStep]) {
    for step in steps {
        if case let .trash(_, _, trashed?) = step.action, FileOps.exists(trashed) {
            try? FileManager.default.removeItem(atPath: trashed)
        }
    }
}

/// The thrown error of an injected failure.
struct InjectedFailure: Error, CustomStringConvertible {
    var index: Int
    var description: String { "injected failure at step \(index)" }
}
