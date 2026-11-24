import XCTest
@testable import OWAWidget

/// The bytes `get_mail_attachment` reads in pieces: downloaded once, kept for minutes, bounded.
@MainActor
final class MCPAttachmentStoreTests: XCTestCase {
    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    @MainActor
    private final class Downloads {
        var count = 0
    }

    func testPiecesAskedAtOnceDownloadOnce() async throws {
        let store = MCPAttachmentStore()
        let downloads = Downloads()
        let fetch: @MainActor @Sendable () async throws -> Data = {
            downloads.count += 1
            try await Task.sleep(for: .milliseconds(50))
            return Data([1, 2, 3])
        }
        async let first = store.data(for: "A", download: fetch)
        async let second = store.data(for: "A", download: fetch)
        let (a, b) = try await (first, second)
        XCTAssertEqual(a, Data([1, 2, 3]))
        XCTAssertEqual(b, a)
        XCTAssertEqual(downloads.count, 1)
        _ = try await store.data(for: "A", download: fetch)
        XCTAssertEqual(downloads.count, 1, "the next piece comes from memory")
    }

    func testFileExpiresAfterItsLifetime() async throws {
        let clock = Clock()
        let store = MCPAttachmentStore(clock: { clock.now })
        let downloads = Downloads()
        let fetch: @MainActor @Sendable () async throws -> Data = {
            downloads.count += 1
            return Data([9])
        }
        _ = try await store.data(for: "A", download: fetch)
        clock.now += MCPAttachmentStore.lifetime - 1
        _ = try await store.data(for: "A", download: fetch)
        XCTAssertEqual(downloads.count, 1, "reading keeps it")
        clock.now += MCPAttachmentStore.lifetime
        _ = try await store.data(for: "A", download: fetch)
        XCTAssertEqual(downloads.count, 2)
    }

    func testOldestFileMakesRoom() async throws {
        let store = MCPAttachmentStore()
        let big = Data(count: MCPAttachmentStore.byteLimit / 2)
        let downloads = Downloads()
        func fetch(_ data: Data) -> @MainActor @Sendable () async throws -> Data {
            { downloads.count += 1; return data }
        }
        _ = try await store.data(for: "A", download: fetch(big))
        _ = try await store.data(for: "B", download: fetch(big))
        XCTAssertEqual(store.cachedBytes, MCPAttachmentStore.byteLimit)
        _ = try await store.data(for: "C", download: fetch(Data(count: 10)))
        XCTAssertLessThanOrEqual(store.cachedBytes, MCPAttachmentStore.byteLimit)
        _ = try await store.data(for: "B", download: fetch(big))
        XCTAssertEqual(downloads.count, 3, "B stayed")
        _ = try await store.data(for: "A", download: fetch(big))
        XCTAssertEqual(downloads.count, 4, "A, read longest ago, made room")
    }

    func testFailedDownloadIsNotKept() async throws {
        let store = MCPAttachmentStore()
        do {
            _ = try await store.data(for: "A") { throw MailError.notFound }
            XCTFail("expected an error")
        } catch MailError.notFound {}
        let data = try await store.data(for: "A") { Data([5]) }
        XCTAssertEqual(data, Data([5]))
    }
}
