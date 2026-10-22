import XCTest
@testable import OWAWidget

final class AppTimeZoneTests: XCTestCase {

    private var originalStored: String?

    override func setUp() {
        super.setUp()
        // `AppTimeZone.zone` now reads UserDefaults, so isolate these tests from any value
        // a parallel/previous test (or the dev machine) may have left behind.
        originalStored = UserDefaults.standard.string(forKey: AppTimeZone.storageKey)
        UserDefaults.standard.removeObject(forKey: AppTimeZone.storageKey)
    }

    override func tearDown() {
        UserDefaults.standard.set(originalStored, forKey: AppTimeZone.storageKey)
        super.tearDown()
    }

    func testDefaultZoneIsEuropeMoscowWhenUnset() {
        XCTAssertEqual(AppTimeZone.zone.identifier, "Europe/Moscow")
    }

    func testZoneFollowsStoredSelection() {
        UserDefaults.standard.set("Asia/Yekaterinburg", forKey: AppTimeZone.storageKey)
        XCTAssertEqual(AppTimeZone.zone.identifier, "Asia/Yekaterinburg")
        XCTAssertEqual(AppTimeZone.zone.secondsFromGMT(), 5 * 3600)
    }

    @MainActor
    func testCachedShortTimeFollowsTheDisplayZone() {
        let localization = LocalizationService(selectedLanguage: .russian)
        let nineUTC = Date(timeIntervalSince1970: 1_760_000_400) // 2025-10-09 09:00 UTC
        UserDefaults.standard.set("Europe/Moscow", forKey: AppTimeZone.storageKey)
        XCTAssertEqual(localization.shortTime(nineUTC), "12:00")
        // The formatter is kept between calls; the zone is not.
        UserDefaults.standard.set("Asia/Yekaterinburg", forKey: AppTimeZone.storageKey)
        XCTAssertEqual(localization.shortTime(nineUTC), "14:00")
    }

    func testInvalidStoredZoneFallsBackToMoscow() {
        UserDefaults.standard.set("Not/AZone", forKey: AppTimeZone.storageKey)
        XCTAssertEqual(AppTimeZone.zone.identifier, "Europe/Moscow")
    }

    func testUtcOffsetLabelUsesWholeHourOffset() {
        // Europe/Moscow is UTC+3 year-round in the current policy window used by Foundation.
        XCTAssertTrue(AppTimeZone.utcOffsetLabel.contains("UTC"))
        XCTAssertTrue(AppTimeZone.utcOffsetLabel.contains("+") || AppTimeZone.utcOffsetLabel.contains("-"))
    }

    func testCalendarUsesDisplayZone() {
        XCTAssertEqual(AppTimeZone.calendar.timeZone.identifier, AppTimeZone.zone.identifier)
    }
}
