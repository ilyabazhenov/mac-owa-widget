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
