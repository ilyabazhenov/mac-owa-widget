import AppKit
import XCTest
@testable import OWAWidget

@MainActor
final class MenuBarContextMenuTests: XCTestCase {
    func testClosureMenuItemConfiguresActionAndTarget() {
        let item = ClosureMenuItem(title: "Sync") {}

        XCTAssertEqual(item.title, "Sync")
        XCTAssertNotNil(item.action)
        XCTAssertTrue(item.target === item)
    }

    func testClosureMenuItemExecutesClosureViaMenuAction() {
        var didRun = false
        let item = ClosureMenuItem(title: "Run") {
            didRun = true
        }
        guard let action = item.action, let target = item.target as AnyObject? else {
            XCTFail("Menu item should have target/action configured")
            return
        }
        _ = target.perform(action, with: item)

        XCTAssertTrue(didRun)
    }
}
