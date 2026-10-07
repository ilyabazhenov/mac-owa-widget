import Darwin
import XCTest
@testable import OWAWidgetMCPShared

final class MCPSocketPathTests: XCTestCase {
    func testPathIsShortAndUnderCaches() {
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        let url = MCPSocketPath.socketURL(bundleIdentifier: "com.owawidget.MacOwaWidget.dev", homeDirectory: home)

        XCTAssertTrue(url.path.hasPrefix("/Users/someone/Library/Caches/owawidget/mcp-"))
        XCTAssertTrue(url.path.hasSuffix(".sock"))
        // 50 bytes plus the user name: room for names up to ~50 characters.
        XCTAssertEqual(url.path.utf8.count, 50 + "someone".count)
        XCTAssertTrue(MCPSocketPath.fitsSocketAddress(url))
    }

    func testDevAndReleaseBuildsGetDifferentSockets() {
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        let release = MCPSocketPath.socketURL(bundleIdentifier: "com.owawidget.MacOwaWidget", homeDirectory: home)
        let dev = MCPSocketPath.socketURL(bundleIdentifier: "com.owawidget.MacOwaWidget.dev", homeDirectory: home)
        XCTAssertNotEqual(release, dev)
    }

    func testOverlongPathIsReported() {
        let home = URL(fileURLWithPath: "/Users/" + String(repeating: "x", count: 60), isDirectory: true)
        let url = MCPSocketPath.socketURL(bundleIdentifier: "com.owawidget.MacOwaWidget", homeDirectory: home)
        XCTAssertFalse(MCPSocketPath.fitsSocketAddress(url))
    }
}

final class MCPBridgeStateTests: XCTestCase {
    private func line(_ json: String) -> Data { Data(json.utf8) }

    private func object(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func testPendingRequestsGetErrorsWhenConnectionIsLost() {
        var state = MCPBridgeState()
        state.noteClientMessage(line(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{}}"#))
        state.noteClientMessage(line(#"{"jsonrpc":"2.0","id":"abc","method":"tools/list"}"#))
        state.noteClientMessage(line(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
        XCTAssertTrue(state.noteServerMessage(line(#"{"jsonrpc":"2.0","id":1,"result":{}}"#)))

        let errors = state.connectionLost(message: "gone")

        XCTAssertEqual(errors.count, 1)
        let error = object(errors[0])
        XCTAssertEqual(error["id"] as? String, "abc")
        XCTAssertEqual((error["error"] as? [String: Any])?["code"] as? Int, MCPBridgeState.connectionLostCode)
        XCTAssertTrue(state.inFlight.isEmpty)
    }

    func testNumericAndStringIDsStayDistinct() {
        var state = MCPBridgeState()
        state.noteClientMessage(line(#"{"jsonrpc":"2.0","id":5,"method":"tools/list"}"#))
        state.noteClientMessage(line(#"{"jsonrpc":"2.0","id":"5","method":"tools/list"}"#))
        _ = state.noteServerMessage(line(#"{"jsonrpc":"2.0","id":5,"result":{}}"#))
        XCTAssertEqual(state.inFlight, [#""5""#])
    }

    func testCancelledRequestIsNoLongerPending() {
        var state = MCPBridgeState()
        state.noteClientMessage(line(#"{"jsonrpc":"2.0","id":7,"method":"tools/call"}"#))
        state.noteClientMessage(line(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":7}}"#))
        XCTAssertTrue(state.connectionLost(message: "gone").isEmpty)
    }

    func testLegacyInitializeIsReplayedAndItsAnswerSwallowed() {
        var state = MCPBridgeState()
        state.noteClientMessage(line(#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}"#))
        _ = state.noteServerMessage(line(#"{"jsonrpc":"2.0","id":0,"result":{}}"#))

        let replay = state.replayLinesForNewConnection()
        XCTAssertEqual(replay.count, 1)
        let replayed = object(replay[0])
        XCTAssertEqual(replayed["method"] as? String, "initialize")
        let replayID = replayed["id"] as? String
        XCTAssertEqual(replayID?.hasPrefix(MCPBridgeState.replayIDPrefix), true)

        // The app's answer to the replay must not reach the client, which never sent it.
        let answer = #"{"jsonrpc":"2.0","id":"\#(replayID ?? "")","result":{}}"#
        XCTAssertFalse(state.noteServerMessage(line(answer)))
    }

    func testStatelessClientsNeedNoReplay() {
        var state = MCPBridgeState()
        state.noteClientMessage(line(#"{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{}}"#))
        XCTAssertTrue(state.replayLinesForNewConnection().isEmpty)
    }

    func testErrorLineForUnreachableApp() throws {
        let request = line(#"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#)
        let error = try XCTUnwrap(MCPBridgeState.errorLine(forRequest: request, code: -32000, message: "not \"running\""))
        let parsed = object(error)
        XCTAssertEqual(parsed["id"] as? Int, 3)
        XCTAssertEqual((parsed["error"] as? [String: Any])?["message"] as? String, "not \"running\"")
        // Notifications get no answer.
        XCTAssertNil(MCPBridgeState.errorLine(forRequest: line(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#), code: -32000, message: "x"))
    }

    func testHelloIsRecognisedOnlyWithItsMarker() {
        let hello = MCPBridgeHello(parentPID: 42, parentPath: "/Applications/Claude.app/Contents/MacOS/Claude")
        XCTAssertEqual(MCPBridgeHello.decode(hello.encodedLine()), hello)
        XCTAssertNil(MCPBridgeHello.decode(line(#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#)))
    }
}

final class MCPUnixSocketWriteTests: XCTestCase {
    /// The bridge's stdout: a pipe the client may close while an answer is on its way.
    /// `FileHandle.write(_:)` raised an uncatchable exception here and crashed the bridge.
    func testWriteToPipeWithClosedReaderFailsInsteadOfCrashing() {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        defer { close(fds[1]) }
        // The bridge ignores SIGPIPE process-wide; the test process must not die either.
        XCTAssertEqual(fcntl(fds[1], F_SETNOSIGPIPE, 1), 0)

        XCTAssertTrue(MCPUnixSocket.writeAll(fds[1], Data("first\n".utf8)))
        close(fds[0])

        XCTAssertFalse(MCPUnixSocket.writeAll(fds[1], Data(#"{"jsonrpc":"2.0","id":2,"result":{}}"#.utf8)))
        XCTAssertEqual(errno, EPIPE)
    }
}
