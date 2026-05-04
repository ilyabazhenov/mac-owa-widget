import CoreGraphics
import XCTest
@testable import OWAWidget

final class PopoverWindowPositioningTests: XCTestCase {
    func testPlacesWindowToLeftOfAnchor() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)

        let x = PopoverWindowPositioning.leftAlignedOriginX(
            anchorX: 1_000,
            windowWidth: 420,
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(x, 580, accuracy: 0.001)
    }

    func testClampsWindowToLeftScreenEdge() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)

        let x = PopoverWindowPositioning.leftAlignedOriginX(
            anchorX: 300,
            windowWidth: 420,
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(x, 0, accuracy: 0.001)
    }

    func testClampsWindowToRightScreenEdgeWhenAnchorIsOutsideVisibleFrame() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)

        let x = PopoverWindowPositioning.leftAlignedOriginX(
            anchorX: 1_500,
            windowWidth: 420,
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(x, 1_020, accuracy: 0.001)
    }
}
