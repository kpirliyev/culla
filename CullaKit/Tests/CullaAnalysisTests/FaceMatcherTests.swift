@testable import CullaAnalysis
import CullaCore
import Foundation
import Testing

/// Frames of 3000 × 2000 pixels; faces placed by their centre in unit coordinates and their
/// height as a share of the short side.
private let width = 3000
private let height = 2000

private func face(_ x: Double, _ y: Double, size: Double = 0.15, openness: Double = 0.4, yaw: Double = 0) -> FaceScores {
    let boxHeight = size
    let boxWidth = size * Double(height) / Double(width)
    return FaceScores(
        box: UnitRect(x: x - boxWidth / 2, y: y - boxHeight / 2, width: boxWidth, height: boxHeight),
        sizeFraction: size,
        leftEyeOpenness: openness,
        rightEyeOpenness: openness,
        yawDegrees: yaw
    )
}

private func frame(_ faces: FaceScores...) -> FaceFrame {
    FaceFrame(faces: faces, imageWidth: width, imageHeight: height)
}

private func frame(_ faces: [FaceScores]) -> FaceFrame {
    FaceFrame(faces: faces, imageWidth: width, imageHeight: height)
}

/// For each row, the faces' x centres per frame, rounded, so a test can say who is in a row.
private func xs(_ matching: FaceMatching, _ frames: [FaceFrame]) -> [[Double?]] {
    matching.rows.map { row in
        row.faces.enumerated().map { frameIndex, face in
            face.map { (frames[frameIndex].faces[$0].box.center.x * 100).rounded() / 100 }
        }
    }
}

@Suite("FaceMatcher")
struct FaceMatcherTests {
    @Test func twoPeopleSteadyAcrossFiveFrames() {
        // Small jitter, and the faces are listed in a different order in some frames.
        let frames = [
            frame(face(0.30, 0.40), face(0.70, 0.42)),
            frame(face(0.705, 0.41), face(0.302, 0.40)),
            frame(face(0.298, 0.405), face(0.698, 0.42)),
            frame(face(0.71, 0.415), face(0.305, 0.395)),
            frame(face(0.30, 0.40), face(0.70, 0.42)),
        ]
        let matching = FaceMatcher.match(frames)
        #expect(matching.method == .tracked)
        #expect(matching.frameCount == 5)
        #expect(matching.rows.map(\.faces) == [[0, 1, 0, 1, 0], [1, 0, 1, 0, 1]])
        #expect(matching.rows.map(\.frameCount) == [5, 5])
        #expect(matching.face(row: 1, frame: 1) == 0)
        #expect(matching.face(row: 2, frame: 0) == nil)
    }

    @Test func aBlinkChangesNothing() {
        let frames = [
            frame(face(0.30, 0.40), face(0.70, 0.40)),
            frame(face(0.30, 0.40, openness: 0.05), face(0.70, 0.40)),
            frame(face(0.30, 0.40), face(0.70, 0.40, openness: 0.02)),
        ]
        let matching = FaceMatcher.match(frames)
        #expect(matching.rows.map(\.faces) == [[0, 0, 0], [1, 1, 1]])
    }

    @Test func aPersonMissingInTheMiddleFramesComesBackToTheSameRow() {
        let frames = [
            frame(face(0.30, 0.40), face(0.70, 0.40)),
            frame(face(0.30, 0.40)),
            frame(face(0.31, 0.40)),
            frame(face(0.30, 0.41)),
            frame(face(0.30, 0.40), face(0.69, 0.40)),
        ]
        let matching = FaceMatcher.match(frames)
        #expect(matching.method == .tracked)
        #expect(matching.rows.map(\.faces) == [[0, 0, 0, 0, 0], [1, nil, nil, nil, 1]])
    }

    @Test func aPersonEnteringLateGetsARowInPlaceOrder() {
        let frames = [
            frame(face(0.25, 0.40), face(0.75, 0.40)),
            frame(face(0.25, 0.40), face(0.75, 0.40)),
            frame(face(0.25, 0.40), face(0.75, 0.40), face(0.50, 0.45)),
            frame(face(0.50, 0.45), face(0.25, 0.40), face(0.75, 0.40)),
        ]
        let matching = FaceMatcher.match(frames)
        // Rows left to right: the person at 0.25, the newcomer at 0.50, the person at 0.75.
        #expect(matching.rows.map(\.faces) == [[0, 0, 0, 1], [nil, nil, 2, 0], [1, 1, 1, 2]])
        #expect(matching.rows[1].firstFrame == 2)
    }

    @Test func peopleOfOneSizeSwappingSidesAreRowedByPlace() {
        // Nothing tells the two apart but where they are, so each row follows a place: the
        // left row holds whoever stands on the left. A face is never matched across the frame.
        let frames = [
            frame(face(0.30, 0.40), face(0.70, 0.40, openness: 0.1)),
            frame(face(0.30, 0.40, openness: 0.1), face(0.70, 0.40)),
        ]
        let matching = FaceMatcher.match(frames)
        #expect(xs(matching, frames) == [[0.3, 0.3], [0.7, 0.7]])
    }

