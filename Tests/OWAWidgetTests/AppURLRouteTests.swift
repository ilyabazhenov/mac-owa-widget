import XCTest
@testable import OWAWidget

/// `owawidget://` links: what they parse to, what they open, and the mail window following one.
final class AppURLRouteTests: XCTestCase {
    /// An Exchange id as OWA gives it: base64 with `+`, `/` and `=`.
    private let exchangeID = "AAMkADk2ZjE+NmQ0LWE3/2ItNDk1ZC04OTJjLTQ1ZWI3YzE4ZGY3ZQBGAAAAAAB=="
    private let accountID = UUID(uuidString: "6F1C2B3A-1111-4222-8333-944455556666")!

    private func parse(_ string: String) -> AppURLRoute? {
        URL(string: string).flatMap(AppURLRoute.parse)
    }

    func testParsesTheThreeRoutes() {
        XCTAssertEqual(parse("owawidget://mail"), .mail)
        XCTAssertEqual(parse("owawidget://mail/"), .mail)
        XCTAssertEqual(parse("OWAWidget://MAIL"), .mail, "scheme and host are case-insensitive")
        XCTAssertEqual(parse("owawidget://thread?id=0123456789ab"), .thread(id: "0123456789ab", accountID: nil))
        XCTAssertEqual(
            parse("owawidget://message?id=0123456789ab&account=\(accountID.uuidString)"),
            .message(id: "0123456789ab", accountID: accountID)
        )
        XCTAssertEqual(parse("owawidget-dev://mail"), .mail, "a development build's links")
    }

    func testRefusesAnythingElse() {
        let refused = [
            "https://mail",
            "owawidget://compose?to=a@example.com",
            "owawidget://send",
            "owawidget://message",
            "owawidget://message?id=",
            "owawidget://message?id=abc%20def",
            "owawidget://message?id=abc<script>",
            "owawidget://message?id=a&id=b",
            "owawidget://message?id=abc&account=not-a-uuid",
            "owawidget://message?id=abc&account=",
            "owawidget://thread/extra?id=abc",
            "owawidget://user:pass@mail",
            "owawidget://mail:8080",
            "owawidget://message?id=" + String(repeating: "A", count: AppURLRoute.maxIDLength + 1),
        ]
        for string in refused {
            XCTAssertNil(parse(string), string)
        }
    }

    func testUnknownParametersAreIgnored() {
        XCTAssertEqual(parse("owawidget://thread?id=abc&utm_source=note"), .thread(id: "abc", accountID: nil))
    }

    /// `+` in a query would read as a space and `=`/`/` as separators: the link encodes them.
    func testExchangeIDSurvivesTheRoundTrip() throws {
        let route = AppURLRoute.message(id: exchangeID, accountID: accountID)
        let url = try XCTUnwrap(route.url(scheme: "owawidget"))
        XCTAssertFalse(url.absoluteString.contains("+"))
        XCTAssertTrue(url.absoluteString.hasPrefix("owawidget://message?id=AAMkADk2ZjE%2BNmQ0"))
        XCTAssertEqual(AppURLRoute.parse(url), route)
        XCTAssertEqual(AppURLRoute.mail.url(scheme: "owawidget-dev")?.absoluteString, "owawidget-dev://mail")
    }

    func testSchemeComesFromTheBundle() {
        func info(_ scheme: String) -> [String: Any] {
            ["CFBundleURLTypes": [["CFBundleURLName": "links", "CFBundleURLSchemes": [scheme]]]]
        }
        XCTAssertEqual(AppURLRoute.scheme(fromInfo: info("owawidget-dev")), "owawidget-dev")
        XCTAssertEqual(AppURLRoute.scheme(fromInfo: info("owawidget")), "owawidget")
        XCTAssertEqual(AppURLRoute.scheme(fromInfo: info("somethingelse")), "owawidget")
        XCTAssertEqual(AppURLRoute.scheme(fromInfo: nil), "owawidget")
    }

    // MARK: - What a link opens

