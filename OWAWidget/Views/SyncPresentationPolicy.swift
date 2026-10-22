import Foundation

enum SyncPresentationPolicy {
    /// Whether the popover should replace the day timeline with the error state.
    ///
    /// Derived from `blocksSync` instead of listing the cases: an `if case` chain silently ignores
    /// any status added later, which is how a suspended sync ended up rendering as an ordinary
    /// empty day.
    static func shouldShowErrorState(syncStatus: SyncStatus, eventsCount: Int) -> Bool {
        guard eventsCount == 0 else { return false }
        if case .error = syncStatus { return true }
        return syncStatus.blocksSync
    }

    /// What the timeline says over a day without timed meetings.
    enum EmptyDayNote: Equatable {
        /// No calendar has arrived yet and one is on its way.
        case loading
        /// The day was read and is free.
        case free
    }

    /// `loading` only while no calendar has ever arrived — neither a finished sync nor a cache
    /// from an earlier run — and a sync is coming; asked of the coverage rather than the status
    /// alone, so an empty calendar does not show a spinner on every periodic sync. `free` only for
    /// a day the coverage includes: after a failed first sync nothing is known, and no note says
    /// less than a confident "no meetings".
    static func emptyDayNote(
        eventsAreEmpty: Bool,
        coverage: EventCoverage?,
        syncStatus: SyncStatus,
        dayStart: Date
    ) -> EmptyDayNote? {
        guard let coverage else {
            guard eventsAreEmpty else { return nil }
            switch syncStatus {
            case .idle, .syncing: return .loading
            default: return nil
            }
        }
        return coverage.start <= dayStart && dayStart < coverage.end ? .free : nil
    }
}
