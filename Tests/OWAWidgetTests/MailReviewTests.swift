import XCTest
@testable import OWAWidget

/// The UI/UX review fixes: system senders, bundles, people-only counts, notifications, bulk
/// actions, meeting answers from mail, the sidebar, the window's selection and the MCP digest.
@MainActor
final class MailReviewTests: XCTestCase {
    private var defaults: UserDefaults!
    private var provider: FakeMailProvider!
    private var backend: FakeMailBackend!

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: "MailReviewTests-\(UUID().uuidString)")
        provider = FakeMailProvider(account: MailFixtures.account)
        backend = FakeMailBackend(provider: provider)
    }

    private func makeService(_ change: (inout MailSettings) -> Void = { _ in }) -> MailService {
        var settings = MailSettings()
        settings.enabled = true
        change(&settings)
        settings.save(to: defaults)
        return MailService(backend: backend, defaults: defaults)
    }

    private func conversation(_ id: String, from sender: String, unread: Int = 1, replied: Bool = false, refs: Int = 1) -> MailConversationSummary {
        MailConversationSummary(
            id: id, topic: "Topic \(id)", senders: [sender], recipients: [], lastDelivery: Date(), messageCount: 1,
            globalMessageCount: replied ? 2 : 1, unreadCount: unread, hasAttachments: false, importance: .normal, preview: "Hi",
            itemRefs: (0..<refs).map { MailItemRef(id: "I-\(id)-\($0)", changeKey: "CK") }, categories: [], isFlagged: false,
            isProtected: false, instanceKey: "K-\(id)", parentFolderID: "INBOX"
        )
    }

    // MARK: - Classification

    func testSystemSenders() {
        for name in ["Bitbucket", "Jira", "jenkins@example.com", "confluence-noreply@example.com", "RSM@example.com",
                     "Informatica PROD ETL", "Appsec", "Контур.Толк", "HR-команда", "PrometheusProdQA"] {
            XCTAssertTrue(MailSenderClassifier.isAutomated(name: name, email: nil), name)
        }
        for name in ["Сидоров Пётр Алексеевич", "Thomas Wright", "Ольга Васильева", "Grace Miller"] {
            XCTAssertFalse(MailSenderClassifier.isAutomated(name: name, email: nil), name)
        }
        XCTAssertTrue(MailSenderClassifier.isAutomated(name: "Build Server", email: "noreply@example.com"))
    }

    func testBundlesFoldRepeatedSystemSenders() {
        let list = [
            conversation("A", from: "Bitbucket"), conversation("B", from: "Ольга Васильева"),
            conversation("C", from: "Bitbucket"), conversation("D", from: "Jira"),
        ]
        let rows = MailListRow.rows(list, bundleAutomated: true)
        XCTAssertEqual(rows.map(\.id), ["bundle:Bitbucket", "B", "D"], "a single Jira message stays a plain row")
        guard case .bundle(_, let bundled) = rows[0] else { return XCTFail("expected a bundle") }
        XCTAssertEqual(bundled.map(\.id), ["A", "C"])
        XCTAssertEqual(MailListRow.rows(list, bundleAutomated: false).count, 4)
    }

    func testVIPMatchingIgnoresOrderAndPatronymic() {
        let names: Set<String> = [MailVIP.normalized("Пётр Иванов"), MailVIP.normalized("Grace Miller")]
        XCTAssertTrue(MailVIP.matches("Иванов Петр Сергеевич", in: names))
        XCTAssertTrue(MailVIP.matches("Miller Grace", in: names))
        XCTAssertFalse(MailVIP.matches("Иванов", in: names))
        XCTAssertFalse(MailVIP.matches("Пётр Сидоров", in: names))
    }

    // MARK: - People only and notifications

    func testPeopleOnlyCountsAndNotifications() async {
        await provider.setConversations([conversation("A", from: "Bitbucket"), conversation("B", from: "Ольга Васильева")])
        let service = makeService { $0.menuBarBadgeEnabled = true; $0.notifyMode = .people }
        var notified: [String] = []
        service.notifier = { conversation, _ in notified.append(conversation.id) }
        await service.checkInbox()
        XCTAssertEqual(service.popoverUnread.map(\.id), ["B"])
        XCTAssertEqual(service.menuBarUnreadCount, 1)
        XCTAssertTrue(notified.isEmpty, "the first check records what is already unread, silently")

        await provider.setConversations([conversation("C", from: "Jira"), conversation("D", from: "Дмитрий Орлов"), conversation("B", from: "Ольга Васильева")])
        await provider.setUnread(5)
        await service.checkInbox()
        XCTAssertEqual(notified, ["D"], "new mail from a person notifies; a system and old mail do not")
    }

    /// The server's "external sender" warning is cut from previews; a notification must say it.
    func testNotificationMarksExternalSender() async {
        await provider.setConversations([conversation("A", from: "Ольга Васильева")])
        let service = makeService { $0.notifyMode = .people }
        let localization = LocalizationService(selectedLanguage: .russian)
        service.localization = localization
        var labels: [String: String?] = [:]
        service.notifier = { conversation, label in labels[conversation.id] = label }
        await service.checkInbox()
        var outside = conversation("X", from: "Пётр Иванов")
        outside.hasExternalBanner = true
        await provider.setConversations([outside, conversation("Y", from: "Анна Смирнова"), conversation("A", from: "Ольга Васильева")])
        await provider.setUnread(7)
        await service.checkInbox()
        XCTAssertEqual(labels["X"], .some("внешний"))
        XCTAssertEqual(labels["Y"], .some(nil))
        XCTAssertTrue(service.isExternalSender(outside))
    }

    func testImportantNotificationsNeedTodaysPeople() async {
        await provider.setConversations([conversation("A", from: "Ольга Васильева")])
        let service = makeService { $0.notifyMode = .important }
        var notified: [String] = []
        service.notifier = { conversation, _ in notified.append(conversation.id) }
        await service.checkInbox()
        backend.vipNames = [MailVIP.normalized("Дмитрий Орлов")]
        await provider.setConversations([conversation("B", from: "Сергей Морозов"), conversation("C", from: "Орлов Дмитрий")])
        await provider.setUnread(9)
        await service.checkInbox()
        XCTAssertEqual(notified, ["C"])
    }

    // MARK: - Bulk actions

    func testMarkingConversationsReadIsOneRequest() async throws {
        let service = makeService()
        try await service.setRead(conversations: [conversation("A", from: "x y", refs: 3), conversation("B", from: "x y", refs: 2)], true)
        let calls = await provider.calls.filter { $0 == "update" }
        let count = await provider.updateCount
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(count, 5, "every message of both conversations")
        try await service.setRead(conversations: [conversation("C", from: "x y", unread: 0, refs: 4)], false)
        let after = await provider.updateCount
        XCTAssertEqual(after, 6, "unread marks only the newest message")
    }

    func testMarkAllReadPagesUntilNothingIsLeft() async throws {
        let items = (0..<120).map { index in
            MailListItem(ref: MailItemRef(id: "M\(index)", changeKey: nil), conversationID: nil, subject: "", from: nil, displayTo: "",
                         received: nil, isRead: false, hasAttachments: false, importance: .normal, preview: "", instanceKey: "K\(index)")
        }
        await provider.setUnreadItems(items)
        let service = makeService()
        var progress: [Int] = []
        let marked = try await service.markAllRead(in: .distinguished(.inbox)) { progress.append($0) }
        XCTAssertEqual(marked, 120)
        XCTAssertEqual(progress, [50, 100, 120])
        XCTAssertEqual(service.inboxUnreadCount, 0)
    }

    func testMeetingAnswerGoesThroughTheCalendar() async throws {
        backend.knownMeetings = ["CAL-1"]
        let service = makeService()
        func request(_ calendarID: String) -> MailMessage {
            let base = MailFixtures.message("M", conversation: "C")
            return MailMessage(
                ref: base.ref, conversationID: "C", parentFolderID: nil, kind: .meetingRequest, subject: "Sync", from: base.from,
                to: [], cc: [], bcc: [], hiddenRecipientCount: 0, received: nil, sent: nil, isRead: true, isDraft: false,
                importance: .normal, bodyHTML: nil, preview: "", attachments: [], categories: [], isFlagged: false,
                actions: [.acceptMeeting], meeting: MailMeetingInfo(start: nil, end: nil, location: nil, associatedCalendarItemID: calendarID),
                internetMessageID: nil
            )
        }
        let answered = try await service.respond(to: request("CAL-1"), action: .accept)
        XCTAssertTrue(answered)
        XCTAssertEqual(backend.meetingAnswers.map(\.0), ["CAL-1"])
        let outside = try await service.respond(to: request("CAL-OLD"), action: .decline)
        XCTAssertFalse(outside, "a meeting outside the synced calendar is left to OWA")
    }

    func testRelatedSearchQuery() {
        XCTAssertEqual(MailRelatedSearch.subjectQuery("RE: FW: Релиз 1.3 — финальный чек-лист"), "Релиз финальный чек лист")
        XCTAssertEqual(MailRelatedSearch.subjectQuery("1:1"), "")
    }

    // MARK: - Sidebar

    func testSidebarHidesServiceFolders() {
        func folder(_ id: String, _ distinguished: String?, parent: String? = "ROOT", total: Int = 1) -> MailFolder {
            MailFolder(id: id, distinguishedID: distinguished, displayName: id, parentID: parent, unreadCount: 0, totalCount: total, childFolderCount: 0)
        }
        let folders = [
            folder("ROOT", "msgfolderroot", parent: nil), folder("INBOX", "inbox"), folder("JIRA", nil, parent: "INBOX"),
            folder("HISTORY", "conversationhistory"), folder("SYNC", "syncissues"), folder("CONFLICTS", "conflicts", parent: "SYNC"),
            folder("CHILD", nil, parent: "SYNC"), folder("OUTBOX", "outbox", total: 0), folder("CUSTOM", nil),
        ]
        let visible = MailSidebarPolicy.visibleFolders(folders).map(\.id)
        XCTAssertEqual(Set(visible), ["INBOX", "JIRA", "CUSTOM"])
        XCTAssertEqual(MailSidebarPolicy.topLevelCustom(MailSidebarPolicy.visibleFolders(folders)).map(\.id), ["CUSTOM"])
        XCTAssertEqual(MailSidebarPolicy.children(of: "INBOX", in: folders).map(\.id), ["JIRA"])
    }

    // MARK: - Window

    func testFolderChangeClearsTheReaderAndModesFilter() async {
        await provider.setConversations([
            conversation("A", from: "Bitbucket"), conversation("B", from: "Ольга Васильева", replied: true),
            conversation("C", from: "Дмитрий Орлов"),
        ])
        await provider.setThread(MailThread(id: "B", messages: [MailFixtures.message("M1", conversation: "B", isRead: true)], totalMessageCount: 1))
        let service = makeService()
        let model = MailWindowModel(service: service)
        await model.start()
        await model.openConversation("B")
        XCTAssertNotNil(model.thread)
        model.mode = .people
        XCTAssertEqual(model.visibleConversations.map(\.id), ["B", "C"])
        model.mode = .awaitingReply
        XCTAssertEqual(model.visibleConversations.map(\.id), ["C"], "the user already wrote in B")
        model.select(folder: MailFolder(id: "SENT", distinguishedID: "sentitems", displayName: "Sent", parentID: nil, unreadCount: 0, totalCount: 0, childFolderCount: 0))
        XCTAssertNil(model.thread)
        XCTAssertNil(model.selectedConversationID)
    }

    func testCommandClickPicksSeveral() async {
        await provider.setConversations([conversation("A", from: "Ольга Васильева"), conversation("B", from: "Дмитрий Орлов"), conversation("C", from: "Сергей Морозов")])
        let service = makeService()
        let model = MailWindowModel(service: service)
        await model.reloadList()
        model.click(model.conversations[0], modifiers: .command)
        model.click(model.conversations[2], modifiers: .command)
        XCTAssertEqual(model.selectedIDs, ["A", "C"])
        XCTAssertEqual(Set(model.actionTargets.map(\.id)), ["A", "C"])
        model.selectAllVisible()
        XCTAssertEqual(model.selectedIDs.count, 3)
    }

    func testCancellationIsNotShown() {
        let model = MailWindowModel(service: makeService())
        model.show(URLError(.cancelled))
        model.show(CancellationError())
        XCTAssertNil(model.actionError)
        model.show(MailError.serverError("ErrorAccessDenied"))
        XCTAssertNotNil(model.actionError)
    }

    func testListTimeKeepsTheHourForRecentDays() {
        let localization = LocalizationService(selectedLanguage: .russian)
        let now = Date()
        let yesterday = AppTimeZone.calendar.date(byAdding: .day, value: -1, to: now)!
        XCTAssertTrue(MailPresentation.listTime(yesterday, localization: localization, now: now).hasPrefix("Вчера "))
    }
}
