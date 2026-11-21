import Foundation

/// What duplicate ranking looks at in one copy of a photo.
public struct DuplicateCopy: Sendable, Hashable {
    /// Width times height in pixels, from the file's metadata. Nil when unknown; an unknown size
    /// loses to any known one.
    public var pixelCount: Int?
    /// True when the copy is a RAW file, or a RAW+JPEG pair.
    public var hasRAW: Bool
    /// The file name with its extension, such as "IMG_0001 copy.jpg".
    public var fileName: String
    /// Any further text that orders copies with the same name, such as the path in the shoot.
    public var tieBreaker: String

    public init(pixelCount: Int?, hasRAW: Bool, fileName: String, tieBreaker: String = "") {
        self.pixelCount = pixelCount
        self.hasRAW = hasRAW
        self.fileName = fileName
        self.tieBreaker = tieBreaker
    }
}

/// Why a copy was chosen as the one to keep. Each rule only counts when it set the chosen copy
/// apart from at least one other.
public enum DuplicatePickReason: String, Sendable, Hashable, Codable, CaseIterable {
    case highestResolution
    case rawFile
    case originalName
    case shorterName
    case firstByName

    /// The reason in English words, such as "highest resolution", for logs and `culla-eval`. The
    /// interface shows `DuplicateReview.pickCaption(_:)` (CullaCommands), in the person's language.
    public var description: String {
        switch self {
        case .highestResolution: "highest resolution"
        case .rawFile: "RAW file"
        case .originalName: "original name"
        case .shorterName: "shorter name"
        case .firstByName: "first by name"
        }
    }
}

/// The copy of a duplicate set Culla proposes to keep, and why.
public struct DuplicateRankingPick: Sendable, Hashable {
    /// Index of the chosen copy in the list given.
    public var index: Int
    /// The rule that left this copy alone in the running.
    public var reason: DuplicatePickReason
    /// Every rule that narrowed the choice, in the order they are applied.
    public var reasons: [DuplicatePickReason]
}

/// Chooses which copy of a duplicate set to keep (User Flows, Flow 4).
///
/// The copies are narrowed down in five steps, each applied only to the copies left by the one
/// before:
///
/// 1. **Highest resolution**: the most pixels, from metadata. An unknown size counts as zero.
/// 2. **RAW file**: a RAW file, or a RAW+JPEG pair, beats a file without RAW.
/// 3. **Original name**: a name that is not a copy name (see `isCopyName(_:among:)`) beats one
///    that is.
/// 4. **Shorter name**: the fewest characters in the file name.
/// 5. **First by name**: file names compared without case and with numbers in numeric order,
///    then `DuplicateCopy.tieBreaker` the same way, then the earliest in the list.
public enum DuplicateRanking {
    /// The copy to keep. Nil for an empty list.
    public static func pick(_ copies: [DuplicateCopy]) -> DuplicateRankingPick? {
        pick(among: Array(copies.indices), of: copies, copyNames: copyNames(copies))
    }

    /// Every copy's index, the one to keep first, then the best of the rest, and so on.
    public static func ranking(_ copies: [DuplicateCopy]) -> [Int] {
        let copyNames = copyNames(copies)
        var remaining = Array(copies.indices)
        var result: [Int] = []
        while let next = pick(among: remaining, of: copies, copyNames: copyNames) {
            result.append(next.index)
            remaining.removeAll { $0 == next.index }
        }
        return result
    }

    private static func copyNames(_ copies: [DuplicateCopy]) -> [Bool] {
        let names = copies.map(\.fileName)
        return names.map { isCopyName($0, among: names) }
    }

    private static func pick(among indices: [Int], of copies: [DuplicateCopy], copyNames: [Bool]) -> DuplicateRankingPick? {
        guard !indices.isEmpty else { return nil }
        var pool = indices
        var reasons: [DuplicatePickReason] = []
        func narrow(_ reason: DuplicatePickReason, _ keep: [Int]) {
            guard !keep.isEmpty, keep.count < pool.count else { return }
            pool = keep
            reasons.append(reason)
        }

        let most = pool.map { copies[$0].pixelCount ?? 0 }.max() ?? 0
        narrow(.highestResolution, pool.filter { (copies[$0].pixelCount ?? 0) == most })
        narrow(.rawFile, pool.filter { copies[$0].hasRAW })
        narrow(.originalName, pool.filter { !copyNames[$0] })
        let shortest = pool.map { copies[$0].fileName.count }.min() ?? 0
        narrow(.shorterName, pool.filter { copies[$0].fileName.count == shortest })
        if pool.count > 1 {
            let first = pool.min { a, b in
                let byName = compareNames(copies[a].fileName, copies[b].fileName)
                if byName != .orderedSame { return byName == .orderedAscending }
                let byTie = compareNames(copies[a].tieBreaker, copies[b].tieBreaker)
                if byTie != .orderedSame { return byTie == .orderedAscending }
                return a < b
            }!
            pool = [first]
            reasons.append(.firstByName)
        }
        return DuplicateRankingPick(index: pool[0], reason: reasons.last ?? .firstByName, reasons: reasons)
    }

    private static func compareNames(_ a: String, _ b: String) -> ComparisonResult {
        // Not locale-dependent: no locale is passed.
        a.compare(b, options: [.caseInsensitive, .numeric])
    }

