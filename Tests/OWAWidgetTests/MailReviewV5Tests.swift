import XCTest
@testable import OWAWidget

@MainActor
final class MailReviewV5Tests: XCTestCase {
    private let localization = LocalizationService(selectedLanguage: .russian)

    private func conversation(_ id: String, from: String = "Grace Miller", minutesAgo: Double = 10, unread: Int = 0,
                              messages: Int = 1, global: Int? = nil, classes: [String] = []) -> MailConversationSummary {
        var summary = MailConversationSummary(
            id: id, topic: "Topic \(id)", senders: [from], recipients: [], lastDelivery: Date().addingTimeInterval(-minutesAgo * 60),
            messageCount: messages, globalMessageCount: global ?? messages, unreadCount: unread, hasAttachments: false, importance: .normal,
            preview: "", itemRefs: [], categories: [], isFlagged: false, isProtected: false, instanceKey: nil, parentFolderID: "INBOX"
        )
        summary.itemClasses = classes
        return summary
    }

    // MARK: - External banner

    func testExchangeExternalBannerIsCutFromPreview() {
        let raw = "⚠       Внешний отправитель! Будьте осторожны с вложениями и ссылками            Пользователь Петров Иван разрешил вам"
        let result = MailExternalBanner.strip(raw)
        XCTAssertTrue(result.found)
        XCTAssertEqual(result.text, "Пользователь Петров Иван разрешил вам")
        XCTAssertFalse(MailExternalBanner.strip("Внешний вид отчёта изменился").found)
        XCTAssertEqual(MailExternalBanner.strip("\u{26A0}\u{FE0F} Внешний отправитель! Будьте осторожны с вложениями и ссылками. Текст").text, "Текст")
    }

    func testParserReadsItemClassesAndBanner() throws {
        let dict: [String: Any] = [
            "ConversationId": ["Id": "C1"],
            "ConversationTopic": "Встреча",
            "UniqueSenders": ["Сидоров Пётр"],
            "ItemClasses": ["IPM.Schedule.Meeting.Request"],
            "Preview": "⚠ Внешний отправитель! Будьте осторожны с вложениями и ссылками\r\n\r\nПривет",
        ]
        let summary = try XCTUnwrap(OWAMailParsers.conversation(from: dict))
        XCTAssertTrue(summary.isMeetingRequest)
        XCTAssertFalse(summary.isMeetingCancellation)
        XCTAssertTrue(summary.hasExternalBanner)
        XCTAssertEqual(summary.preview, "Привет")
        XCTAssertTrue(summary.with(unreadCount: 0).isMeetingRequest, "copies keep the classes")
    }

    // MARK: - List

    func testDaySections() {
        let now = AppTimeZone.calendar.date(bySettingHour: 20, minute: 0, second: 0, of: Date())!
        let day: (Int) -> Date = { AppTimeZone.calendar.date(byAdding: .day, value: -$0, to: now)! }
        let starts = MailPresentation.sectionStarts([day(0), day(0), day(1), day(3), day(3), day(9), day(30)], now: now)
        XCTAssertEqual(starts, [0, nil, 1, 3, nil, 7, nil])
        XCTAssertEqual(MailPresentation.sectionTitle(0, sample: now, localization: localization), "Сегодня")
        XCTAssertEqual(MailPresentation.sectionTitle(7, sample: nil, localization: localization), "Ранее")
        XCTAssertEqual(MailPresentation.rowTime(day(1), localization: localization, now: now), localization.shortTime(day(1)))
        XCTAssertFalse(MailPresentation.rowTime(day(30), localization: localization, now: now).contains(":"))
    }

    func testMeetingLine() {
        let start = Date().addingTimeInterval(86_400)
        let line = MailPresentation.meetingLine(conversation("1", classes: ["IPM.Schedule.Meeting.Request"]),
                                                interval: DateInterval(start: start, duration: 1800), localization: localization)
        XCTAssertTrue(line?.hasPrefix("Приглашение · ") == true)
        XCTAssertEqual(MailPresentation.meetingLine(conversation("2", classes: ["IPM.Schedule.Meeting.Request"]), interval: nil, localization: localization), "Приглашение на встречу")
        XCTAssertEqual(MailPresentation.meetingLine(conversation("3", classes: ["IPM.Schedule.Meeting.Canceled"]), interval: nil, localization: localization), "Встреча отменена")
        XCTAssertNil(MailPresentation.meetingLine(conversation("4", classes: ["IPM.Note"]), interval: nil, localization: localization))
    }

