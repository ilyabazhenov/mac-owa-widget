import XCTest
@testable import OWAWidget

/// The invitation message.
///
/// Everything asserted here is something Exchange accepts without complaint when it is wrong:
/// a missing `METHOD:REQUEST` arrives as an ordinary mail with an attachment, an unescaped
/// semicolon truncates a property, an unfolded long line corrupts the one it runs into, and a
/// raw Cyrillic header is dropped by whichever hop is strictest. None of it fails visibly at
/// the protocol level — it fails on the attendee's screen.
final class EASMeetingRequestMIMETests: XCTestCase {

    private let start = EASDate.parse("20260915T070000Z")!
    private let end = EASDate.parse("20260915T080000Z")!
    private let stamp = EASDate.parse("20260914T120000Z")!
    private let moscow = TimeZone(secondsFromGMT: 3 * 3600)!
    private let organizer = EASMeetingRequestMIME.Organizer(
        name: "Алексей Аниканов",
        email: "alexey@example.com"
    )

    private func person(_ name: String, _ email: String) -> ResolvedAttendee {
        ResolvedAttendee(displayName: name, email: email, jobTitle: nil)
    }

    private func calendar(
        subject: String = "Планёрка",
        agenda: String = "",
        location: String = "",
        required: [ResolvedAttendee] = [],
        optional: [ResolvedAttendee] = []
    ) -> String {
        EASMeetingRequestMIME.iCalendar(
            organizer: organizer,
            subject: subject,
            agenda: agenda,
            location: location,
            start: start,
            end: end,
            requiredAttendees: required,
            optionalAttendees: optional,
            uid: "UID1",
            stamp: stamp
        )
    }

    /// Undoes the 75-octet folding, so a test can assert on a property as one string. Folding
    /// itself is asserted separately, below.
    private func unfold(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n ", with: "")
    }

    private func message(
        subject: String = "Планёрка",
        required: [ResolvedAttendee] = [],
        optional: [ResolvedAttendee] = []
    ) -> String {
        EASMeetingRequestMIME.message(
            organizer: organizer,
            subject: subject,
            agenda: "Повестка",
            location: "Переговорная 3",
            start: start,
            end: end,
            requiredAttendees: required,
            optionalAttendees: optional,
            uid: "UID1",
            timeZone: moscow,
            stamp: stamp,
            boundary: "BOUNDARY"
        )
    }

    // MARK: The iCalendar body

    func testCarriesTheRequestMethodAndTheCoreFields() {
        let ics = unfold(calendar(agenda: "Повестка", location: "Переговорная 3"))

        XCTAssertTrue(ics.contains("METHOD:REQUEST"))
        XCTAssertTrue(ics.contains("UID:UID1"))
        XCTAssertTrue(ics.contains("DTSTART:20260915T070000Z"))
        XCTAssertTrue(ics.contains("DTEND:20260915T080000Z"))
        XCTAssertTrue(ics.contains("DTSTAMP:20260914T120000Z"))
        XCTAssertTrue(ics.contains("SUMMARY:Планёрка"))
        XCTAssertTrue(ics.contains("DESCRIPTION:Повестка"))
        XCTAssertTrue(ics.contains("LOCATION:Переговорная 3"))
        XCTAssertTrue(ics.hasSuffix("END:VCALENDAR\r\n"))
    }

