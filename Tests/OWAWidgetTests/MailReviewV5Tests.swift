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
        XCTAssertEqual(line?.hasSuffix(localization.shortTime(start) + "–" + localization.shortTime(start.addingTimeInterval(1800))), true, "the tag says invitation, the line says when")
        XCTAssertNil(MailPresentation.meetingLine(conversation("2", classes: ["IPM.Schedule.Meeting.Request"]), interval: nil, localization: localization))
        XCTAssertEqual(conversation("5", classes: ["IPM.Schedule.Meeting.Request"]).meetingStatus, .invitation)
        XCTAssertNil(MailPresentation.meetingLine(conversation("3", classes: ["IPM.Schedule.Meeting.Canceled"]), interval: nil, localization: localization), "the cancelled tag says it")
        XCTAssertNil(MailPresentation.meetingLine(conversation("4", classes: ["IPM.Note"]), interval: nil, localization: localization))
    }

    // MARK: - Digest

    func testDigestPicksWhatNeedsAttention() {
        let unread = conversation("u", unread: 1)
        let folders = [
            MailFolder(id: "INBOX", distinguishedID: "inbox", displayName: "Входящие", parentID: nil, unreadCount: 3, totalCount: 9, childFolderCount: 2),
            MailFolder(id: "BB", distinguishedID: nil, displayName: "Bitbucket", parentID: "INBOX", unreadCount: 16, totalCount: 20, childFolderCount: 0),
            MailFolder(id: "RP", distinguishedID: nil, displayName: "Reports", parentID: "INBOX", unreadCount: 4, totalCount: 20, childFolderCount: 0),
            MailFolder(id: "QQ", distinguishedID: nil, displayName: "Quiet", parentID: "INBOX", unreadCount: 0, totalCount: 20, childFolderCount: 0),
            MailFolder(id: "JK", distinguishedID: "junkemail", displayName: "Junk", parentID: nil, unreadCount: 1, totalCount: 1, childFolderCount: 0),
        ]
        let digest = MailDigest.build(peopleUnread: [unread], folders: folders)
        XCTAssertEqual(digest.unreadFromPeople.map(\.id), ["u"])
        XCTAssertEqual(digest.busyFolders.map(\.displayName), ["Bitbucket", "Reports"])
        XCTAssertTrue(MailDigest.build(peopleUnread: [], folders: []).isEmpty)
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

@MainActor
final class MailInboxPanelTests: XCTestCase {
    func testPanelListIsTheFolderAsIsAndNotRefetchedWithin30Seconds() async throws {
        let defaults = UserDefaults(suiteName: "recent-\(UUID().uuidString)")!
        var settings = MailSettings()
        settings.enabled = true
        settings.save(to: defaults)
        let provider = FakeMailProvider(account: MailFixtures.account)
        await provider.setConversations([MailFixtures.conversation("robot"), MailFixtures.conversation("person", unread: 0)])
        let backend = FakeMailBackend(provider: provider)
        let service = MailService(backend: backend, defaults: defaults)
        await service.refreshPanelList()
        XCTAssertEqual(service.panelList.map(\.id), ["robot", "person"], "no filtering: what the inbox holds")
        await service.refreshPanelList()
        let lists = await provider.calls.filter { $0.hasPrefix("conversations:All") }
        XCTAssertEqual(lists.count, 1, "a second call within 30 s makes no request")
    }

    func testPanelLoadsMorePagesAndARefreshKeepsThem() async throws {
        let defaults = UserDefaults(suiteName: "panel-more-\(UUID().uuidString)")!
        var settings = MailSettings()
        settings.enabled = true
        settings.save(to: defaults)
        let provider = FakeMailProvider(account: MailFixtures.account)
        await provider.setConversations((1...5).map { MailFixtures.conversation("c\($0)") })
        await provider.setConversationPageSize(2)
        let backend = FakeMailBackend(provider: provider)
        let service = MailService(backend: backend, defaults: defaults)
        await service.refreshPanelList()
        XCTAssertEqual(service.panelList.map(\.id), ["c1", "c2"])
        await service.loadMorePanelList()
        await service.loadMorePanelList()
        XCTAssertEqual(service.panelList.map(\.id), ["c1", "c2", "c3", "c4", "c5"])
        XCTAssertNil(service.panelNextCursor, "the folder's end")

        // New mail on top: the first page is fresh, the rows scrolled to stay.
        await provider.setConversations([MailFixtures.conversation("new")] + (1...5).map { MailFixtures.conversation("c\($0)") })
        await service.refreshPanelList(minInterval: 0)
        XCTAssertEqual(service.panelList.map(\.id), ["new", "c1", "c2", "c3", "c4", "c5"])
        XCTAssertNil(service.panelNextCursor, "still the folder's end")

        // More new mail than a page: the old rows no longer join on, so the list starts over.
        await provider.setConversations(["n1", "n2", "n3"].map { MailFixtures.conversation($0) } + (1...5).map { MailFixtures.conversation("c\($0)") })
        await service.refreshPanelList(minInterval: 0)
        XCTAssertEqual(service.panelList.map(\.id), ["n1", "n2"])
        XCTAssertNotNil(service.panelNextCursor)
    }

    func testPanelStatusReadsLikeThePopoverSyncLine() {
        let localization = LocalizationService(selectedLanguage: .russian)
        let now = Date()
        XCTAssertEqual(MailPresentation.panelStatus(unread: 3, lastChecked: now.addingTimeInterval(-10), now: now, localization: localization),
                       "Непрочитанных: 3 · проверено " + localization.relativeSyncPhrase(since: now.addingTimeInterval(-10), now: now))
        XCTAssertTrue(MailPresentation.panelStatus(unread: 0, lastChecked: now.addingTimeInterval(-180), now: now, localization: localization).hasPrefix("Проверено "))
        XCTAssertEqual(MailPresentation.panelStatus(unread: nil, lastChecked: nil, localization: localization), "Ещё не обновлялось")
    }

    func testPanelFolderIsRememberedAndFallsBackWhenGone() async throws {
        let defaults = UserDefaults(suiteName: "panel-folder-\(UUID().uuidString)")!
        var settings = MailSettings()
        settings.enabled = true
        settings.save(to: defaults)
        let provider = FakeMailProvider(account: MailFixtures.account)
        func folder(_ id: String, _ distinguished: String?, parent: String? = "ROOT") -> MailFolder {
            MailFolder(id: id, distinguishedID: distinguished, displayName: id, parentID: parent, unreadCount: 2, totalCount: 9, childFolderCount: 0)
        }
        let root = folder("ROOT", "msgfolderroot", parent: nil)
        await provider.setFolders([root, folder("INBOX", "inbox"), folder("DIANA", nil)])
        let backend = FakeMailBackend(provider: provider)
        let service = MailService(backend: backend, defaults: defaults)
        try await service.loadFolders()
        await service.selectPanelFolder(.id("DIANA"))
        XCTAssertEqual(service.panelFolderInfo?.id, "DIANA")
        XCTAssertEqual(MailService(backend: backend, defaults: defaults).panelFolder, .id("DIANA"), "remembered between launches")

        // The GetFolder fallback: system folders only, none with a parent.
        await provider.setFolders([folder("INBOX", "inbox", parent: nil), folder("SENT", "sentitems", parent: nil)])
        try await service.loadFolders()
        XCTAssertEqual(service.panelFolder, .id("DIANA"), "a system-only tree (the GetFolder fallback) proves nothing")

        // A full tree with no folders of the user's own left: the remembered one is gone all the same.
        await provider.setFolders([root, folder("INBOX", "inbox"), folder("SENT", "sentitems")])
        try await service.loadFolders()
        XCTAssertEqual(service.panelFolder, .distinguished(.inbox), "a folder that is gone from a full tree falls back to the inbox")
        XCTAssertNil(defaults.string(forKey: MailService.panelFolderKey))
        XCTAssertNil(defaults.string(forKey: MailService.panelFolderAccountKey))
    }

    func testPanelFolderSurvivesProviderRebuildsButNotAnotherAccount() async throws {
        let defaults = UserDefaults(suiteName: "panel-account-\(UUID().uuidString)")!
        var settings = MailSettings()
        settings.enabled = true
        settings.save(to: defaults)
        let provider = FakeMailProvider(account: MailFixtures.account)
        let backend = FakeMailBackend(provider: provider)
        let other = CalendarAccount(id: UUID(), displayName: "Other", serverURL: "https://mail.example.org", email: "EXAMPLE\\other", accountType: .owa)
        backend.accounts.append(other)
        backend.providers[other.id] = FakeMailProvider(account: other)
        let service = MailService(backend: backend, defaults: defaults)
        await service.selectPanelFolder(.id("DIANA"))

        // A settings change that leaves the same account in charge (as a rebuild at launch does).
        service.updateSettings { $0.accountID = MailFixtures.account.id }
        XCTAssertEqual(service.panelFolder, .id("DIANA"), "the same mailbox keeps the user's folder")

        service.updateSettings { $0.accountID = other.id }
        XCTAssertEqual(service.panelFolder, .distinguished(.inbox), "another mailbox starts from its inbox")
        XCTAssertNil(defaults.string(forKey: MailService.panelFolderKey))
    }

    func testOlderPanelAnswerDoesNotOverwriteNewerOne() async throws {
        let defaults = UserDefaults(suiteName: "panel-race-\(UUID().uuidString)")!
        var settings = MailSettings()
        settings.enabled = true
        settings.save(to: defaults)
        let provider = FakeMailProvider(account: MailFixtures.account)
        await provider.setConversations([MailFixtures.conversation("old")])
        await provider.setConversationDelays([300_000_000, 0])
        // The service holds its backend weakly.
        let backend = FakeMailBackend(provider: provider)
        let service = MailService(backend: backend, defaults: defaults)

        let slow = Task { await service.refreshPanelList(minInterval: 0) }
        try await Task.sleep(nanoseconds: 50_000_000)
        await provider.setConversations([MailFixtures.conversation("new")])
        await service.refreshPanelList(minInterval: 0)
        await slow.value
        XCTAssertEqual(service.panelList.map(\.id), ["new"], "the slow first request answered last but is older")
        XCTAssertFalse(service.isLoadingPanelList)
    }

    func testEmptyPanelFolderIsNotLoadingOnceAnswered() async throws {
        let defaults = UserDefaults(suiteName: "panel-empty-\(UUID().uuidString)")!
        var settings = MailSettings()
        settings.enabled = true
        settings.save(to: defaults)
        let backend = FakeMailBackend(provider: FakeMailProvider(account: MailFixtures.account))
        let service = MailService(backend: backend, defaults: defaults)
        XCTAssertFalse(service.panelListAnswered)
        await service.refreshPanelList(minInterval: 0)
        XCTAssertTrue(service.panelList.isEmpty)
        XCTAssertNil(service.lastChecked, "no inbox check yet: the panel must not wait for one")
        XCTAssertTrue(service.panelListAnswered)
    }

    func testFailedPanelLoadIsNotAnEmptyFolder() async throws {
        let defaults = UserDefaults(suiteName: "panel-fail-\(UUID().uuidString)")!
        var settings = MailSettings()
        settings.enabled = true
        settings.save(to: defaults)
        let provider = FakeMailProvider(account: MailFixtures.account)
        await provider.setConversations([MailFixtures.conversation("c1")])
        await provider.setFailure(URLError(.timedOut))
        let backend = FakeMailBackend(provider: provider)
        let service = MailService(backend: backend, defaults: defaults)

        await service.refreshPanelList(minInterval: 0)
        XCTAssertTrue(service.panelListFailed)
        XCTAssertFalse(service.isLoadingPanelList)
        XCTAssertTrue(service.panelList.isEmpty)

        await provider.setFailure(nil)
        await service.refreshPanelList(minInterval: 0)
        XCTAssertFalse(service.panelListFailed)
        XCTAssertEqual(service.panelList.map(\.id), ["c1"])
    }

    func testPanelFolderStorageRoundTrip() {
        for ref in [MailFolderRef.distinguished(.sentitems), .id("AAMkAD=")] {
            XCTAssertEqual(MailService.folderRef(storageValue: MailService.storageValue(ref)), ref)
        }
        XCTAssertNil(MailService.folderRef(storageValue: "distinguished:nonsense"))
        XCTAssertNil(MailService.folderRef(storageValue: nil))
    }
}

@MainActor
final class MailPanelFolderListTests: XCTestCase {
    func testSubfoldersSitRightUnderTheirParent() {
        func folder(_ id: String, _ distinguished: String? = nil, parent: String? = "ROOT") -> MailFolder {
            MailFolder(id: id, distinguishedID: distinguished, displayName: id, parentID: parent, unreadCount: 0, totalCount: 1, childFolderCount: 0)
        }
        let folders = [
            folder("ROOT", "msgfolderroot", parent: nil),
            folder("INBOX", "inbox"), folder("DIANA", parent: "INBOX"), folder("NIGHT", parent: "DIANA"),
            folder("SENT", "sentitems"), folder("Archive"),
        ]
        let rows = MailPanelFolderList.rows(folders)
        XCTAssertEqual(rows.map(\.folder.id), ["INBOX", "DIANA", "NIGHT", "SENT", "Archive"])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 2, 0, 0])
        XCTAssertEqual(rows.map(\.startsCustom), [false, false, false, false, true])
    }
}

