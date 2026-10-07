import Darwin
import Security
import XCTest
@testable import OWAWidget

/// Who a connection belongs to, worked out by the server: our bridge, a process on the socket
/// directly, and interpreters whose script is the real client.
final class MCPClientIdentityTests: XCTestCase {
    private struct FakeInspector: MCPProcessInspecting {
        var processes: [pid_t: MCPProcessFacts]
        func facts(for pid: pid_t) -> MCPProcessFacts? { processes[pid] }
    }

    private static let bridgePath = "/Applications/OWAWidget.app/Contents/Helpers/owawidget-mcp"

    private func bridge(pid: pid_t = 100, parent: pid_t) -> MCPProcessFacts {
        MCPProcessFacts(pid: pid, parentPID: parent, executablePath: Self.bridgePath, arguments: [Self.bridgePath],
                        teamIdentifier: "N577X226Q5", signingIdentifier: "owawidget-mcp",
                        appBundleIdentifier: "com.owawidget.MacOwaWidget", appName: "OWA Widget")
    }

    private func claudeCode(pid: pid_t = 50, version: String = "2.1.293") -> MCPProcessFacts {
        let path = "/Users/me/Library/Application Support/Claude/claude-code/\(version)/8433d0d9cd0d/claude.app/Contents/MacOS/claude"
        return MCPProcessFacts(pid: pid, parentPID: 10, executablePath: path, arguments: [path, "--output-format", "stream-json"],
                               teamIdentifier: "Q6L2SF6YDW", signingIdentifier: "com.anthropic.claude-code",
                               appBundleIdentifier: "com.anthropic.claude-code", appName: "Claude Code")
    }

    private func node(pid: pid_t, parent: pid_t = 10, arguments: [String], cwd: String? = "/Users/me/agent") -> MCPProcessFacts {
        let path = "/opt/homebrew/Cellar/node/26.0.0/bin/node"
        return MCPProcessFacts(pid: pid, parentPID: parent, executablePath: path, arguments: [path] + arguments, workingDirectory: cwd)
    }

