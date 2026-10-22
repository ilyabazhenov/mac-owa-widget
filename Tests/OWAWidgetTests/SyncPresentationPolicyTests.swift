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

    func testShowsErrorWhenAuthRequiredAndNoEvents() {
        XCTAssertTrue(
            SyncPresentationPolicy.shouldShowErrorState(
                syncStatus: .authenticationRequired,
                eventsCount: 0
            )
        )
    }

    func testDoesNotShowErrorWhenAuthRequiredButCachedEventsExist() {
        XCTAssertFalse(
            SyncPresentationPolicy.shouldShowErrorState(
                syncStatus: .authenticationRequired,
                eventsCount: 3
            )
        )
    }

    // MARK: - Empty day note

    private let day = Date(timeIntervalSince1970: 1_800_000_000)
    private var coverageAroundDay: EventCoverage {
        EventCoverage(start: day.addingTimeInterval(-7 * 86_400), end: day.addingTimeInterval(30 * 86_400), refreshedAt: day)
    }

    func testEmptyDayIsLoadingBeforeTheFirstSync() {
        for status in [SyncStatus.idle, .syncing] {
            XCTAssertEqual(
                SyncPresentationPolicy.emptyDayNote(eventsAreEmpty: true, coverage: nil, syncStatus: status, dayStart: day),
                .loading
            )
        }
    }

    func testEmptyCalendarDoesNotTurnIntoASpinnerOnLaterSyncs() {
        XCTAssertEqual(
            SyncPresentationPolicy.emptyDayNote(eventsAreEmpty: true, coverage: coverageAroundDay, syncStatus: .syncing, dayStart: day),
            .free
        )
    }

    func testFailedFirstSyncClaimsNothing() {
        XCTAssertNil(SyncPresentationPolicy.emptyDayNote(eventsAreEmpty: true, coverage: nil, syncStatus: .offlineCached("no VPN"), dayStart: day))
        XCTAssertNil(SyncPresentationPolicy.emptyDayNote(eventsAreEmpty: true, coverage: nil, syncStatus: .error("down"), dayStart: day))
    }

    func testDayOutsideTheCoverageClaimsNothing() {
        let later = day.addingTimeInterval(40 * 86_400)
        XCTAssertNil(SyncPresentationPolicy.emptyDayNote(eventsAreEmpty: false, coverage: coverageAroundDay, syncStatus: .lastSynced(day), dayStart: later))
    }

    func testCoveredDayIsFree() {
        XCTAssertEqual(
            SyncPresentationPolicy.emptyDayNote(eventsAreEmpty: false, coverage: coverageAroundDay, syncStatus: .offlineCached("no VPN"), dayStart: day),
            .free
        )
    }
}
