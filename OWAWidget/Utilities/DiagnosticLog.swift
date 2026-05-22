import AppKit
import Foundation
import os.log

/// Always-on lightweight diagnostic event log.
///
/// Captures app lifecycle checkpoints (boot, menu bar appearance, account state, sync triggers)
/// to two rotating files in `~/Library/Application Support/OWAWidget/` AND to the unified
/// logging system. The goal is to have reproducible context the next time a release build
/// behaves unexpectedly — without requiring DEBUG builds or `log show` invocations from the user.
///
/// Two files are kept:
/// - `diagnostic.log` — current session (overwritten on launch)
/// - `diagnostic.previous.log` — previous session, useful after a crash or after relaunch
///
/// Messages must be non-PII (no event titles, attendee emails, server URLs). Only lifecycle
/// metadata and counts.
enum DiagnosticLog {
    /// Records a lifecycle event. Safe to call from any thread.
    static func event(_ message: String) {
        Store.shared.write(message)
    }

    /// Returns a full diagnostic report: header + current session + previous session.
    /// Intended for the "Copy diagnostics" menu item.
    static func report() -> String {
        Store.shared.report()
    }

    /// Copies the diagnostic report to the system pasteboard.
    @MainActor
    static func copyReportToClipboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(Store.shared.report(), forType: .string)
    }
}

private final class Store: @unchecked Sendable {
    static let shared = Store()

    private let queue = DispatchQueue(label: "com.owawidget.diagnostic")
    private let log = Logger(subsystem: "com.owawidget", category: "Diag")
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()
    private let fileURL: URL?
    private let previousURL: URL?
    private let header: String

    init() {
        let support = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = support?.appendingPathComponent("OWAWidget", isDirectory: true)
        if let dir {
            try? FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        fileURL = dir?.appendingPathComponent("diagnostic.log", isDirectory: false)
        previousURL = dir?.appendingPathComponent("diagnostic.previous.log", isDirectory: false)
        header = Self.buildHeader()

        rotateOnLaunch()
        writeHeader()
    }

    func write(_ message: String) {
        log.info("\(message, privacy: .public)")
        let date = Date()
        queue.async {
            guard let url = self.fileURL else { return }
            let stamp = self.formatter.string(from: date)
            let line = "[\(stamp)] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url, options: [.atomic])
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: url.path
                )
            }
        }
    }

    func report() -> String {
        queue.sync {
            var parts: [String] = [header]
            if let current = fileURL,
               let body = try? String(contentsOf: current, encoding: .utf8) {
                parts.append("--- current session ---")
                parts.append(body)
            }
            if let previous = previousURL,
               let body = try? String(contentsOf: previous, encoding: .utf8) {
                parts.append("--- previous session ---")
                parts.append(body)
            }
            return parts.joined(separator: "\n")
        }
    }

    private func rotateOnLaunch() {
        guard let current = fileURL, let previous = previousURL else { return }
        let fm = FileManager.default
        if fm.fileExists(atPath: current.path) {
            try? fm.removeItem(at: previous)
            try? fm.moveItem(at: current, to: previous)
        }
    }

    private func writeHeader() {
        guard let url = fileURL,
              let data = (header + "\n").data(using: .utf8)
        else { return }
        try? data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private static func buildHeader() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let locale = Locale.current.identifier
        let started = ISO8601DateFormatter().string(from: Date())
        return """
        OWAWidget diagnostics
        version: \(version) (build \(build))
        macOS: \(os)
        locale: \(locale)
        session started: \(started)
        """
    }
}
