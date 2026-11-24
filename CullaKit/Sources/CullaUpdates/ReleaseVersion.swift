import Foundation

/// A dotted numeric version such as "1.0" or "1.0.1", as Culla's version and the macOS version
/// are written.
///
/// Versions compare component by component as numbers, and a missing component counts as zero:
/// "1.0" equals "1.0.0" and "1.10" is newer than "1.9". Anything else ("1.1 beta", "v1.1", "1..1",
/// "") is rejected rather than guessed at.
public struct ReleaseVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    /// The numbers, as written: "1.0" is [1, 0].
    public let components: [Int]

    /// Reads "1", "1.0", "26.0.1". Nil for anything that is not digits separated by single dots.
    public init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 8 else { return nil }
        var components: [Int] = []
        for part in parts {
            // ASCII digits only: no sign, no spaces, no other scripts' digits. Int(_:) refuses a
            // number too large for Int, so nothing overflows.
            guard !part.isEmpty, part.count <= 9, part.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
                  let number = Int(part)
            else { return nil }
            components.append(number)
        }
        self.components = components
    }

    public init(_ system: OperatingSystemVersion) {
        components = [system.majorVersion, system.minorVersion, system.patchVersion]
    }

    /// This Mac's macOS version.
    public static var currentSystem: ReleaseVersion {
        ReleaseVersion(ProcessInfo.processInfo.operatingSystemVersion)
    }

    /// The components without trailing zeros: "1.0.0" and "1" are both [1].
    private var significant: ArraySlice<Int> {
        var end = components.count
        while end > 0, components[end - 1] == 0 { end -= 1 }
        return components[..<end]
    }

    public static func == (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        lhs.significant == rhs.significant
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(Array(significant))
    }

    public static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    /// The version as written: "1.1", "1.0.1".
    public var description: String {
        components.map(String.init).joined(separator: ".")
    }

    /// The version without trailing zeros, as Apple names macOS releases: "26.0" is "26",
    /// "26.1.0" is "26.1".
    public var systemDescription: String {
        var shown = Array(significant)
        if shown.isEmpty { shown = [0] }
        return shown.map(String.init).joined(separator: ".")
    }
}
