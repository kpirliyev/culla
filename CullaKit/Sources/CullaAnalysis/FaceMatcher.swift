import CullaCore
import Foundation

/// The faces of one frame, with the size of the image their boxes are relative to.
public struct FaceFrame: Sendable, Hashable {
    public var faces: [FaceScores]
    /// The image's size in any unit; only the ratio matters, to measure distances in the same
    /// unit across and down the frame.
    public var imageWidth: Int
    public var imageHeight: Int

    public init(faces: [FaceScores], imageWidth: Int, imageHeight: Int) {
        self.faces = faces
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
    }

    /// The faces of an analysed photo. A photo without scores has no faces.
    public init(scores: PhotoScores?) {
        self.init(
            faces: scores?.faces ?? [],
            imageWidth: scores?.analysedWidth ?? 1,
            imageHeight: scores?.analysedHeight ?? 1
        )
    }
}

/// One person across the frames of a stack: a row of the face strip.
public struct FaceRow: Sendable, Hashable {
    /// For every frame, the index of this person's face in that frame's `FaceFrame.faces`, or nil
    /// when the person is not found in it.
    public var faces: [Int?]

    public init(faces: [Int?]) {
        self.faces = faces
    }

    /// The first frame the person is found in.
    public var firstFrame: Int? { faces.firstIndex { $0 != nil } }
    /// How many frames the person is found in.
    public var frameCount: Int { faces.count(where: { $0 != nil }) }
}

/// The rows of a face strip.
public struct FaceMatching: Sendable, Hashable {
    public enum Method: String, Sendable, Hashable {
        /// Faces were followed from frame to frame by position and size.
        case tracked
        /// Following them gave too many broken rows to trust, so each frame's faces were put in
        /// rows by their order from left to right: row 0 holds the leftmost face of every frame.
        case positionOrder
    }

    /// One row per person, ordered left to right by where the person first appears (top to
    /// bottom when two first appear at the same place across), measured with the camera's
    /// shift taken out.
    public var rows: [FaceRow]
    public var method: Method
    public var frameCount: Int

    public init(rows: [FaceRow], method: Method, frameCount: Int) {
        self.rows = rows
        self.method = method
        self.frameCount = frameCount
    }

    /// The face of `row` in `frame`, or nil.
    public func face(row: Int, frame: Int) -> Int? {
        guard rows.indices.contains(row), frame >= 0, frame < rows[row].faces.count else { return nil }
        return rows[row].faces[frame]
    }
}

/// Matches the people in the frames of a stack, so the face strip can show one row per person.
///
/// Vision says nothing about who a face belongs to, so faces are matched by geometry: in frames
/// taken a moment apart a person stays in about the same place at about the same size.
///
/// Positions are measured in units of the image's short side, and distances relative to the size
/// of the faces compared, so the rules hold for small and large faces alike. Frame by frame:
///
/// 1. **Common shift.** A camera that moves between frames moves every face by the same amount.
///    The shift is estimated by trying each displacement between a known person and a face of
///    the new frame, and counting how many faces it brings within `Parameters.shiftInlierDistance`
///    face sizes of a known person. A shift other than none is used only when it explains at
///    least `Parameters.minimumShiftSupport` faces and more faces than no shift does, so one
///    person walking across the frame is never mistaken for the camera moving.
/// 2. **Assignment.** The faces of the frame are assigned to the people seen so far (in any
///    earlier frame, so a person can be missing for a while and come back) by an optimal
///    assignment (the Hungarian method) that first matches as many faces as possible and then
///    keeps the total distance smallest. A face and a person are never matched when, after the
///    common shift, their centres lie more than `Parameters.maximumDistance` face sizes apart, or
///    one face is more than `Parameters.maximumSizeRatio` times the size of the other. Each frame
///    a person has been missing adds `Parameters.gapPenalty` to the cost, so a person seen in
///    the frame before wins a close call.
/// 3. **New people.** A face matched to nobody starts a new row.
///
/// Two people who swap places are matched by place, not by identity: when they look alike in size
/// the row of the person on the left holds whoever stands on the left; when their sizes differ by
/// more than the ratio, neither is matched and each gets a new row. A match across the frame is
/// never made, since nothing tells two people apart but where they are.
///
/// When following faces breaks into more than twice as many rows as the most faces any frame
/// holds, the result is not trusted and the rows are made by position instead
/// (`FaceMatching.Method.positionOrder`), the fallback the plan names for unreliable matching.
public enum FaceMatcher {
    public struct Parameters: Sendable, Hashable {
        /// Largest distance between a person's last position and a face, in face sizes, after the
        /// common shift.
        public var maximumDistance = 1.0
        /// Largest ratio between the larger and the smaller of two faces that are matched.
        public var maximumSizeRatio = 1.6
        /// A face within this many face sizes of a known person, after a candidate shift, counts
        /// for that shift.
        public var shiftInlierDistance = 0.35
        /// Fewest faces a shift other than none must explain.
        public var minimumShiftSupport = 2
        /// Added to the cost of a match for each frame the person was missing in.
        public var gapPenalty = 0.05
        /// Weight of the size difference (the absolute log of the size ratio) in the cost.
        public var sizeWeight = 0.5

