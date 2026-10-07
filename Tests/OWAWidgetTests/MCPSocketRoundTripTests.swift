import Darwin
import XCTest
@testable import OWAWidget
import OWAWidgetMCPShared

/// The listener, a connection and the protocol handler over a real Unix socket in a temp dir.
final class MCPSocketRoundTripTests: XCTestCase {
    private struct EchoToolbox: MCPToolProviding {
        var tools: [MCPToolDefinition] {
            [MCPToolDefinition(name: "echo", title: "Echo", description: "", inputSchema: ["type": "object"])]
        }

        func callTool(name: String, arguments: [String: JSONValue], client: String?) async -> MCPToolResult {
            .success(["arguments": .object(arguments), "client": .optional(client)])
        }
    }

    private var directory: URL!
    private var listener: MCPSocketListener?

    override func setUpWithError() throws {
        // Short on purpose: sun_path holds 103 bytes.
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mcp-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        listener?.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    private func startListener() throws -> String {
        let path = directory.appendingPathComponent("t.sock").path
        let handler = MCPProtocolHandler(serverName: "owa-widget", serverTitle: "OWA Widget", serverVersion: "test",
                                         instructions: "", tools: EchoToolbox().tools)
        let listener = MCPSocketListener(path: path) { channel in
            let connection = MCPConnection(channel: channel, handler: handler, tools: EchoToolbox(), clientLabel: "Verified client") { _ in }
            Task { await connection.run() }
        }
        try listener.start()
        self.listener = listener
        return path
    }

    private func connect(_ path: String) throws -> Int32 {
        let fd = try XCTUnwrap(MCPUnixSocket.connect(path: path))
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    private func send(_ fd: Int32, _ text: String) {
        let data = Array((text + "\n").utf8)
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    private func readLine(_ fd: Int32) -> JSONValue? {
        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        while read(fd, &byte, 1) == 1 {
            if byte == 0x0A { return JSONLine.decode(Data(bytes)) }
            bytes.append(byte)
        }
        return nil
    }

    func testLegacyHandshakeAndToolCallOverTheSocket() throws {
        let path = try startListener()
        var info = stat()
        XCTAssertEqual(stat(path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)

        let fd = try connect(path)
        defer { close(fd) }
        let hello = String(data: MCPBridgeHello(parentPID: 1, parentPath: "/Applications/Claude.app/Contents/MacOS/Claude").encodedLine(), encoding: .utf8)!
        send(fd, hello)
        send(fd, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}"#)
        XCTAssertEqual(readLine(fd)?["result"]?["protocolVersion"], "2025-11-25")

        send(fd, #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"echo","arguments":{"x":1}}}"#)
        let call = readLine(fd)
        XCTAssertEqual(call?["id"], 2)
        XCTAssertEqual(call?["result"]?["structuredContent"]?["arguments"], ["x": 1])
        // The hello names Claude, but only the server's own lookup labels the connection.
        XCTAssertEqual(call?["result"]?["structuredContent"]?["client"], "Verified client")
    }

    func testPeerCredentialsNameTheConnectingProcess() throws {
        let path = directory.appendingPathComponent("p.sock").path
        let accepted = expectation(description: "accepted")
        nonisolated(unsafe) var credentials: MCPPeerCredentials?
        let listener = MCPSocketListener(path: path) { channel in
            credentials = channel.peerCredentials()
            accepted.fulfill()
        }
        try listener.start()
        self.listener = listener

        let fd = try connect(path)
        defer { close(fd) }
        wait(for: [accepted], timeout: 5)
        XCTAssertEqual(credentials?.pid, getpid())
        XCTAssertNotNil(credentials?.auditToken)
    }

    func testSecondListenerDoesNotStealALiveSocket() throws {
        let path = try startListener()
        let second = MCPSocketListener(path: path) { _ in }
        XCTAssertThrowsError(try second.start()) { error in
            guard case MCPSocketListener.ListenerError.alreadyInUse = error else {
                return XCTFail("expected alreadyInUse, got \(error)")
            }
        }
        XCTAssertEqual(listener?.isSocketFileIntact, true)
    }

    func testStaleSocketFileIsReplaced() throws {
        let path = try startListener()
        listener?.stop()
        // A crashed instance leaves a file nobody answers on; the next start must take it over.
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = try XCTUnwrap(MCPUnixSocket.address(path: path))
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        close(fd)
        listener = nil
        XCTAssertNoThrow(try startListener())
    }

    func testWatchdogNoticesDeletedSocketFile() throws {
        let path = try startListener()
        XCTAssertEqual(listener?.isSocketFileIntact, true)
        unlink(path)
        XCTAssertEqual(listener?.isSocketFileIntact, false)
    }
}