    private func decide(_ route: AppURLRoute, enabled: Bool = true, account: UUID? = nil, known: [String: String] = [:]) -> AppURLAction {
        AppURLAction.decide(route, mailEnabled: enabled, windowAccountID: account ?? accountID, resolve: { known[$0] })
    }

    func testOpensWhatTheLinkNames() {
        XCTAssertEqual(decide(.mail), .openMail)
        XCTAssertEqual(decide(.message(id: exchangeID, accountID: nil)), .openMessage(exchangeID), "a full id needs no lookup")
        XCTAssertEqual(decide(.thread(id: "0123456789ab", accountID: accountID), known: ["0123456789ab": exchangeID]), .openThread(exchangeID))
    }

    func testMailOffOrNoAccountOpensNothing() {
        if case .ignore = decide(.mail, enabled: false) {} else { XCTFail("mail off: nothing opens") }
        let none = AppURLAction.decide(.mail, mailEnabled: true, windowAccountID: nil, resolve: { _ in nil })
        if case .ignore = none {} else { XCTFail("no account: nothing opens") }
    }

    func testUnknownShortIDOrOtherAccountShowsANotice() {
        XCTAssertEqual(decide(.message(id: "0123456789ab", accountID: nil)), .notice(.linkNotFound), "a short id from before a restart")
        XCTAssertEqual(decide(.thread(id: exchangeID, accountID: UUID())), .notice(.linkOtherAccount))
    }
}

/// The mail window following a link to one message.
@MainActor
final class MailOpenMessageLinkTests: XCTestCase {
    /// `MailService` holds its backend weakly: the test keeps it alive.
    private var backend: FakeMailBackend?

    private func makeModel() async throws -> (MailWindowModel, FakeMailProvider) {
        let defaults = UserDefaults(suiteName: "open-link-\(UUID().uuidString)")!
        var settings = MailSettings()
        settings.enabled = true
        settings.markReadPolicy = .manual
        settings.save(to: defaults)
        let provider = FakeMailProvider(account: MailFixtures.account)
        await provider.setConversations([MailFixtures.conversation("c1")])
        let newest = MailFixtures.message("m2", conversation: "c1", isRead: true)
        let older = MailFixtures.message("m1", conversation: "c1", isRead: true)
        await provider.setThread(MailThread(id: "c1", messages: [newest, older], totalMessageCount: 2))
        let backend = FakeMailBackend(provider: provider)
        self.backend = backend
        let service = MailService(backend: backend, defaults: defaults)
        let model = MailWindowModel(service: service, defaults: defaults)
        await model.reloadList()
        return (model, provider)
    }

    func testOpensTheConversationAtTheMessage() async throws {
        let (model, _) = try await makeModel()
        await model.openMessage("m1")
        XCTAssertEqual(model.thread?.id, "c1", model.threadError ?? "")
        XCTAssertTrue(model.expandedMessageIDs.contains("m1"), "the linked message is unfolded")
        XCTAssertTrue(model.expandedMessageIDs.contains("m2"), "the newest one too, as always")
        XCTAssertEqual(model.scrollTarget?.messageID, "m1")
    }

    /// Conversations leave out Deleted Items: such a message opens on its own.
    func testMessageMissingFromItsConversationOpensAlone() async throws {
        let (model, provider) = try await makeModel()
        await provider.setFullMessage(MailFixtures.message("m9", conversation: "c1", isRead: true))
        await model.openMessage("m9")
        XCTAssertEqual(model.thread?.id, "m9")
        XCTAssertEqual(model.thread?.messages.map(\.id), ["m9"])
    }

    func testUnknownMessageSaysSo() async throws {
        let (model, _) = try await makeModel()
        await model.openMessage("missing")
        XCTAssertNil(model.thread)
        XCTAssertNotNil(model.threadError)
        XCTAssertNil(model.scrollTarget)
    }

    func testOpeningAnotherConversationDropsTheScrollTarget() async throws {
        let (model, _) = try await makeModel()
        await model.openMessage("m1")
        await model.openConversation("c1", asMessage: false)
        XCTAssertNil(model.scrollTarget)
    }
}
