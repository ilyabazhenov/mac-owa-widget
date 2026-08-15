import XCTest
@testable import OWAWidget

/// Cleanup of the cleartext debug artefacts earlier versions left behind.
///
/// Everything here runs against a temporary tree: the production entry point is guarded by
/// `SecureStore.isRunningTests`, and this exercises the same logic with an injected root.
final class SecureStoreMigratorTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("migrator-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    private func makeDirectory(_ name: String, files: Int = 1) throws {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for index in 0..<files {
            try Data("совещание \(index)".utf8)
                .write(to: directory.appendingPathComponent("dump-\(index).json"))
        }
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path)
    }

    func testRemovesBothLegacyDirectories() throws {
        try makeDirectory("owa-debug", files: 3)
        try makeDirectory("debug", files: 2)

        XCTAssertEqual(SecureStoreMigrator.removeLegacyCleartextDirectories(under: root), 2)
        XCTAssertFalse(exists("owa-debug"))
        XCTAssertFalse(exists("debug"))
    }

    func testRemovesWhatIsThereAndIgnoresWhatIsNot() throws {
        try makeDirectory("owa-debug")

        XCTAssertEqual(SecureStoreMigrator.removeLegacyCleartextDirectories(under: root), 1)
        XCTAssertFalse(exists("owa-debug"))
    }

    func testDoesNothingWhenNothingIsLeftBehind() {
        XCTAssertEqual(SecureStoreMigrator.removeLegacyCleartextDirectories(under: root), 0)
    }

    func testIsIdempotent() throws {
        try makeDirectory("owa-debug")
        XCTAssertEqual(SecureStoreMigrator.removeLegacyCleartextDirectories(under: root), 1)
        XCTAssertEqual(SecureStoreMigrator.removeLegacyCleartextDirectories(under: root), 0)
    }

    func testLeavesEverythingElseAlone() throws {
        try makeDirectory("owa-debug")
        try makeDirectory("store", files: 2)
        try Data("diagnostics".utf8).write(to: root.appendingPathComponent("diagnostic.log"))

        SecureStoreMigrator.removeLegacyCleartextDirectories(under: root)

        XCTAssertFalse(exists("owa-debug"))
        XCTAssertTrue(exists("store"), "зашифрованные контейнеры трогать нельзя")
        XCTAssertTrue(exists("diagnostic.log"), "диагностический лог удалять нельзя")
    }

    func testIgnoresAFileNamedLikeALegacyDirectory() throws {
        // Only directories are removed — a stray file with the same name is left alone rather
        // than deleted on a name match.
        try Data("не каталог".utf8).write(to: root.appendingPathComponent("owa-debug"))

        XCTAssertEqual(SecureStoreMigrator.removeLegacyCleartextDirectories(under: root), 0)
        XCTAssertTrue(exists("owa-debug"))
    }

    func testProductionEntryPointIsInertUnderTests() {
        // The guard is what keeps `swift test` from deleting the developer's own directories.
        XCTAssertTrue(SecureStore.isRunningTests)
        SecureStoreMigrator.removeLegacyCleartextDebugDirectories()
    }
}
