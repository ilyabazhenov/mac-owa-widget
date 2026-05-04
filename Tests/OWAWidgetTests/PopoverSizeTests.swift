import XCTest
@testable import OWAWidget

final class PopoverSizeTests: XCTestCase {
    func testClampsSizeToSupportedBounds() {
        let tooSmall = PopoverSize(width: 200, height: 200).clamped()
        let tooLarge = PopoverSize(width: 900, height: 900).clamped()

        XCTAssertEqual(tooSmall, PopoverSize.minimum)
        XCTAssertEqual(tooLarge, PopoverSize.maximum)
    }

    func testResizesByDragDeltaWithinBounds() {
        let resized = PopoverSize.defaultValue.resizedBy(widthDelta: 120, heightDelta: -80)

        XCTAssertEqual(resized.width, PopoverSize.defaultValue.width + 120, accuracy: 0.001)
        XCTAssertEqual(resized.height, PopoverSize.defaultValue.height - 80, accuracy: 0.001)
    }

    func testStoreLoadsDefaultWhenNoSavedSizeExists() {
        let defaults = UserDefaults(suiteName: "PopoverSizeTests.empty")!
        defaults.removePersistentDomain(forName: "PopoverSizeTests.empty")

        XCTAssertEqual(PopoverSizeStore.load(from: defaults), .defaultValue)
    }

    func testStorePersistsClampedSize() {
        let defaults = UserDefaults(suiteName: "PopoverSizeTests.persisted")!
        defaults.removePersistentDomain(forName: "PopoverSizeTests.persisted")

        PopoverSizeStore.save(PopoverSize(width: 900, height: 200), to: defaults)

        XCTAssertEqual(PopoverSizeStore.load(from: defaults), PopoverSize(width: 760, height: 320))
    }
}