    // MARK: - Digest

    func testDigestPicksWhatNeedsAttention() {
        let unread = conversation("u", unread: 1)
        let replied = conversation("r", messages: 1, global: 2)
        let waiting = conversation("w")
        let old = conversation("o", minutesAgo: 60 * 24 * 10)
        let robot = conversation("b", from: "jenkins@example.com")
        let invite = conversation("i", classes: ["IPM.Schedule.Meeting.Request"])
        let folders = [
            MailFolder(id: "INBOX", distinguishedID: "inbox", displayName: "Входящие", parentID: nil, unreadCount: 3, totalCount: 9, childFolderCount: 2),
            MailFolder(id: "BB", distinguishedID: nil, displayName: "Bitbucket", parentID: "INBOX", unreadCount: 16, totalCount: 20, childFolderCount: 0),
            MailFolder(id: "RP", distinguishedID: nil, displayName: "Reports", parentID: "INBOX", unreadCount: 4, totalCount: 20, childFolderCount: 0),
            MailFolder(id: "QQ", distinguishedID: nil, displayName: "Quiet", parentID: "INBOX", unreadCount: 0, totalCount: 20, childFolderCount: 0),
            MailFolder(id: "JK", distinguishedID: "junkemail", displayName: "Junk", parentID: nil, unreadCount: 1, totalCount: 1, childFolderCount: 0),
        ]
        let digest = MailDigest.build(peopleUnread: [unread], inboxList: [unread, replied, waiting, old, robot, invite], folders: folders)
        XCTAssertEqual(digest.unreadFromPeople.map(\.id), ["u"])
        XCTAssertEqual(digest.awaitingReply.map(\.id), ["w"], "not unread twice, not replied, not old, not systems or invitations")
        XCTAssertEqual(digest.busyFolders.map(\.displayName), ["Bitbucket", "Reports"])
        XCTAssertTrue(MailDigest.build(peopleUnread: [], inboxList: nil, folders: []).isEmpty)
    }

    // MARK: - Sidebar and agenda

    func testFolderExpansionIsRemembered() async {
        let defaults = UserDefaults(suiteName: "expand-\(UUID().uuidString)")!
        let service = MailService(backend: nil, defaults: defaults)
        let first = MailWindowModel(service: service, defaults: defaults)
        XCTAssertTrue(first.expandedFolderIDs.isEmpty, "the inbox no longer starts open")
        first.expandedFolderIDs.insert("BB")
        let second = MailWindowModel(service: service, defaults: defaults)
        XCTAssertEqual(second.expandedFolderIDs, ["BB"])
    }

    func testTomorrowShowsOnceTodayIsOver() {
        let now = Date()
        func event(_ minutesFromNow: Double) -> CalendarEvent {
            CalendarEvent(id: "\(minutesFromNow)", title: "x", startDate: now.addingTimeInterval(minutesFromNow * 60),
                          endDate: now.addingTimeInterval(minutesFromNow * 60 + 1800), location: nil, bodyPreview: nil, joinURL: nil,
                          platform: .generic, isAllDay: false, organizer: nil, accountID: UUID())
        }
        XCTAssertTrue(MailAgendaPolicy.showsTomorrow([event(-120)], now: now))
        XCTAssertTrue(MailAgendaPolicy.showsTomorrow([], now: now))
        XCTAssertFalse(MailAgendaPolicy.showsTomorrow([event(-120), event(60)], now: now))
        XCTAssertFalse(MailAgendaPolicy.showsTomorrow([event(-10)], now: now), "a meeting still running")
    }

    func testOpeningMarksReadByDefault() {
        XCTAssertEqual(MailSettings().markReadPolicy, .onOpen)
        let defaults = UserDefaults(suiteName: "markread-\(UUID().uuidString)")!
        defaults.set("afterDelay", forKey: "mailMarkReadPolicy")
        XCTAssertEqual(MailSettings.load(from: defaults).markReadPolicy, .onOpen, "the old auto-saved value is not carried over")
        var settings = MailSettings()
        settings.markReadPolicy = .manual
        settings.save(to: defaults)
        XCTAssertEqual(MailSettings.load(from: defaults).markReadPolicy, .manual)
    }
}

