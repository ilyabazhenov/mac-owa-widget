import XCTest
@testable import OWAWidget

final class MeetingDraftTests: XCTestCase {

    func testSlotAutoRefreshKeyIgnoresTitleAndAgenda() {
        var a = MeetingDraft()
        a.title = "A"
        a.agenda = "X"
        a.requiredAttendees = [ResolvedAttendee(displayName: "U", email: "u@e.com", jobTitle: nil)]
        a.searchRange = .nextWeek
        a.durationMinutes = 45

        var b = MeetingDraft()
        b.title = "B"
        b.agenda = "Y"
        b.requiredAttendees = [ResolvedAttendee(displayName: "U", email: "u@e.com", jobTitle: nil)]
        b.searchRange = .nextWeek
        b.durationMinutes = 45

        XCTAssertEqual(a.slotAutoRefreshKey, b.slotAutoRefreshKey)
    }

    func testSlotAutoRefreshKeyStableUnderAttendeeReorder() {
        let u = ResolvedAttendee(displayName: "U", email: "u@e.com", jobTitle: nil)
        let v = ResolvedAttendee(displayName: "V", email: "v@e.com", jobTitle: nil)
        var a = MeetingDraft()
        a.requiredAttendees = [u, v]
        var b = MeetingDraft()
        b.requiredAttendees = [v, u]
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
        a.requiredAttendees = [ResolvedAttendee(displayName: "U", email: "u@e.com", jobTitle: nil)]
        var b = MeetingDraft()
        b.requiredAttendees = [
            ResolvedAttendee(displayName: "U", email: "u@e.com", jobTitle: nil),
            ResolvedAttendee(displayName: "V", email: "v@e.com", jobTitle: nil),
        ]
        XCTAssertNotEqual(a.slotAutoRefreshKey, b.slotAutoRefreshKey)
    }

    func testSlotAutoRefreshKeyIgnoresOptionalAttendeeChanges() {
        let u = ResolvedAttendee(displayName: "U", email: "u@e.com", jobTitle: nil)
        let v = ResolvedAttendee(displayName: "V", email: "v@e.com", jobTitle: nil)
        var a = MeetingDraft()
        a.requiredAttendees = [u]
        var b = MeetingDraft()
        b.requiredAttendees = [u]
        b.optionalAttendees = [v]
        // v1: optional attendees do not affect slot search, so the refresh key must not change.
        XCTAssertEqual(a.slotAutoRefreshKey, b.slotAutoRefreshKey)
    }

    func testAllAttendeesCombinesRequiredAndOptional() {
        let u = ResolvedAttendee(displayName: "U", email: "u@e.com", jobTitle: nil)
        let v = ResolvedAttendee(displayName: "V", email: "v@e.com", jobTitle: nil)
        var draft = MeetingDraft()
        draft.requiredAttendees = [u]
        draft.optionalAttendees = [v]
        XCTAssertEqual(draft.allAttendees, [u, v])
        XCTAssertEqual(draft.kind(of: u), .required)
        XCTAssertEqual(draft.kind(of: v), .optional)
    }
}
