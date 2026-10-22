import XCTest
@testable import OWAWidget

@MainActor
final class MailDigestTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let account = UUID()

    private func mail(
        _ id: String, topic: String, unread: Int = 0, invitation: Bool = false,
        flagged: Bool = false, importance: MailImportance = .normal, minutesAgo: Double = 10
    ) -> MailConversationSummary {
        var summary = MailConversationSummary(
            id: id, topic: topic, senders: ["Grace Miller"], recipients: [], lastDelivery: now.addingTimeInterval(-minutesAgo * 60),
            messageCount: 1, globalMessageCount: 1, unreadCount: unread, hasAttachments: false, importance: importance,
            preview: "", itemRefs: [], categories: [], isFlagged: flagged, isProtected: false, instanceKey: nil, parentFolderID: "INBOX"
        )
        summary.itemClasses = invitation ? ["IPM.Schedule.Meeting.Request"] : ["IPM.Note"]
        return summary
    }

    private func meeting(
        _ id: String, title: String, inHours hours: Double = 24, response: MeetingResponseType = .notResponded,
        organizer: Bool = false, changeKey: String? = "ck", cancelled: Bool = false
    ) -> CalendarEvent {
        let start = now.addingTimeInterval(hours * 3600)
        return CalendarEvent(
            id: id, title: title, startDate: start, endDate: start.addingTimeInterval(1800), location: nil, bodyPreview: nil,
            joinURL: nil, platform: .generic, isAllDay: false, organizer: "Grace Miller", accountID: account,
            isCancelled: cancelled, isOrganizer: organizer, responseType: response, changeKey: changeKey
        )
    }

    func testInvitationEmailsMatchedToMeetingsStillWaitingForAnAnswer() {
        let digest = MailDigest.build(
            peopleUnread: [],
            folders: [],
            conversations: [
                mail("m1", topic: "Design review", invitation: true),
                mail("m2", topic: "Планирование", invitation: true),
                mail("m3", topic: "Old one", invitation: true),
                mail("m4", topic: "Answered", invitation: true),
                mail("n1", topic: "Design review"),
            ],
            events: [
                meeting("e2", title: "Планирование", inHours: 2),
                meeting("e1", title: "Design review", inHours: 26),
                meeting("e3", title: "Old one", inHours: -5),
                meeting("e4", title: "Answered", response: .accepted),
            ],
            now: now
        )
        XCTAssertEqual(digest.invitations.map(\.event.id), ["e2", "e1"], "soonest first; past and answered left out")
        XCTAssertEqual(digest.invitations.first?.conversationID, "m2")
    }

    /// Dozens of unanswered recurring meetings must not fill the list: only invitations at hand.
    func testUnansweredMeetingsWithoutAnInvitationEmailAreNotListed() {
        let digest = MailDigest.build(
            peopleUnread: [], folders: [], conversations: [],
            events: (0..<20).map { meeting("r\($0)", title: "Daily \($0)") }, now: now
        )
        XCTAssertTrue(digest.invitations.isEmpty)
    }

    func testOnlyMeetingsTheUserCanAnswerCount() {
        let invitations = ["Mine", "Read only", "Cancelled"].enumerated().map { mail("m\($0.offset)", topic: $0.element, invitation: true) }
        let digest = MailDigest.build(
            peopleUnread: [], folders: [], conversations: invitations,
            events: [
                meeting("a", title: "Mine", organizer: true),
                meeting("b", title: "Read only", changeKey: nil),
                meeting("c", title: "Cancelled", cancelled: true),
            ],
            now: now
        )
        XCTAssertTrue(digest.invitations.isEmpty)
    }

    func testImportantAndFlaggedNewestFirstWithoutDuplicates() {
        let flagged = mail("f", topic: "Flagged", unread: 1, flagged: true, minutesAgo: 30)
        let digest = MailDigest.build(
            peopleUnread: [flagged],
            folders: [],
            conversations: [flagged, mail("h", topic: "Urgent", importance: .high, minutesAgo: 5), mail("p", topic: "Plain")],
            now: now
        )
        XCTAssertEqual(digest.important.map(\.id), ["h", "f"])
        XCTAssertEqual(digest.flaggedCount, 1)
        XCTAssertEqual(digest.peopleUnreadCount, 1)
    }

    func testInboxCountComesFromTheFolderList() {
        let folders = [
            MailFolder(id: "INBOX", distinguishedID: "inbox", displayName: "Входящие", parentID: nil, unreadCount: 12, totalCount: 90, childFolderCount: 0),
        ]
        XCTAssertEqual(MailDigest.build(peopleUnread: [], folders: folders).inboxUnread, 12)
        XCTAssertNil(MailDigest.build(peopleUnread: [], folders: []).inboxUnread)
    }
}
