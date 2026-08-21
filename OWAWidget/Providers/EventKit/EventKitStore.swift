import EventKit
import Foundation

/// Read access to the calendars macOS already syncs.
///
/// A protocol so the provider and the settings UI can be driven by a fake: constructing a real
/// `EKEventStore` in tests risks a TCC prompt, and `swift test` gates `make release-package`.
protocol EventKitStoring: Sendable {
    func authorizationStatus() async -> EventKitAccessStatus
    /// Triggers the system prompt when the status is `notDetermined`; returns the resulting status.
    func requestAccess() async throws -> EventKitAccessStatus
    /// Asks for access only if the system has no decision on record, and returns where things
    /// stand afterwards. A no-op once the user has answered, either way.
    func ensureReadAccess() async throws -> EventKitAccessStatus
    /// Event calendars visible to this Mac, across all configured accounts.
    func calendars() async throws -> [EventKitCalendarSnapshot]
    /// Events in the window. An empty `calendarIdentifiers` reads every calendar.
    func events(
        from start: Date,
        to end: Date,
        calendarIdentifiers: [String]
    ) async throws -> [EventKitEventSnapshot]
}

extension EventKitStoring {
    func ensureReadAccess() async throws -> EventKitAccessStatus {
        let current = await authorizationStatus()
        guard current == .notDetermined else { return current }
        return try await requestAccess()
    }
}

enum EventKitStoreError: Error, LocalizedError, Sendable {
    case accessDenied
    case accessNotDetermined
    case writeOnlyAccess

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            "OWA Widget is not allowed to read your calendars. Grant access in System Settings › Privacy & Security › Calendars."
        case .accessNotDetermined:
            "Calendar access has not been granted yet."
        case .writeOnlyAccess:
            "OWA Widget was granted write-only calendar access, which cannot be used to read meetings. Grant full access in System Settings › Privacy & Security › Calendars."
        }
    }
}