@MainActor
final class MailOfflineListTests: XCTestCase {
    private func makeModel() async -> (MailWindowModel, FakeMailProvider, FakeMailBackend) {
        let defaults = UserDefaults(suiteName: "offline-\(UUID().uuidString)")!
        var settings = MailSettings()
        settings.enabled = true
        settings.save(to: defaults)
        let provider = FakeMailProvider(account: MailFixtures.account)
        await provider.setConversations([MailFixtures.conversation("c1"), MailFixtures.conversation("c2", unread: 0)])
        let backend = FakeMailBackend(provider: provider)
        let service = MailService(backend: backend, defaults: defaults)
        return (MailWindowModel(service: service, defaults: defaults), provider, backend)
    }

    func testLoadedListSurvivesALostConnection() async {
        let (model, provider, backend) = await makeModel()
        _ = backend
        await model.reloadList()
        XCTAssertEqual(model.conversations.map(\.id), ["c1", "c2"])
        XCTAssertNil(model.staleList)

        await provider.setFailure(URLError(.notConnectedToInternet))
        await model.reloadList()
        XCTAssertEqual(model.conversations.map(\.id), ["c1", "c2"], "the list on screen stays")
        XCTAssertEqual(model.staleList?.isConnectionError, true)
        XCTAssertNil(model.listError)

        await provider.setFailure(nil)
        await model.reloadList()
        XCTAssertNil(model.staleList, "the notice goes once a load succeeds")
    }

