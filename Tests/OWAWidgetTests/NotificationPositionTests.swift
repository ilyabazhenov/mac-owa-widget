import AppKit
import XCTest
@testable import OWAWidget

final class NotificationPositionTests: XCTestCase {
    private let visibleFrame = NSRect(x: 100, y: 50, width: 1000, height: 800)
    private let contentSize = NSSize(width: 360, height: 200)
    private let margin: CGFloat = 16

    func testTopRightOrigin() {
        let origin = NotificationPosition.topRight.origin(in: visibleFrame, contentSize: contentSize, margin: margin)
        XCTAssertEqual(origin.x, visibleFrame.maxX - contentSize.width - margin, accuracy: 0.001)
        XCTAssertEqual(origin.y, visibleFrame.maxY - contentSize.height - margin, accuracy: 0.001)
    }

    func testTopLeftOrigin() {
        let origin = NotificationPosition.topLeft.origin(in: visibleFrame, contentSize: contentSize, margin: margin)
        XCTAssertEqual(origin.x, visibleFrame.minX + margin, accuracy: 0.001)
        XCTAssertEqual(origin.y, visibleFrame.maxY - contentSize.height - margin, accuracy: 0.001)
    }

    func testTopCenterOrigin() {
        let origin = NotificationPosition.topCenter.origin(in: visibleFrame, contentSize: contentSize, margin: margin)
        XCTAssertEqual(origin.x, visibleFrame.midX - contentSize.width / 2, accuracy: 0.001)
        XCTAssertEqual(origin.y, visibleFrame.maxY - contentSize.height - margin, accuracy: 0.001)
    }

    func testBottomLeftOrigin() {
        let origin = NotificationPosition.bottomLeft.origin(in: visibleFrame, contentSize: contentSize, margin: margin)
        XCTAssertEqual(origin.x, visibleFrame.minX + margin, accuracy: 0.001)
        XCTAssertEqual(origin.y, visibleFrame.minY + margin, accuracy: 0.001)
    }

    func testBottomCenterOrigin() {
        let origin = NotificationPosition.bottomCenter.origin(in: visibleFrame, contentSize: contentSize, margin: margin)
        XCTAssertEqual(origin.x, visibleFrame.midX - contentSize.width / 2, accuracy: 0.001)
        XCTAssertEqual(origin.y, visibleFrame.minY + margin, accuracy: 0.001)
    }

    func testBottomRightOrigin() {
        let origin = NotificationPosition.bottomRight.origin(in: visibleFrame, contentSize: contentSize, margin: margin)
        XCTAssertEqual(origin.x, visibleFrame.maxX - contentSize.width - margin, accuracy: 0.001)
        XCTAssertEqual(origin.y, visibleFrame.minY + margin, accuracy: 0.001)
    }

    func testOffScreenOriginForTopPositionsIsAboveVisibleFrame() {
        for position in [NotificationPosition.topLeft, .topCenter, .topRight] {
            let off = position.offScreenOrigin(in: visibleFrame, contentSize: contentSize, margin: margin)
            XCTAssertGreaterThan(off.y, visibleFrame.maxY, "expected off-screen above for \(position)")
        }
    }

    func testOffScreenOriginForBottomPositionsIsBelowVisibleFrame() {
        for position in [NotificationPosition.bottomLeft, .bottomCenter, .bottomRight] {
            let off = position.offScreenOrigin(in: visibleFrame, contentSize: contentSize, margin: margin)
            XCTAssertLessThan(off.y + contentSize.height, visibleFrame.minY, "expected off-screen below for \(position)")
        }
    }

    func testOffScreenOriginPreservesTargetXCoordinate() {
        for position in NotificationPosition.allCases {
            let target = position.origin(in: visibleFrame, contentSize: contentSize, margin: margin)
            let off = position.offScreenOrigin(in: visibleFrame, contentSize: contentSize, margin: margin)
            XCTAssertEqual(off.x, target.x, accuracy: 0.001, "x must match for \(position)")
        }
    }

