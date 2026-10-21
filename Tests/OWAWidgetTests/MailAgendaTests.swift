import XCTest
@testable import OWAWidget

final class MailAgendaTests: XCTestCase {
    private let accountID = UUID()

    private func event(_ id: String, start: Date, minutes: Int = 30, allDay: Bool = false) -> CalendarEvent {
        CalendarEvent(
            id: id,
            title: id,
            startDate: start,
            endDate: start.addingTimeInterval(TimeInterval(minutes * 60)),
            location: nil,
            bodyPreview: nil,
            joinURL: nil,
            platform: .generic,
            isAllDay: allDay,
            organizer: nil,
            accountID: accountID
        )
    }

    func testEventsOfDayAllDayFirstThenByStart() {
        let calendar = AppTimeZone.calendar
        let day = calendar.startOfDay(for: Date())
        let late = event("late", start: day.addingTimeInterval(15 * 3600))
        let early = event("early", start: day.addingTimeInterval(9 * 3600))
        let allDay = event("allday", start: day, minutes: 24 * 60, allDay: true)
        let tomorrow = event("tomorrow", start: day.addingTimeInterval(30 * 3600))
        let ids = MailAgendaPolicy.events(on: day, in: [late, tomorrow, early, allDay]).map(\.id)
        XCTAssertEqual(ids, ["allday", "early", "late"])
    }

    func testNowLineSitsBeforeNextMeetingOnly() {
        let now = Date()
        let events = [
            event("past", start: now.addingTimeInterval(-7200)),
            event("next", start: now.addingTimeInterval(1800)),
            event("later", start: now.addingTimeInterval(7200)),
        ]
        XCTAssertFalse(MailAgendaPolicy.nowLineGoesBefore(index: 0, events: events, now: now))
        XCTAssertTrue(MailAgendaPolicy.nowLineGoesBefore(index: 1, events: events, now: now))
        XCTAssertFalse(MailAgendaPolicy.nowLineGoesBefore(index: 2, events: events, now: now))
        // During a meeting there is no line: the meeting itself is "now".
        let running = [event("running", start: now.addingTimeInterval(-600))]
        XCTAssertFalse(MailAgendaPolicy.nowLineGoesBefore(index: 0, events: running, now: now))
    }

    func testDetailLineHidesLinkLocationWhileFolded() {
        func make(location: String?, organizer: String?, isOrganizer: Bool = false) -> CalendarEvent {
            CalendarEvent(
                id: "e", title: "e", startDate: Date(), endDate: Date().addingTimeInterval(1800),
                location: location, bodyPreview: nil, joinURL: nil, platform: .generic,
                isAllDay: false, organizer: organizer, accountID: accountID, isOrganizer: isOrganizer
            )
        }
        let link = make(location: "https://example.ktalk.ru/room", organizer: "Иванов")
        XCTAssertEqual(MailAgendaPolicy.detailLine(link, expanded: false), "Иванов")
        XCTAssertEqual(MailAgendaPolicy.detailLine(link, expanded: true), "https://example.ktalk.ru/room")
        XCTAssertEqual(MailAgendaPolicy.detailLine(make(location: "Переговорная 5", organizer: "Иванов"), expanded: false), "Переговорная 5")
        XCTAssertNil(MailAgendaPolicy.detailLine(make(location: "https://x.ru", organizer: "Я", isOrganizer: true), expanded: false))
    }

    @MainActor
    func testFreeStatus() {
        let localization = LocalizationService(selectedLanguage: .russian)
        let now = Date()
        let running = event("running", start: now.addingTimeInterval(-600))
        let next = event("next", start: now.addingTimeInterval(3600))
        XCTAssertTrue(MailAgendaPolicy.freeStatus([running, next], now: now, localization: localization)?.hasPrefix("Занят до") == true)
        XCTAssertTrue(MailAgendaPolicy.freeStatus([next], now: now, localization: localization)?.hasPrefix("Свободен до") == true)
        XCTAssertEqual(MailAgendaPolicy.freeStatus([], now: now, localization: localization), "Больше встреч сегодня нет")
    }

    func testSenderBundlesOffByDefault() {
        XCTAssertFalse(MailSettings().bundleAutomated)
    }

    func testColumnWidthsClamp() {
        XCTAssertEqual(MailColumnWidths.clamp(0, MailColumnWidths.list), CGFloat(MailColumnWidths.list.ideal))
        XCTAssertEqual(MailColumnWidths.clamp(10, MailColumnWidths.list), CGFloat(MailColumnWidths.list.min))
        XCTAssertEqual(MailColumnWidths.clamp(10_000, MailColumnWidths.list), CGFloat(MailColumnWidths.list.max))
    }
}

final class MailColumnFitTests: XCTestCase {
    func testWideWindowKeepsPreferredWidths() {
        let fit = MailColumnWidths.fit(total: 1600, sidebar: 220, list: 360, agenda: 280)
        XCTAssertEqual(fit, .init(sidebar: 220, list: 360, agenda: 280))
    }

    func testListShrinksBeforeAgendaHides() {
        // 220 + 1 + 360 + 1 + 380 + 1 + 280 = 1243; 1200 is 43 short, the list gives it up.
        let fit = MailColumnWidths.fit(total: 1200, sidebar: 220, list: 360, agenda: 280)
        XCTAssertEqual(fit, .init(sidebar: 220, list: 317, agenda: 280))
    }

    func testAgendaHidesWhenColumnsCannotShrinkEnough() {
        let fit = MailColumnWidths.fit(total: 1000, sidebar: 220, list: 360, agenda: 280)
        XCTAssertNil(fit.agenda)
        XCTAssertEqual(fit, .init(sidebar: 220, list: 360, agenda: nil), "without the agenda the preferred widths fit again")
    }

    func testTooNarrowFallsBackToMinimums() {
        let fit = MailColumnWidths.fit(total: 500, sidebar: 220, list: 360, agenda: nil)
        XCTAssertEqual(fit, .init(sidebar: CGFloat(MailColumnWidths.sidebar.min), list: CGFloat(MailColumnWidths.list.min), agenda: nil))
    }
}

@MainActor
final class MailWindowSubtitleTests: XCTestCase {
    func testSubtitle() {
        let localization = LocalizationService(selectedLanguage: .russian)
        let checked = AppTimeZone.calendar.date(bySettingHour: 16, minute: 44, second: 0, of: Date())!
        XCTAssertEqual(MailPresentation.windowSubtitle(unread: 12, lastChecked: checked, localization: localization), "Непрочитанных: 12 · обновлено в 16:44")
        XCTAssertEqual(MailPresentation.windowSubtitle(unread: 0, lastChecked: checked, localization: localization), "Обновлено в 16:44")
        XCTAssertEqual(MailPresentation.windowSubtitle(unread: nil, lastChecked: nil, localization: localization), "Ещё не обновлялось")
    }
}
