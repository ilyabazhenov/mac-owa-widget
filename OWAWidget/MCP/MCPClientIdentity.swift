import Darwin
import Foundation

// Who is on the other end of an MCP connection, worked out by the app itself.
//
// The bridge's first line (`MCPBridgeHello`) names its parent process, but anyone can open the
// socket and write that line. So the server never takes a client's word for who it is:
// - the kernel tells it which process is connected (LOCAL_PEERPID / LOCAL_PEERTOKEN);
// - the code signature tells it whether that process is our bridge (`MCPPeerVerifier`);
// - for the bridge, the client is the bridge's parent, which the server looks up itself;
//   anything else that connects directly is itself the client.
//
// This labels connections for the settings list and the "new client" notification. It is not
// access control: any process of the same user can still connect (see the design document).

/// How the connected process relates to our bridge.
enum MCPPeerKind: String, Codable, Equatable, Sendable {
    /// Our signed bridge; the client is its parent process.
    case bridge
    /// Our bridge, started before the app was updated or rebuilt: the running code no longer
    /// matches the file on disk, so its signature cannot be checked any more. Still treated as the
    /// bridge — see `MCPPeerVerifier` for why that is safe enough for a label.
    case staleBridge
    /// Anything else, connected to the socket directly. It is the client itself.
    case direct
}

/// What the server reads about one process. Never comes from the peer.
struct MCPProcessFacts: Equatable, Sendable {
    var pid: pid_t
    var parentPID: pid_t
    var executablePath: String
    /// `argv`, including `argv[0]`. Empty when the process would not tell.
    var arguments: [String] = []
    var workingDirectory: String?
    /// Team ID and signing identifier, only when the running code still matches its file.
    var teamIdentifier: String?
    var signingIdentifier: String?
    /// The outermost `.app` around the executable: "ImpAgent Helper" reports as "ImpAgent".
    var appBundleIdentifier: String?
    var appName: String?
}

protocol MCPProcessInspecting: Sendable {
    func facts(for pid: pid_t) -> MCPProcessFacts?
}

/// A resolved client: what the settings list and the journal show.
struct MCPClientIdentity: Equatable, Sendable {
    /// Stable across versions where possible: Team ID plus bundle id for signed apps, otherwise
    /// the executable path; plus the script for interpreters.
    var key: String
    var name: String
    var executablePath: String
    /// The script, module or inline-code marker an interpreter runs, when the client is one.
    var script: String?
    var kind: MCPPeerKind
    var pid: pid_t

    /// The process could not be read (it exited, or its parent is launchd).
    static func unknown(kind: MCPPeerKind, pid: pid_t) -> MCPClientIdentity {
        MCPClientIdentity(key: "", name: "", executablePath: "", script: nil, kind: kind, pid: pid)
    }

    var isResolved: Bool { !key.isEmpty }
}

enum MCPClientIdentifier {
    /// `sh -c "…"` wrappers are skipped on the way up; a few levels are plenty.
    static let maxWrapperDepth = 4

    static func identify(peerPID: pid_t, kind: MCPPeerKind, inspector: any MCPProcessInspecting) -> MCPClientIdentity {
        guard let peer = inspector.facts(for: peerPID) else { return .unknown(kind: kind, pid: peerPID) }

        var current: MCPProcessFacts
        if kind == .direct {
            current = peer
        } else {
            // A parent of 1 means the client exited and launchd adopted the bridge.
            guard peer.parentPID > 1, let parent = inspector.facts(for: peer.parentPID) else {
                return .unknown(kind: kind, pid: peer.parentPID)
            }
            current = parent
        }

        for _ in 0..<maxWrapperDepth {
            let invocation = MCPInterpreter.invocation(of: current)
            guard invocation == .shellCommand, current.parentPID > 1,
                  let parent = inspector.facts(for: current.parentPID) else { break }
            current = parent
        }
        return identity(of: current, kind: kind)
    }

