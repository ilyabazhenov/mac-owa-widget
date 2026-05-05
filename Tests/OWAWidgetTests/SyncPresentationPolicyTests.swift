import XCTest
@testable import OWAWidget

final class SyncPresentationPolicyTests: XCTestCase {
    func testShowsErrorWhenSyncFailedAndNoEventsAvailable() {
        XCTAssertTrue(
            SyncPresentationPolicy.shouldShowErrorState(
                syncStatus: .error("offline"),
                eventsCount: 0
            )
        )
    }

    func testDoesNotShowErrorWhenSyncFailedButCachedEventsExist() {
        XCTAssertFalse(
            SyncPresentationPolicy.shouldShowErrorState(
                syncStatus: .offlineCached("offline"),
                eventsCount: 3
            )
        )
        XCTAssertFalse(
            SyncPresentationPolicy.shouldShowErrorState(
                syncStatus: .error("offline"),
                eventsCount: 3
            )
        )
    }
}
