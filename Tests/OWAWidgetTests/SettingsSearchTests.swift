import XCTest
@testable import OWAWidget

@MainActor
final class SettingsSearchTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "OWAWidgetTests.SettingsSearch.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func panes(_ query: String, _ language: AppLanguage) -> [SettingsPane] {
        let localization = LocalizationService(userDefaults: defaults, selectedLanguage: language)
        return SettingsSearch.panes(matching: query, translate: { localization.tr($0) })
    }

    func testEmptyQueryShowsEverySection() {
        XCTAssertEqual(panes("", .russian), SettingsPane.allCases)
        XCTAssertEqual(panes("   ", .english), SettingsPane.allCases)
    }

    /// "Notifications" is a word users type but no section is called that any more.
    func testNotificationsFindsEverySectionThatNotifies() {
        let found = Set(panes("уведомления", .russian))
        XCTAssertTrue(found.isSuperset(of: [.reminders, .invitations, .mail]), "\(found)")
        let foundEnglish = Set(panes("notifications", .english))
        XCTAssertTrue(foundEnglish.isSuperset(of: [.reminders, .invitations, .mail]), "\(foundEnglish)")
    }

    func testOnPageWordsAndSynonymsLeadToTheirSection() {
        XCTAssertEqual(panes("звук", .russian), [.reminders])
        XCTAssertEqual(panes("sound", .english), [.reminders])
        XCTAssertTrue(panes("хоткей", .russian).contains(.general))
        XCTAssertTrue(panes("пароль", .russian).contains(.accounts))
        XCTAssertTrue(panes("Claude", .russian).contains(.mcp))
        XCTAssertTrue(panes("диагностика", .russian).contains(.about))
    }

    func testCounterSearchFindsBothCountersAndThePointerToThem() {
        let found = Set(panes("счётчик", .russian))
        XCTAssertTrue(found.isSuperset(of: [.invitations, .mail, .menuBar]), "\(found)")
    }

    func testYoAndCaseDoNotMatter() {
        XCTAssertEqual(Set(panes("СЧЕТЧИК", .russian)), Set(panes("счётчик", .russian)))
    }

    func testUnknownWordFindsNothing() {
        XCTAssertTrue(panes("zzzq", .english).isEmpty)
    }

    /// Every string a section is searched by — its title, keywords and on-page labels — exists in
    /// both languages; a missing key would come back as the key itself and match nothing useful.
    func testEverySearchedStringIsTranslated() {
        for language in [AppLanguage.russian, .english] {
            let localization = LocalizationService(userDefaults: defaults, selectedLanguage: language)
            for pane in SettingsPane.allCases {
                for key in [pane.titleKey, pane.keywordsKey] + pane.searchedKeys {
                    XCTAssertNotEqual(localization.tr(key), key, "\(language.rawValue): \(key) (\(pane.rawValue))")
                }
            }
        }
    }
}
