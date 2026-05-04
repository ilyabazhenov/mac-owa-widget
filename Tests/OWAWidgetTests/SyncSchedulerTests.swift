import XCTest
@testable import OWAWidget

final class SyncSchedulerTests: XCTestCase {
    func testSchedulerDoesNotRunWorkImmediatelyOnStart() async throws {
        let scheduler = SyncScheduler()
        let counter = AsyncCounter()

        await scheduler.start(interval: 0.2) {
            await counter.increment()
        }

        try await Task.sleep(for: .milliseconds(50))
        let value = await counter.value
        await scheduler.stop()

        XCTAssertEqual(value, 0)
    }
}

private actor AsyncCounter {
    private var count = 0

    var value: Int { count }

    func increment() {
        count += 1
    }
}