    func testFolderNeverLoadedStillShowsTheError() async {
        let (model, provider, backend) = await makeModel()
        _ = backend
        await provider.setFailure(URLError(.timedOut))
        await model.reloadList()
        XCTAssertTrue(model.conversations.isEmpty)
        XCTAssertNil(model.staleList)
        XCTAssertNotNil(model.listError)
    }

    func testStaleNoticeDoesNotFollowToAnotherFolder() async {
        let (model, provider, backend) = await makeModel()
        _ = backend
        await model.reloadList()
        await provider.setFailure(URLError(.notConnectedToInternet))
        await model.reloadList()
        XCTAssertNotNil(model.staleList)
        model.select(ref: .distinguished(.sentitems))
        XCTAssertNil(model.staleList, "the inbox's notice does not stand over the folder being loaded")
    }

    func testStartOnAGivenFolderLoadsOnlyThatFolder() async {
        let (model, provider, backend) = await makeModel()
        _ = backend
        await model.start(folder: .distinguished(.sentitems))
        XCTAssertEqual(model.selectedFolder, .distinguished(.sentitems))
        let lists = await provider.calls.filter { $0.hasPrefix("conversations:") }
        XCTAssertEqual(lists.count, 1, "the window's previous folder is not loaded first")
    }

    func testConnectionErrorsAreToldApartFromServerErrors() {
        XCTAssertTrue(MailConnectivity.isConnectionError(URLError(.cannotFindHost)))
        XCTAssertTrue(MailConnectivity.isConnectionError(NSError(domain: "Wrapper", code: 1, userInfo: [NSUnderlyingErrorKey: URLError(.timedOut)])))
        XCTAssertFalse(MailConnectivity.isConnectionError(URLError(.badServerResponse)))
        XCTAssertFalse(MailConnectivity.isConnectionError(MailError.notSupported))
    }