        public init() {}
    }

    /// The faces of a frame that get rows: the main faces by the same rules as
    /// `PhotoSummary.mainFaces` (frontal enough, large enough, not background), or every face.
    public static func faces(in frame: FaceFrame, tuning: Tuning, includeAllFaces: Bool = false) -> [Int] {
        includeAllFaces ? Array(frame.faces.indices) : PhotoSummary.mainFaces(of: frame.faces, tuning: tuning)
    }

    /// Matches the people across the frames, given in capture order.
    public static func match(
        _ frames: [FaceFrame],
        tuning: Tuning = Tuning(),
        includeAllFaces: Bool = false,
        parameters: Parameters = Parameters()
    ) -> FaceMatching {
        let spots = frames.map { frame in
            faces(in: frame, tuning: tuning, includeAllFaces: includeAllFaces).map { Spot(frame: frame, index: $0) }
        }
        let mostFaces = spots.map(\.count).max() ?? 0
        guard mostFaces > 0 else { return FaceMatching(rows: [], method: .tracked, frameCount: frames.count) }

        let tracked = track(spots, parameters: parameters)
        if tracked.count <= 2 * mostFaces {
            return FaceMatching(rows: tracked, method: .tracked, frameCount: frames.count)
        }
        return FaceMatching(rows: positionOrder(spots, rows: mostFaces), method: .positionOrder, frameCount: frames.count)
    }

    // MARK: - Geometry

    /// One face, measured in units of the image's short side.
    struct Spot {
        var index: Int
        var x: Double
        var y: Double
        var size: Double

        init(frame: FaceFrame, index: Int) {
            let width = Double(max(frame.imageWidth, 1))
            let height = Double(max(frame.imageHeight, 1))
            let short = min(width, height)
            let box = frame.faces[index].box
            self.index = index
            x = (box.x + box.width / 2) * width / short
            y = (box.y + box.height / 2) * height / short
            size = max((box.width * width + box.height * height) / 2 / short, 1e-6)
        }
    }

    private struct Track {
        var cells: [Int?]
        /// Position in the first frame's coordinates: the frame position minus the common shift.
        var x: Double
        var y: Double
        var size: Double
        var lastFrame: Int
        var firstX: Double
        var firstY: Double
        var firstFrame: Int
    }

    private static func sizeRatio(_ a: Double, _ b: Double) -> Double {
        max(a, b) / min(a, b)
    }

    // MARK: - Tracking

