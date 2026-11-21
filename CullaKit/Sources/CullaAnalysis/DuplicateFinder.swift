import Foundation

/// What the duplicate finder needs to know about one photo.
public struct DuplicateCandidate: Sendable {
    public var fileSize: Int64
    public var captureDate: Date?
    public var feature: [Float]?

    public init(fileSize: Int64, captureDate: Date? = nil, feature: [Float]? = nil) {
        self.fileSize = fileSize
        self.captureDate = captureDate
        self.feature = feature
    }
}

public struct DuplicateSet: Sendable, Hashable {
    public enum Kind: String, Sendable, Codable {
        /// Every file has the same bytes.
        case exact
        /// The images match but the files differ: a resized, re-saved or re-exported copy.
        case near
    }

    public var kind: Kind
    /// Candidate indices, lowest first.
    public var members: [Int]
}

/// Finds copies of the same photo.
public enum DuplicateFinder {
    /// - Parameter contentHash: returns a hash of the file content for a candidate index, or nil
    ///   when the file cannot be read. It is only called for files that share their size with
    ///   another file, so most files are never read.
    public static func find(
        _ candidates: [DuplicateCandidate],
        tuning: Tuning,
        contentHash: (Int) -> String?
    ) -> [DuplicateSet] {
        var sets = DisjointSets(count: candidates.count)
        var hashes: [Int: String] = [:]

        // Exact copies: same size first, then same content.
        // Off, files are not hashed at all; a set of near-duplicates may still turn out to be
        // byte-identical, and is then reported as near (nothing was read to say otherwise).
        let bySize = tuning.findExactDuplicates ? Dictionary(grouping: candidates.indices, by: { candidates[$0].fileSize }) : [:]
        for group in bySize.values where group.count > 1 {
            var firstWithHash: [String: Int] = [:]
            for index in group {
                guard let hash = contentHash(index) else { continue }
                hashes[index] = hash
                if let first = firstWithHash[hash] {
                    sets.union(first, index)
                } else {
                    firstWithHash[hash] = index
                }
            }
        }

        // Near-duplicates: the same image saved again. Frames of a burst can look just as alike,
        // so two files only count when they also share their capture instant, or when one of
        // them has no capture time to compare.
        // Photos are compared in capture-time order, each only with those taken within the same
        // instant, so a shoot of 10,000 photos costs about 10,000 comparisons rather than 50
        // million. Photos without a capture time are compared with every other photo.
        func joinIfAlike(_ i: Int, _ j: Int) {
            guard let a = candidates[i].feature, let b = candidates[j].feature,
                  let distance = FeatureMath.distance(a, b),
                  distance <= tuning.nearDuplicateDistance
            else { return }
            sets.union(i, j)
        }
        let withFeature = tuning.findNearDuplicates ? candidates.indices.filter { candidates[$0].feature != nil } : []
        let dated = withFeature
            .compactMap { index in candidates[index].captureDate.map { (index: index, date: $0) } }
            .sorted { $0.date < $1.date }
        for (position, first) in dated.enumerated() {
            var next = position + 1
            while next < dated.count, sameInstant(first.date, dated[next].date) {
                joinIfAlike(first.index, dated[next].index)
                next += 1
            }
        }
        for i in withFeature where candidates[i].captureDate == nil {
            for j in withFeature where j != i {
                joinIfAlike(i, j)
            }
        }

        return sets.groups()
            .filter { $0.count > 1 }
            .map { members in
                let memberHashes = Set(members.map { hashes[$0] })
                let allSame = memberHashes.count == 1 && memberHashes.first! != nil
                return DuplicateSet(kind: allSame ? .exact : .near, members: members)
            }
            .sorted { $0.members[0] < $1.members[0] }
    }

    private static func sameInstant(_ a: Date?, _ b: Date?) -> Bool {
        guard let a, let b else { return true }
        return abs(a.timeIntervalSince(b)) < 0.01
    }
}

/// Union-find: tracks which items have been joined into the same group.
struct DisjointSets {
    private var parent: [Int]

    init(count: Int) {
        parent = Array(0..<count)
    }

    mutating func find(_ item: Int) -> Int {
        var root = item
        while parent[root] != root { root = parent[root] }
        var node = item
        while parent[node] != root {
            let next = parent[node]
            parent[node] = root
            node = next
        }
        return root
    }

    mutating func union(_ a: Int, _ b: Int) {
        let rootA = find(a)
        let rootB = find(b)
        if rootA != rootB { parent[max(rootA, rootB)] = min(rootA, rootB) }
    }

    /// All groups, each with its members in ascending order.
    mutating func groups() -> [[Int]] {
        var byRoot: [Int: [Int]] = [:]
        for item in parent.indices {
            byRoot[find(item), default: []].append(item)
        }
        return byRoot.values.map { $0.sorted() }
    }
}
