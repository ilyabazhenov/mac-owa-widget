import XCTest
@testable import OWAWidget

final class OWAJoinURLResolutionTests: XCTestCase {

    func testBodyKTalkURLUsedWhenLocationIsEmpty() {
        let item = makeItem(
            location: "   ",
            textBody: "Agenda: подключение https://acme.ktalk.ru/room/123"
        )

        let (url, platform) = OWACalendarProvider.resolveJoinURL(from: item)

        XCTAssertEqual(url?.absoluteString, "https://acme.ktalk.ru/room/123")
        XCTAssertEqual(platform, .ktalk)
    }

    func testBodyFallbackSkippedWhenLocationIsPresent() {
        let item = makeItem(
            location: "Conference Room 101",
            textBody: "Agenda: подключение https://acme.ktalk.ru/room/123"
        )

        let (url, platform) = OWACalendarProvider.resolveJoinURL(from: item)

        XCTAssertNil(url)
        XCTAssertEqual(platform, .generic)
    }

    func testJoinOnlineMeetingURLHasHighestPriority() {
        let item = makeItem(
            joinOnlineMeetingURL: "https://teams.microsoft.com/l/meetup-join/abc",
            location: nil,
            textBody: "Agenda: https://acme.ktalk.ru/room/123"
        )

        let (url, platform) = OWACalendarProvider.resolveJoinURL(from: item)

        XCTAssertEqual(url?.absoluteString, "https://teams.microsoft.com/l/meetup-join/abc")
        XCTAssertEqual(platform, .teams)
    }

    func testBodyFallbackUsesUniqueBodyWhenTextBodyMissing() {
        let item = makeItem(
            location: nil,
            uniqueBody: "<p>Join: https://acme.ktalk.ru/room/789</p>"
        )

        let (url, platform) = OWACalendarProvider.resolveJoinURL(from: item)

        XCTAssertEqual(url?.absoluteString, "https://acme.ktalk.ru/room/789")
        XCTAssertEqual(platform, .ktalk)
    }

    private func makeItem(
        joinOnlineMeetingURL: String? = nil,
        location: String? = nil,
        textBody: String? = nil,
        uniqueBody: String? = nil
    ) -> OWACalendarItem {
        OWACalendarItem(
            ItemId: nil,
            Subject: "Meeting",
            Start: nil,
            End: nil,
            IsAllDayEvent: false,
            Location: location.map { OWALocation(DisplayName: $0) },
            Organizer: nil,
            TextBody: textBody.map { OWATextBody(Value: $0) },
            Body: nil,
            UniqueBody: uniqueBody.map { OWABodyContent(Value: $0, BodyType: "HTML") },
            NormalizedBody: nil,
            Preview: nil,
            JoinOnlineMeetingUrl: joinOnlineMeetingURL,
            RequiredAttendees: nil,
            OptionalAttendees: nil
        )
    }
}