    static func identity(of process: MCPProcessFacts, kind: MCPPeerKind) -> MCPClientIdentity {
        let codeKey: String
        if let team = process.teamIdentifier, !team.isEmpty {
            codeKey = "team:\(team):\(process.appBundleIdentifier ?? process.signingIdentifier ?? process.executablePath)"
        } else {
            codeKey = "path:\(process.executablePath)"
        }

        let executableName = URL(fileURLWithPath: process.executablePath).lastPathComponent
        let invocation = MCPInterpreter.invocation(of: process)
        switch invocation {
        case .script(let path):
            return MCPClientIdentity(
                key: codeKey + "|script:" + path,
                name: "\(MCPInterpreter.displayName(forScript: path)) (\(executableName))",
                executablePath: process.executablePath,
                script: path,
                kind: kind,
                pid: process.pid
            )
        case .module(let module):
            return MCPClientIdentity(
                key: codeKey + "|module:" + module,
                name: "\(executableName) -m \(module)",
                executablePath: process.executablePath,
                script: "-m \(module)",
                kind: kind,
                pid: process.pid
            )
        case .inline(let flag):
            return MCPClientIdentity(
                key: codeKey + "|inline",
                name: flag.isEmpty ? executableName : "\(executableName) \(flag)",
                executablePath: process.executablePath,
                script: flag.isEmpty ? nil : flag,
                kind: kind,
                pid: process.pid
            )
        case .shellCommand, .interactive, .notInterpreter:
            let name = process.appName.flatMap { $0.isEmpty ? nil : $0 }
                ?? signedName(process)
                ?? executableName
            return MCPClientIdentity(
                key: codeKey,
                name: name,
                executablePath: process.executablePath,
                script: nil,
                kind: kind,
                pid: process.pid
            )
        }
    }
}

extension MCPClientIdentifier {
    /// The last part of a team-signed identifier: the Claude Code CLI lives at
    /// `~/.local/share/claude/versions/2.1.288`, and its file name is a version, not a name.
    static func signedName(_ process: MCPProcessFacts) -> String? {
        guard process.teamIdentifier != nil,
              let identifier = process.signingIdentifier,
              let last = identifier.split(separator: ".").last, !last.isEmpty else { return nil }
        return String(last)
    }
}

/// Interpreters run someone else's program: "node" alone says nothing about which client it is,
/// so the script path becomes part of the client's name and key.
enum MCPInterpreter {
    enum Family: Equatable {
        case shell, node, python, ruby, perl, php, bun, deno, osascript, electron
    }

    enum Invocation: Equatable {
        case notInterpreter
        /// A script file or, for Electron, an app directory. Absolute and standardized.
        case script(String)
        case module(String)
        /// Code on the command line (`node -e`, `python -c`); carries the flag.
        case inline(String)
        /// `sh -c "…"`: a wrapper someone else started. The client is further up.
        case shellCommand
        /// A shell reading commands from a terminal or stdin.
        case interactive
    }

    static func family(ofExecutable path: String) -> Family? {
        let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        switch name {
        case "sh", "bash", "zsh", "dash", "ksh", "fish", "tcsh", "csh": return .shell
        case "node", "nodejs": return .node
        case "ruby": return .ruby
        case "php": return .php
        case "bun": return .bun
        case "deno": return .deno
        case "osascript": return .osascript
        default: break
        }
        if name.hasPrefix("python"), name.dropFirst("python".count).allSatisfy({ $0.isNumber || $0 == "." }) {
            return .python
        }
        if name.hasPrefix("perl"), name.dropFirst("perl".count).allSatisfy({ $0.isNumber || $0 == "." }) {
            return .perl
        }
        // An unpackaged Electron app (`electron .` during development). Packaged apps rename the
        // binary and are identified by their bundle instead.
        if name == "electron", path.contains("/Electron.app/") {
            return .electron
        }
        return nil
    }

