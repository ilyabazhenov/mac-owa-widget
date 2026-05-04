import Foundation

/// Prevents manual refresh bursts from amplifying transient OWA server faults.
///
/// Logs showed repeated user-triggered refreshes could produce many sequential
/// `GetCalendarView` calls in a few seconds. OWA sometimes responds to that
/// pattern with fast HTTP 500 `Cannot create an abstract class` faults instead
/// of a clean throttling status. This gate keeps the UI responsive while
/// reducing request pressure on the Exchange backend.
struct SyncRequestGate {
    enum Decision: Equatable {
        case allow
        case reject(RejectionReason)
    }

    enum RejectionReason: Equatable {
        case alreadySyncing
        case tooSoonAfterSync
        case transientFailureCooldown
    }

    // Chosen from observed logs: successful requests normally complete in
    // hundreds of ms, while bad OWA windows can last tens of seconds.
    private let minimumManualSpacing: TimeInterval = 15
    private let transientFailureCooldown: TimeInterval = 30

    private var lastSyncStartedAt: Date?
    private var transientFailureCooldownUntil: Date?

    mutating func manualSyncDecision(now: Date, hasActiveSync: Bool) -> Decision {
        if hasActiveSync {
            return .reject(.alreadySyncing)
        }

        if let transientFailureCooldownUntil, now < transientFailureCooldownUntil {
            return .reject(.transientFailureCooldown)
        }

        if let lastSyncStartedAt,
           now.timeIntervalSince(lastSyncStartedAt) < minimumManualSpacing {
            return .reject(.tooSoonAfterSync)
        }

        return .allow
    }

    mutating func recordSyncStarted(at date: Date) {
        lastSyncStartedAt = date
    }

    mutating func recordTransientFailure(at date: Date) {
        transientFailureCooldownUntil = date.addingTimeInterval(transientFailureCooldown)
    }

    mutating func recordSyncSucceeded() {
        transientFailureCooldownUntil = nil
    }
}
