import CoreGraphics
import CullaCore
import Testing

@Suite("UnitRect")
struct UnitRectTests {
    private func isClose(_ a: Double, _ b: Double, tolerance: Double = 1e-9) -> Bool {
        abs(a - b) <= tolerance
    }

    private func isClose(_ a: UnitRect, _ b: UnitRect) -> Bool {
        isClose(a.x, b.x) && isClose(a.y, b.y) && isClose(a.width, b.width) && isClose(a.height, b.height)
    }

    @Test func pixelRoundTrip() {
        let pixels = CGRect(x: 120, y: 45, width: 300, height: 150)
        let unit = UnitRect(pixelRect: pixels, imageWidth: 1200, imageHeight: 900)
        #expect(isClose(unit, UnitRect(x: 0.1, y: 0.05, width: 0.25, height: 1.0 / 6)))
        let back = unit.pixelRect(imageWidth: 1200, imageHeight: 900)
        #expect(isClose(back.minX, 120) && isClose(back.minY, 45))
        #expect(isClose(back.width, 300) && isClose(back.height, 150))
    }

    @Test func pixelRectWithZeroSizedImageDoesNotDivideByZero() {
        let unit = UnitRect(pixelRect: CGRect(x: 1, y: 1, width: 1, height: 1), imageWidth: 0, imageHeight: 0)
        #expect(unit.x.isFinite && unit.width.isFinite)
    }

    @Test func clampedKeepsOnlyThePartInsideTheImage() {
        let rect = UnitRect(x: -0.2, y: 0.5, width: 0.5, height: 0.8)
        #expect(isClose(rect.clamped(), UnitRect(x: 0, y: 0.5, width: 0.3, height: 0.5)))
        #expect(UnitRect.full.clamped() == .full)
        // Entirely outside: nothing left.
        #expect(UnitRect(x: 1.5, y: 0, width: 0.2, height: 0.2).clamped().area == 0)
    }

    @Test func union() {
        let a = UnitRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
        let b = UnitRect(x: 0.5, y: 0.6, width: 0.1, height: 0.3)
        #expect(isClose(a.union(b), UnitRect(x: 0.1, y: 0.1, width: 0.5, height: 0.8)))
        #expect(isClose(a.union(a), a))
    }

    @Test func intersection() throws {
        let a = UnitRect(x: 0, y: 0, width: 0.5, height: 0.5)
        let b = UnitRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let overlap = try #require(a.intersection(b))
        #expect(isClose(overlap, UnitRect(x: 0.25, y: 0.25, width: 0.25, height: 0.25)))
        #expect(a.intersection(UnitRect(x: 0.6, y: 0.6, width: 0.1, height: 0.1)) == nil)
        // Rectangles that only touch share no area.
        #expect(a.intersection(UnitRect(x: 0.5, y: 0, width: 0.5, height: 0.5)) == nil)
    }

    @Test func intersectionOverUnion() {
        let a = UnitRect(x: 0, y: 0, width: 0.5, height: 0.5)
        #expect(isClose(a.intersectionOverUnion(with: a), 1))
        #expect(a.intersectionOverUnion(with: UnitRect(x: 0.6, y: 0.6, width: 0.2, height: 0.2)) == 0)
        // Overlap 0.0625, union 0.25 + 0.25 - 0.0625.
        let b = UnitRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        #expect(isClose(a.intersectionOverUnion(with: b), 0.0625 / 0.4375))
        #expect(isClose(b.intersectionOverUnion(with: a), a.intersectionOverUnion(with: b)))
    }

    @Test func insetPositiveShrinksAroundTheCentre() {
        let rect = UnitRect(x: 0.2, y: 0.4, width: 0.4, height: 0.2)
        let inset = rect.inset(byFraction: 0.1)
        #expect(isClose(inset, UnitRect(x: 0.24, y: 0.42, width: 0.32, height: 0.16)))
        #expect(isClose(inset.center.x, rect.center.x) && isClose(inset.center.y, rect.center.y))
    }

    @Test func insetNegativeGrowsAroundTheCentre() {
        let rect = UnitRect(x: 0.2, y: 0.4, width: 0.4, height: 0.2)
        let grown = rect.inset(byFraction: -0.25)
        #expect(isClose(grown, UnitRect(x: 0.1, y: 0.35, width: 0.6, height: 0.3)))
        #expect(isClose(grown.center.x, rect.center.x) && isClose(grown.center.y, rect.center.y))
    }

    @Test func derivedValues() {
        let rect = UnitRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        #expect(isClose(rect.maxX, 0.4) && isClose(rect.maxY, 0.6))
        #expect(isClose(rect.center.x, 0.25) && isClose(rect.center.y, 0.4))
        #expect(isClose(rect.area, 0.12))
        #expect(UnitRect(x: 0, y: 0, width: -1, height: 1).area == 0)
    }
}
