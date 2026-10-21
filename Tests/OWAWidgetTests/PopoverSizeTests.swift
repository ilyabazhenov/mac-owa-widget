import AppKit
import XCTest
@testable import OWAWidget

final class PopoverSizeTests: XCTestCase {

    // MARK: - Presets

    func testCompactPresetMatchesHistoricalDefault() {
        XCTAssertEqual(PopoverSize.Preset.compact.size, .defaultValue)
    }

    func testPresetsOnlyGrowFromCompact() {
        let compact = PopoverSize.Preset.compact.size
        for preset in [PopoverSize.Preset.medium, .large] {
            XCTAssertGreaterThanOrEqual(preset.size.width, compact.width)
            XCTAssertGreaterThanOrEqual(preset.size.height, compact.height)
        }
        XCTAssertGreaterThan(PopoverSize.Preset.large.size.width, PopoverSize.Preset.medium.size.width)
        XCTAssertGreaterThan(PopoverSize.Preset.large.size.height, PopoverSize.Preset.medium.size.height)
    }

    func testEveryPresetStaysWithinSupportedBounds() {
        for preset in PopoverSize.Preset.allCases {
            let size = preset.size
            XCTAssertGreaterThanOrEqual(size.width, PopoverSize.minimum.width, "\(preset) width too small")
            XCTAssertLessThanOrEqual(size.width, PopoverSize.maximum.width, "\(preset) width too large")
            XCTAssertGreaterThanOrEqual(size.height, PopoverSize.minimum.height, "\(preset) height too small")
            XCTAssertLessThanOrEqual(size.height, PopoverSize.maximum.height, "\(preset) height too large")
        }
    }

    func testOldWidePresetBecomesCompactWithTheInboxPanel() {
        let defaults = UserDefaults(suiteName: "PopoverSizePresetTests.wide")!
        defaults.removePersistentDomain(forName: "PopoverSizePresetTests.wide")
        defaults.set("wide", forKey: "popoverSizePreset")

        XCTAssertEqual(PopoverSizePresetStore.load(from: defaults), .compact)
        XCTAssertTrue(PopoverInboxPanelStore.isShown(in: defaults), "the panel the user had stays on")
        XCTAssertEqual(defaults.string(forKey: "popoverSizePreset"), "compact")
    }

    func testInboxPanelIsOffByDefault() {
        let defaults = UserDefaults(suiteName: "PopoverSizePresetTests.panel")!
        defaults.removePersistentDomain(forName: "PopoverSizePresetTests.panel")
        XCTAssertFalse(PopoverInboxPanelStore.isShown(in: defaults))
    }

    func testInboxPanelGoesLeftThenRightThenNowhere() {
        let screen = NSRect(x: 0, y: 0, width: 1500, height: 900)
        let popover = NSRect(x: 1060, y: 300, width: 420, height: 560)
        let left = InboxPanelAttachmentView.panelFrame(beside: popover, width: 340, screen: screen)
        XCTAssertEqual(left, NSRect(x: 1060 - 8 - 340, y: 300, width: 340, height: 560))
        let nearLeftEdge = NSRect(x: 100, y: 300, width: 420, height: 560)
        XCTAssertEqual(InboxPanelAttachmentView.panelFrame(beside: nearLeftEdge, width: 340, screen: screen)?.minX, 100 + 420 + 8)
        let tiny = NSRect(x: 0, y: 0, width: 500, height: 900)
        XCTAssertNil(InboxPanelAttachmentView.panelFrame(beside: NSRect(x: 40, y: 0, width: 420, height: 560), width: 340, screen: tiny))
    }

    // MARK: - Preset store

    func testStoreLoadsCompactWhenNothingSaved() {
        let defaults = UserDefaults(suiteName: "PopoverSizePresetTests.empty")!
        defaults.removePersistentDomain(forName: "PopoverSizePresetTests.empty")

        XCTAssertEqual(PopoverSizePresetStore.load(from: defaults), .compact)
    }

    func testStoreRoundTripsEveryPreset() {
        let defaults = UserDefaults(suiteName: "PopoverSizePresetTests.roundtrip")!
        defaults.removePersistentDomain(forName: "PopoverSizePresetTests.roundtrip")

        for preset in PopoverSize.Preset.allCases {
            PopoverSizePresetStore.save(preset, to: defaults)
            XCTAssertEqual(PopoverSizePresetStore.load(from: defaults), preset)
        }
    }

    func testStoreFallsBackToCompactForUnknownRawValue() {
        let defaults = UserDefaults(suiteName: "PopoverSizePresetTests.unknown")!
        defaults.removePersistentDomain(forName: "PopoverSizePresetTests.unknown")
        defaults.set("gigantic", forKey: "popoverSizePreset")

        XCTAssertEqual(PopoverSizePresetStore.load(from: defaults), .compact)
    }
}
