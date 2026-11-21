import CryptoKit
import Foundation

/// Content hashes for finding byte-identical files.
public enum FileHasher {
    /// SHA-256 of a file's content as hex, read in chunks so large RAW files never sit in memory whole.
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// A short, file-name-safe key for a string, used to name thumbnails after a photo's path.
    public static func shortKey(for text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