    func testStaleNoticeText() {
        let localization = LocalizationService(selectedLanguage: .russian)
        // Noon, so "ten minutes ago" is today whenever the suite runs.
        let now = AppTimeZone.calendar.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        let today = MailStaleListNotice(loadedAt: now.addingTimeInterval(-600), isConnectionError: true)
        XCTAssertEqual(MailPresentation.staleListText(today, now: now, localization: localization),
                       "Нет связи с сервером — показано то, что было загружено в " + localization.shortTime(today.loadedAt))
        let earlier = MailStaleListNotice(loadedAt: now.addingTimeInterval(-3 * 86_400), isConnectionError: false)
        XCTAssertTrue(MailPresentation.staleListText(earlier, now: now, localization: localization).hasPrefix("Не удалось обновить список — показано то, что было загружено "))
    }
}

@MainActor
final class MailReviewFixesTests: XCTestCase {
    private func makeService(folders: [MailFolder] = []) async throws -> (MailService, FakeMailProvider, FakeMailBackend, UserDefaults) {
        let defaults = UserDefaults(suiteName: "fixes-\(UUID().uuidString)")!
        var settings = MailSettings()
        settings.enabled = true
        settings.save(to: defaults)
        let provider = FakeMailProvider(account: MailFixtures.account)
        await provider.setFolders(folders)
        let backend = FakeMailBackend(provider: provider)
        let service = MailService(backend: backend, defaults: defaults)
        if !folders.isEmpty { try await service.loadFolders() }
        return (service, provider, backend, defaults)
    }

