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
}
