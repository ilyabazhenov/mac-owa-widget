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
        // Words only in an explanation behind "?" count too.
        XCTAssertTrue(panes("трекпад", .russian).contains(.mail))
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

    // MARK: - Every label of a section is searchable

    /// Strings that are values, states or per-item text rather than the name of a setting: a
    /// search for them would not mean "take me to that setting".
    private static func isValueText(_ key: String) -> Bool {
        let valueParts = [
            ".status.", ".before", ".group.top", ".group.bottom", ".preview", ".minutes",
            "mcp.clients.", "mcp.connect.", "mcp.approve.", "mcp.journal.", "about.version",
            "settings.accounts.empty", "settings.accounts.remove", "settings.account.",
        ]
        let kept = ["mcp.clients.section", "mcp.clients.ask", "mcp.connect.section", "mcp.journal.section"]
        return !kept.contains(key) && valueParts.contains { key.contains($0) }
    }

    /// The source of each section: the views it is built from, debug-only code left out.
    private static func sources() throws -> [SettingsPane: String] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func file(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        /// The text of `struct name` up to the next top-level declaration.
        func type(_ name: String, in text: String) -> String {
            guard let start = text.range(of: "struct \(name)") else { return "" }
            let rest = text[start.upperBound...]
            let end = rest.range(of: "\nstruct ")?.lowerBound ?? rest.range(of: "\n// MARK:")?.lowerBound ?? rest.endIndex
            return String(rest[..<end])
        }
        func withoutDebug(_ text: String) -> String {
            var out = text
            while let start = out.range(of: "#if DEBUG"), let end = out.range(of: "#endif", range: start.upperBound..<out.endIndex) {
                out.removeSubrange(start.lowerBound..<end.upperBound)
            }
            return out
        }
        let panes = try file("OWAWidget/Views/Settings/SettingsPanes.swift")
        let mail = try file("OWAWidget/Views/Mail/MailPopoverSectionView.swift")
        return [
            .general: withoutDebug(type("GeneralSettingsPane", in: panes)),
            .accounts: type("SyncSettingsSection", in: panes),
            .menuBar: type("MenuBarSettingsPane", in: panes),
            .reminders: type("RemindersSettingsPane", in: panes),
            .invitations: type("InvitationsSettingsPane", in: panes),
            .colleagues: type("ColleaguesSettingsPane", in: panes),
            .mail: type("MailSettingsSections", in: mail),
            .mcp: try file("OWAWidget/Views/MCPSettingsView.swift"),
            .about: try file("OWAWidget/Views/AboutView.swift"),
        ]
    }

    /// A setting added to a section is found by search only once its key is in `searchedKeys`;
    /// this keeps the list from falling behind the screens.
    func testEveryLabelOfASectionIsInItsSearchedKeys() throws {
        let pattern = try NSRegularExpression(pattern: #"tr\("([a-zA-Z0-9_.]+)""#)
        for (pane, source) in try Self.sources() {
            XCTAssertFalse(source.isEmpty, "no source found for \(pane.rawValue)")
            let range = NSRange(source.startIndex..., in: source)
            let keys = Set(pattern.matches(in: source, range: range).compactMap { match in
                Range(match.range(at: 1), in: source).map { String(source[$0]) }
            })
            let missing = keys.filter { !Self.isValueText($0) && !pane.searchedKeys.contains($0) && $0 != pane.titleKey }
            XCTAssertTrue(missing.isEmpty, "\(pane.rawValue) shows keys search does not know: \(missing.sorted())")
        }
    }
}
