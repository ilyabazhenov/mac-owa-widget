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
    /// `nil` when the address is not in the address book.
    func organizationHierarchy(email: String) async throws -> OrgHierarchy?
    /// `nil` when the address book has nobody with this address.
    func personProfile(email: String) async throws -> PersonProfile?
    func resolveOrganizerSMTPEmail() async throws -> String?
    func getUserAvailability(emails: [String], from start: Date, to end: Date) async throws -> [AttendeeAvailability]
    func createMeeting(
        title: String,
        agenda: RichText,
        location: String,
        start: Date,
        end: Date,
        requiredAttendees: [ResolvedAttendee],
        optionalAttendees: [ResolvedAttendee]
    ) async throws
    func removeMeeting(_ event: CalendarEvent, mode: MeetingRemovalMode, message: String) async throws
}

extension CalendarProvider {
    func removeMeeting(_ event: CalendarEvent, mode: MeetingRemovalMode, message: String) async throws {
        throw CalendarProviderError.notSupported
    }

    func respondToMeeting(_ event: CalendarEvent, action: MeetingResponseAction) async throws {
        throw CalendarProviderError.notSupported
    }

    func fetchDetails(for event: CalendarEvent) async throws -> CalendarEventDetails {
        throw CalendarProviderError.notSupported
    }

    func findPeople(query: String) async throws -> [ResolvedAttendee] {
        throw CalendarProviderError.notSupported
    }

    func organizationHierarchy(email: String) async throws -> OrgHierarchy? {
        throw CalendarProviderError.notSupported
    }

    func personProfile(email: String) async throws -> PersonProfile? {
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
        agenda: RichText,
        location: String,
        start: Date,
        end: Date,
        requiredAttendees: [ResolvedAttendee],
        optionalAttendees: [ResolvedAttendee]
    ) async throws {
        throw CalendarProviderError.notSupported
    }
}

