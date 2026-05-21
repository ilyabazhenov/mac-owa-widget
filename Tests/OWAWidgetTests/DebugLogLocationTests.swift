#if DEBUG
import XCTest
@testable import OWAWidget

final class DebugLogLocationTests: XCTestCase {

    func testReturnsPathUnderApplicationSupportDebugDirectory() {
        guard let url = DebugLogLocation.url(for: "sample.log") else {
            XCTFail("expected URL in Application Support"); return
        }
        let path = url.path
        XCTAssertFalse(path.hasPrefix("/tmp/"), "logs не должны жить в публичной /tmp")
        XCTAssertTrue(path.contains("/Application Support/OWAWidget/debug/"))
        XCTAssertTrue(path.hasSuffix("/sample.log"))
    }

    func testDirectoryIsCreatedWithUserOnlyPermissions() {
        guard let url = DebugLogLocation.url(for: "perms-check.log") else {
            XCTFail(); return
        }
        let dir = url.deletingLastPathComponent()
        let attrs = try? FileManager.default.attributesOfItem(atPath: dir.path)
        let perms = attrs?[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.int16Value, 0o700, "директория должна быть user-only (0700)")
    }

    func testTightenPermissionsAppliesUserOnlyFileMode() throws {
        guard let url = DebugLogLocation.url(for: "tighten-check.log") else {
            XCTFail(); return
        }
        defer { try? FileManager.default.removeItem(at: url) }

        try Data("hello".utf8).write(to: url, options: .atomic)
        DebugLogLocation.tightenPermissions(at: url)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let perms = attrs[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.int16Value, 0o600, "файлы с PII должны быть только-чтение для владельца")
    }

    func testReturnsStableURLAcrossCalls() {
        let a = DebugLogLocation.url(for: "stable.log")
        let b = DebugLogLocation.url(for: "stable.log")
        XCTAssertEqual(a, b)
    }
}
#endif
