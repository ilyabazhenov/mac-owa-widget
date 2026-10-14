#if DEBUG
import XCTest
@testable import OWAWidget

/// DEBUG-трейсы содержат самую сырую PII в проекте — тела OWA-ответов, FreeBusy, выдачу GAL.
/// Раньше защитой были права 0600; теперь они шифруются, и проверять надо именно это.
final class DebugLogLocationTests: XCTestCase {

    private func uniqueName(_ label: String) -> String {
        "\(label)-\(UUID().uuidString).log"
    }

    override func tearDown() {
        super.tearDown()
    }

    func testWriteThenReadRoundTrips() {
        let name = uniqueName("roundtrip")
        defer { DebugLogLocation.remove(name) }

        DebugLogLocation.write("первая строка\n", to: name)
        XCTAssertEqual(DebugLogLocation.readText(name), "первая строка\n")
    }

    func testWriteReplacesPreviousContent() {
        let name = uniqueName("replace")
        defer { DebugLogLocation.remove(name) }

        DebugLogLocation.write("старое\n", to: name)
        DebugLogLocation.write("новое\n", to: name)
        XCTAssertEqual(DebugLogLocation.readText(name), "новое\n")
    }

    func testAppendAccumulatesLines() {
        let name = uniqueName("append")
        defer { DebugLogLocation.remove(name) }

        DebugLogLocation.write("=== заголовок ===\n", to: name)
        DebugLogLocation.append("строка 1\n", to: name)
        DebugLogLocation.append("строка 2\n", to: name)

        XCTAssertEqual(DebugLogLocation.readText(name), "=== заголовок ===\nстрока 1\nстрока 2\n")
    }

    func testAppendToMissingTraceStartsIt() {
        let name = uniqueName("append-fresh")
        defer { DebugLogLocation.remove(name) }

        DebugLogLocation.append("первая\n", to: name)
        XCTAssertEqual(DebugLogLocation.readText(name), "первая\n")
    }

    func testReadReturnsNilForUnknownTrace() {
        XCTAssertNil(DebugLogLocation.read(uniqueName("never-written")))
    }

    func testRemoveDeletesTrace() {
        let name = uniqueName("remove")
        DebugLogLocation.write("что-то\n", to: name)
        DebugLogLocation.remove(name)
        XCTAssertNil(DebugLogLocation.read(name))
    }

    func testRotateMovesContentAndClearsSource() {
        let current = uniqueName("rotate-current")
        let previous = uniqueName("rotate-previous")
        defer {
            DebugLogLocation.remove(current)
            DebugLogLocation.remove(previous)
        }

        DebugLogLocation.write("сессия\n", to: current)
        DebugLogLocation.rotate(from: current, to: previous)

        XCTAssertEqual(DebugLogLocation.readText(previous), "сессия\n")
        XCTAssertNil(DebugLogLocation.read(current))
    }

    func testTraceIsNotReadableOnDisk() throws {
        let name = uniqueName("ondisk")
        defer { DebugLogLocation.remove(name) }

        let secret = "ivan.petrov@corp.example.com"
        DebugLogLocation.write("attendee=\(secret)\n", to: name)

        let url = SecureStore.shared.url(for: DebugLogLocation.storageName(for: name))
        let raw = try Data(contentsOf: url)
        XCTAssertNil(raw.range(of: Data(secret.utf8)), "PII читается на диске открытым текстом")
    }

    // MARK: - Bounded growth

    func testDroppingOldestHalfCutsOnALineBoundary() {
        let content = Data("aaaa\nbbbb\ncccc\ndddd\n".utf8)
        let trimmed = DebugLogLocation.droppingOldestHalf(of: content)

        let text = String(data: trimmed, encoding: .utf8)
        XCTAssertEqual(text, "cccc\ndddd\n", "обрубок должен начинаться с целой строки")
    }

    func testDroppingOldestHalfHandlesContentWithoutNewlines() {
        let trimmed = DebugLogLocation.droppingOldestHalf(of: Data("abcdefgh".utf8))
        XCTAssertEqual(String(data: trimmed, encoding: .utf8), "efgh")
    }

    func testTraceStaysBoundedWhenCallerHasNoSizeCap() {
        // `owaclient.log` and `findpeople_trace.log` never rotate themselves, so the store has to
        // stop them growing without limit in memory and on disk.
        let name = uniqueName("unbounded")
        defer { DebugLogLocation.remove(name) }

        let chunk = String(repeating: "x", count: 64 * 1024 - 1) + "\n"
        let target = DebugLogLocation.maxTraceBytes + 1024 * 1024
        var written = 0
        while written < target {
            DebugLogLocation.append(chunk, to: name)
            written += chunk.utf8.count
        }

        let size = DebugLogLocation.size(of: name)
        XCTAssertGreaterThan(written, DebugLogLocation.maxTraceBytes)
        XCTAssertLessThanOrEqual(size, DebugLogLocation.maxTraceBytes, "трейс перерос потолок")
        XCTAssertGreaterThan(size, 0, "трейс не должен обнуляться при ротации")
    }

    func testStorageNameStripsPathAndExtensionSeparators() {
        XCTAssertEqual(DebugLogLocation.storageName(for: "sample.log"), "debug-sample-log")
        XCTAssertEqual(DebugLogLocation.storageName(for: "a/b.json"), "debug-a-b-json")
    }

    // MARK: - Pruning dumps

    private func makeStore() -> (SecureStore, URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("debug-prune-\(UUID().uuidString)", isDirectory: true)
        return (SecureStore(directory: directory, keyProvider: InMemorySecureStoreKeyProvider()), directory)
    }

    /// Dumps live next to the accounts and the event cache: pruning must touch its own prefix
    /// and nothing else, and keep the newest.
    func testPruneKeepsNewestDumpsAndTouchesNothingElse() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        for minute in 10..<20 {
            let name = DebugLogLocation.storageName(for: "getcalendarview-2026-10-14T10-\(minute)-00Z-status200-req1-sync1.json")
            try store.write(Data("{}".utf8), name: name)
        }
        let others = ["calendarAccounts", "events", "debug-owaclient-log", "debug-getcalendarevent_last-json"]
        for other in others {
            try store.write(Data("x".utf8), name: other)
        }

        DebugLogLocation.prune(fileNamePrefix: "getcalendarview-", keep: 3, store: store)

        let dumps = store.names(withPrefix: "debug-getcalendarview-")
        XCTAssertEqual(dumps.count, 3)
        XCTAssertTrue(dumps.allSatisfy { $0.contains("T10-17") || $0.contains("T10-18") || $0.contains("T10-19") })
        for other in others {
            XCTAssertTrue(store.exists(other), other)
        }
    }

    func testEmptyPrefixPrunesNothing() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.write(Data("x".utf8), name: "debug-a")

        DebugLogLocation.prune(fileNamePrefix: "", keep: 0, store: store)
        XCTAssertTrue(store.exists("debug-a"))
        XCTAssertEqual(store.names(withPrefix: ""), [])
    }
}
#endif
