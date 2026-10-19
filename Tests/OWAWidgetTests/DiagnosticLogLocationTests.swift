import XCTest
@testable import OWAWidget

/// `swift test` used to rotate the running app's `diagnostic.log` away and fill it with test
/// accounts' lines, so the log of a real bug mixed with the suite's.
final class DiagnosticLogLocationTests: XCTestCase {
    func testTestsWriteTheLogToATemporaryFolder() throws {
        let directory = try XCTUnwrap(DiagnosticLog.directory)
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        XCTAssertFalse(directory.standardizedFileURL.path.hasPrefix(support.standardizedFileURL.path), directory.path)
        XCTAssertTrue(directory.standardizedFileURL.path.hasPrefix(URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL.path), directory.path)

        let marker = "test marker \(UUID().uuidString)"
        DiagnosticLog.event(marker)
        XCTAssertTrue(DiagnosticLog.report().contains(marker), "the log still works, only elsewhere")
    }
}