    private func identify(_ processes: [MCPProcessFacts], peer: pid_t = 100, kind: MCPPeerKind = .bridge) -> MCPClientIdentity {
        let inspector = FakeInspector(processes: Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) }))
        return MCPClientIdentifier.identify(peerPID: peer, kind: kind, inspector: inspector)
    }

    // MARK: - Bridge, direct, interpreters

    func testOwnBridgeIsIdentifiedByItsParent() {
        let identity = identify([bridge(parent: 50), claudeCode()])
        XCTAssertEqual(identity.name, "Claude Code")
        XCTAssertEqual(identity.kind, .bridge)
        XCTAssertEqual(identity.pid, 50)
        XCTAssertEqual(identity.key, "team:Q6L2SF6YDW:com.anthropic.claude-code")
        XCTAssertNil(identity.script)
    }

    func testSignedClientKeepsItsKeyAcrossVersions() {
        let old = identify([bridge(parent: 50), claudeCode(version: "2.1.293")])
        let new = identify([bridge(parent: 50), claudeCode(version: "2.2.0")])
        XCTAssertEqual(old.key, new.key)
        XCTAssertNotEqual(old.executablePath, new.executablePath)
    }

    func testSignedCommandLineToolIsNamedBySignatureNotByFileName() {
        let path = "/Users/me/.local/share/claude/versions/2.1.288"
        let cli = MCPProcessFacts(pid: 51, parentPID: 10, executablePath: path, arguments: ["claude", "-p"],
                                  teamIdentifier: "Q6L2SF6YDW", signingIdentifier: "com.anthropic.claude-code")
        let identity = identify([bridge(parent: 51), cli])
        XCTAssertEqual(identity.name, "claude-code")
        XCTAssertEqual(identity.key, "team:Q6L2SF6YDW:com.anthropic.claude-code")
    }

    func testForeignProcessOnTheSocketIsTheClientItself() {
        // Started by Claude Code, but connected without the bridge: whatever it writes in its
        // first line, the client is this binary, not its parent.
        let intruder = MCPProcessFacts(pid: 200, parentPID: 50, executablePath: "/tmp/x/fake-bridge", arguments: ["/tmp/x/fake-bridge"])
        let identity = identify([intruder, claudeCode()], peer: 200, kind: .direct)
        XCTAssertEqual(identity.name, "fake-bridge")
        XCTAssertEqual(identity.kind, .direct)
        XCTAssertEqual(identity.key, "path:/tmp/x/fake-bridge")
        XCTAssertEqual(identity.pid, 200)
    }

    func testInterpreterScriptIsPartOfNameAndKey() {
        let first = identify([bridge(parent: 60), node(pid: 60, arguments: ["--enable-source-maps", "client.js"])])
        XCTAssertEqual(first.name, "client.js (node)")
        XCTAssertEqual(first.script, "/Users/me/agent/client.js")
        XCTAssertEqual(first.key, "path:/opt/homebrew/Cellar/node/26.0.0/bin/node|script:/Users/me/agent/client.js")

        let other = identify([bridge(parent: 61), node(pid: 61, arguments: ["-r", "dotenv/config", "/Users/me/other/tool.mjs"])])
        XCTAssertEqual(other.name, "tool.mjs (node)")
        XCTAssertNotEqual(first.key, other.key)
    }

    func testGenericScriptNameUsesTheProjectDirectory() {
        let identity = identify([bridge(parent: 60), node(pid: 60, arguments: ["/Users/me/imp-agent/dist/index.js"])])
        XCTAssertEqual(identity.name, "imp-agent (node)")
        XCTAssertEqual(identity.script, "/Users/me/imp-agent/dist/index.js")
    }

    func testElectronDuringDevelopmentIsNamedAfterTheAppDirectory() {
        let path = "/Users/me/imp-agent-crossplatform/node_modules/electron/dist/Electron.app/Contents/MacOS/Electron"
        let electron = MCPProcessFacts(pid: 70, parentPID: 10, executablePath: path, arguments: [path, "."],
                                       workingDirectory: "/Users/me/imp-agent-crossplatform", appName: "Electron")
        let identity = identify([bridge(parent: 70), electron])
        XCTAssertEqual(identity.name, "imp-agent-crossplatform (Electron)")
        XCTAssertEqual(identity.script, "/Users/me/imp-agent-crossplatform")
    }

    func testPackagedElectronHelperReportsTheOuterApp() {
        let path = "/Applications/ImpAgent.app/Contents/Frameworks/ImpAgent Helper.app/Contents/MacOS/ImpAgent Helper"
        let helper = MCPProcessFacts(pid: 80, parentPID: 10, executablePath: path, arguments: [path, "--type=utility"],
                                     teamIdentifier: "ABCDE12345", signingIdentifier: "com.imp.agent.helper",
                                     appBundleIdentifier: "com.imp.agent", appName: "ImpAgent")
        let identity = identify([bridge(parent: 80), helper])
        XCTAssertEqual(identity.name, "ImpAgent")
        XCTAssertEqual(identity.key, "team:ABCDE12345:com.imp.agent")
    }

    func testShellCommandWrapperIsSkipped() {
        let codexPath = "/opt/homebrew/Caskroom/codex/0.153.4/bin/codex"
        let codex = MCPProcessFacts(pid: 90, parentPID: 10, executablePath: codexPath, arguments: [codexPath],
                                    teamIdentifier: "2DC432GLL2", signingIdentifier: "codex")
        let shell = MCPProcessFacts(pid: 91, parentPID: 90, executablePath: "/bin/zsh",
                                    arguments: ["/bin/zsh", "-lc", "exec \(Self.bridgePath)"])
        let identity = identify([bridge(parent: 91), shell, codex])
        XCTAssertEqual(identity.name, "codex")
        XCTAssertEqual(identity.pid, 90)
        XCTAssertEqual(identity.key, "team:2DC432GLL2:codex")
    }

    func testShellScriptIsTheClient() {
        let shell = MCPProcessFacts(pid: 92, parentPID: 10, executablePath: "/bin/bash",
                                    arguments: ["/bin/bash", "-e", "scripts/run-mcp.sh"], workingDirectory: "/Users/me/tools")
        let identity = identify([bridge(parent: 92), shell])
        XCTAssertEqual(identity.name, "run-mcp.sh (bash)")
        XCTAssertEqual(identity.script, "/Users/me/tools/scripts/run-mcp.sh")
    }

    func testPythonModuleAndInlineCode() {
        let python = MCPProcessFacts(pid: 93, parentPID: 10, executablePath: "/usr/local/bin/python3.12",
                                     arguments: ["python3", "-u", "-m", "calendar_agent"])
        let module = identify([bridge(parent: 93), python])
        XCTAssertEqual(module.name, "python3.12 -m calendar_agent")
        XCTAssertTrue(module.key.hasSuffix("|module:calendar_agent"))

        let inline = identify([bridge(parent: 94), node(pid: 94, arguments: ["-e", "require('child_process').spawn(...)"])])
        XCTAssertEqual(inline.name, "node -e")
        XCTAssertTrue(inline.key.hasSuffix("|inline"))
    }

    func testOrphanedBridgeHasNoClient() {
        XCTAssertFalse(identify([bridge(parent: 1)]).isResolved)
        XCTAssertFalse(identify([bridge(parent: 55)]).isResolved, "parent already exited")
    }

    // MARK: - Real system

    func testInspectorReadsTheCurrentProcess() throws {
        let facts = try XCTUnwrap(MCPSystemProcessInspector().facts(for: getpid()))
        XCTAssertEqual(facts.parentPID, getppid())
        XCTAssertEqual(facts.arguments.count, CommandLine.arguments.count)
        XCTAssertFalse(facts.executablePath.isEmpty)
        XCTAssertEqual(facts.workingDirectory, FileManager.default.currentDirectoryPath)
    }

    func testProcArgsParsing() {
        var bytes: [UInt8] = []
        withUnsafeBytes(of: Int32(2)) { bytes += $0 }
        bytes += Array("/usr/bin/node".utf8) + [0, 0, 0]
        bytes += Array("node".utf8) + [0] + Array("a b.js".utf8) + [0]
        bytes += Array("PATH=/usr/bin".utf8) + [0]
        XCTAssertEqual(MCPSystemProcessInspector.parseProcArgs(bytes), ["node", "a b.js"])
    }

    func testVerifierAcceptsOnlyCodeMatchingTheRequirement() throws {
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer { close(pair[0]); close(pair[1]) }
        let peer = try XCTUnwrap(MCPPeerCredentials.read(fd: pair[0]))
        XCTAssertEqual(peer.pid, getpid())

        // The test runner is not the bridge.
        let bridgeOnly = MCPPeerVerifier(
            requirementText: "identifier \"owawidget-mcp\" and anchor apple generic and certificate leaf[subject.OU] = \"N577X226Q5\"",
            bridgePath: Self.bridgePath
        )
        XCTAssertEqual(bridgeOnly.kind(of: peer, executablePath: nil), .direct)

        // A requirement this very process meets passes: the check runs on the real signature.
        var me: SecCode?
        XCTAssertEqual(SecCodeCopySelf([], &me), errSecSuccess)
        var staticCode: SecStaticCode?
        XCTAssertEqual(SecCodeCopyStaticCode(try XCTUnwrap(me), [], &staticCode), errSecSuccess)
        let cdhash = try XCTUnwrap(MCPCodeSignature.cdhash(try XCTUnwrap(staticCode)))
        let selfOnly = MCPPeerVerifier(
            requirementText: "cdhash H\"\(cdhash.map { String(format: "%02x", $0) }.joined())\"",
            bridgePath: Self.bridgePath
        )
        XCTAssertEqual(selfOnly.kind(of: peer, executablePath: nil), .bridge)

        // No requirement (unsigned app): nothing counts as the bridge.
        XCTAssertEqual(MCPPeerVerifier(requirementText: nil, bridgePath: Self.bridgePath).kind(of: peer, executablePath: nil), .direct)
    }

    // MARK: - Known clients list

    private func identity(_ key: String, name: String = "Client") -> MCPClientIdentity {
        MCPClientIdentity(key: key, name: name, executablePath: "/bin/\(name)", script: nil, kind: .bridge, pid: 42)
    }

    func testFirstConnectionIsNewAndLaterOnesUpdateTheEntry() {
        let start = Date(timeIntervalSince1970: 1_000)
        let first = MCPKnownClientList.record(identity("a"), at: start, in: [])
        XCTAssertTrue(first.isNew)

        var renamed = identity("a", name: "Client 2")
        renamed.kind = .direct
        let second = MCPKnownClientList.record(renamed, at: start.addingTimeInterval(60), in: first.list)
        XCTAssertFalse(second.isNew)
        XCTAssertEqual(second.list.count, 1)
        XCTAssertEqual(second.list[0].name, "Client 2")
        XCTAssertEqual(second.list[0].lastKind, .direct)
        XCTAssertEqual(second.list[0].firstSeen, start)
        XCTAssertEqual(second.list[0].lastSeen, start.addingTimeInterval(60))
    }

    func testUnresolvedClientIsNotRecorded() {
        let result = MCPKnownClientList.record(.unknown(kind: .bridge, pid: 1), at: Date(), in: [])
        XCTAssertFalse(result.isNew)
        XCTAssertTrue(result.list.isEmpty)
    }

    func testListKeepsTheMostRecentClients() {
        var list: [MCPKnownClient] = []
        for index in 0...MCPKnownClientList.maxCount {
            list = MCPKnownClientList.record(identity("k\(index)"), at: Date(timeIntervalSince1970: Double(index)), in: list).list
        }
        XCTAssertEqual(list.count, MCPKnownClientList.maxCount)
        XCTAssertEqual(list.first?.key, "k\(MCPKnownClientList.maxCount)")
        XCTAssertFalse(list.contains { $0.key == "k0" })
    }

    func testDeclaredNameIsKeptAsAHint() {
        let list = MCPKnownClientList.record(identity("a"), at: Date(), in: []).list
        let updated = MCPKnownClientList.noteDeclaredName("Claude Code", forKey: "a", in: list)
        XCTAssertEqual(updated[0].declaredName, "Claude Code")
        XCTAssertEqual(updated[0].name, "Client")
    }
}