    private static func track(_ spots: [[Spot]], parameters: Parameters) -> [FaceRow] {
        let frameCount = spots.count
        var tracks: [Track] = []
        // The camera's shift so far: a position in frame k minus this is a position in the first
        // frame's coordinates.
        var offsetX = 0.0
        var offsetY = 0.0

        for (frame, faces) in spots.enumerated() where !faces.isEmpty {
            if !tracks.isEmpty {
                let shift = commonShift(faces, tracks: tracks, offsetX: offsetX, offsetY: offsetY, parameters: parameters)
                offsetX += shift.x
                offsetY += shift.y
            }

            var assigned = [Int?](repeating: nil, count: faces.count)
            if !tracks.isEmpty {
                let forbidden = 1e6
                var cost = [[Double]](repeating: [Double](repeating: forbidden, count: faces.count), count: tracks.count)
                for (t, track) in tracks.enumerated() {
                    for (f, face) in faces.enumerated() {
                        let mean = (track.size + face.size) / 2
                        let dx = face.x - offsetX - track.x
                        let dy = face.y - offsetY - track.y
                        let distance = (dx * dx + dy * dy).squareRoot() / mean
                        let ratio = sizeRatio(track.size, face.size)
                        guard distance <= parameters.maximumDistance, ratio <= parameters.maximumSizeRatio else { continue }
                        let gap = Double(frame - track.lastFrame - 1)
                        cost[t][f] = distance + parameters.sizeWeight * log(ratio) + parameters.gapPenalty * gap
                    }
                }
                let assignment = Hungarian.solve(cost)
                for (t, f) in assignment.enumerated() {
                    guard let f, cost[t][f] < forbidden else { continue }
                    assigned[f] = t
                }
            }

            for (f, face) in faces.enumerated() {
                let x = face.x - offsetX
                let y = face.y - offsetY
                if let t = assigned[f] {
                    tracks[t].cells[frame] = face.index
                    tracks[t].x = x
                    tracks[t].y = y
                    tracks[t].size = face.size
                    tracks[t].lastFrame = frame
                } else {
                    var cells = [Int?](repeating: nil, count: frameCount)
                    cells[frame] = face.index
                    tracks.append(Track(cells: cells, x: x, y: y, size: face.size, lastFrame: frame, firstX: x, firstY: y, firstFrame: frame))
                }
            }
        }

        return tracks
            .sorted { ($0.firstX, $0.firstY, $0.firstFrame) < ($1.firstX, $1.firstY, $1.firstFrame) }
            .map { FaceRow(faces: $0.cells) }
    }

    /// The camera's move between the known people and a new frame, or none.
    private static func commonShift(
        _ faces: [Spot],
        tracks: [Track],
        offsetX: Double,
        offsetY: Double,
        parameters: Parameters
    ) -> (x: Double, y: Double) {
        // Where each known person would be in the new frame if the camera had not moved.
        let known = tracks.map { (x: $0.x + offsetX, y: $0.y + offsetY, size: $0.size) }

        func support(_ dx: Double, _ dy: Double) -> (count: Int, residual: Double) {
            var count = 0
            var residual = 0.0
            for face in faces {
                var best = Double.infinity
                for person in known where sizeRatio(person.size, face.size) <= parameters.maximumSizeRatio {
                    let ex = face.x - dx - person.x
                    let ey = face.y - dy - person.y
                    best = min(best, (ex * ex + ey * ey).squareRoot() / ((person.size + face.size) / 2))
                }
                if best <= parameters.shiftInlierDistance {
                    count += 1
                    residual += best
                }
            }
            return (count, residual)
        }

        let none = support(0, 0)
        var best = (x: 0.0, y: 0.0, count: none.count, residual: none.residual)
        for person in known {
            for face in faces where sizeRatio(person.size, face.size) <= parameters.maximumSizeRatio {
                let dx = face.x - person.x
                let dy = face.y - person.y
                let result = support(dx, dy)
                guard result.count >= parameters.minimumShiftSupport, result.count > none.count else { continue }
                if result.count > best.count || (result.count == best.count && result.residual < best.residual) {
                    best = (dx, dy, result.count, result.residual)
                }
            }
        }
        return (best.x, best.y)
    }

    // MARK: - Fallback

    /// Rows by left-to-right order within each frame.
    private static func positionOrder(_ spots: [[Spot]], rows: Int) -> [FaceRow] {
        var result = [FaceRow](repeating: FaceRow(faces: [Int?](repeating: nil, count: spots.count)), count: rows)
        for (frame, faces) in spots.enumerated() {
            let ordered = faces.sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
            for (row, face) in ordered.enumerated() {
                result[row].faces[frame] = face.index
            }
        }
        return result
    }
}

