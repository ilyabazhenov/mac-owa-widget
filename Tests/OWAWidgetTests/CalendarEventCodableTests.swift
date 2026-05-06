import XCTest
@testable import OWAWidget

final class CalendarEventCodableTests: XCTestCase {

    func testDecodeLegacyPayloadWithoutMetadataFields() throws {
        let accountID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let json = """
        {"id":"legacy","title":"T","startDate":1700000000,"endDate":1700003600,"location":null,"bodyPreview":null,"joinURL":null,"platform":"teams","isAllDay":false,"organizer":null,"attendees":[],"accountID":"33333333-3333-3333-3333-333333333333"}
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let event = try decoder.decode(CalendarEvent.self, from: json)

        XCTAssertFalse(event.isCancelled)
        XCTAssertFalse(event.isOrganizer)
        XCTAssertEqual(event.categories, [])
        XCTAssertEqual(event.id, "legacy")
        XCTAssertEqual(event.accountID, accountID)
    }

    func testEffectiveCancellationUsesRussianCancelledPrefix() {
        let event = CalendarEvent(
            id: "prefixed",
            title: "Отменено: ИИ агент по верхнеуровневой оценке",
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_000_600),
            location: nil,
            bodyPreview: nil,
            joinURL: URL(string: "https://acme.ktalk.ru/room/1"),
            platform: .ktalk,
            isAllDay: false,
            organizer: nil,
            accountID: UUID(),
            isCancelled: false
        )

        XCTAssertTrue(event.isEffectivelyCancelled)
        XCTAssertNil(event.joinURLForActions)
    }

    func testEffectiveCancellationRespectsExplicitFlag() {
        let event = CalendarEvent(
            id: "flagged",
            title: "Обычная встреча",
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_000_600),
            location: nil,
            bodyPreview: nil,
            joinURL: URL(string: "https://acme.ktalk.ru/room/2"),
            platform: .ktalk,
            isAllDay: false,
            organizer: nil,
            accountID: UUID(),
            isCancelled: true
        )

        XCTAssertTrue(event.isEffectivelyCancelled)
        XCTAssertNil(event.joinURLForActions)
    }
}
