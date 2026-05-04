import Foundation

/// Abstraction over calendar backends (EWS, Google Calendar, etc.)
/// Each implementation is an Actor for safe concurrent access.
protocol CalendarProvider: Actor {
    var account: CalendarAccount { get }
    func fetchEvents(from start: Date, to end: Date) async throws -> [CalendarEvent]
    func validateCredentials() async throws
}