    @Test func peopleOfDifferentSizesSwappingSidesAreNotMatched() {
        // An adult and a child swap places: the faces at each place differ too much in size, and
        // the jump across the frame is too far, so nobody is matched and each face gets a row.
        let frames = [
            frame(face(0.30, 0.40, size: 0.15), face(0.70, 0.50, size: 0.08)),
            frame(face(0.30, 0.50, size: 0.08), face(0.70, 0.40, size: 0.15)),
        ]
        let matching = FaceMatcher.match(frames)
        #expect(matching.method == .tracked)
        #expect(matching.rows.count == 4)
        #expect(matching.rows.allSatisfy { $0.frameCount == 1 })
        // Never matched across the swap: no row holds both of the adult's faces.
        #expect(!matching.rows.contains { $0.faces == [0, 1] || $0.faces == [1, 0] })
    }

    @Test func aFrameWithoutFacesLeavesAGap() {
        let frames = [
            frame(face(0.30, 0.40), face(0.70, 0.40)),
            frame([]),
            frame(face(0.30, 0.40), face(0.70, 0.40)),
        ]
        let matching = FaceMatcher.match(frames)
        #expect(matching.rows.map(\.faces) == [[0, nil, 0], [1, nil, 1]])
        #expect(FaceMatcher.match([frame([]), frame([])]).rows.isEmpty)
        #expect(FaceMatcher.match([]).rows.isEmpty)
    }

    @Test func aCommonCameraShiftIsFollowed() {
        // Three people 0.25 apart; the camera moves so every face shifts 0.12 across and 0.05
        // down, well beyond the distance a single face may move.
        let people: [(Double, Double)] = [(0.20, 0.40), (0.45, 0.42), (0.70, 0.40)]
        func shifted(_ dx: Double, _ dy: Double) -> FaceFrame {
            frame(people.map { face($0.0 + dx, $0.1 + dy, size: 0.10) })
        }
        let frames = [shifted(0, 0), shifted(0.12, 0.05), shifted(0.12, 0.05), shifted(-0.05, 0), shifted(0.20, -0.04)]
        let matching = FaceMatcher.match(frames)
        #expect(matching.method == .tracked)
        #expect(matching.rows.map(\.faces) == [[0, 0, 0, 0, 0], [1, 1, 1, 1, 1], [2, 2, 2, 2, 2]])
    }

    @Test func aCommonShiftAfterAFrameWithoutFaces() {
        let frames = [
            frame(face(0.20, 0.40, size: 0.1), face(0.50, 0.40, size: 0.1)),
            frame([]),
            frame(face(0.35, 0.40, size: 0.1), face(0.65, 0.40, size: 0.1)),
        ]
        let matching = FaceMatcher.match(frames)
        #expect(matching.rows.map(\.faces) == [[0, nil, 0], [1, nil, 1]])
    }

    @Test func oneFaceJumpingAcrossTheFrameIsNotTakenForACameraMove() {
        // A lone face that moves far is not matched by an invented shift: one face is not enough
        // to tell a camera move from someone else stepping in.
        let frames = [frame(face(0.20, 0.40)), frame(face(0.80, 0.40))]
        let matching = FaceMatcher.match(frames)
        #expect(matching.method == .tracked)
        #expect(matching.rows.map(\.faces) == [[0, nil], [nil, 0]])
    }

    @Test func twelveFacesInAGroupShot() {
        // Two staggered rows of six, small jitter, one blink, and the faces listed in a shuffled
        // order in each frame.
        var people: [(Double, Double)] = []
        for column in 0..<6 {
            people.append((0.12 + Double(column) * 0.15, 0.35))
            people.append((0.19 + Double(column) * 0.15, 0.62))
        }
        var frames: [FaceFrame] = []
        var orders: [[Int]] = []
        var generator = SeededGenerator(seed: 7)
        for frameIndex in 0..<4 {
            let order = Array(0..<12).shuffled(using: &generator)
            orders.append(order)
            frames.append(frame(order.map { person in
                let jitter = Double((person * 7 + frameIndex * 3) % 5 - 2) * 0.002
                return face(people[person].0 + jitter, people[person].1 - jitter, size: 0.07, openness: person == 5 && frameIndex == 2 ? 0.05 : 0.4)
            }))
        }
        let matching = FaceMatcher.match(frames)
        #expect(matching.method == .tracked)
        #expect(matching.rows.count == 12)
        for row in matching.rows {
            // Every row holds one person in every frame.
            let persons = row.faces.enumerated().map { frameIndex, face in face.map { orders[frameIndex][$0] } }
            #expect(persons.allSatisfy { $0 != nil })
            #expect(Set(persons).count == 1)
        }
        // Rows are ordered left to right by where each person first appears.
        let firstXs = matching.rows.map { frames[0].faces[$0.faces[0]!].box.center.x }
        #expect(firstXs == firstXs.sorted())
    }

