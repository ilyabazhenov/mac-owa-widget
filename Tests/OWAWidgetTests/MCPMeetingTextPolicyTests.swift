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

    /// Text hidden in characters that draw nothing: the panel would show only the visible part.
    func testInvisibleCarriersAreDetected() {
        func tags(_ ascii: String) -> String {
            String(String.UnicodeScalarView(ascii.unicodeScalars.map { Unicode.Scalar(0xE0000 + $0.value)! }))
        }
        // Unicode tags: ASCII smuggled one to one, with and without a flag in front.
        XCTAssertTrue(MCPMeetingTextPolicy.containsHiddenCharacters("Thanks!" + tags("secret")))
        XCTAssertTrue(MCPMeetingTextPolicy.containsHiddenCharacters("🏴" + tags("password is 123")))
        XCTAssertTrue(MCPMeetingTextPolicy.containsHiddenCharacters("🏴" + tags("gbsct")))
        XCTAssertTrue(MCPMeetingTextPolicy.containsHiddenCharacters("Hi\u{E0001}"))
        // Variation selectors: a byte per character, and Characters do not change.
        let selectors = "OK" + String(String.UnicodeScalarView([0xFE00, 0xE0100, 0xE01EF].map { Unicode.Scalar($0)! }))
        XCTAssertEqual(selectors.count, 2)
        XCTAssertTrue(MCPMeetingTextPolicy.containsHiddenCharacters(selectors))
        XCTAssertTrue(MCPMeetingTextPolicy.containsHiddenCharacters("a\u{FE0F}"), "emoji presentation only after an emoji")
        XCTAssertTrue(MCPMeetingTextPolicy.containsHiddenCharacters("❤\u{FE0F}\u{FE0F}"))
        // Joiners outside emoji and the scripts that need them: binary in plain text.
        XCTAssertTrue(MCPMeetingTextPolicy.containsHiddenCharacters("a\u{200C}b\u{200D}c"))
        XCTAssertTrue(MCPMeetingTextPolicy.containsHiddenCharacters("Да\u{200C}нет"))
        XCTAssertTrue(MCPMeetingTextPolicy.containsHiddenCharacters("👍\u{200D}\u{200D}👍"))
        // Hangul fillers, combining grapheme joiner, soft hyphen, C1 control.
        for hidden in ["\u{3164}", "\u{115F}", "\u{FFA0}", "\u{034F}", "\u{00AD}", "\u{0085}", "\u{0007}"] {
            XCTAssertTrue(MCPMeetingTextPolicy.containsHiddenCharacters("ok" + hidden + "ok"), hidden.unicodeScalars.map { String($0.value, radix: 16) }.joined())
        }
    }

    func testOrdinaryTextAndEmojiPass() {
        for text in [
            "❤️ Спасибо!", "Вариант 1️⃣", "🏳️‍🌈", "👍🏽", "👩🏽‍💻 и 👨‍👩‍👧‍👦", "🏴󠁧󠁢󠁥󠁮󠁧󠁿 и 🏴󠁧󠁢󠁷󠁬󠁳󠁿",
            "می\u{200C}خواهم", "क्\u{200D}ष", "Строка\tс табуляцией\nи переносом", "Ромашка — 1 000 ₽",
        ] {
            XCTAssertFalse(MCPMeetingTextPolicy.containsHiddenCharacters(text), text)
        }
    }

    func testSpacesThatLookPlainBecomePlainAndLineEndsAreTrimmed() {
        XCTAssertEqual(MCPMeetingTextPolicy.normalizedSpaces("1\u{00A0}000\u{2009}₽ \u{202F}x \t  \u{2003}"), "1 000 ₽  x")
        XCTAssertEqual(MCPMeetingTextPolicy.normalizedSpaces("  отступ"), "  отступ")
    }

    func testInvisibleOnlyLinesCountAsBlank() {
        let gap = "\n\u{2800}\n\u{3164}\n \u{200B}\n\n"
        XCTAssertEqual(MCPMeetingTextPolicy.normalizedAgenda("OK" + gap + "хвост  "), "OK\n\nхвост")
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
