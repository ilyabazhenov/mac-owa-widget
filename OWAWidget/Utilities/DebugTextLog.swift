import Foundation

#if DEBUG
/// Plain-text DEBUG logs a developer reads with `tail`: `~/Library/Logs/OWAWidget/<name>`.
///
/// They used to live in `/tmp`, which every local user can read and write. The files came out
/// 0644, so anyone on the Mac could read meeting titles and join links from them; and since
/// `/tmp` is shared, another user could plant a symlink under the expected name beforehand and
/// have the app append those lines to a file of the victim's own. `~/Library` is 0700, the
/// directory is created 0700, files are 0600 and opened with `O_NOFOLLOW`.
///
/// Traces with whole server responses go through ``DebugLogLocation`` (encrypted) instead; this
/// is for short status lines that must stay readable without tooling.
enum DebugTextLog {
    private static let lock = NSLock()

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/OWAWidget", isDirectory: true)
    }

    /// Starts the log over with `text` (one per launch).
    static func reset(_ name: String, with text: String) {
        write(text, to: name, truncate: true)
    }

    /// Appends one timestamped line.
    static func append(_ message: String, to name: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        write("[\(formatter.string(from: Date()))] \(message)\n", to: name, truncate: false)
    }

    private static func write(_ text: String, to name: String, truncate: Bool) {
        // Tests run DEBUG code too; they have no business filling the developer's real logs.
        guard !SecureStore.isRunningTests else { return }
        let data = Data(text.utf8)
        let directory = directory
        lock.lock()
        defer { lock.unlock() }

        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        write(data, toPath: directory.appendingPathComponent(name, isDirectory: false).path, truncate: truncate)
    }

    /// The file part, without the test guard, so the permissions and the symlink refusal are testable.
    static func write(_ data: Data, toPath path: String, truncate: Bool) {
        let flags = O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC | (truncate ? O_TRUNC : O_APPEND)
        let fd = open(path, flags, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        // A file created by an older build may be 0644.
        fchmod(fd, 0o600)
        data.withUnsafeBytes { buffer in
            _ = Darwin.write(fd, buffer.baseAddress, buffer.count)
        }
    }
}
#endif
