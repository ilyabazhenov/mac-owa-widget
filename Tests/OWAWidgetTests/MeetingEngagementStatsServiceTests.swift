import XCTest
@testable import OWAWidget

@MainActor
final class MeetingEngagementStatsServiceTests: XCTestCase {
    func testTrackJoinDeduplicatesSameEventPerDay() {
        let defaults = UserDefaults(suiteName: "MeetingEngagementStatsServiceTests.dedup.\(UUID().uuidString)")!
        defaults.removePersistentDomain(forName: defaultsSuiteName(defaults))
        let service = MeetingEngagementStatsService(defaults: defaults)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let event = makeEvent(id: "e1", startDate: now.addingTimeInterval(3600), hasJoinURL: true)

        service.trackJoin(for: event, source: .meetingRow, at: now)
        service.trackJoin(for: event, source: .meetingRow, at: now.addingTimeInterval(30))

        let snapshot = service.snapshot(events: [event], period: .today, now: now)
        XCTAssertEqual(snapshot.joinedViaWidget, 1)
    }

    func testEligibleMeetingsUsesConfiguredScope() {
        let defaults = UserDefaults(suiteName: "MeetingEngagementStatsServiceTests.scope.\(UUID().uuidString)")!
        defaults.removePersistentDomain(forName: defaultsSuiteName(defaults))
        let service = MeetingEngagementStatsService(defaults: defaults)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let withLink = makeEvent(id: "with-link", startDate: now.addingTimeInterval(3600), hasJoinURL: true)
        let withoutLink = makeEvent(id: "without-link", startDate: now.addingTimeInterval(7200), hasJoinURL: false)

        service.setScope(.joinableOnly)
        XCTAssertEqual(service.snapshot(events: [withLink, withoutLink], period: .today, now: now).eligibleMeetings, 1)

        service.setScope(.allEvents)
        XCTAssertEqual(service.snapshot(events: [withLink, withoutLink], period: .today, now: now).eligibleMeetings, 2)
    }

    func testStreakAndMilestoneAreComputedFromHistory() {
        let defaults = UserDefaults(suiteName: "MeetingEngagementStatsServiceTests.streak.\(UUID().uuidString)")!
        defaults.removePersistentDomain(forName: defaultsSuiteName(defaults))
        let service = MeetingEngagementStatsService(defaults: defaults)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let calendar = AppTimeZone.calendar
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!

        let eventToday = makeEvent(id: "today", startDate: today.addingTimeInterval(3600), hasJoinURL: true)
        let eventYesterday = makeEvent(id: "yesterday", startDate: yesterday.addingTimeInterval(3600), hasJoinURL: true)

        service.trackJoin(for: eventYesterday, source: .meetingRow, at: yesterday.addingTimeInterval(600))
        service.trackJoin(for: eventToday, source: .nextBanner, at: today.addingTimeInterval(600))

        let snapshot = service.snapshot(events: [eventToday], period: .today, now: now)
        XCTAssertEqual(snapshot.streakDays, 2)
        XCTAssertEqual(snapshot.totalJoined, 2)
        XCTAssertEqual(snapshot.nextMilestone, 10)
    }

    private func makeEvent(id: String, startDate: Date, hasJoinURL: Bool) -> CalendarEvent {
        CalendarEvent(
            id: id,
            title: "Meeting \(id)",
            startDate: startDate,
            endDate: startDate.addingTimeInterval(1800),
            location: nil,
            bodyPreview: nil,
            joinURL: hasJoinURL ? URL(string: "https://example.com/\(id)") : nil,
            platform: .teams,
            isAllDay: false,
            organizer: nil,
            accountID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        )
    }

    private func defaultsSuiteName(_ defaults: UserDefaults) -> String {
        defaults.volatileDomainNames.first { $0.contains("MeetingEngagementStatsServiceTests") } ?? ""
    }
}
