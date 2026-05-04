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
}
