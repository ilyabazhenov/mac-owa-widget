import XCTest
@testable import OWAWidget

/// The `error_code` contract: stable snake_case values, listed for every tool, every listed code
/// reachable, and errors from Exchange sorted into the right code.
@MainActor
final class MCPErrorCodeTests: XCTestCase {
    private var allTools: [MCPToolDefinition] {
        MCPToolRegistry.tools(mailRead: true, mailSend: true, mailOrganize: true, mailArrange: true)
    }

    func testCodesAreStableSnakeCase() {
        let values = MCPErrorCode.allCases.map(\.rawValue)
        XCTAssertEqual(Set(values).count, values.count)
        for value in values {
            XCTAssertNotNil(value.range(of: #"^[a-z]+(_[a-z]+)*$"#, options: .regularExpression), value)
        }
        // The contract with clients: these names never change.
        XCTAssertEqual(MCPErrorCode.settingDisabled.rawValue, "setting_disabled")
        XCTAssertEqual(MCPErrorCode.confirmationTimeout.rawValue, "confirmation_timeout")
        XCTAssertEqual(MCPErrorCode.noArchiveFolder.rawValue, "no_archive_folder")
    }

    func testEveryToolListsItsCodesInItsDescription() throws {
        XCTAssertTrue(allTools.contains { $0.name == "get_changes" }, "get_changes is in the list")
        for tool in allTools {
            let codes = MCPToolErrorCodes.codes(for: tool.name)
            XCTAssertEqual(Array(codes.prefix(3)), MCPToolErrorCodes.gate, tool.name)
            let description = try XCTUnwrap(tool.json["description"]?.stringValue)
            for code in codes {
                XCTAssertTrue(description.contains("`\(code.rawValue)`"), "\(tool.name) lists \(code.rawValue)")
            }
            if MCPMailTools.toolNames.contains(tool.name) {
                XCTAssertTrue(codes.contains(.mailNotAllowed), tool.name)
            }
        }
    }

    func testEveryCodeBelongsToSomeTool() {
        let listed = Set(allTools.flatMap { MCPToolErrorCodes.codes(for: $0.name) })
        XCTAssertEqual(Set(MCPErrorCode.allCases).subtracting(listed), [])
    }

    func testToolsThatChangeSomethingListTheirOwnCodes() {
        let respond = MCPToolErrorCodes.codes(for: "respond_to_meeting")
        for code in [MCPErrorCode.settingDisabled, .notInvitation, .pastEvent, .stale, .userDeclined, .confirmationTimeout, .busy, .unconfirmed] {
            XCTAssertTrue(respond.contains(code), code.rawValue)
        }
        let move = MCPToolErrorCodes.codes(for: "move_mail")
        XCTAssertTrue(move.contains(.forbiddenFolder))
        XCTAssertTrue(move.contains(.noArchiveFolder))
        XCTAssertFalse(MCPToolErrorCodes.codes(for: "list_events").contains(.userDeclined), "no panel, no decline")
        XCTAssertTrue(MCPToolErrorCodes.descriptionSuffix(for: "set_mail_flag").contains("Each `failed` entry carries `code`"))
        XCTAssertFalse(MCPToolErrorCodes.descriptionSuffix(for: "list_mail").contains("`failed`"))
    }

    func testGateRefusalsCarryTheirCodes() {
        XCTAssertEqual(MCPServerService.Refusal.serverDisabled.code, .serverDisabled)
        XCTAssertEqual(MCPServerService.Refusal.unidentified.code, .clientNotApproved)
        XCTAssertEqual(MCPServerService.Refusal.denied.code, .clientNotApproved)
        XCTAssertEqual(MCPServerService.Refusal.waiting.code, .approvalPending)
        XCTAssertEqual(MCPServerService.Refusal.mailDenied.code, .mailNotAllowed)
        XCTAssertEqual(MCPServerService.Refusal.mailWaiting.code, .approvalPending)
        let mailOff = MCPToolError.settingOff(.readMail, "off", code: .mailNotAllowed)
        XCTAssertEqual(mailOff.code, .mailNotAllowed)
        XCTAssertEqual(mailOff.setting, .readMail)
    }

    func testExchangeErrorsSortIntoCodes() {
        let cases: [(Error, Bool, MCPErrorCode)] = [
            (URLError(.notConnectedToInternet), false, .offline),
            (URLError(.cannotFindHost), true, .offline),
            (URLError(.timedOut), false, .offline),
            (URLError(.timedOut), true, .unconfirmed),
            (URLError(.networkConnectionLost), true, .unconfirmed),
            (URLError(.serverCertificateUntrusted), false, .trustRequired),
            (URLError(.badServerResponse), false, .exchangeError),
            (URLError(.badServerResponse), true, .unconfirmed),
            (OWAError.authenticationFailed("no"), false, .authFailed),
            (OWAError.notAuthenticated, true, .authFailed),
            (OWAError.ewsError("ErrorIrresolvableConflict"), true, .stale),
            (OWAError.ewsError("ErrorItemNotFound"), false, .notFound),
            (OWAError.ewsError("ErrorAccessDenied"), false, .exchangeError),
            (MailError.notFound, false, .notFound),
            (MailError.sendUncertain, true, .unconfirmed),
            (MailError.serverError("ErrorServerBusy"), false, .exchangeError),
            (MailError.blocked("paused"), false, .authFailed),
            (CancellationError(), true, .cancelled),
            (MCPToolError(.busy, "busy"), false, .busy),
        ]
        for (error, sent, code) in cases {
            XCTAssertEqual(MCPToolError.code(for: error, mayHaveBeenSent: sent), code, "\(error) sent=\(sent)")
        }
    }

    func testAppendingKeepsTheCodeAndTheSetting() {
        let error = MCPToolError.settingOff(.arrangeMail, "Off.").appending(" Nothing was moved.")
        XCTAssertEqual(error.code, .settingDisabled)
        XCTAssertEqual(error.setting, .arrangeMail)
        XCTAssertEqual(error.message, "Off. Nothing was moved.")
        XCTAssertNotNil(error.settingTitle)
    }

    func testRateLimitIsItsOwnCode() {
        XCTAssertEqual(MCPAccessGuard.Denial.rateLimited.error.code, .rateLimited)
        XCTAssertEqual(MCPAccessGuard.Denial.blocked(MCPToolError(.authFailed, "x")).error.code, .authFailed)
    }
}
