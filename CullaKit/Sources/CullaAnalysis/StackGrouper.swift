import Accelerate
import Foundation

/// Distances between Vision feature prints.
public enum FeatureMath {
    /// Straight-line distance between two feature vectors. Nil when they cannot be compared.
    public static func distance(_ a: [Float], _ b: [Float]) -> Double? {
        guard !a.isEmpty, a.count == b.count else { return nil }
        var squared: Float = 0
        vDSP_distancesq(a, 1, b, 1, &squared, vDSP_Length(a.count))
        return Double(squared.squareRoot())
    }
}

/// What the stack grouper needs to know about one photo.
public struct StackCandidate: Sendable {
    public var date: Date
    /// False when `date` is only the file's modification time. Such photos are never stacked by time.
    public var hasCaptureDate: Bool
    public var burstID: String?
    public var feature: [Float]?

    public init(date: Date, hasCaptureDate: Bool, burstID: String? = nil, feature: [Float]? = nil) {
        self.date = date
        self.hasCaptureDate = hasCaptureDate
        self.burstID = burstID
        self.feature = feature
    }
}

/// The relation between two photos that are neighbours in time.
public struct StackLink: Sendable, Hashable {
    public var gapSeconds: Double
    public var distance: Double?
    public var isLinked: Bool
}

public struct Stacking: Sendable {
    /// Candidate indices in time order.
    public var order: [Int]
    /// `links[i]` relates `order[i]` to `order[i + 1]`.
    public var links: [StackLink]
    /// Each stack lists candidate indices in time order and holds at least the minimum stack size.
    public var stacks: [[Int]]
}

/// Groups photos taken close together that look alike.
public enum StackGrouper {
    /// Walks the photos in time order and joins each to the one before it when they share a camera
    /// burst, or when they were taken within the time gap and look alike. Time is the hard limit:
    /// similar-looking photos taken far apart never share a stack.
    public static func group(_ candidates: [StackCandidate], tuning: Tuning) -> Stacking {
        let order = candidates.indices.sorted {
            candidates[$0].date != candidates[$1].date ? candidates[$0].date < candidates[$1].date : $0 < $1
        }

        var links: [StackLink] = []
        var stacks: [[Int]] = []
        var current: [Int] = []

        func close(_ stack: [Int]) {
            if stack.count >= max(2, tuning.minStackSize) { stacks.append(stack) }
        }

        for (position, index) in order.enumerated() {
            guard position > 0 else {
                current = [index]
                continue
            }
            let previous = candidates[order[position - 1]]
            let candidate = candidates[index]
            let gap = candidate.date.timeIntervalSince(previous.date)
            let distance: Double? = if let a = previous.feature, let b = candidate.feature {
                FeatureMath.distance(a, b)
            } else {
                nil
            }

            let sameBurst = tuning.useBurstData && candidate.burstID != nil && candidate.burstID == previous.burstID
            let closeInTime = previous.hasCaptureDate && candidate.hasCaptureDate && gap <= tuning.stackGapSeconds
            let lookAlike = distance.map { $0 <= tuning.stackDistance } ?? false
            let isLinked = sameBurst || (closeInTime && lookAlike)
            links.append(StackLink(gapSeconds: gap, distance: distance, isLinked: isLinked))

            if isLinked {
                current.append(index)
            } else {
                close(current)
                current = [index]
            }
        }
        close(current)
        return Stacking(order: order, links: links, stacks: stacks)
    }
}
