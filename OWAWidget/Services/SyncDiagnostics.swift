import Foundation

/// Carries a correlation id through CalendarService -> provider -> OWAClient.
///
/// OWA failures are intermittent and can only be understood by comparing the
/// sequence of auth, folder selection, fallback, retries, and final status for
/// one sync attempt. TaskLocal keeps that id available across child tasks
/// without threading diagnostic parameters through the calendar provider API.
enum SyncDiagnostics {
    @TaskLocal static var syncID: Int?

    static var syncIDText: String {
        syncID.map(String.init) ?? "-"
    }
}