    private func folder(_ id: String, _ distinguished: String?) -> MailFolder {
        MailFolder(id: id, distinguishedID: distinguished, displayName: id, parentID: nil, unreadCount: 0, totalCount: 1, childFolderCount: 0)
    }

    func testThreadOpenedFromDeletedItemsKeepsThatFolderAndSkipsTheCache() async throws {
        let (service, provider, backend, _) = try await makeService(folders: [folder("INBOX", "inbox"), folder("DEL", "deleteditems")])
        _ = backend
        await provider.setThread(MailThread(id: "C", messages: [MailFixtures.message("m", conversation: "C")], totalMessageCount: 1))
        _ = try await service.thread("C")
        let normal = await provider.lastIgnoredFolders
        XCTAssertEqual(normal, ["DEL"])
        let cached = service.cachedThreadCount
        _ = try await service.thread("C", useCache: false, includingDeleted: true)
        let fromDeleted = await provider.lastIgnoredFolders
        XCTAssertEqual(fromDeleted, [])
        XCTAssertEqual(service.cachedThreadCount, cached, "the deleted-items shape is not cached")
    }

    func testPanelRetriesOnNextLookAfterAFailure() async throws {
        let (service, provider, backend, _) = try await makeService()
        _ = backend
        await provider.setConversations([MailFixtures.conversation("c1")])
        await provider.setFailure(URLError(.timedOut))
        await service.refreshPanelList()
        XCTAssertTrue(service.panelListFailed)
        await provider.setFailure(nil)
        await service.refreshPanelList()
        XCTAssertEqual(service.panelList.map(\.id), ["c1"], "a failed load does not hold the next one back for 30 s")
    }

