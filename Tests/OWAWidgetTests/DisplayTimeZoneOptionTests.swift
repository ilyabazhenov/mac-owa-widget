import Foundation
import XCTest
@testable import OWAWidget

final class DisplayTimeZoneOptionTests: XCTestCase {
    func testNilStorageFallsBackToMoscow() {
        let option = DisplayTimeZoneOption(storageValue: nil)
        XCTAssertEqual(option, .fixed("Europe/Moscow"))
        XCTAssertEqual(option.resolvedTimeZone.identifier, "Europe/Moscow")
    }

    func testEmptyStorageFallsBackToMoscow() {
        XCTAssertEqual(DisplayTimeZoneOption(storageValue: ""), .fixed("Europe/Moscow"))
    }

    func testUnknownIdentifierFallsBackToMoscow() {
        XCTAssertEqual(DisplayTimeZoneOption(storageValue: "Mars/Olympus"), .fixed("Europe/Moscow"))
    }

    func testSystemTokenRoundTrips() {
        let option = DisplayTimeZoneOption(storageValue: "system")
        XCTAssertEqual(option, .system)
        XCTAssertEqual(option.storageValue, "system")
        XCTAssertEqual(option.resolvedTimeZone.identifier, TimeZone.current.identifier)
    }

    func testFixedIdentifierRoundTrips() {
        let option = DisplayTimeZoneOption(storageValue: "Asia/Vladivostok")
        XCTAssertEqual(option, .fixed("Asia/Vladivostok"))
        XCTAssertEqual(option.storageValue, "Asia/Vladivostok")
        XCTAssertEqual(option.resolvedTimeZone.identifier, "Asia/Vladivostok")
    }

    func testSelectableStartsWithSystemThenCuratedList() {
        let selectable = DisplayTimeZoneOption.selectable
        XCTAssertEqual(selectable.first, .system)
        XCTAssertEqual(selectable.count, DisplayTimeZoneOption.curatedIdentifiers.count + 1)
        XCTAssertEqual(selectable.dropFirst().map(\.storageValue), DisplayTimeZoneOption.curatedIdentifiers)
    }

    func testUTCOffsetLabelForMoscowIsPlusThree() {
        // Moscow is UTC+3 year-round (no DST).
        XCTAssertEqual(DisplayTimeZoneOption.fixed("Europe/Moscow").utcOffsetLabel, "UTC+3")
    }

    func testLocalizationKeyDerivesCitySlug() {
        XCTAssertEqual(DisplayTimeZoneOption.system.localizationKey, "timezone.option.system")
        XCTAssertEqual(DisplayTimeZoneOption.fixed("Asia/Yekaterinburg").localizationKey, "timezone.city.yekaterinburg")
    }

    /// End-to-end: a stored selection drives the zone `AppTimeZone` resolves for the UI.
    /// This is the wiring the calendar rendering depends on.
    func testAppTimeZoneReflectsStoredSelection() {
        let key = AppTimeZone.storageKey
        let original = UserDefaults.standard.string(forKey: key)
        defer { UserDefaults.standard.set(original, forKey: key) }

        // Default (nothing stored) → Moscow / UTC+3.
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(AppTimeZone.zone.identifier, "Europe/Moscow")
        XCTAssertEqual(AppTimeZone.zone.secondsFromGMT(), 3 * 3600)

        // Select Samara (UTC+4) → calendar should resolve to +4, not stay on Moscow.
        UserDefaults.standard.set("Europe/Samara", forKey: key)
        XCTAssertEqual(AppTimeZone.zone.identifier, "Europe/Samara")
        XCTAssertEqual(AppTimeZone.zone.secondsFromGMT(), 4 * 3600)
        XCTAssertEqual(AppTimeZone.calendar.timeZone.identifier, "Europe/Samara")
    }
}
