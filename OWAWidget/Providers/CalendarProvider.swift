import Foundation

/// Abstraction over calendar backends (EWS, Google Calendar, etc.)
/// Each implementation is an Actor for safe concurrent access.
protocol CalendarProvider: Actor {
    nonisolated var account: CalendarAccount { get }
    func fetchEvents(from start: Date, to end: Date) async throws -> [CalendarEvent]
    func validateCredentials() async throws
    func respondToMeeting(_ event: CalendarEvent, action: MeetingResponseAction) async throws
}

extension CalendarProvider {
    func respondToMeeting(_ event: CalendarEvent, action: MeetingResponseAction) async throws {
        throw CalendarProviderError.notSupported
    }
}