    @Test func onlyMainFacesGetRowsUnlessAllAreAsked() {
        // A small face in the background and a profile are not main faces.
        let frames = [
            frame(face(0.30, 0.40), face(0.80, 0.20, size: 0.03), face(0.55, 0.45, yaw: 70)),
            frame(face(0.30, 0.40), face(0.80, 0.20, size: 0.03), face(0.55, 0.45, yaw: 70)),
        ]
        #expect(FaceMatcher.faces(in: frames[0], tuning: Tuning()) == [0])
        #expect(FaceMatcher.match(frames).rows.map(\.faces) == [[0, 0]])
        let all = FaceMatcher.match(frames, includeAllFaces: true)
        #expect(all.rows.map(\.faces) == [[0, 0], [2, 2], [1, 1]])
    }

    @Test func brokenTrackingFallsBackToPlaceOrder() {
        // One face that is somewhere else in every frame breaks into a row per frame; the strip
        // then shows each frame's faces by place instead.
        let frames = [
            frame(face(0.10, 0.30)), frame(face(0.50, 0.70)), frame(face(0.90, 0.30)), frame(face(0.30, 0.80)),
        ]
        let matching = FaceMatcher.match(frames)
        #expect(matching.method == .positionOrder)
        #expect(matching.rows.map(\.faces) == [[0, 0, 0, 0]])
    }

    @Test func placeOrderFallbackPutsTheLeftmostFirst() {
        let frames = [
            frame(face(0.10, 0.30), face(0.60, 0.30)),
            frame(face(0.90, 0.80), face(0.40, 0.70)),
            frame(face(0.50, 0.10)),
            frame(face(0.20, 0.90), face(0.05, 0.10)),
        ]
        let matching = FaceMatcher.match(frames)
        #expect(matching.method == .positionOrder)
        #expect(matching.rows.map(\.faces) == [[0, 1, 0, 1], [1, 0, nil, 0]])
    }

    @Test func faceRowsDoNotCrossAtNeighbours() {
        // Two neighbours both drift right; an assignment that looked at the first face alone
        // would give it the nearest face and leave the second person without one.
        let frames = [
            frame(face(0.40, 0.40, size: 0.1), face(0.50, 0.40, size: 0.1)),
            frame(face(0.46, 0.40, size: 0.1), face(0.555, 0.40, size: 0.1)),
        ]
        let matching = FaceMatcher.match(frames)
        #expect(matching.rows.map(\.faces) == [[0, 0], [1, 1]])
    }

    @Test func theAssignmentIsOptimalNotGreedy() {
        // Greedy would give row 0 column 0 (cost 1) and leave row 1 with the forbidden column 1.
        let forbidden = 1e6
        #expect(Hungarian.solve([[1, 2], [1.5, forbidden]]) == [1, 0])
        #expect(Hungarian.solve([[4, 1, 3], [2, 0, 5], [3, 2, 2]]) == [1, 0, 2])
        // More rows than columns: one row goes without.
        #expect(Hungarian.solve([[1], [0.5], [2]]) == [nil, 0, nil])
        #expect(Hungarian.solve([]) == [])
    }
}

@Suite("FaceCellCrop")
struct FaceCellCropTests {
    @Test func aCentredFaceGetsASquarePaddedCrop() {
        // A face 300 × 300 pixels in a 6000 × 4000 image.
        let box = UnitRect(x: 0.5, y: 0.5, width: 300.0 / 6000, height: 300.0 / 4000)
        let crop = FaceCellCrop(face: box, imageWidth: 6000, imageHeight: 4000)
        // 30 % of the face on each side: 480 pixels square.
        #expect(crop.pixelWidth == 480 && crop.pixelHeight == 480)
        #expect(abs(crop.rect.width * 6000 - 480) < 1e-6)
        #expect(abs(crop.rect.height * 4000 - 480) < 1e-6)
        #expect(abs(crop.rect.center.x - box.center.x) < 1e-9)
        #expect(abs(crop.face.x - 90.0 / 480) < 1e-9 && abs(crop.face.width - 300.0 / 480) < 1e-9)
    }

    @Test func aFaceAtTheEdgeIsMovedInsideTheImage() {
        let box = UnitRect(x: 0, y: 0.95, width: 0.05, height: 0.05)
        let crop = FaceCellCrop(face: box, imageWidth: 1000, imageHeight: 1000)
        #expect(crop.rect.x == 0)
        #expect(abs(crop.rect.maxY - 1) < 1e-9)
        #expect(crop.pixelWidth == 80 && crop.pixelHeight == 80)
        // The face sits in the crop's bottom-left corner.
        #expect(crop.face.x == 0)
        #expect(abs(crop.face.maxY - 1) < 1e-9)
    }

    @Test func aFaceLargerThanTheImageIsCutToTheImage() {
        let crop = FaceCellCrop(face: UnitRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8), imageWidth: 400, imageHeight: 300)
        #expect(crop.rect == UnitRect(x: 0, y: 0, width: 1, height: 1))
        #expect(crop.pixelWidth == 400 && crop.pixelHeight == 300)
    }
}

/// A small deterministic random number generator for shuffling test input.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &+ 0x9E37_79B9_7F4A_7C15
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
