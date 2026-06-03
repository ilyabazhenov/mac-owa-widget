import Foundation

enum SyncPresentationPolicy {
    static func shouldShowErrorState(syncStatus: SyncStatus, eventsCount: Int) -> Bool {
        guard eventsCount == 0 else { return false }
        if case .error = syncStatus { return true }
        if case .authenticationRequired = syncStatus { return true }
        if case .certificateTrustRequired = syncStatus { return true }
        return false
    }
}
