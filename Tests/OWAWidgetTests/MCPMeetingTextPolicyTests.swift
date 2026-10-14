import XCTest
@testable import OWAWidget

/// The confirmation panel must show what `create_meeting` sends: text that displays differently
/// from its content is refused or flagged before the user is asked.
final class MCPMeetingTextPolicyTests: XCTestCase {
    func testBidiControlsAreDetected() {
        XCTAssertTrue(MCPMeetingTextPolicy.containsBidiControls("ivan@\u{202E}moc.live"))
        XCTAssertTrue(MCPMeetingTextPolicy.containsBidiControls("a\u{2066}b\u{2069}"))
        XCTAssertFalse(MCPMeetingTextPolicy.containsBidiControls("Планёрка — שלום"))
    }

    func testHiddenCharactersSpareEmojiJoiners() {
        XCTAssertTrue(MCPMeetingTextPolicy.containsHiddenCharacters("Пере\u{200B}нос"))
        XCTAssertTrue(MCPMeetingTextPolicy.containsHiddenCharacters("\u{FEFF}Повестка"))
        XCTAssertFalse(MCPMeetingTextPolicy.containsHiddenCharacters("Команда 👨‍👩‍👧"))
        XCTAssertFalse(MCPMeetingTextPolicy.containsHiddenCharacters("🏴󠁧󠁢󠁳󠁣󠁴󠁿 Scotland"))
        XCTAssertFalse(MCPMeetingTextPolicy.containsHiddenCharacters("Обычный текст"))
    }

    func testAddressesMustBePlainASCII() {
        XCTAssertTrue(MCPMeetingTextPolicy.isPlainASCIIAddress("ivan.ivanov@corp.ru"))
        // Cyrillic «а» in the domain looks identical to the Latin one.
        XCTAssertFalse(MCPMeetingTextPolicy.isPlainASCIIAddress("ivan@\u{0430}lfabank.ru"))
        XCTAssertFalse(MCPMeetingTextPolicy.isPlainASCIIAddress("ivan@corp.ru\u{200B}"))
    }

    func testAgendaBlankRunsCollapse() {
        let agenda = "1. Итоги\n\n\n   \n\n\n\n\n2. Планы\r\n\r\n\r\n3. Разное\n\n"
        XCTAssertEqual(MCPMeetingTextPolicy.normalizedAgenda(agenda), "1. Итоги\n\n2. Планы\n\n3. Разное")
    }

    func testOtherLineSeparatorsCollapseToo() {
        let gap = String(repeating: "\u{2028}", count: 200) + String(repeating: "\r", count: 50) + "\u{2029}\u{85}"
        XCTAssertEqual(MCPMeetingTextPolicy.normalizedAgenda("OK" + gap + "хвост"), "OK\n\nхвост")
    }
}
