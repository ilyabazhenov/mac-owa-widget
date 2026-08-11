import Foundation

/// Abstraction over calendar backends (EWS, Google Calendar, etc.)
/// Each implementation is an Actor for safe concurrent access.
protocol CalendarProvider: Actor {
    nonisolated var account: CalendarAccount { get }
    func fetchEvents(from start: Date, to end: Date) async throws -> [CalendarEvent]
    func validateCredentials() async throws
    func respondToMeeting(_ event: CalendarEvent, action: MeetingResponseAction) async throws
    func fetchDetails(for event: CalendarEvent) async throws -> CalendarEventDetails
    func findPeople(query: String) async throws -> [ResolvedAttendee]
    func resolveOrganizerSMTPEmail() async throws -> String?
    func getUserAvailability(emails: [String], from start: Date, to end: Date) async throws -> [AttendeeAvailability]
    func createMeeting(
        title: String,
        agenda: String,
        location: String,
        start: Date,
        end: Date,
        requiredAttendees: [ResolvedAttendee],
        optionalAttendees: [ResolvedAttendee]
    ) async throws
}

extension CalendarProvider {
    func respondToMeeting(_ event: CalendarEvent, action: MeetingResponseAction) async throws {
        throw CalendarProviderError.notSupported
    }

    func fetchDetails(for event: CalendarEvent) async throws -> CalendarEventDetails {
        throw CalendarProviderError.notSupported
    }

    func findPeople(query: String) async throws -> [ResolvedAttendee] {
        throw CalendarProviderError.notSupported
    }

    func resolveOrganizerSMTPEmail() async throws -> String? {
        return nil
    }

    func getUserAvailability(emails: [String], from start: Date, to end: Date) async throws -> [AttendeeAvailability] {
        throw CalendarProviderError.notSupported
    }

    func createMeeting(
        title: String,
        agenda: String,
        location: String,
        start: Date,
        end: Date,
        requiredAttendees: [ResolvedAttendee],
        optionalAttendees: [ResolvedAttendee]
    ) async throws {
        throw CalendarProviderError.notSupported
    }
}