    func testIsTop() {
        XCTAssertTrue(NotificationPosition.topLeft.isTop)
        XCTAssertTrue(NotificationPosition.topCenter.isTop)
        XCTAssertTrue(NotificationPosition.topRight.isTop)
        XCTAssertFalse(NotificationPosition.bottomLeft.isTop)
        XCTAssertFalse(NotificationPosition.bottomCenter.isTop)
        XCTAssertFalse(NotificationPosition.bottomRight.isTop)
    }

    func testCurrentFallsBackToDefaultForMissingValue() {
        let defaults = UserDefaults.standard
        let key = NotificationPosition.defaultsKey
        let previous = defaults.string(forKey: key)
        defaults.removeObject(forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) } else { defaults.removeObject(forKey: key) }
        }

        XCTAssertEqual(NotificationPosition.current, NotificationPosition.default)
    }

    func testCurrentFallsBackToDefaultForInvalidValue() {
        let defaults = UserDefaults.standard
        let key = NotificationPosition.defaultsKey
        let previous = defaults.string(forKey: key)
        defaults.set("nonsense", forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) } else { defaults.removeObject(forKey: key) }
        }

        XCTAssertEqual(NotificationPosition.current, NotificationPosition.default)
    }

    func testCurrentReadsStoredValue() {
        let defaults = UserDefaults.standard
        let key = NotificationPosition.defaultsKey
        let previous = defaults.string(forKey: key)
        defaults.set(NotificationPosition.bottomCenter.rawValue, forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) } else { defaults.removeObject(forKey: key) }
        }

        XCTAssertEqual(NotificationPosition.current, .bottomCenter)
    }

    func testTopAndBottomCasesContents() {
        XCTAssertEqual(NotificationPosition.topCases, [.topLeft, .topCenter, .topRight])
        XCTAssertEqual(NotificationPosition.bottomCases, [.bottomLeft, .bottomCenter, .bottomRight])
    }

    func testTopAndBottomCasesPartitionAllCases() {
        let combined = NotificationPosition.topCases + NotificationPosition.bottomCases
        XCTAssertEqual(Set(combined), Set(NotificationPosition.allCases))
        XCTAssertEqual(combined.count, NotificationPosition.allCases.count, "no overlap between top and bottom cases")
    }

    func testGroupLocalizationKey() {
        for position in NotificationPosition.topCases {
            XCTAssertEqual(position.groupLocalizationKey, "preferences.notifications.position.group.top")
        }
        for position in NotificationPosition.bottomCases {
            XCTAssertEqual(position.groupLocalizationKey, "preferences.notifications.position.group.bottom")
        }
    }

    func testShortLocalizationKey() {
        XCTAssertEqual(NotificationPosition.topLeft.shortLocalizationKey, "preferences.notifications.position.short.left")
        XCTAssertEqual(NotificationPosition.bottomLeft.shortLocalizationKey, "preferences.notifications.position.short.left")
        XCTAssertEqual(NotificationPosition.topCenter.shortLocalizationKey, "preferences.notifications.position.short.center")
        XCTAssertEqual(NotificationPosition.bottomCenter.shortLocalizationKey, "preferences.notifications.position.short.center")
        XCTAssertEqual(NotificationPosition.topRight.shortLocalizationKey, "preferences.notifications.position.short.right")
        XCTAssertEqual(NotificationPosition.bottomRight.shortLocalizationKey, "preferences.notifications.position.short.right")
    }

    func testRawValuePersistenceRoundtrip() {
        for position in NotificationPosition.allCases {
            XCTAssertEqual(NotificationPosition(rawValue: position.rawValue), position)
        }
    }

    func testAllCasesCount() {
        XCTAssertEqual(NotificationPosition.allCases.count, 6)
    }
}
