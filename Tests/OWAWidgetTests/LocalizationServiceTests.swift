import XCTest
@testable import OWAWidget

@MainActor
final class LocalizationServiceTests: XCTestCase {
    func testForcedEnglishReturnsEnglishStrings() {
        let service = LocalizationService(
            selectedLanguage: .english,
            preferredLanguages: ["ru-RU"]
        )

        XCTAssertEqual(service.effectiveLanguageCode, "en")
        XCTAssertEqual(service.tr("settings.tab.preferences"), "Preferences")
        XCTAssertEqual(service.tr("notification.action.join"), "Join")
    }

    func testForcedRussianReturnsRussianStrings() {
        let service = LocalizationService(
            selectedLanguage: .russian,
            preferredLanguages: ["en-US"]
        )

        XCTAssertEqual(service.effectiveLanguageCode, "ru")
        XCTAssertEqual(service.tr("settings.tab.preferences"), "Настройки")
        XCTAssertEqual(service.tr("notification.action.join"), "Перейти")
    }

    func testSystemFallsBackToEnglishForUnsupportedLanguages() {
        let service = LocalizationService(
            selectedLanguage: .system,
            preferredLanguages: ["de-DE", "fr-FR"]
        )

        XCTAssertEqual(service.effectiveLanguageCode, "en")
        XCTAssertEqual(service.tr("language.option.system"), "System")
    }

    func testRussianPluralMinuteForms() {
        let service = LocalizationService(
            selectedLanguage: .russian,
            preferredLanguages: ["en-US"]
        )

        XCTAssertEqual(service.minutes(1), "1 минута")
        XCTAssertEqual(service.minutes(2), "2 минуты")
        XCTAssertEqual(service.minutes(5), "5 минут")
    }

    func testSyncStatusShowsElapsedSecondsInRussian() {
        let service = LocalizationService(
            selectedLanguage: .russian,
            preferredLanguages: ["en-US"]
        )
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let syncedAt = now.addingTimeInterval(-5)

        let text = service.syncStatusText(.lastSynced(syncedAt), relativeTo: now)

        XCTAssertEqual(text, "Синхронизировано 5 с назад")
    }

    func testSyncStatusClampsFutureSyncDateToZeroSeconds() {
        let service = LocalizationService(
            selectedLanguage: .english,
            preferredLanguages: ["en-US"]
        )
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let syncedAt = now.addingTimeInterval(4)

        let text = service.syncStatusText(.lastSynced(syncedAt), relativeTo: now)

        XCTAssertEqual(text, "Synced 0 s ago")
    }

    func testDaySectionLabelForTodayIncludesConcreteDateInRussian() {
        let service = LocalizationService(
            selectedLanguage: .russian,
            preferredLanguages: ["en-US"]
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(from: DateComponents(year: 2026, month: 5, day: 4, hour: 10))!

        let label = service.daySectionLabel(for: date, calendar: calendar, relativeTo: date)

        XCTAssertEqual(label, "Сегодня, 4 мая")
    }

    func testDaySectionLabelForTodayIncludesConcreteDateInEnglish() {
        let service = LocalizationService(
            selectedLanguage: .english,
            preferredLanguages: ["en-US"]
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(from: DateComponents(year: 2026, month: 5, day: 4, hour: 10))!

        let label = service.daySectionLabel(for: date, calendar: calendar, relativeTo: date)

        XCTAssertEqual(label, "Today, May 4")
    }
}
