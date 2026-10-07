import Darwin
import Foundation
import Security

/// The connected process, as the kernel recorded it when it called `connect`.
struct MCPPeerCredentials: Sendable {
    let pid: pid_t
    /// Identifies this exact process, unlike a pid that can be reused once it exits.
    let auditToken: audit_token_t?

    /// `nil` when the socket has no peer any more.
    static func read(fd: Int32) -> MCPPeerCredentials? {
        var pid: pid_t = 0
        var pidLength = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &pidLength) == 0, pid > 0 else { return nil }

        var token = audit_token_t()
        var tokenLength = socklen_t(MemoryLayout<audit_token_t>.size)
        let hasToken = getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &tokenLength) == 0
        return MCPPeerCredentials(pid: pid, auditToken: hasToken ? token : nil)
    }
}

/// Tells our bridge apart from any other process by its code signature.
///
/// The requirement comes from the app's own signature, not from a file it could be handed:
/// - signed with a certificate (Developer ID, Apple Development): identifier `owawidget-mcp`
///   under an Apple anchor with the app's Team ID — stable across versions, so a bridge from an
///   older release still passes;
/// - ad-hoc (local builds without a certificate): the cdhash of the bridge inside this bundle.
///
/// A bridge that was running when the app was updated or rebuilt fails the check with
/// `errSecCSStaticCodeChanged`: Security compares the running code with the file on disk, and the
/// file is now the new version. Such a peer counts as `.staleBridge` when the kernel's signing
/// identifier (not the disk) says `owawidget-mcp` and it was started from this bundle's bridge
/// path. Faking that means writing into the app bundle, which macOS protects for signed apps
/// (App Management); and the result is only a label, never access.
struct MCPPeerVerifier: Sendable {
    static let bridgeIdentifier = "owawidget-mcp"

    private let requirementText: String?
    private let bridgePath: String

    init(requirementText: String?, bridgePath: String) {
        self.requirementText = requirementText
        self.bridgePath = bridgePath
    }

    /// The verifier for the running app. With an unsigned app nothing verifies, and every peer is
    /// reported as connected directly.
    static func forCurrentApp(bridgePath: String) -> MCPPeerVerifier {
        MCPPeerVerifier(requirementText: requirementText(bridgePath: bridgePath), bridgePath: bridgePath)
    }

    static func requirementText(bridgePath: String) -> String? {
        var me: SecCode?
        if SecCodeCopySelf([], &me) == errSecSuccess, let me,
           let team = MCPCodeSignature.signingInformation(me)?.team {
            return "identifier \"\(bridgeIdentifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        }
        var bridge: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: bridgePath) as CFURL, [], &bridge) == errSecSuccess,
              let bridge,
              SecStaticCodeCheckValidity(bridge, [], nil) == errSecSuccess,
              let cdhash = MCPCodeSignature.cdhash(bridge) else { return nil }
        return "cdhash H\"\(cdhash.map { String(format: "%02x", $0) }.joined())\""
    }

    func kind(of peer: MCPPeerCredentials, executablePath: String?) -> MCPPeerKind {
        guard let requirementText, var token = peer.auditToken else { return .direct }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return .direct }

        let tokenData = Data(bytes: &token, count: MemoryLayout<audit_token_t>.size)
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: tokenData] as CFDictionary, [], &code) == errSecSuccess,
              let code else { return .direct }

        switch SecCodeCheckValidity(code, [], requirement) {
        case errSecSuccess:
            return .bridge
        case errSecCSStaticCodeChanged:
            guard let executablePath,
                  Self.samePath(executablePath, bridgePath),
                  Self.kernelSigningIdentifier(token) == Self.bridgeIdentifier else { return .direct }
            return .staleBridge
        default:
            return .direct
        }
    }

    private static func kernelSigningIdentifier(_ token: audit_token_t) -> String? {
        guard let task = SecTaskCreateWithAuditToken(nil, token) else { return nil }
        return SecTaskCopySigningIdentifier(task, nil) as String?
    }

    private static func samePath(_ lhs: String, _ rhs: String) -> Bool {
        URL(fileURLWithPath: lhs).resolvingSymlinksInPath().path == URL(fileURLWithPath: rhs).resolvingSymlinksInPath().path
    }
}

enum MCPCodeSignature {
    struct Info {
        let team: String?
        let identifier: String?
    }

    static func signingInformation(_ code: SecCode) -> Info? {
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return nil }
        let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String
        return Info(team: team?.isEmpty == false ? team : nil, identifier: dictionary[kSecCodeInfoIdentifier as String] as? String)
    }

    static func cdhash(_ code: SecStaticCode) -> Data? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, [], &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoUnique as String] as? Data
    }

    /// Team ID and identifier of a running process, only when its code still matches the file on
    /// disk: signing information is read from that file, and a client updated in place (Claude
    /// Code keeps versions side by side, Homebrew replaces them) would otherwise report the new
    /// file's signature for the old process.
    static func runningProcessInfo(pid: pid_t) -> Info? {
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary, [], &code) == errSecSuccess,
              let code,
              SecCodeCheckValidity(code, [], nil) == errSecSuccess else { return nil }
        return signingInformation(code)
    }
}

/// Reads process facts from the kernel: path, parent, argv, working directory, signature.
/// Works for processes of the same user, which is every process that can reach the socket.
struct MCPSystemProcessInspector: MCPProcessInspecting {
    func facts(for pid: pid_t) -> MCPProcessFacts? {
        guard pid > 0, let path = Self.executablePath(pid), let parent = Self.parentPID(pid) else { return nil }
        var facts = MCPProcessFacts(pid: pid, parentPID: parent, executablePath: path)
        facts.arguments = Self.arguments(pid)
        facts.workingDirectory = Self.workingDirectory(pid)
        if let info = MCPCodeSignature.runningProcessInfo(pid: pid) {
            facts.teamIdentifier = info.team
            facts.signingIdentifier = info.identifier
        }
        if let app = Self.outermostApp(path), let bundle = Bundle(url: app) {
            facts.appBundleIdentifier = bundle.bundleIdentifier
            facts.appName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? app.deletingPathExtension().lastPathComponent
        }
        return facts
    }

    static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    static func parentPID(_ pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }

    static func workingDirectory(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        return path.isEmpty ? nil : path
    }

    /// `argv` from KERN_PROCARGS2: argc, the exec path, padding, then the arguments.
    static func arguments(_ pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        return parseProcArgs(Array(buffer.prefix(size)))
    }

    static func parseProcArgs(_ bytes: [UInt8]) -> [String] {
        guard bytes.count > MemoryLayout<Int32>.size else { return [] }
        let argc = bytes.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var index = 4
        // Skip the exec path and the NUL padding after it.
        while index < bytes.count, bytes[index] != 0 { index += 1 }
        while index < bytes.count, bytes[index] == 0 { index += 1 }

        var arguments: [String] = []
        while arguments.count < argc, index < bytes.count {
            let start = index
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            arguments.append(String(decoding: bytes[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
    }

    static func outermostApp(_ path: String) -> URL? {
        let components = URL(fileURLWithPath: path).pathComponents
        guard let index = components.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return URL(fileURLWithPath: NSString.path(withComponents: Array(components[...index])), isDirectory: true)
    }
}
