import XCTest
@testable import OWAWidget

final class MCPProtocolHandlerTests: XCTestCase {
    private let handler = MCPProtocolHandler(
        serverName: "owa-widget",
        serverTitle: "OWA Widget",
        serverVersion: "1.0.0",
        instructions: "Read-only calendar.",
        tools: [
            MCPToolDefinition(name: "b_tool", title: "B", description: "b", inputSchema: ["type": "object"]),
            MCPToolDefinition(name: "a_tool", title: "A", description: "a", inputSchema: ["type": "object"]),
        ]
    )

    private let modernMeta: JSONValue = [
        "io.modelcontextprotocol/protocolVersion": "2026-07-28",
        "io.modelcontextprotocol/clientCapabilities": [:],
    ]

    private func request(_ id: Int, _ method: String, _ params: JSONValue = [:]) -> JSONValue {
        ["jsonrpc": "2.0", "id": .int(Int64(id)), "method": .string(method), "params": params]
    }

    private func reply(_ dispatch: MCPDispatch, file: StaticString = #filePath, line: UInt = #line) -> JSONValue {
        guard case .reply(let value) = dispatch else {
            XCTFail("expected a reply, got \(dispatch)", file: file, line: line)
            return .null
        }
        return value
    }

    // MARK: - Legacy

    func testInitializeEchoesSupportedLegacyVersion() {
        var session = MCPSessionState()
        let response = reply(handler.handle(request(1, "initialize", ["protocolVersion": "2025-06-18"]), session: &session))

        XCTAssertEqual(response["result"]?["protocolVersion"], "2025-06-18")
        XCTAssertEqual(response["result"]?["instructions"], "Read-only calendar.")
        XCTAssertEqual(session.era, .legacy(version: "2025-06-18"))
    }

    func testInitializeWithUnknownVersionGetsNewestLegacyNeverModern() {
        var session = MCPSessionState()
        for requested in ["2024-11-05", "2026-07-28", "garbage"] {
            let response = reply(handler.handle(request(1, "initialize", ["protocolVersion": .string(requested)]), session: &session))
            XCTAssertEqual(response["result"]?["protocolVersion"], "2025-11-25", requested)
        }
    }

