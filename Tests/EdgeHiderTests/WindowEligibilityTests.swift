import XCTest
import ApplicationServices
@testable import EdgeHider

final class WindowEligibilityTests: XCTestCase {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let visible = CGRect(x: 0, y: 70, width: 1440, height: 805)

    func allows(_ frame: CGRect, role: String? = kAXWindowRole,
                subrole: String? = kAXStandardWindowSubrole, movable: Bool = true,
                modal: Bool = false, fullScreen: Bool = false) -> Bool {
        WindowEligibility.allows(role: role, subrole: subrole, movable: movable,
            minimized: false, fullScreen: fullScreen, modal: modal, frame: frame,
            screenFrames: [screen], visibleFrames: [visible])
    }

    func testScreenshotOverlayWithoutFullScreenFlagIsExcluded() {
        XCTAssertFalse(allows(screen))
        XCTAssertFalse(allows(screen.insetBy(dx: 2, dy: 2)))
    }

    func testMaximizedWindowIsStillExcluded() {
        XCTAssertFalse(allows(visible))
    }

    func testOverlaySpanningDisplaysIsExcluded() {
        XCTAssertFalse(allows(CGRect(x: -1920, y: -200, width: 3360, height: 1400)))
        let upper = CGRect(x: -300, y: 900, width: 1920, height: 1080)
        XCTAssertFalse(WindowEligibility.allows(role: kAXWindowRole, subrole: kAXStandardWindowSubrole,
            movable: true, minimized: false, fullScreen: false, modal: false, frame: upper,
            screenFrames: [screen, upper], visibleFrames: [visible]))
    }

    func testOrdinaryChatWindowsAtAllEdgesRemainEligible() {
        for frame in [CGRect(x: 0, y: 200, width: 700, height: 500),
                      CGRect(x: 740, y: 200, width: 700, height: 500),
                      CGRect(x: 200, y: 375, width: 700, height: 500),
                      CGRect(x: 200, y: 70, width: 700, height: 500)] {
            XCTAssertTrue(allows(frame))
        }
    }

    func testPanelsDialogsAndUnknownTypesAreExcluded() {
        let frame = CGRect(x: 0, y: 200, width: 500, height: 400)
        for subrole in [kAXDialogSubrole, kAXFloatingWindowSubrole, "AXUnknown", nil] as [String?] {
            XCTAssertFalse(allows(frame, subrole: subrole))
        }
        XCTAssertFalse(allows(frame, role: nil))
        XCTAssertFalse(allows(frame, movable: false))
        XCTAssertFalse(allows(frame, modal: true))
        XCTAssertFalse(allows(frame, fullScreen: true))
    }

    func testEqualSizeWindowOutsideDisplayIsNotMistakenForCoveringOverlay() {
        XCTAssertTrue(allows(CGRect(x: 500, y: 300, width: visible.width, height: visible.height)))
    }
}