/// The optimal assignment between the rows and columns of a cost matrix (the Hungarian method,
/// O(n³)). Works on rectangular matrices.
enum Hungarian {
    /// For every row, the column assigned to it, or nil when there are more rows than columns and
    /// the row got none. Minimises the total cost.
    static func solve(_ cost: [[Double]]) -> [Int?] {
        let rowCount = cost.count
        guard rowCount > 0 else { return [] }
        let columnCount = cost[0].count
        guard columnCount > 0 else { return [Int?](repeating: nil, count: rowCount) }
        // The method below needs no more rows than columns; transpose when there are.
        if rowCount > columnCount {
            let transposed = (0..<columnCount).map { c in (0..<rowCount).map { r in cost[r][c] } }
            let byColumn = solve(transposed)
            var result = [Int?](repeating: nil, count: rowCount)
            for (c, r) in byColumn.enumerated() {
                if let r { result[r] = c }
            }
            return result
        }

        let n = rowCount
        let m = columnCount
        // 1-based potentials and matching, after the classic formulation.
        var u = [Double](repeating: 0, count: n + 1)
        var v = [Double](repeating: 0, count: m + 1)
        var matchOfColumn = [Int](repeating: 0, count: m + 1)
        var way = [Int](repeating: 0, count: m + 1)
        for i in 1...n {
            matchOfColumn[0] = i
            var j0 = 0
            var minimum = [Double](repeating: .infinity, count: m + 1)
            var used = [Bool](repeating: false, count: m + 1)
            repeat {
                used[j0] = true
                let i0 = matchOfColumn[j0]
                var delta = Double.infinity
                var j1 = 0
                for j in 1...m where !used[j] {
                    let current = cost[i0 - 1][j - 1] - u[i0] - v[j]
                    if current < minimum[j] {
                        minimum[j] = current
                        way[j] = j0
                    }
                    if minimum[j] < delta {
                        delta = minimum[j]
                        j1 = j
                    }
                }
                for j in 0...m {
                    if used[j] {
                        u[matchOfColumn[j]] += delta
                        v[j] -= delta
                    } else {
                        minimum[j] -= delta
                    }
                }
                j0 = j1
            } while matchOfColumn[j0] != 0
            repeat {
                let j1 = way[j0]
                matchOfColumn[j0] = matchOfColumn[j1]
                j0 = j1
            } while j0 != 0
        }
        var result = [Int?](repeating: nil, count: n)
        for j in 1...m where matchOfColumn[j] != 0 {
            result[matchOfColumn[j] - 1] = j - 1
        }
        return result
    }
}

/// Where to cut a face strip cell: the face with room around it, as a square of image pixels
/// where the image allows.
public struct FaceCellCrop: Sendable, Hashable {
    /// The part of the image to cut, in unit coordinates (origin at the top-left), inside the
    /// image.
    public let rect: UnitRect
    /// The size of a 100% crop of `rect`: the pixels to cut from an image of the size given.
    public let pixelWidth: Int
    public let pixelHeight: Int
    /// The face box inside the crop, in the crop's unit coordinates, for drawing an outline.
    public let face: UnitRect

    /// Room on each side of the face, as a share of the face's longer side.
    public static let defaultPadding = 0.3

    /// - Parameters:
    ///   - face: the face box in unit coordinates of the image (`FaceScores.box`).
    ///   - imageWidth, imageHeight: the size of the image the crop is cut from, in pixels. Use the
    ///     full image's size for a 100% crop.
    public init(face: UnitRect, imageWidth: Int, imageHeight: Int, padding: Double = FaceCellCrop.defaultPadding) {
        let width = Double(max(imageWidth, 1))
        let height = Double(max(imageHeight, 1))
        let faceWidth = face.width * width
        let faceHeight = face.height * height
        // A square around the face's centre, kept inside the image by moving it rather than
        // cutting it, unless the image is too small for it.
        let side = max(faceWidth, faceHeight) * (1 + 2 * max(padding, 0))
        let cropWidth = min(max(side, 1), width)
        let cropHeight = min(max(side, 1), height)
        let centerX = (face.x + face.width / 2) * width
        let centerY = (face.y + face.height / 2) * height
        let left = min(max(centerX - cropWidth / 2, 0), width - cropWidth)
        let top = min(max(centerY - cropHeight / 2, 0), height - cropHeight)

        rect = UnitRect(x: left / width, y: top / height, width: cropWidth / width, height: cropHeight / height)
        pixelWidth = max(1, Int(cropWidth.rounded()))
        pixelHeight = max(1, Int(cropHeight.rounded()))
        self.face = UnitRect(
            x: (face.x * width - left) / cropWidth,
            y: (face.y * height - top) / cropHeight,
            width: faceWidth / cropWidth,
            height: faceHeight / cropHeight
        )
    }
}