    /// Lines are separated by CRLF, not LF. A body with bare newlines is a different document
    /// to a strict parser, and Exchange is one.
    func testLinesEndWithCRLF() {
        let ics = calendar()
        XCTAssertFalse(ics.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
    }

    /// The difference between an invitation and a notice: without `RSVP`/`PARTSTAT` the invitee
    /// sees an appointment with no way to answer it.
    func testAttendeesCarryRoleAndResponseRequest() {
        let ics = unfold(calendar(
            required: [person("Анна", "anna@example.com")],
            optional: [person("Борис", "boris@example.com")]
        ))

        XCTAssertTrue(
            ics.contains(
                "ATTENDEE;CN=\"Анна\";ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:MAILTO:anna@example.com"
            )
        )
        XCTAssertTrue(ics.contains("ROLE=OPT-PARTICIPANT"))
        XCTAssertTrue(ics.contains("ORGANIZER;CN=\"Алексей Аниканов\":MAILTO:alexey@example.com"))
    }

    /// RFC 5545 gives comma and semicolon a meaning inside a value. Unescaped, "Отчёт: план,
    /// факт" ends the property early and the rest of the line is read as another one.
    func testTextValuesAreEscaped() {
        let ics = unfold(calendar(subject: "План, факт; и \\ прочее", agenda: "Строка\nВторая"))

        XCTAssertTrue(ics.contains("SUMMARY:План\\, факт\\; и \\\\ прочее"))
        XCTAssertTrue(ics.contains("DESCRIPTION:Строка\\nВторая"))
    }

    /// A name with a comma is the normal shape of a directory entry, and unquoted it would end
    /// the parameter.
    func testCommonNameIsQuoted() {
        let ics = unfold(calendar(required: [person("Аниканов, Алексей", "a@example.com")]))
        XCTAssertTrue(ics.contains("CN=\"Аниканов, Алексей\""))
    }

    // MARK: Folding

    func testLongLinesAreFoldedWithinTheOctetLimit() {
        let ics = calendar(subject: String(repeating: "Совещание ", count: 20))

        for line in ics.components(separatedBy: "\r\n") {
            XCTAssertLessThanOrEqual(line.utf8.count, 75, "line over the limit: \(line)")
        }
        XCTAssertTrue(ics.contains("\r\n "), "continuation lines start with a space")
    }

    /// Folding counts octets but must cut between characters: a fold through the middle of a
    /// two-byte character produces two invalid sequences and unreadable text on the far side.
    func testFoldingDoesNotSplitMultiByteCharacters() {
        let folded = EASMeetingRequestMIME.fold("SUMMARY:" + String(repeating: "я", count: 80))

        for segment in folded.components(separatedBy: "\r\n ") {
            XCTAssertTrue(segment.unicodeScalars.allSatisfy { $0.value != 0xFFFD })
        }
        let rejoined = folded.replacingOccurrences(of: "\r\n ", with: "")
        XCTAssertEqual(rejoined, "SUMMARY:" + String(repeating: "я", count: 80))
    }

    // MARK: The message around it

    func testMessageWrapsTextAndCalendarAlternatives() {
        let mail = message(required: [person("Анна", "anna@example.com")])

        XCTAssertTrue(mail.contains("Content-Type: multipart/alternative; boundary=\"BOUNDARY\""))
        XCTAssertTrue(mail.contains("Content-Type: text/plain; charset=\"utf-8\""))
        XCTAssertTrue(mail.contains("Content-Type: text/calendar; charset=\"utf-8\"; method=REQUEST"))
        XCTAssertTrue(mail.contains("--BOUNDARY--"), "the multipart is closed")
    }

    func testRecipientsAreSplitBetweenToAndCc() {
        let mail = message(
            required: [person("Анна", "anna@example.com")],
            optional: [person("Борис", "boris@example.com")]
        )

        let headers = mail.components(separatedBy: "\r\n\r\n")[0]
        XCTAssertTrue(headers.contains("To: =?utf-8?B?0JDQvdC90LA=?= <anna@example.com>"))
        XCTAssertTrue(headers.contains("Cc: "))
        XCTAssertTrue(headers.contains("<boris@example.com>"))
    }

    /// Headers are ASCII. A raw Cyrillic subject is not invalid everywhere, but it is mangled
    /// often enough that RFC 2047 is the only safe way to send one.
    func testNonASCIIHeadersAreEncoded() {
        let mail = message(subject: "Планёрка")

        XCTAssertTrue(mail.contains("Subject: =?utf-8?B?"))
        XCTAssertFalse(mail.components(separatedBy: "\r\n\r\n")[0].contains("Планёрка"))
    }

    /// Encoded words are capped at 75 characters each, so a long subject becomes several.
    func testLongNonASCIIHeaderBecomesSeveralEncodedWords() {
        let encoded = EASMeetingRequestMIME.encodedHeaderText(String(repeating: "совещание ", count: 12))

        let words = encoded.components(separatedBy: "\r\n ")
        XCTAssertGreaterThan(words.count, 1)
        for word in words {
            XCTAssertLessThanOrEqual(word.count, 75)
            XCTAssertTrue(word.hasPrefix("=?utf-8?B?") && word.hasSuffix("?="))
        }

        let decoded = words
            .map { $0.dropFirst("=?utf-8?B?".count).dropLast("?=".count) }
            .compactMap { Data(base64Encoded: String($0)) }
            .reduce(Data(), +)
        XCTAssertEqual(String(decoding: decoded, as: UTF8.self), String(repeating: "совещание ", count: 12))
    }

    /// ASCII needs no encoding, but a comma in a display name would split one recipient into
    /// two addresses.
    func testASCIINameWithAddressSyntaxIsQuoted() {
        XCTAssertEqual(EASMeetingRequestMIME.encodedHeaderText("Smith, John"), "\"Smith, John\"")
        XCTAssertEqual(EASMeetingRequestMIME.encodedHeaderText("Standup"), "Standup")
    }

    /// The whole message has to survive a 7-bit transport: both bodies are base64 and every
    /// header is either ASCII or an encoded word.
    func testMessageIsSevenBitClean() {
        let mail = message(
            subject: "Планёрка",
            required: [person("Анна", "anna@example.com")]
        )
        XCTAssertTrue(mail.allSatisfy { $0.isASCII })
    }

    // MARK: The SendMail request

    /// The request the message travels in. A token this client gets wrong is not rejected —
    /// the server answers with the same empty body it returns on success, and nothing is sent.
    func testSendMailRequestCarriesTheMessageAndSavesACopy() throws {
        let data = EASClient.sendMailBody(mime: "MIME-Version: 1.0\r\n", saveInSentItems: true, clientId: "CID")
        let tree = try WBXMLReader.parse(data)

        let sendMail = try XCTUnwrap(tree.first(CM.sendMail))
        XCTAssertEqual(sendMail.value(CM.clientId), "CID")
        XCTAssertNotNil(sendMail.child(CM.saveInSentItems), "a meeting request belongs in Sent Items")
        XCTAssertEqual(sendMail.value(CM.mime), "MIME-Version: 1.0\r\n")
    }

    /// The MIME goes out as a length-prefixed blob, not an inline string: it is large, and an
    /// inline string is terminated by a NUL byte it has no way to escape.
    func testMimeTravelsAsOpaqueData() throws {
        let data = EASClient.sendMailBody(mime: "BODY", saveInSentItems: false, clientId: "CID")
        let tree = try WBXMLReader.parse(data)

        let mime = try XCTUnwrap(tree.first(CM.mime))
        guard case .element(_, let children) = mime, case .opaque(let blob) = children.first else {
            return XCTFail("expected an opaque payload, got \(mime)")
        }
        XCTAssertEqual(String(decoding: blob, as: UTF8.self), "BODY")
        XCTAssertNil(tree.first(CM.saveInSentItems), "omitted when a copy is not wanted")
    }
}
