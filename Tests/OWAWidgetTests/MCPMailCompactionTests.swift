import XCTest
@testable import OWAWidget

/// The pieces of `get_mail_thread`'s compact view: subjects, recipients, signatures.
final class MCPMailCompactionTests: XCTestCase {
    func testReplyAndForwardPrefixesDoNotMakeANewSubject() {
        let topic = "Импортозамещение телефонии: статус"
        for subject in [
            "RE: Импортозамещение телефонии: статус",
            "Re: RE: FW: Импортозамещение телефонии: статус",
            "Ответ: Импортозамещение  телефонии: статус",
            "Пересл.: Импортозамещение телефонии: статус",
            "RE[2]: импортозамещение телефонии: статус",
            "Fwd: AW: Импортозамещение телефонии: статус",
        ] {
            XCTAssertTrue(MCPMailCompaction.repeatsTopic(subject, topic: topic), subject)
        }
        XCTAssertFalse(MCPMailCompaction.repeatsTopic("RE: Импортозамещение телефонии: бюджет", topic: topic))
        XCTAssertFalse(MCPMailCompaction.repeatsTopic("Срочно: Импортозамещение телефонии: статус", topic: topic), "only reply and forward prefixes go")
        XCTAssertEqual(MCPMailCompaction.baseSubject("RE: Note: the plan"), "note: the plan", "a colon in the subject itself stays")
    }

    func testRecipientChangeIgnoresOrderCaseAndToCcMoves() {
        let ann = MailAddress(name: "Ann", email: "ann@example.com")
        let bob = MailAddress(name: "Bob", email: "Bob@Example.com")
        let cid = MailAddress(name: "Cid", email: "cid@example.com")
        let same = MCPMailCompaction.recipientChange(from: [bob, ann], to: [ann, MailAddress(name: "Bob B.", email: "bob@example.com")])
        XCTAssertTrue(same.isEmpty)
        let change = MCPMailCompaction.recipientChange(from: [ann, bob], to: [ann, cid])
        XCTAssertEqual(change.added, [cid])
        XCTAssertEqual(change.removed, [bob])
        let noAddress = MailAddress(name: "Team List", email: nil)
        XCTAssertTrue(MCPMailCompaction.recipientChange(from: [noAddress], to: [MailAddress(name: "team list", email: "")]).isEmpty)
    }

    func testSignatureAfterAClosingPhraseIsCut() {
        let text = """
        Коллеги, по телефонии: тестовый стенд готов, миграцию начинаем в понедельник.
        Просьба до пятницы подтвердить окна.

        С уважением,
        Иван Петров
        Руководитель направления
        Департамент ИТ-инфраструктуры
        Управление сетей и связи
        Отдел телефонии
        +7 (495) 000-00-00
        """
        XCTAssertEqual(
            MCPMailCompaction.strippingSignature(text),
            "Коллеги, по телефонии: тестовый стенд готов, миграцию начинаем в понедельник.\nПросьба до пятницы подтвердить окна."
        )
        XCTAssertEqual(MCPMailCompaction.strippingSignature("Done, see the PR.\n--\nAlex\nhttps://example.com"), "Done, see the PR.")
        XCTAssertEqual(MCPMailCompaction.strippingSignature("Thanks!\n\nBest regards, Alex"), "Thanks!")
    }

    func testUnsureSignaturesStay() {
        // Short lines without a closing phrase: a list, not a signature.
        XCTAssertNil(MCPMailCompaction.strippingSignature("Итоги:\nстенд готов\nокна согласованы\nИван Петров\n+7 (495) 000-00-00"))
        // A long line after the phrase is text.
        let long = "Ok.\nRegards\n" + String(repeating: "word ", count: 30)
        XCTAssertNil(MCPMailCompaction.strippingSignature(long))
        // Too many lines after it.
        XCTAssertNil(MCPMailCompaction.strippingSignature("Ok.\n--\n" + (1...13).map { "line \($0)" }.joined(separator: "\n")))
        // Nothing but the signature: keep it.
        XCTAssertNil(MCPMailCompaction.strippingSignature("С уважением,\nИван"))
        // "Regardless" is not "Regards".
        XCTAssertNil(MCPMailCompaction.strippingSignature("Ok.\nRegardless of the date\nwe go"))
    }
}
