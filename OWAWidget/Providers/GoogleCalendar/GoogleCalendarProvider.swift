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

    var errorDescription: String? {
        switch self {
        case .notImplemented(let name):
            return "\(name) provider is not yet implemented"
        case .notSupported:
            return "This calendar provider does not support responding to meeting invitations."
        }
    }
}
