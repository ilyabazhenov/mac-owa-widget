import XCTest
@testable import OWAWidget

/// DEBUG status logs moved out of `/tmp`: the files must not be readable by other users and a
/// symlink planted under the log's name must not redirect the writes.
final class DebugTextLogTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("debug-text-log-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    func testFileIsOwnerOnlyAndAppends() throws {
        let path = directory.appendingPathComponent("a.log").path
        DebugTextLog.write(Data("one\n".utf8), toPath: path, truncate: true)
        DebugTextLog.write(Data("two\n".utf8), toPath: path, truncate: false)

        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "one\ntwo\n")
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int)
        XCTAssertEqual(mode & 0o777, 0o600)
    }

    func testLoosePermissionsFromAnOlderBuildAreTightened() throws {
        let path = directory.appendingPathComponent("old.log").path
        XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: Data(), attributes: [.posixPermissions: 0o644]))
        DebugTextLog.write(Data("x\n".utf8), toPath: path, truncate: false)

        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int)
        XCTAssertEqual(mode & 0o777, 0o600)
    }

    func testSymlinkIsNotFollowed() throws {
        let victim = directory.appendingPathComponent("victim.txt").path
        XCTAssertTrue(FileManager.default.createFile(atPath: victim, contents: Data("keep\n".utf8)))
        let link = directory.appendingPathComponent("planted.log").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: victim)

        DebugTextLog.write(Data("meeting title\n".utf8), toPath: link, truncate: false)
        DebugTextLog.write(Data("meeting title\n".utf8), toPath: link, truncate: true)

        XCTAssertEqual(try String(contentsOfFile: victim, encoding: .utf8), "keep\n")
    }
}
