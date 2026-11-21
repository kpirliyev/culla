import CullaCore
import Darwin
import Foundation

/// The file operations applying and undoing are built from. Every one of them refuses to replace
/// an existing file: moves and renames use `renamex_np` with `RENAME_EXCL`, which fails atomically
/// when the destination exists, and new files are created with `O_EXCL`. All of them block, so
/// they run on a `BlockingQueue`, never on Swift's cooperative pool.
public enum FileOps {
    /// A file system call failed.
    public struct Failure: Error, CustomStringConvertible, Equatable {
        public var operation: String
        public var path: String
        public var code: Int32

        public init(operation: String, path: String, code: Int32) {
            self.operation = operation
            self.path = path
            self.code = code
        }

        public var description: String {
            "\(operation) \(path): \(String(cString: strerror(code)))"
        }

        /// True when the call failed because something already exists at the destination.
        public var isExists: Bool { code == EEXIST || code == ENOTEMPTY }
    }

    /// The size and modification time of the item at `path` (not following a final symbolic
    /// link), or nil when there is nothing there.
    public static func stamp(_ path: String) -> FileStamp? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return FileStamp(size: Int64(info.st_size), seconds: Int64(info.st_mtimespec.tv_sec), nanoseconds: Int64(info.st_mtimespec.tv_nsec))
    }

    /// True when anything (file, folder or link) is at `path`.
    public static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    /// True when a folder is at `path`.
    public static func isDirectory(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    /// Renames within a volume. Fails with EEXIST when anything is at `to`, and with EXDEV when
    /// `to` is on another volume.
    ///
    /// File systems that do not support `RENAME_EXCL` (it fails with ENOTSUP or EINVAL; FAT and
    /// exFAT memory cards may be among them) get a check that nothing is at `to` followed by a
    /// plain `rename`. That leaves a window of microseconds in which a file created at `to` by
    /// another program would be replaced; nothing else writes into `_Rejected` or the Copy Keepers
    /// destination while Culla applies, and undo checks the same way.
    public static func moveExclusive(from: String, to: String) throws(Failure) {
        if renamex_np(from, to, UInt32(RENAME_EXCL)) == 0 { return }
        let code = errno
        guard code == ENOTSUP || code == EINVAL else { throw Failure(operation: "Moving to", path: to, code: code) }
        guard !exists(to) else { throw Failure(operation: "Moving to", path: to, code: EEXIST) }
        guard exists(from) else { throw Failure(operation: "Moving", path: from, code: ENOENT) }
        guard rename(from, to) == 0 else { throw Failure(operation: "Moving to", path: to, code: errno) }
    }

    /// Creates one folder; fails when anything is already there.
    public static func makeDirectory(_ path: String) throws(Failure) {
        guard mkdir(path, 0o755) == 0 else { throw Failure(operation: "Creating folder", path: path, code: errno) }
    }

    /// Removes a folder when it is empty, or holds nothing but a `.DS_Store` file (which Finder
    /// leaves behind once the folder has been looked at). Returns false, removing nothing, when
    /// anything else is in it.
    public static func removeDirectoryIfEmpty(_ path: String) throws(Failure) -> Bool {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        guard entries.allSatisfy({ $0 == ".DS_Store" }) else { return false }
        if entries.contains(".DS_Store") {
            guard unlink(path + "/.DS_Store") == 0 || errno == ENOENT else {
                throw Failure(operation: "Removing", path: path + "/.DS_Store", code: errno)
            }
        }
        guard rmdir(path) == 0 else {
            if errno == ENOTEMPTY || errno == EEXIST { return false }
            throw Failure(operation: "Removing folder", path: path, code: errno)
        }
        return true
    }

    /// Removes a file.
    public static func removeFile(_ path: String) throws(Failure) {
        guard unlink(path) == 0 else { throw Failure(operation: "Removing", path: path, code: errno) }
    }

    /// Sets a file's modification time to the stamp's, to the nanosecond, leaving its access time.
    public static func setModificationTime(_ stamp: FileStamp, of path: String) throws(Failure) {
        var times = [
            timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)),
            timespec(tv_sec: Int(stamp.seconds), tv_nsec: Int(stamp.nanoseconds)),
        ]
        guard utimensat(AT_FDCWD, path, &times, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw Failure(operation: "Setting the date of", path: path, code: errno)
        }
    }

    /// Writes `data` to a new file at `path`, failing when anything is there already.
    public static func createFile(_ path: String, data: Data) throws(Failure) {
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard descriptor >= 0 else { throw Failure(operation: "Creating", path: path, code: errno) }
        var failure: Failure?
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    failure = Failure(operation: "Writing", path: path, code: errno)
                    return
                }
                offset += written
            }
        }
        if failure == nil, fsync(descriptor) != 0 {
            failure = Failure(operation: "Writing", path: path, code: errno)
        }
        close(descriptor)
        if let failure {
            unlink(path)
            throw failure
        }
    }

    /// Writes `data` to `path` atomically: to `tempPath` beside it first, then into place. A new
    /// file is renamed into place and never replaces anything that appeared meanwhile; an
    /// existing file is replaced with `FileManager.replaceItemAt`, which keeps its permissions,
    /// extended attributes and creation date. The temporary file is removed on failure.
    public static func writeAtomically(_ data: Data, to path: String, tempPath: String, replacing: Bool) throws {
        try createFile(tempPath, data: data)
        do {
            if replacing {
                _ = try FileManager.default.replaceItemAt(
                    URL(fileURLWithPath: path), withItemAt: URL(fileURLWithPath: tempPath)
                )
            } else {
                try moveExclusive(from: tempPath, to: path)
            }
        } catch {
            unlink(tempPath)
            throw error
        }
    }

    /// Copies a file to `path` through `tempPath` beside it, never replacing anything: the copy
    /// (with its modification date and attributes, as `FileManager` copies them) is made at
    /// `tempPath` and then renamed into place. Returns the copy's stamp.
    public static func copyExclusive(from source: String, to path: String, tempPath: String) throws -> FileStamp {
        try FileManager.default.copyItem(atPath: source, toPath: tempPath)
        do {
            try moveExclusive(from: tempPath, to: path)
        } catch {
            unlink(tempPath)
            throw error
        }
        guard let stamp = stamp(path) else { throw Failure(operation: "Reading", path: path, code: ENOENT) }
        return stamp
    }

    /// A name for a temporary file beside `path`, hidden and never taken for a photo or sidecar.
    public static func temporaryPath(beside path: String) -> String {
        let directory = (path as NSString).deletingLastPathComponent
        return (directory as NSString).appendingPathComponent(".culla-\(UUID().uuidString).tmp")
    }
}