    // MARK: - Copy names

    /// True when a file name looks like a copy that a file manager or an exporter made.
    ///
    /// Two kinds of marks are recognised, ignoring case, at the end of the name before the
    /// extension (several may follow one another, as in "IMG_0001 copy 2 (1).jpg"):
    ///
    /// - **Always a copy**: " copy", " copy 2" (Finder), "-copy", "_copy", " - Copy",
    ///   " - Copy (2)" (Windows), a number in brackets such as " (1)" or "(2)" (browsers and
    ///   Windows), and the prefixes "Copy of " and "Copy (2) of " (older Windows).
    /// - **A copy only when the original is in the set**: a separator and a number of one or two
    ///   digits, as in "IMG_0001-1", "IMG_0001_2" (Lightroom and other exporters) or
    ///   "IMG_0001 2" (Finder, when a file of that name already exists). This counts only when
    ///   another name in `names` has the same stem without it, because cameras end names with
    ///   numbers too: "DSC_12" alone is no copy.
    ///
    /// The stem is the name without its last extension; names are compared without case.
    public static func isCopyName(_ fileName: String, among names: [String]) -> Bool {
        let stem = Self.stem(fileName)
        let (base, marked) = stripCopyMarks(stem)
        if marked { return true }
        guard let numberless = stripNumberSuffix(base) else { return false }
        let others = names.filter { $0 != fileName }.map { stripCopyMarks(Self.stem($0)).base }
        return others.contains(numberless)
    }

    /// The name without its copy marks, lowercased and without extension: "img_0001" for
    /// "IMG_0001 copy 2.JPG". Numbered suffixes such as "-1" are kept; see `isCopyName`.
    public static func originalStem(of fileName: String) -> String {
        stripCopyMarks(stem(fileName)).base
    }

    private static func stem(_ fileName: String) -> String {
        let name = fileName.lowercased()
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name }
        return String(name[..<dot])
    }

    /// Removes every always-a-copy mark; says whether there was one.
    private static func stripCopyMarks(_ stem: String) -> (base: String, marked: Bool) {
        var current = trimmed(stem)
        var marked = false
        while let shorter = stripOneMark(current) {
            current = shorter
            marked = true
        }
        return (current, marked)
    }

    /// The stem without one always-a-copy mark, or nil when it has none. Never returns an empty
    /// stem: a file called "copy.jpg" is no copy of anything.
    private static func stripOneMark(_ stem: String) -> String? {
        var chars = Array(stem)
        // "(2)" at the end.
        if chars.last == ")", let open = chars.lastIndex(of: "(") {
            let inside = chars[(open + 1)..<(chars.count - 1)]
            if !inside.isEmpty, inside.allSatisfy(\.isASCIIDigit) {
                let rest = trimmed(String(chars[..<open]))
                if !rest.isEmpty { return rest }
            }
        }
        // "copy" or "copy 2" at the end, after a space, "-" or "_".
        var end = chars.count
        var digitStart = end
        while digitStart > 0, chars[digitStart - 1].isASCIIDigit { digitStart -= 1 }
        if digitStart < end, digitStart > 0, chars[digitStart - 1].isWhitespace {
            var wordEnd = digitStart
            while wordEnd > 0, chars[wordEnd - 1].isWhitespace { wordEnd -= 1 }
            if String(chars[max(0, wordEnd - 4)..<wordEnd]) == "copy" { end = wordEnd }
        }
        if end >= 5, String(chars[(end - 4)..<end]) == "copy", separators.contains(chars[end - 5]) {
            chars = Array(chars[..<(end - 5)])
            while let last = chars.last, separators.contains(last) { chars.removeLast() }
            if !chars.isEmpty { return String(chars) }
        }
        // "copy of " or "copy (2) of " at the start.
        if stem.hasPrefix("copy") {
            var rest = Substring(stem.dropFirst(4))
            rest = rest.drop { $0.isWhitespace }
            if rest.first == "(", let close = rest.firstIndex(of: ")"),
               rest[rest.index(after: rest.startIndex)..<close].allSatisfy(\.isASCIIDigit) {
                rest = rest[rest.index(after: close)...].drop { $0.isWhitespace }
            }
            if rest.hasPrefix("of"), rest.dropFirst(2).first?.isWhitespace == true {
                let name = trimmed(String(rest.dropFirst(2)))
                if !name.isEmpty { return name }
            }
        }
        return nil
    }

    private static let separators: Set<Character> = [" ", "-", "_"]

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespaces)
    }

    /// The stem without a trailing separator and one- or two-digit number, as in "img_0001-1",
    /// or nil without one. A longer run of digits, as in "img_0012", is a camera number.
    private static func stripNumberSuffix(_ stem: String) -> String? {
        let chars = Array(stem)
        var digitStart = chars.count
        while digitStart > 0, chars[digitStart - 1].isASCIIDigit { digitStart -= 1 }
        let digits = chars.count - digitStart
        guard (1...2).contains(digits), digitStart >= 2, separators.contains(chars[digitStart - 1]) else { return nil }
        let rest = trimmed(String(chars[..<(digitStart - 1)]))
        return rest.isEmpty ? nil : rest
    }
}

extension Character {
    fileprivate var isASCIIDigit: Bool { isASCII && isNumber }
}