@MainActor
final class MailFolderCountsTests: XCTestCase {
    private func folder(_ id: String, unread: Int, distinguished: String? = nil) -> MailFolder {
        MailFolder(id: id, distinguishedID: distinguished, displayName: id, parentID: nil, unreadCount: unread, totalCount: 10, childFolderCount: 0)
    }

    private func makeService(_ folders: [MailFolder]) async throws -> (MailService, FakeMailProvider, FakeMailBackend) {
        let defaults = UserDefaults(suiteName: "counts-\(UUID().uuidString)")!
        var settings = MailSettings()
        settings.enabled = true
        settings.save(to: defaults)
        let provider = FakeMailProvider(account: MailFixtures.account)
        await provider.setFolders(folders)
        let backend = FakeMailBackend(provider: provider)
        let service = MailService(backend: backend, defaults: defaults)
        try await service.loadFolders()
        return (service, provider, backend)
    }

    func testCountsFollowTheServer() async throws {
        let (service, provider, backend) = try await makeService([folder("INBOX", unread: 3, distinguished: "inbox"), folder("Reports", unread: 2)])
        _ = backend
        await provider.setFolders([folder("INBOX", unread: 3, distinguished: "inbox"), folder("Reports", unread: 0)])
        await service.refreshFolderCounts(minInterval: 0)
        XCTAssertEqual(service.folders.first { $0.id == "Reports" }?.unreadCount, 0)
        XCTAssertEqual(service.folders.first { $0.id == "Reports" }?.displayName, "Reports", "names and tree stay")

        await provider.setFolders([folder("INBOX", unread: 3, distinguished: "inbox"), folder("Reports", unread: 5)])
        await service.refreshFolderCounts()
        XCTAssertEqual(service.folders.first { $0.id == "Reports" }?.unreadCount, 0, "a second call within 10 s is skipped")
    }

    func testLocalAdjustmentNeverGoesNegative() async throws {
        let (service, _, backend) = try await makeService([folder("Reports", unread: 2)])
        _ = backend
        service.adjustFolderUnread(["Reports": -1])
        XCTAssertEqual(service.folders.first?.unreadCount, 1)
        service.adjustFolderUnread(["Reports": -5])
        XCTAssertEqual(service.folders.first?.unreadCount, 0)
    }

    func testReadingInTheWindowMovesTheFolderCounter() async throws {
        let (service, _, backend) = try await makeService([folder("INBOX", unread: 1, distinguished: "inbox"), folder("Reports", unread: 2)])
        _ = backend
        let model = MailWindowModel(service: service, defaults: UserDefaults(suiteName: "m-\(UUID().uuidString)")!)
        await model.loadFolders()
        model.select(folder: try XCTUnwrap(model.folders.first { $0.id == "Reports" }))
        var conversation = MailFixtures.conversation("c1", unread: 2)
        conversation = MailConversationSummary(
            id: conversation.id, topic: conversation.topic, senders: conversation.senders, recipients: [], lastDelivery: Date(),
            messageCount: 2, unreadCount: 2, hasAttachments: false, importance: .normal, preview: "", itemRefs: conversation.itemRefs,
            categories: [], isFlagged: false, isProtected: false, instanceKey: nil, parentFolderID: "Reports"
        )
        await model.markRead([conversation], true)
        XCTAssertEqual(model.folders.first { $0.id == "Reports" }?.unreadCount, 0)
        XCTAssertEqual(model.folders.first { $0.id == "INBOX" }?.unreadCount, 1, "other folders untouched")
    }
}

@MainActor
final class MailSendCountdownTests: XCTestCase {
    func testSendLabelCountsDown() {
        let localization = LocalizationService(selectedLanguage: .russian)
        XCTAssertEqual(MCPMailConfirmationView.sendDelaySeconds, 3)
        XCTAssertEqual(MCPMailConfirmationView.sendLabel(remaining: 3, localization: localization), "Отправить · 3")
        XCTAssertEqual(MCPMailConfirmationView.sendLabel(remaining: 1, localization: localization), "Отправить · 1")
        XCTAssertEqual(MCPMailConfirmationView.sendLabel(remaining: 0, localization: localization), "Отправить")
    }
}
