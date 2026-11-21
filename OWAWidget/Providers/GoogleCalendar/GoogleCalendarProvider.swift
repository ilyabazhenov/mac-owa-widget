import Foundation

// Stub for future Google Calendar integration.
// Implementation: Google Calendar API v3 with OAuth 2.0 + PKCE flow.
actor GoogleCalendarProvider: CalendarProvider {
    nonisolated let account: CalendarAccount

    init(account: CalendarAccount) {
        self.account = account
    }

    func fetchEvents(from start: Date, to end: Date) async throws -> [CalendarEvent] {
        throw CalendarProviderError.notImplemented("Google Calendar")
    }

    func validateCredentials() async throws {
        throw CalendarProviderError.notImplemented("Google Calendar")
    }
}

enum CalendarProviderError: Error, LocalizedError, Sendable {
    case notImplemented(String)
    case notSupported
    /// The meeting was cancelled: there is nothing left to answer.
    case meetingCancelled

    var errorDescription: String? {
        switch self {
        case .meetingCancelled:
            return "This meeting was cancelled by the organizer, so it can no longer be answered."
        case .notImplemented(let name):
            return "\(name) provider is not yet implemented"
        case .notSupported:
            return "This calendar provider does not support responding to meeting invitations."
        }
    }
}
