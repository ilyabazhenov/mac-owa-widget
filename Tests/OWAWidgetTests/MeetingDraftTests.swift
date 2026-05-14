import XCTest
@testable import OWAWidget

final class MeetingDraftTests: XCTestCase {

    func testSlotAutoRefreshKeyIgnoresTitleAndAgenda() {
        var a = MeetingDraft()
        a.title = "A"
        a.agenda = "X"
        a.attendees = [ResolvedAttendee(displayName: "U", email: "u@e.com", jobTitle: nil)]
        a.searchRange = .nextWeek
        a.durationMinutes = 45

        var b = MeetingDraft()
        b.title = "B"
        b.agenda = "Y"
        b.attendees = [ResolvedAttendee(displayName: "U", email: "u@e.com", jobTitle: nil)]
        b.searchRange = .nextWeek
        b.durationMinutes = 45

        XCTAssertEqual(a.slotAutoRefreshKey, b.slotAutoRefreshKey)
    }

    func testSlotAutoRefreshKeyStableUnderAttendeeReorder() {
        let u = ResolvedAttendee(displayName: "U", email: "u@e.com", jobTitle: nil)
        let v = ResolvedAttendee(displayName: "V", email: "v@e.com", jobTitle: nil)
        var a = MeetingDraft()
        a.attendees = [u, v]
        var b = MeetingDraft()
        b.attendees = [v, u]
        XCTAssertEqual(a.slotAutoRefreshKey, b.slotAutoRefreshKey)
    }

    func testSlotAutoRefreshKeyChangesWhenSearchRangeChanges() {
        var a = MeetingDraft()
        a.searchRange = .thisWeek
        var b = MeetingDraft()
        b.searchRange = .nextWeek
        XCTAssertNotEqual(a.slotAutoRefreshKey, b.slotAutoRefreshKey)
    }

    func testSlotAutoRefreshKeyChangesWhenDurationChanges() {
        var a = MeetingDraft()
        a.durationMinutes = 30
        var b = MeetingDraft()
        b.durationMinutes = 60
        XCTAssertNotEqual(a.slotAutoRefreshKey, b.slotAutoRefreshKey)
    }

    func testSlotAutoRefreshKeyChangesWhenAttendeeSetChanges() {
        var a = MeetingDraft()
        a.attendees = [ResolvedAttendee(displayName: "U", email: "u@e.com", jobTitle: nil)]
        var b = MeetingDraft()
        b.attendees = [
            ResolvedAttendee(displayName: "U", email: "u@e.com", jobTitle: nil),
            ResolvedAttendee(displayName: "V", email: "v@e.com", jobTitle: nil),
        ]
        XCTAssertNotEqual(a.slotAutoRefreshKey, b.slotAutoRefreshKey)
    }
}
