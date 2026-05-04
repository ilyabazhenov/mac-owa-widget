import XCTest
@testable import OWAWidget

final class SyncRequestGateTests: XCTestCase {
    func testAllowsManualSyncWhenIdleAndOutsideCooldowns() {
        var gate = SyncRequestGate()
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertEqual(
            gate.manualSyncDecision(now: now, hasActiveSync: false),
            .allow
        )
    }

    func testRejectsManualSyncWhenAnotherSyncIsActive() {
        var gate = SyncRequestGate()

        XCTAssertEqual(
            gate.manualSyncDecision(now: Date(timeIntervalSince1970: 1_000), hasActiveSync: true),
            .reject(.alreadySyncing)
        )
    }

    func testRejectsManualSyncSoonAfterAnySyncStart() {
        var gate = SyncRequestGate()
        let firstSync = Date(timeIntervalSince1970: 1_000)

        gate.recordSyncStarted(at: firstSync)

        XCTAssertEqual(
            gate.manualSyncDecision(
                now: firstSync.addingTimeInterval(5),
                hasActiveSync: false
            ),
            .reject(.tooSoonAfterSync)
        )
    }

    func testAllowsManualSyncAfterMinimumSpacing() {
        var gate = SyncRequestGate()
        let firstSync = Date(timeIntervalSince1970: 1_000)

        gate.recordSyncStarted(at: firstSync)

        XCTAssertEqual(
            gate.manualSyncDecision(
                now: firstSync.addingTimeInterval(15),
                hasActiveSync: false
            ),
            .allow
        )
    }

    func testRejectsManualSyncDuringTransientFailureCooldown() {
        var gate = SyncRequestGate()
        let failureTime = Date(timeIntervalSince1970: 1_000)

        gate.recordTransientFailure(at: failureTime)

        XCTAssertEqual(
            gate.manualSyncDecision(
                now: failureTime.addingTimeInterval(20),
                hasActiveSync: false
            ),
            .reject(.transientFailureCooldown)
        )
    }

    func testAllowsManualSyncAfterTransientFailureCooldown() {
        var gate = SyncRequestGate()
        let failureTime = Date(timeIntervalSince1970: 1_000)

        gate.recordTransientFailure(at: failureTime)

        XCTAssertEqual(
            gate.manualSyncDecision(
                now: failureTime.addingTimeInterval(31),
                hasActiveSync: false
            ),
            .allow
        )
    }
}
