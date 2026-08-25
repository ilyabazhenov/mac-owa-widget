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
        XCTAssertEqual(service.tr("notification.action.join"), "Подключиться")
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

    func testSyncStatusShowsJustNowWhenRecentInRussian() {
        let service = LocalizationService(
            selectedLanguage: .russian,
            preferredLanguages: ["en-US"]
        )
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let syncedAt = now.addingTimeInterval(-5)

        let text = service.syncStatusText(.lastSynced(syncedAt), relativeTo: now)

        XCTAssertEqual(text, "Синхронизировано только что")
    }

    func testSyncStatusShowsElapsedMinutesInRussian() {
        let service = LocalizationService(
            selectedLanguage: .russian,
            preferredLanguages: ["en-US"]
        )
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let syncedAt = now.addingTimeInterval(-5 * 60)

        let text = service.syncStatusText(.lastSynced(syncedAt), relativeTo: now)

        XCTAssertEqual(text, "Синхронизировано 5 мин назад")
    }

    func testSyncStatusShowsElapsedHoursInEnglish() {
        let service = LocalizationService(
            selectedLanguage: .english,
            preferredLanguages: ["en-US"]
        )
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let syncedAt = now.addingTimeInterval(-2 * 3600)

        let text = service.syncStatusText(.lastSynced(syncedAt), relativeTo: now)

        XCTAssertEqual(text, "Synced 2 h ago")
    }

    func testSyncStatusSecondsToMinutesBoundaryInEnglish() {
        let service = LocalizationService(
            selectedLanguage: .english,
            preferredLanguages: ["en-US"]
        )
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertEqual(
            service.syncStatusText(.lastSynced(now.addingTimeInterval(-59)), relativeTo: now),
            "Synced just now"
        )
        XCTAssertEqual(
            service.syncStatusText(.lastSynced(now.addingTimeInterval(-60)), relativeTo: now),
            "Synced 1 min ago"
        )
    }

    func testSyncStatusMinutesToHoursBoundaryInEnglish() {
        let service = LocalizationService(
            selectedLanguage: .english,
            preferredLanguages: ["en-US"]
        )
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertEqual(
            service.syncStatusText(.lastSynced(now.addingTimeInterval(-59 * 60)), relativeTo: now),
            "Synced 59 min ago"
        )
        XCTAssertEqual(
            service.syncStatusText(.lastSynced(now.addingTimeInterval(-60 * 60)), relativeTo: now),
            "Synced 1 h ago"
        )
    }

    func testSyncStatusClampsFutureSyncDateToJustNow() {
        let service = LocalizationService(
            selectedLanguage: .english,
            preferredLanguages: ["en-US"]
        )
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let syncedAt = now.addingTimeInterval(4)

        let text = service.syncStatusText(.lastSynced(syncedAt), relativeTo: now)

        XCTAssertEqual(text, "Synced just now")
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

    func testNotificationBodyWithJoinFormatInEnglish() {
        let service = LocalizationService(
            selectedLanguage: .english,
            preferredLanguages: ["en-US"]
        )
        let localization = service.notificationLocalization

        let text = String(
            format: localization.bodyWithJoinFormat,
            locale: Locale(identifier: localization.localeIdentifier),
            "5 minutes",
            "2:12 PM"
        )

        XCTAssertEqual(text, "Your meeting starts in 5 minutes at 2:12 PM. Tap Join.")
    }

    func testNotificationBodyWithJoinFormatInRussian() {
        let service = LocalizationService(
            selectedLanguage: .russian,
            preferredLanguages: ["en-US"]
        )
        let localization = service.notificationLocalization

        let text = String(
            format: localization.bodyWithJoinFormat,
            locale: Locale(identifier: localization.localeIdentifier),
            "5 минут",
            "14:12"
        )

        XCTAssertEqual(text, "Встреча начнётся через 5 минут, в 14:12. Нажмите «Подключиться».")
    }

    func testNotificationClusterTitleFormatInEnglish() {
        let service = LocalizationService(
            selectedLanguage: .english,
            preferredLanguages: ["en-US"]
        )
        let localization = service.notificationLocalization
        let text = String(
            format: localization.clusterTitleFormat,
            locale: Locale(identifier: localization.localeIdentifier),
            "2 meetings"
        )

        XCTAssertEqual(text, "Starting soon: 2 meetings")
    }

    func testNewMeetingMenuKeyInEnglish() {
        let service = LocalizationService(
            selectedLanguage: .english,
            preferredLanguages: ["ru-RU"]
        )

        XCTAssertEqual(service.tr("menu.new.meeting"), "New Meeting")
    }

    func testNewMeetingMenuKeyInRussian() {
        let service = LocalizationService(
            selectedLanguage: .russian,
            preferredLanguages: ["en-US"]
        )

        XCTAssertEqual(service.tr("menu.new.meeting"), "Новая встреча")
    }

    func testNotificationClusterTitleFormatInRussian() {
        let service = LocalizationService(
            selectedLanguage: .russian,
            preferredLanguages: ["en-US"]
        )
        let localization = service.notificationLocalization
        let text = String(
            format: localization.clusterTitleFormat,
            locale: Locale(identifier: localization.localeIdentifier),
            "2 встречи"
        )

        XCTAssertEqual(text, "Скоро начнутся: 2 встречи")
    }

    func testLocalizableStringsKeyParityBetweenEnglishAndRussian() throws {
        func loadKeys(_ language: String) throws -> Set<String> {
            let path = "\(FileManager.default.currentDirectoryPath)/OWAWidget/Resources/\(language).lproj/Localizable.strings"
            guard let dict = NSDictionary(contentsOfFile: path) as? [String: String] else {
                throw XCTSkip("Could not load \(language) Localizable.strings at \(path)")
            }
            return Set(dict.keys)
        }

        let en = try loadKeys("en")
        let ru = try loadKeys("ru")

        XCTAssertFalse(en.isEmpty)
        XCTAssertEqual(
            en.subtracting(ru).sorted(), [],
            "Keys present in en but missing in ru"
        )
        XCTAssertEqual(
            ru.subtracting(en).sorted(), [],
            "Keys present in ru but missing in en"
        )
    }

    func testCompactDurationSwitchesUnitsInRussian() {
        let service = LocalizationService(
            selectedLanguage: .russian,
            preferredLanguages: ["en-US"]
        )

        XCTAssertEqual(service.compactDuration(minutes: 45), "45 мин")
        XCTAssertEqual(service.compactDuration(minutes: 120), "2 ч")
        XCTAssertEqual(service.compactDuration(minutes: 200), "3 ч 20 мин")
        // Отпуск на неделю: раньше здесь печаталось «2 464 мин».
        XCTAssertEqual(service.compactDuration(minutes: 2_464), "1 д 17 ч")
        XCTAssertEqual(service.compactDuration(minutes: 2 * 24 * 60), "2 д")
    }

    func testCompactDurationSwitchesUnitsInEnglish() {
        let service = LocalizationService(
            selectedLanguage: .english,
            preferredLanguages: ["ru-RU"]
        )

        XCTAssertEqual(service.compactDuration(minutes: 45), "45 min")
        XCTAssertEqual(service.compactDuration(minutes: 200), "3 h 20 min")
        XCTAssertEqual(service.compactDuration(minutes: 2_464), "1 d 17 h")
    }
}
