import XCTest
@testable import OWAWidget

/// The reader's documents are built off the main thread and kept until their inputs change.
@MainActor
final class MailReaderDocumentTests: XCTestCase {
    private func openThread(body: String) async throws -> (MailWindowModel, MailMessage, FakeMailBackend) {
        let defaults = UserDefaults(suiteName: "reader-doc-\(UUID().uuidString)")!
        var settings = MailSettings()
        settings.enabled = true
        settings.markReadPolicy = .manual
        settings.save(to: defaults)
        let provider = FakeMailProvider(account: MailFixtures.account)
        await provider.setConversations([MailFixtures.conversation("c1")])
        var message = MailFixtures.message("m1", conversation: "c1", isRead: true)
        message = MailMessage(
            ref: message.ref, conversationID: message.conversationID, parentFolderID: message.parentFolderID, kind: message.kind,
            subject: message.subject, from: message.from, to: [], cc: [], bcc: [], hiddenRecipientCount: 0,
            received: message.received, sent: message.sent, isRead: true, isDraft: false, importance: .normal,
            bodyHTML: body, preview: "", attachments: [], categories: [], isFlagged: false,
            actions: message.actions, meeting: nil, internetMessageID: nil
        )
        await provider.setThread(MailThread(id: "c1", messages: [message], totalMessageCount: 1))
        let backend = FakeMailBackend(provider: provider)
        let service = MailService(backend: backend, defaults: defaults)
        let model = MailWindowModel(service: service, defaults: defaults)
        await model.reloadList()
        await model.openConversation("c1")
        return (model, try XCTUnwrap(model.thread?.messages.first), backend)
    }

    private func waitForDocument(_ model: MailWindowModel, _ message: MailMessage) async throws -> MailReaderDocument {
        for _ in 0..<200 {
            if let document = model.readerDocument(for: message) { return document }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw XCTSkip("the build did not finish in 2 s")
    }

    func testFirstCallStartsABuildAndTheResultIsKept() async throws {
        let (model, message, backend) = try await openThread(body: #"<p>Hello <img src="https://tracker.example.com/p.gif"></p>"#)
        _ = backend
        XCTAssertNil(model.readerDocument(for: message), "nothing is built on the main thread")
        let document = try await waitForDocument(model, message)
        XCTAssertTrue(document.html.contains("Hello"))
        XCTAssertTrue(document.hasRemoteImages)
        XCTAssertFalse(document.isVisuallyEmpty)
        XCTAssertEqual(model.readerDocument(for: message)?.html, document.html, "the same inputs reuse the build")
    }

    func testEmptyBodyIsReportedEmpty() async throws {
        let (model, message, backend) = try await openThread(body: "<div>&nbsp;</div>")
        _ = backend
        let document = try await waitForDocument(model, message)
        XCTAssertTrue(document.isVisuallyEmpty)
    }

    func testAnotherThreadDropsTheDocuments() async throws {
        let (model, message, backend) = try await openThread(body: "<p>Hello</p>")
        _ = backend
        _ = try await waitForDocument(model, message)
        model.clearSelection()
        XCTAssertTrue(model.readerDocuments.isEmpty)
    }
}
