import AppKit
import Darwin
import Foundation
import OWAWidgetMCPShared

// MCP stdio server that MCP clients (Claude Desktop, Claude Code, Cursor, ...) launch.
//
// The MCP server itself lives inside the running OWA Widget app, which already holds the
// Keychain items, the Exchange session and the auth circuit breaker. This binary only moves
// newline-delimited JSON-RPC between stdio and the app's Unix socket. It never touches the
// Keychain or the network.
//
// Invariants:
// - Nothing happens at startup. Some clients spawn the server twice (a throwaway process probes
//   the protocol version first), so the app is launched and the socket opened only once the
//   first message arrives on stdin.
// - The app is launched through LaunchServices (`NSWorkspace`), never by exec'ing its binary:
//   as a child of this process it would inherit the client as its "responsible process", and
//   calendar (TCC) and Keychain prompts would be attributed to the client app.
// - stdout carries MCP messages only. Diagnostics go to stderr.
// - stdio is written with POSIX `write`, never `FileHandle.write(_:)`: that one raises an
//   Objective-C exception on EPIPE, which Swift cannot catch. A client that closed our stdout is
//   gone, so the bridge exits with 0.

private func logStderr(_ message: String) {
    MCPUnixSocket.writeAll(STDERR_FILENO, Data("owawidget-mcp: \(message)\n".utf8))
}

/// The enclosing `.app`, when this binary sits at `X.app/Contents/Helpers/owawidget-mcp`.
private func enclosingAppURL() -> URL? {
    guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
    let app = executable
        .deletingLastPathComponent() // Helpers
        .deletingLastPathComponent() // Contents
        .deletingLastPathComponent() // X.app
    return app.pathExtension == "app" ? app : nil
}

private func parentProcessPath() -> String? {
    var buffer = [CChar](repeating: 0, count: 4096)
    let length = proc_pidpath(getppid(), &buffer, UInt32(buffer.count))
    guard length > 0 else { return nil }
    return String(cString: buffer)
}

final class Bridge: @unchecked Sendable {
    private let appURL: URL?
    private let bundleIdentifier: String
    private let socketPath: String
    private let lock = NSLock()
    private var state = MCPBridgeState()
    private var socketFD: Int32 = -1
    private var connectionGeneration = 0

    init() {
        appURL = enclosingAppURL()
        bundleIdentifier = appURL.flatMap { Bundle(url: $0)?.bundleIdentifier }
            ?? ProcessInfo.processInfo.environment["OWAWIDGET_BUNDLE_ID"]
            ?? "com.owawidget.MacOwaWidget"
        socketPath = MCPSocketPath.socketURL(
            bundleIdentifier: bundleIdentifier,
            homeDirectory: MCPSocketPath.userHomeDirectory()
        ).path
    }

    func handleClientLine(_ line: Data) {
        lock.lock()
        defer { lock.unlock() }

        // Two attempts: a write can fail because the app just restarted (Sparkle update), and the
        // new instance is usually already listening.
        for _ in 0..<2 {
            if socketFD < 0, !connectLocked() { break }
            if MCPUnixSocket.writeAll(socketFD, line + Data([0x0A])) {
                // Noted only once delivered, so a legacy `initialize` is recorded after it reached
                // the app and gets replayed on reconnects, never on the connection it went out on.
                // The reader thread needs this lock to forward the answer, so it cannot overtake.
                state.noteClientMessage(line)
                return
            }
            dropConnectionLocked()
        }
        state.noteClientMessage(line)
        failLocked(line)
    }

    func shutdown() {
        lock.lock()
        closeSocketLocked()
        lock.unlock()
    }

    // MARK: - Connection

    private func connectLocked() -> Bool {
        if let fd = MCPUnixSocket.connect(path: socketPath) {
            adoptLocked(fd)
            return true
        }

        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
        let deadline: Date
        if running {
            // Starting up, or the socket file went missing. A few seconds covers the first case.
            deadline = Date().addingTimeInterval(5)
        } else {
            guard launchApp() else { return false }
            // A launch right after an update can sit on a Keychain prompt.
            deadline = Date().addingTimeInterval(20)
        }

        while Date() < deadline {
            usleep(250_000)
            if let fd = MCPUnixSocket.connect(path: socketPath) {
                adoptLocked(fd)
                return true
            }
        }
        logStderr(running
            ? "OWA Widget is running but its MCP socket is unavailable at \(socketPath)"
            : "OWA Widget did not open its MCP socket in time")
        return false
    }

    private func adoptLocked(_ fd: Int32) {
        socketFD = fd
        connectionGeneration += 1
        let hello = MCPBridgeHello(parentPID: getppid(), parentPath: parentProcessPath())
        MCPUnixSocket.writeAll(fd, hello.encodedLine() + Data([0x0A]))
        for line in state.replayLinesForNewConnection() {
            MCPUnixSocket.writeAll(fd, line + Data([0x0A]))
        }
        let generation = connectionGeneration
        let thread = Thread { [weak self] in self?.readLoop(fd: fd, generation: generation) }
        thread.name = "owawidget-mcp.reader"
        thread.start()
    }

    private func launchApp() -> Bool {
        guard let appURL else {
            logStderr("not inside OWAWidget.app, cannot launch the app")
            return false
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
            if let error { logStderr("failed to launch OWA Widget: \(error.localizedDescription)") }
        }
        return true
    }

    private func readLoop(fd: Int32, generation: Int) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count <= 0 { break }
            buffer.append(contentsOf: chunk[0..<count])
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                guard !line.isEmpty else { continue }
                forwardServerLine(Data(line))
            }
        }
        lock.lock()
        if generation == connectionGeneration {
            dropConnectionLocked()
        }
        lock.unlock()
    }

    private func forwardServerLine(_ line: Data) {
        lock.lock()
        let forward = state.noteServerMessage(line)
        if forward { writeStdout(line) }
        lock.unlock()
    }

    private func failLocked(_ line: Data) {
        let message = "OWA Widget is not reachable. Make sure the app is installed and running, then retry."
        if let error = MCPBridgeState.errorLine(forRequest: line, code: MCPBridgeState.connectionLostCode, message: message) {
            _ = state.noteServerMessage(error)
            writeStdout(error)
        }
    }

    /// The connection is gone: every request it carried gets an error now instead of waiting for
    /// the client's timeout.
    private func dropConnectionLocked() {
        closeSocketLocked()
        let errors = state.connectionLost(message: "Connection to OWA Widget was lost (the app restarted?). Retry the request.")
        errors.forEach(writeStdout)
    }

    private func closeSocketLocked() {
        guard socketFD >= 0 else { return }
        Darwin.shutdown(socketFD, SHUT_RDWR)
        close(socketFD)
        socketFD = -1
        connectionGeneration += 1
    }

    private func writeStdout(_ line: Data) {
        guard MCPUnixSocket.writeAll(STDOUT_FILENO, line + Data([0x0A])) else {
            // Nobody reads our answers any more. Called with the lock held, so close the socket
            // directly rather than through `shutdown()`.
            logStderr("stdout is closed (\(String(cString: strerror(errno)))), exiting")
            closeSocketLocked()
            exit(0)
        }
    }
}

signal(SIGPIPE, SIG_IGN)
let bridge = Bridge()
while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty else { continue }
    bridge.handleClientLine(Data(line.utf8))
}
bridge.shutdown()
exit(0)