    func testBlockedPanelMakesNoRequestAndIsNotAFailure() async throws {
        let (service, provider, backend, _) = try await makeService()
        backend.isMailBlocked = true
        await service.refreshPanelList(minInterval: 0)
        XCTAssertTrue(service.isBlocked)
        XCTAssertFalse(service.panelListFailed)
        let lists = await provider.calls.filter { $0.hasPrefix("conversations") }
        XCTAssertTrue(lists.isEmpty)
    }

    func testClearedSearchResultsDoNotReplaceTheFolderSnapshot() async throws {
        let (service, provider, backend, defaults) = try await makeService()
        _ = backend
        await provider.setConversations([MailFixtures.conversation("inbox1"), MailFixtures.conversation("inbox2")])
        let model = MailWindowModel(service: service, defaults: defaults)
        await model.reloadList()
        XCTAssertEqual(model.conversations.map(\.id), ["inbox1", "inbox2"])

        await provider.setSearchPages([MailSearchPage(conversations: [MailFixtures.conversation("found")], moreAvailable: false, searchTerms: [], refiners: [], offset: 0)])
        model.searchFilters.text = "report"
        await model.submitSearch()
        XCTAssertEqual(model.conversations.map(\.id), ["found"])

        model.clearSearch()
        await model.markRead(model.conversations, true)   // a change made before the folder reloads
        await provider.setFailure(URLError(.notConnectedToInternet))
        await model.reloadList()
        XCTAssertEqual(model.conversations.map(\.id), ["inbox1", "inbox2"], "the snapshot is still the folder's")
        XCTAssertNotNil(model.staleList)
    }
}


@MainActor
final class MailThreadInlineImageTests: XCTestCase {
    private func message(_ id: String, body: String, attachments: [MailAttachmentInfo]) -> MailMessage {
        MailMessage(
            ref: MailItemRef(id: id, changeKey: "CK"), conversationID: "C1", parentFolderID: "INBOX", kind: .note,
            subject: "Subject", from: MailAddress(name: "Grace Miller", email: "g.miller@example.com"), to: [], cc: [], bcc: [],
            hiddenRecipientCount: 0, received: Date(), sent: Date(), isRead: true, isDraft: false, importance: .normal,
            bodyHTML: body, preview: "Hello", attachments: attachments, categories: [], isFlagged: false,
            actions: [.reply, .replyAll, .forward], meeting: nil, internetMessageID: nil
        )
    }

    /// The conversation leaves out an older message's inline attachments: the message is read on
    /// its own and its screenshot shows instead of OWA's blank pixel.
    func testMissingInlineAttachmentsAreReadFromTheItem() async throws {
        let defaults = UserDefaults(suiteName: "inline-\(UUID().uuidString)")!
        var settings = MailSettings()
        settings.enabled = true
        settings.save(to: defaults)
        let provider = FakeMailProvider(account: MailFixtures.account)
        let body = #"<p>RAM</p><img originalsrc="cid:shot@01" src="data:image/gif;base64,R0lGOD">"#
        let inThread = message("M1", body: body, attachments: [])
        let attachment = MailAttachmentInfo(id: "A1", name: "image001.png", contentType: "image/png", size: 1, isInline: true, contentID: "shot@01", isItemAttachment: false)
        await provider.setThread(MailThread(id: "C1", messages: [inThread], totalMessageCount: 1))
        await provider.setFullMessage(message("M1", body: body, attachments: [attachment]))
        let backend = FakeMailBackend(provider: provider)
        let service = MailService(backend: backend, defaults: defaults)
        let model = MailWindowModel(service: service, defaults: defaults)

        await model.openConversation("C1")
        XCTAssertNil(model.threadError)
        for _ in 0..<200 where model.inlineImages["M1"]?.isEmpty ?? true {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(model.inlineImages["M1"]?["shot@01"]?.data, Data("x".utf8))
        XCTAssertTrue(model.document(for: inThread).contains(#"src="data:image/png;base64,eA==""#))
        let calls = await provider.calls
        XCTAssertTrue(calls.contains("message") && calls.contains("attachment"), "\(calls)")
        withExtendedLifetime(backend) {}
    }
}
