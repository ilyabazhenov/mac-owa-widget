import XCTest
@testable import OWAWidget

/// `diagnostic.log` is the one thing the app still writes to disk in cleartext, and that is a
/// deliberate choice: it is the artefact a user copies into a bug report, and encrypting it would
/// make it unreadable in exactly the situation it exists for — a broken master key.
///
/// The choice only holds while the log stays free of personal data. This suite is the gate that
/// keeps it that way, by scanning the source for logging call sites that interpolate fields
/// carrying meeting or people data.
///
/// It covers the unified-log branch too: ``DiagnosticLog`` mirrors every event into `os.log` with
/// `privacy: .public`, and macOS persists that to `/var/db/diagnostics` where the app has no say.
/// Encrypting the file while leaking the same string into the unified log would be theatre.
final class DiagnosticLogPIIGateTests: XCTestCase {

    /// Accessors that carry meeting content or personal data. Interpolating any of these into a
    /// public log line puts it on disk in cleartext.
    private let forbiddenAccessors = [
        ".title", ".email", ".serverURL", ".organizer", ".location",
        ".bodyPreview", ".fullBody", ".displayName", ".joinURL", ".attendees",
        ".username", ".password"
    ]

    private var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // OWAWidgetTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // package root
            .appendingPathComponent("OWAWidget", isDirectory: true)
    }

    private func swiftSources() throws -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: nil
        ) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    /// Extracts the interpolated segments — `\( ... )` — of a line.
    private func interpolations(in line: String) -> [String] {
        var result: [String] = []
        var rest = Substring(line)
        while let open = rest.range(of: "\\(") {
            rest = rest[open.upperBound...]
            var depth = 1
            var current = ""
            for character in rest {
                if character == "(" { depth += 1 }
                if character == ")" {
                    depth -= 1
                    if depth == 0 { break }
                }
                current.append(character)
            }
            result.append(current)
            guard let next = rest.range(of: ")") else { break }
            rest = rest[next.upperBound...]
        }
        return result
    }

    private func assertNoPII(
        inLinesMatching predicate: (String) -> Bool,
        description: String
    ) throws {
        var violations: [String] = []

        for url in try swiftSources() {
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for (index, line) in contents.components(separatedBy: .newlines).enumerated() {
                guard predicate(line) else { continue }
                for fragment in interpolations(in: line) {
                    for accessor in forbiddenAccessors where fragment.contains(accessor) {
                        let file = url.lastPathComponent
                        violations.append("\(file):\(index + 1) — \(accessor) в «\(fragment)»")
                    }
                }
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            "\(description) не должны содержать персональные данные:\n" + violations.joined(separator: "\n")
        )
    }

    func testDiagnosticLogEventsCarryNoPersonalData() throws {
        try assertNoPII(
            inLinesMatching: { $0.contains("DiagnosticLog.event(") },
            description: "события DiagnosticLog"
        )
    }

    func testPublicUnifiedLogLinesCarryNoPersonalData() throws {
        try assertNoPII(
            inLinesMatching: { $0.contains("privacy: .public") },
            description: "публичные строки унифицированного лога"
        )
    }

    /// A gate that cannot fail is worthless: these pin the detector itself.
    func testDetectorFlagsAnInterpolatedPersonalField() {
        let line = #"DiagnosticLog.event("sync finished for \(event.title) at \(now)")"#
        let fragments = interpolations(in: line)

        XCTAssertEqual(fragments, ["event.title", "now"])
        XCTAssertTrue(fragments.contains { fragment in
            forbiddenAccessors.contains { fragment.contains($0) }
        })
    }

    func testDetectorIgnoresCountsAndStatuses() {
        let line = #"DiagnosticLog.event("accounts=\(accounts.count) events=\(events.count)")"#
        let fragments = interpolations(in: line)

        XCTAssertEqual(fragments, ["accounts.count", "events.count"])
        XCTAssertFalse(fragments.contains { fragment in
            forbiddenAccessors.contains { fragment.contains($0) }
        })
    }

    func testGateActuallyInspectsSources() throws {
        // Guards against the scan silently matching nothing (wrong path, renamed directory).
        let sources = try swiftSources()
        XCTAssertGreaterThan(sources.count, 20, "сканер не нашёл исходники в \(sourceRoot.path)")
    }
}