    /// Options that take the next argument as their value, per family. Everything else starting
    /// with "-" is a plain switch.
    private static func takesValue(_ option: String, family: Family) -> Bool {
        switch family {
        case .shell: return option == "-o" || option == "+o" || option == "-O" || option == "+O"
        case .node:
            return ["-r", "--require", "--import", "--loader", "--experimental-loader", "-C", "--conditions",
                    "--input-type", "--env-file", "--inspect-port", "--title", "--stack-size"].contains(option)
        case .python: return ["-W", "-X", "-Q"].contains(option)
        case .ruby: return ["-I", "-r", "-C", "-E"].contains(option)
        case .perl: return ["-I", "-M", "-m"].contains(option)
        case .php: return ["-c", "-d", "-z"].contains(option)
        case .osascript: return ["-l", "-s"].contains(option)
        case .bun, .deno, .electron: return false
        }
    }

    private static func inlineFlag(_ option: String, family: Family) -> Bool {
        switch family {
        case .shell:
            // "-c", and combined forms such as "-lc" or "-ec".
            return !option.hasPrefix("--") && option.hasPrefix("-") && option.contains("c")
        case .node: return ["-e", "--eval", "-p", "--print"].contains(option)
        case .python: return option == "-c"
        case .ruby, .perl, .osascript: return option == "-e" || option == "-E"
        case .php: return option == "-r"
        case .bun, .deno: return ["-e", "--eval", "eval", "-p", "--print"].contains(option)
        case .electron: return false
        }
    }

    static func invocation(of process: MCPProcessFacts) -> Invocation {
        guard let family = family(ofExecutable: process.executablePath) else { return .notInterpreter }
        var arguments = Array(process.arguments.dropFirst())
        if family == .bun || family == .deno, arguments.first == "run" {
            arguments.removeFirst()
        }

        var index = 0
        var optionsEnded = false
        while index < arguments.count {
            let argument = arguments[index]
            if !optionsEnded {
                if argument == "--" {
                    optionsEnded = true
                    index += 1
                    continue
                }
                if inlineFlag(argument, family: family) {
                    return family == .shell ? .shellCommand : .inline(argument)
                }
                if family == .python, argument == "-m", index + 1 < arguments.count {
                    return .module(arguments[index + 1])
                }
                if family == .php, argument == "-f", index + 1 < arguments.count {
                    return .script(resolve(arguments[index + 1], in: process.workingDirectory))
                }
                if argument == "-" {
                    // The program comes from stdin.
                    return family == .shell ? .interactive : .inline(argument)
                }
                if argument.hasPrefix("-") || (family == .shell && argument.hasPrefix("+")) {
                    index += takesValue(argument, family: family) ? 2 : 1
                    continue
                }
            }
            return .script(resolve(argument, in: process.workingDirectory))
        }
        return family == .shell ? .interactive : .inline("")
    }

    static func resolve(_ path: String, in directory: String?) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return (expanded as NSString).standardizingPath
        }
        guard let directory, !directory.isEmpty else { return expanded }
        return ((directory as NSString).appendingPathComponent(expanded) as NSString).standardizingPath
    }

    private static let genericScriptNames: Set<String> = [
        "index", "main", "cli", "server", "app", "run", "start", "__main__", "bin", "mcp",
    ]
    private static let genericDirectoryNames: Set<String> = [
        "dist", "build", "lib", "bin", "src", "out", "scripts", "node_modules", ".bin",
    ]

    /// "/Users/me/imp-agent/dist/index.js" -> "imp-agent"; "/Users/me/tools/calendar.py" -> "calendar.py".
    static func displayName(forScript path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let stem = url.deletingPathExtension().lastPathComponent.lowercased()
        guard genericScriptNames.contains(stem) else { return url.lastPathComponent }
        var directory = url.deletingLastPathComponent()
        while directory.path != "/", genericDirectoryNames.contains(directory.lastPathComponent.lowercased()) {
            directory = directory.deletingLastPathComponent()
        }
        return directory.path == "/" ? url.lastPathComponent : directory.lastPathComponent
    }
}