    func testLegacyToolsListHasNoModernFields() {
        var session = MCPSessionState(era: .legacy(version: "2025-11-25"))
        let result = reply(handler.handle(request(2, "tools/list"), session: &session))["result"]

        XCTAssertEqual(result?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue }, ["b_tool", "a_tool"])
        XCTAssertNil(result?["resultType"])
        XCTAssertNil(result?["ttlMs"])
        XCTAssertEqual(result?["tools"]?.arrayValue?.first?["annotations"]?["readOnlyHint"], true)
    }

    func testPingAndInitializedNotification() {
        var session = MCPSessionState(era: .legacy(version: "2025-11-25"))
        XCTAssertEqual(reply(handler.handle(request(3, "ping"), session: &session))["result"], [:])
        XCTAssertEqual(handler.handle(["jsonrpc": "2.0", "method": "notifications/initialized"], session: &session), MCPDispatch.none)
    }

    // MARK: - Modern

    func testDiscoverCarriesEveryRequiredField() {
        var session = MCPSessionState()
        let result = reply(handler.handle(request(1, "server/discover", ["_meta": modernMeta]), session: &session))["result"]

        XCTAssertEqual(result?["resultType"], "complete")
        XCTAssertEqual(result?["supportedVersions"], ["2026-07-28"])
        XCTAssertNotNil(result?["capabilities"]?["tools"])
        XCTAssertEqual(result?["instructions"], "Read-only calendar.")
        XCTAssertNotNil(result?["ttlMs"])
        XCTAssertEqual(result?["cacheScope"], "private")
        XCTAssertEqual(result?["_meta"]?["io.modelcontextprotocol/serverInfo"]?["name"], "owa-widget")
    }

    func testModernToolsListIsCacheable() {
        var session = MCPSessionState()
        let result = reply(handler.handle(request(2, "tools/list", ["_meta": modernMeta]), session: &session))["result"]

        XCTAssertEqual(result?["resultType"], "complete")
        XCTAssertEqual(result?["ttlMs"], .int(MCPProtocolHandler.toolsListTTLMilliseconds))
        XCTAssertEqual(result?["cacheScope"], "private")
    }

    func testUnsupportedModernVersion() {
        var session = MCPSessionState()
        let meta: JSONValue = ["io.modelcontextprotocol/protocolVersion": "2030-01-01", "io.modelcontextprotocol/clientCapabilities": [:]]
        let error = reply(handler.handle(request(4, "tools/list", ["_meta": meta]), session: &session))["error"]

        XCTAssertEqual(error?["code"], .int(Int64(JSONRPCErrorCode.unsupportedProtocolVersion)))
        XCTAssertEqual(error?["data"]?["requested"], "2030-01-01")
        XCTAssertEqual(error?["data"]?["supported"]?.arrayValue?.first, "2026-07-28")
    }

    func testModernRequestWithoutCapabilitiesIsInvalidParams() {
        var session = MCPSessionState()
        let meta: JSONValue = ["io.modelcontextprotocol/protocolVersion": "2026-07-28"]
        let error = reply(handler.handle(request(5, "tools/list", ["_meta": meta]), session: &session))["error"]
        XCTAssertEqual(error?["code"], .int(Int64(JSONRPCErrorCode.invalidParams)))
    }

    func testRequestWithoutHandshakeOrMetaNamesSupportedVersions() {
        var session = MCPSessionState()
        let error = reply(handler.handle(request(6, "tools/call", ["name": "a_tool"]), session: &session))["error"]

        XCTAssertEqual(error?["code"], .int(Int64(JSONRPCErrorCode.invalidParams)))
        XCTAssertTrue(error?["message"]?.stringValue?.contains("2026-07-28") == true)
        XCTAssertTrue(error?["message"]?.stringValue?.contains("2025-11-25") == true)
    }

    // MARK: - Tool calls

    func testToolCallIsHandedBack() {
        var session = MCPSessionState()
        let dispatch = handler.handle(request(7, "tools/call", ["name": "a_tool", "arguments": ["x": 1], "_meta": modernMeta]), session: &session)
        XCTAssertEqual(dispatch, .callTool(id: 7, name: "a_tool", arguments: ["x": 1], modern: true))
    }

    func testUnknownToolAndBadArguments() {
        var session = MCPSessionState(era: .legacy(version: "2025-11-25"))
        let unknown = reply(handler.handle(request(8, "tools/call", ["name": "nope"]), session: &session))
        XCTAssertEqual(unknown["error"]?["code"], .int(Int64(JSONRPCErrorCode.invalidParams)))

        let bad = reply(handler.handle(request(9, "tools/call", ["name": "a_tool", "arguments": "x"]), session: &session))
        XCTAssertEqual(bad["error"]?["code"], .int(Int64(JSONRPCErrorCode.invalidParams)))
    }

    func testUnknownMethod() {
        var session = MCPSessionState(era: .legacy(version: "2025-11-25"))
        let error = reply(handler.handle(request(10, "prompts/list"), session: &session))["error"]
        XCTAssertEqual(error?["code"], .int(Int64(JSONRPCErrorCode.methodNotFound)))
    }

    // MARK: - Change resource

    func testBothErasAdvertiseTheSubscribableResource() {
        var legacy = MCPSessionState()
        let initialize = reply(handler.handle(request(1, "initialize", ["protocolVersion": "2025-11-25"]), session: &legacy))
        XCTAssertEqual(initialize["result"]?["capabilities"]?["resources"]?["subscribe"], true)
        var modern = MCPSessionState()
        let discover = reply(handler.handle(request(1, "server/discover", ["_meta": modernMeta]), session: &modern))
        XCTAssertEqual(discover["result"]?["capabilities"]?["resources"]?["subscribe"], true)
        // The mail tools come and go with their switches, and both eras are told when.
        XCTAssertEqual(initialize["result"]?["capabilities"]?["tools"]?["listChanged"], true)
        XCTAssertEqual(discover["result"]?["capabilities"]?["tools"]?["listChanged"], true)
    }

    func testEveryLegacyVersionSubscribes() {
        for version in MCPProtocolHandler.legacyVersions {
            var session = MCPSessionState()
            let initialize = reply(handler.handle(request(1, "initialize", ["protocolVersion": .string(version)]), session: &session))
            XCTAssertEqual(initialize["result"]?["protocolVersion"], .string(version))
            XCTAssertEqual(initialize["result"]?["capabilities"]?["resources"]?["subscribe"], true, version)
            XCTAssertEqual(handler.handle(request(2, "resources/subscribe", ["uri": .string(MCPChangeResource.uri)]), session: &session), .subscribe(id: 2), version)
            XCTAssertEqual(handler.handle(request(3, "resources/unsubscribe", ["uri": .string(MCPChangeResource.uri)]), session: &session), .unsubscribe(id: 3), version)
            let unknown = reply(handler.handle(request(4, "resources/subscribe", ["uri": "x://y"]), session: &session))["error"]
            XCTAssertEqual(unknown?["code"], .int(Int64(JSONRPCErrorCode.resourceNotFound)), version)
        }
        XCTAssertTrue(MCPProtocolHandler.legacyVersions.contains("2025-06-18"))
        let ring = handler.resourceUpdated(subscriptionID: nil)
        XCTAssertEqual(ring["params"], ["uri": .string(MCPChangeResource.uri)])
    }

    func testResourcesListAndRead() {
        var legacy = MCPSessionState(era: .legacy(version: "2025-11-25"))
        let list = reply(handler.handle(request(2, "resources/list"), session: &legacy))["result"]
        XCTAssertEqual(list?["resources"]?.arrayValue?.first?["uri"]?.stringValue, MCPChangeResource.uri)
        XCTAssertNil(list?["ttlMs"])
        let read = reply(handler.handle(request(3, "resources/read", ["uri": .string(MCPChangeResource.uri)]), session: &legacy))["result"]
        XCTAssertEqual(read?["contents"]?.arrayValue?.first?["uri"]?.stringValue, MCPChangeResource.uri)
        let unknown = reply(handler.handle(request(4, "resources/read", ["uri": "file:///etc/passwd"]), session: &legacy))["error"]
        XCTAssertEqual(unknown?["code"], .int(Int64(JSONRPCErrorCode.resourceNotFound)))

        var modern = MCPSessionState()
        let modernList = reply(handler.handle(request(5, "resources/list", ["_meta": modernMeta]), session: &modern))["result"]
        XCTAssertEqual(modernList?["resultType"], "complete")
        XCTAssertNotNil(modernList?["ttlMs"])
        XCTAssertEqual(modernList?["cacheScope"], "private")
        let modernUnknown = reply(handler.handle(request(6, "resources/read", ["_meta": modernMeta, "uri": "x://y"]), session: &modern))["error"]
        XCTAssertEqual(modernUnknown?["code"], .int(Int64(JSONRPCErrorCode.invalidParams)), "2026-07-28 must not emit -32002")
    }

    func testLegacySubscribeAndModernListen() {
        var legacy = MCPSessionState(era: .legacy(version: "2025-11-25"))
        XCTAssertEqual(handler.handle(request(7, "resources/subscribe", ["uri": .string(MCPChangeResource.uri)]), session: &legacy), .subscribe(id: 7))
        XCTAssertEqual(handler.handle(request(8, "resources/unsubscribe", ["uri": .string(MCPChangeResource.uri)]), session: &legacy), .unsubscribe(id: 8))
        XCTAssertEqual(reply(handler.handle(request(9, "subscriptions/listen", ["notifications": [:]]), session: &legacy))["error"]?["code"],
                       .int(Int64(JSONRPCErrorCode.methodNotFound)))

        var modern = MCPSessionState()
        let listen = request(10, "subscriptions/listen", ["_meta": modernMeta, "notifications": ["resourceSubscriptions": [.string(MCPChangeResource.uri)], "toolsListChanged": true]])
        XCTAssertEqual(handler.handle(listen, session: &modern), .listen(id: 10, filter: MCPListenFilter(changes: true, toolsListChanged: true)))
        let changesOnly = request(13, "subscriptions/listen", ["_meta": modernMeta, "notifications": ["resourceSubscriptions": [.string(MCPChangeResource.uri)]]])
        XCTAssertEqual(handler.handle(changesOnly, session: &modern), .listen(id: 13, filter: MCPListenFilter(changes: true, toolsListChanged: false)))
        let toolsOnly = request(11, "subscriptions/listen", ["_meta": modernMeta, "notifications": ["toolsListChanged": true]])
        XCTAssertEqual(handler.handle(toolsOnly, session: &modern), .listen(id: 11, filter: MCPListenFilter(changes: false, toolsListChanged: true)))
        let nothingOurs = request(14, "subscriptions/listen", ["_meta": modernMeta, "notifications": ["resourceSubscriptions": ["x://y"], "promptsListChanged": true]])
        XCTAssertEqual(reply(handler.handle(nothingOurs, session: &modern))["error"]?["code"], .int(Int64(JSONRPCErrorCode.invalidParams)))
        let removed = request(12, "resources/subscribe", ["_meta": modernMeta, "uri": .string(MCPChangeResource.uri)])
        XCTAssertEqual(reply(handler.handle(removed, session: &modern))["error"]?["code"], .int(Int64(JSONRPCErrorCode.methodNotFound)),
                       "2026-07-28 replaced resources/subscribe with subscriptions/listen")
    }

    func testListenAcknowledgmentAndUpdatesCarryTheSubscriptionID() {
        let ack = handler.listenAcknowledgment(id: 10, filter: MCPListenFilter(changes: true, toolsListChanged: false))
        XCTAssertEqual(ack["method"], "notifications/subscriptions/acknowledged")
        XCTAssertNil(ack["id"], "a notification, not the answer")
        XCTAssertEqual(ack["params"]?["_meta"]?[MCPProtocolHandler.subscriptionIDKey], 10)
        XCTAssertEqual(ack["params"]?["notifications"], ["resourceSubscriptions": [.string(MCPChangeResource.uri)]],
                       "only what was asked for and this server honours")
        let both = handler.listenAcknowledgment(id: 11, filter: MCPListenFilter(changes: true, toolsListChanged: true))
        XCTAssertEqual(both["params"]?["notifications"], ["resourceSubscriptions": [.string(MCPChangeResource.uri)], "toolsListChanged": true])
        let toolsOnly = handler.listenAcknowledgment(id: 12, filter: MCPListenFilter(changes: false, toolsListChanged: true))
        XCTAssertEqual(toolsOnly["params"]?["notifications"], ["toolsListChanged": true])

        let listChanged = handler.toolsListChanged(subscriptionID: 11)
        XCTAssertEqual(listChanged["method"], "notifications/tools/list_changed")
        XCTAssertNil(listChanged["id"])
        XCTAssertEqual(listChanged["params"]?["_meta"]?[MCPProtocolHandler.subscriptionIDKey], 11)
        XCTAssertNil(handler.toolsListChanged(subscriptionID: nil)["params"], "legacy: no params at all")

        let modern = handler.resourceUpdated(subscriptionID: 10)
        XCTAssertEqual(modern["method"], "notifications/resources/updated")
        XCTAssertEqual(modern["params"]?["uri"]?.stringValue, MCPChangeResource.uri)
        XCTAssertEqual(modern["params"]?["_meta"]?[MCPProtocolHandler.subscriptionIDKey], 10)
        XCTAssertNil(handler.resourceUpdated(subscriptionID: nil)["params"]?["_meta"])
    }

    func testCancellationNotification() {
        var session = MCPSessionState()
        let dispatch = handler.handle(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 7]], session: &session)
        XCTAssertEqual(dispatch, .cancel(requestID: 7))
    }

    func testToolResultShapes() {
        let success = MCPToolResult.success(["count": 2])
        let modern = handler.toolCallResponse(id: 1, result: success, modern: true)["result"]
        XCTAssertEqual(modern?["structuredContent"], ["count": 2])
        XCTAssertEqual(modern?["content"]?.arrayValue?.first?["text"], #"{"count":2}"#)
        XCTAssertEqual(modern?["isError"], false)
        XCTAssertEqual(modern?["resultType"], "complete")

        let legacy = handler.toolCallResponse(id: 1, result: .failure(.stale, "nope"), modern: false)["result"]
        XCTAssertEqual(legacy?["isError"], true)
        XCTAssertEqual(legacy?["content"]?.arrayValue?.first?["text"], "nope", "the text stays what the model reads")
        XCTAssertEqual(legacy?["structuredContent"], ["error_code": "stale", "message": "nope"])
        XCTAssertNil(legacy?["resultType"])

        let modernFailure = handler.toolCallResponse(id: 1, result: .failure(.invalidArgument, "bad"), modern: true)["result"]
        XCTAssertEqual(modernFailure?["structuredContent"]?["error_code"], "invalid_argument")
        XCTAssertEqual(modernFailure?["isError"], true)
    }
}