/// `EKEventStore`-backed implementation. An actor because `EKEventStore` is not `Sendable` and
/// must never leak out of here — everything crossing the boundary is a snapshot value.
actor SystemEventKitStore: EventKitStoring {
    static let shared = SystemEventKitStore()

    private let store = EKEventStore()
    private var isRequestingAccess = false

    /// Overrides the protocol default to make the check-and-request pair safe against reentrancy.
    ///
    /// The default would let two concurrent fetches both read `notDetermined` and both call
    /// `requestAccess` — actors suspend at every `await`, so the isolation alone guarantees
    /// nothing here — and the user would answer two dialogs for one question. A second caller
    /// arriving mid-request is told the status is still undecided; its fetch fails for this cycle
    /// and the next one sees the answer.
    func ensureReadAccess() async throws -> EventKitAccessStatus {
        let current = authorizationStatus()
        guard current == .notDetermined, !isRequestingAccess else { return current }
        isRequestingAccess = true
        defer { isRequestingAccess = false }
        return try await requestAccess()
    }

    func authorizationStatus() -> EventKitAccessStatus {
        Self.mapStatus(EKEventStore.authorizationStatus(for: .event))
    }

    func requestAccess() async throws -> EventKitAccessStatus {
        if #available(macOS 14.0, *) {
            _ = try await store.requestFullAccessToEvents()
        } else {
            // Deprecated in macOS 14 but the only entry point on macOS 13, which is still the
            // package's deployment target.
            _ = try await store.requestAccess(to: .event)
        }
        return authorizationStatus()
    }

    func calendars() throws -> [EventKitCalendarSnapshot] {
        try requireReadAccess()
        store.refreshSourcesIfNecessary()
        return store.calendars(for: .event).map { calendar in
            EventKitCalendarSnapshot(
                identifier: calendar.calendarIdentifier,
                title: calendar.title,
                sourceIdentifier: calendar.source.sourceIdentifier,
                sourceTitle: calendar.source.title,
                allowsModifications: calendar.allowsContentModifications
            )
        }
    }

    func events(
        from start: Date,
        to end: Date,
        calendarIdentifiers: [String]
    ) throws -> [EventKitEventSnapshot] {
        try requireReadAccess()
        // Pulls anything the sync daemons have queued; the actual network refresh happens on the
        // system's schedule, not ours.
        store.refreshSourcesIfNecessary()

        let all = store.calendars(for: .event)
        let wanted: [EKCalendar]
        if calendarIdentifiers.isEmpty {
            wanted = all
        } else {
            let ids = Set(calendarIdentifiers)
            wanted = all.filter { ids.contains($0.calendarIdentifier) }
        }
        // Reached when every selected calendar has since been deleted or turned off. Returning
        // nothing is the honest answer; falling through to EventKit with an empty calendar list
        // would silently search *all* of them instead.
        guard !wanted.isEmpty else { return [] }

        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: wanted)
        return store.events(matching: predicate).compactMap(Self.snapshot)
    }

    private func requireReadAccess() throws {
        switch authorizationStatus() {
        case .fullAccess: return
        case .writeOnly: throw EventKitStoreError.writeOnlyAccess
        case .notDetermined: throw EventKitStoreError.accessNotDetermined
        case .denied, .restricted: throw EventKitStoreError.accessDenied
        }
    }

    // MARK: - Snapshotting

    /// `EKAuthorizationStatus` is mapped by raw value on purpose.
    ///
    /// `.fullAccess` (macOS 14) and `.authorized` (macOS 13) are the same underlying value 3, so a
    /// `switch` over cases either fails to compile against one SDK or drags `@available` branches
    /// and deprecation warnings into a three-line mapping. The raw values are ABI-stable.
    static func mapStatus(_ status: EKAuthorizationStatus) -> EventKitAccessStatus {
        switch status.rawValue {
        case 0: .notDetermined
        case 1: .restricted
        case 2: .denied
        case 3: .fullAccess
        case 4: .writeOnly
        default: .denied
        }
    }

    private static func snapshot(_ event: EKEvent) -> EventKitEventSnapshot? {
        guard let start = event.startDate, let end = event.endDate else { return nil }
        return EventKitEventSnapshot(
            eventIdentifier: event.eventIdentifier,
            externalIdentifier: event.calendarItemExternalIdentifier,
            calendarIdentifier: event.calendar?.calendarIdentifier ?? "",
            calendarTitle: event.calendar?.title ?? "",
            title: event.title,
            startDate: start,
            endDate: end,
            isAllDay: event.isAllDay,
            occurrenceDate: event.occurrenceDate,
            hasRecurrenceRules: event.hasRecurrenceRules,
            status: mapEventStatus(event.status),
            url: event.url,
            location: event.location,
            notes: event.notes,
            organizer: event.organizer.map(snapshot),
            attendees: (event.attendees ?? []).map(snapshot)
        )
    }

    private static func snapshot(_ participant: EKParticipant) -> EventKitParticipantSnapshot {
        EventKitParticipantSnapshot(
            name: participant.name,
            email: email(from: participant.url),
            isCurrentUser: participant.isCurrentUser,
            role: mapRole(participant.participantRole),
            status: mapParticipantStatus(participant.participantStatus)
        )
    }

    /// Participants carry their address as a `mailto:` URL and nothing else.
    private static func email(from url: URL) -> String? {
        let text = url.absoluteString
        guard text.lowercased().hasPrefix("mailto:") else { return nil }
        let address = String(text.dropFirst("mailto:".count))
            .removingPercentEncoding ?? String(text.dropFirst("mailto:".count))
        return address.isEmpty ? nil : address
    }

    private static func mapEventStatus(_ status: EKEventStatus) -> EventKitEventStatus {
        switch status {
        case .none: .none
        case .confirmed: .confirmed
        case .tentative: .tentative
        case .canceled: .canceled
        @unknown default: .none
        }
    }

    private static func mapRole(_ role: EKParticipantRole) -> EventKitParticipantRole {
        switch role {
        case .unknown: .unknown
        case .required: .required
        case .optional: .optional
        case .chair: .chair
        case .nonParticipant: .nonParticipant
        @unknown default: .unknown
        }
    }

    private static func mapParticipantStatus(_ status: EKParticipantStatus) -> EventKitParticipantStatus {
        switch status {
        case .unknown: .unknown
        case .pending: .pending
        case .accepted: .accepted
        case .declined: .declined
        case .tentative: .tentative
        case .delegated: .delegated
        case .completed: .completed
        case .inProcess: .inProcess
        @unknown default: .unknown
        }
    }
}
