import CoreGraphics
import XCTest
@testable import OWAWidget

final class NotificationScreenPolicyTests: XCTestCase {
    func testPrimaryScreenIndexUsesMainDisplayID() {
        let displayIDs: [CGDirectDisplayID?] = [42, 99, 777]

        let index = NotificationScreenPolicy.primaryScreenIndex(displayIDs: displayIDs, mainDisplayID: 99)

        XCTAssertEqual(index, 1)
    }

    func testPrimaryScreenIndexReturnsNilWhenMissingMainDisplayID() {
        let displayIDs: [CGDirectDisplayID?] = [42, 99, 777]

        let index = NotificationScreenPolicy.primaryScreenIndex(displayIDs: displayIDs, mainDisplayID: 1234)

        XCTAssertNil(index)
    }

    func testActiveScreenIndexFindsScreenContainingMouseLocation() {
        let frames: [CGRect] = [
            CGRect(x: 0, y: 0, width: 1920, height: 1080),
            CGRect(x: 1920, y: 0, width: 1920, height: 1080),
        ]

        let index = NotificationScreenPolicy.activeScreenIndex(
            frames: frames,
            mouseLocation: CGPoint(x: 2500, y: 500)
        )

        XCTAssertEqual(index, 1)
    }

    func testActiveScreenIndexReturnsNilOutsideAllScreens() {
        let frames: [CGRect] = [
            CGRect(x: 0, y: 0, width: 1920, height: 1080),
        ]

        let index = NotificationScreenPolicy.activeScreenIndex(
            frames: frames,
            mouseLocation: CGPoint(x: -200, y: 5000)
        )

        XCTAssertNil(index)
    }

    func testPrimaryScreenIndexSkipsLeadingNilDisplayIDs() {
        let displayIDs: [CGDirectDisplayID?] = [nil, 99, 777]

        let index = NotificationScreenPolicy.primaryScreenIndex(displayIDs: displayIDs, mainDisplayID: 99)

        XCTAssertEqual(index, 1)
    }

    func testPrimaryScreenIndexReturnsNilForEmptyDisplayIDs() {
        let displayIDs: [CGDirectDisplayID?] = []

        let index = NotificationScreenPolicy.primaryScreenIndex(displayIDs: displayIDs, mainDisplayID: 1)

        XCTAssertNil(index)
    }

    func testActiveScreenIndexReturnsNilForEmptyFrames() {
        let index = NotificationScreenPolicy.activeScreenIndex(
            frames: [],
            mouseLocation: CGPoint(x: 100, y: 100)
        )

        XCTAssertNil(index)
    }

    func testActiveScreenIndexUsesFirstMatchWhenMouseInsideOverlappingFrames() {
        let frames: [CGRect] = [
            CGRect(x: 0, y: 0, width: 500, height: 500),
            CGRect(x: 100, y: 100, width: 500, height: 500),
        ]

        let index = NotificationScreenPolicy.activeScreenIndex(
            frames: frames,
            mouseLocation: CGPoint(x: 150, y: 150)
        )

        XCTAssertEqual(index, 0)
    }

    func testActiveScreenIndexFindsInnerScreenWhenPointOutsideFirstButInsideSecond() {
        let frames: [CGRect] = [
            CGRect(x: 0, y: 0, width: 100, height: 100),
            CGRect(x: 200, y: 0, width: 100, height: 100),
        ]

        let index = NotificationScreenPolicy.activeScreenIndex(
            frames: frames,
            mouseLocation: CGPoint(x: 250, y: 50)
        )

        XCTAssertEqual(index, 1)
    }
}
