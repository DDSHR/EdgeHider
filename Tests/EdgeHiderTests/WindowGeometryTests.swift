import XCTest
@testable import EdgeHider

final class WindowGeometryTests: XCTestCase {
    private let main = CGRect(x: 0, y: 0, width: 1440, height: 900)

    func testCoordinateConversionAcrossVerticallyStackedDisplays() {
        let frames = [CGRect(x: 100, y: 100, width: 400, height: 300),
                      CGRect(x: -900, y: 1100, width: 400, height: 300),
                      CGRect(x: 1500, y: -700, width: 400, height: 300)]
        let expectedY: [CGFloat] = [500, -500, 1300]
        for (frame, y) in zip(frames, expectedY) {
            let converted = WindowGeometry.converted(frame, primaryTop: 900)
            XCTAssertEqual(converted.minY, y)
            XCTAssertEqual(WindowGeometry.converted(converted, primaryTop: 900), frame)
        }
    }

    func testScreenChosenByLargestOverlap() {
        let right = CGRect(x: 1440, y: 300, width: 1920, height: 1080)
        XCTAssertEqual(WindowGeometry.screen(for: CGRect(x: 1300, y: 400, width: 600, height: 400), screens: [main, right]), right)
        XCTAssertNil(WindowGeometry.screen(for: main, screens: []))
    }

    func testFixedDirectionDoesNotHideAtAnotherEdge() {
        let frame = CGRect(x: 2, y: 200, width: 400, height: 300)
        XCTAssertEqual(WindowGeometry.edge(frame: frame, screen: main, threshold: 12, preferred: .automatic), .left)
        XCTAssertNil(WindowGeometry.edge(frame: frame, screen: main, threshold: 12, preferred: .right))
    }

    func testThresholdAndOvershoot() {
        let near = CGRect(x: -8, y: 200, width: 400, height: 300)
        XCTAssertEqual(WindowGeometry.edge(frame: near, screen: main, threshold: 12, preferred: .left), .left)
        XCTAssertNil(WindowGeometry.edge(frame: near, screen: main, threshold: 4, preferred: .left))
        XCTAssertNil(WindowGeometry.edge(frame: CGRect(x: -800, y: 200, width: 400, height: 300), screen: main, threshold: 12, preferred: .automatic))
    }

    func testHiddenFramesForAllFourSides() {
        let frame = CGRect(x: 200, y: 200, width: 400, height: 300)
        let expected: [(HiddenSide, CGPoint)] = [(.left, CGPoint(x: -394, y: 200)),
            (.right, CGPoint(x: 1434, y: 200)), (.top, CGPoint(x: 200, y: 894)),
            (.bottom, CGPoint(x: 200, y: -294))]
        for (side, origin) in expected {
            let hidden = WindowGeometry.hidden(frame, side: side, screen: main, peek: 6)
            XCTAssertEqual(hidden.origin, origin)
            XCTAssertEqual(hidden.size, frame.size)
        }
    }

    func testRestoreClampsBothAxesWithoutResizing() {
        let frame = CGRect(x: -40, y: 850, width: 400, height: 300)
        let visible = WindowGeometry.aligned(frame, side: .left, screen: main)
        XCTAssertEqual(visible, CGRect(x: 0, y: 600, width: 400, height: 300))
        let disconnected = CGRect(x: 2000, y: 1500, width: 400, height: 300)
        XCTAssertTrue(main.contains(WindowGeometry.visible(disconnected, screen: main)))
    }

    func testHotZoneUsesConfiguredWidthAndIndividualBarSpan() {
        let bar = CGRect(x: 0, y: 300, width: 24, height: 60)
        let narrow = WindowGeometry.hotZone(bar: bar, side: .left, screen: main, width: 3)
        let wide = WindowGeometry.hotZone(bar: bar, side: .left, screen: main, width: 12)
        XCTAssertFalse(narrow.contains(CGPoint(x: 8, y: 330)))
        XCTAssertTrue(wide.contains(CGPoint(x: 8, y: 330)))
        XCTAssertFalse(wide.contains(CGPoint(x: 8, y: 400)))
        let top = WindowGeometry.hotZone(bar: CGRect(x: 400, y: 876, width: 60, height: 24), side: .top, screen: main, width: 6)
        XCTAssertEqual(top, CGRect(x: 400, y: 894, width: 60, height: 6))
    }
}
