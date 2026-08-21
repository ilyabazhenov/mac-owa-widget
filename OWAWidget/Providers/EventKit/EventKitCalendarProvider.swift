import Foundation
import os.log

/// Reads meetings from the calendars macOS already syncs (Google, iCloud, local) through EventKit.
///
/// Read-only by design: every mutating method of `CalendarProvider` keeps its `notSupported`
/// default. The UI degrades on its own — RSVP controls key off `changeKey`, which this provider
/// never sets, and the create-meeting entry point checks `AccountType.supportsMeetingCreation`.
actor EventKitCalendarProvider: CalendarProvider {
    nonisolated let account: CalendarAccount

    private let store: any EventKitStoring
    private let mapper: EventKitEventMapper
    private let log = Logger(subsystem: "com.owawidget", category: "EventKitCalendarProvider")

    init(
        account: CalendarAccount,
        store: any EventKitStoring = SystemEventKitStore.shared,
        mapper: EventKitEventMapper = EventKitEventMapper()
    ) {
        self.account = account
        self.store = store
        self.mapper = mapper
        #if DEBUG
        Self.setupDebugLog()
        #endif
    }

    func fetchEvents(from start: Date, to end: Date) async throws -> [CalendarEvent] {
        let accountID = String(account.id.uuidString.prefix(8))
        guard let identifiers = selectedCalendarIdentifiers() else {
            log.info("EventKit account \(accountID, privacy: .public) has no calendars selected")
            #if DEBUG
            dlog("fetch skipped account=\(accountID): no calendars selected")
            #endif
            return []
        }

        // Ask for access if macOS has no decision on record.
        //
        // Reached in exactly one situation that matters: the app was updated. TCC ties a grant to
        // the code signature, this app is ad-hoc signed, so every new build looks like a stranger
        // and the permission silently reverts to undecided. Without this the account keeps
        // existing and syncing keeps failing until the user thinks to reopen its settings.
        //
        // It cannot fire for someone who has not already granted once — an EventKit account can
        // only be created after the picker has listed their calendars — and never for someone who
        // said no, because a denial is a decision.
        let access = try await store.ensureReadAccess()
        if access != .fullAccess {
            log.warning(
                "EventKit access unavailable account=\(accountID, privacy: .public) status=\(String(describing: access), privacy: .public)"
            )
            #if DEBUG
            dlog("fetch blocked account=\(accountID): access=\(access)")
            #endif
        }

        let snapshots = try await store.events(
            from: start,
            to: end,
            calendarIdentifiers: identifiers
        )
        let events = snapshots
            .compactMap { mapper.map($0, accountID: account.id) }
            .sorted { $0.startDate < $1.startDate }

        log.info(
            "EventKit fetch complete account=\(accountID, privacy: .public) raw=\(snapshots.count, privacy: .public) mapped=\(events.count, privacy: .public)"
        )
        #if DEBUG
        dlog("fetch account=\(accountID) window=\(start)...\(end) raw=\(snapshots.count) mapped=\(events.count)")
        for snapshot in snapshots.prefix(20) {
            dlog("  raw title=\(snapshot.title ?? "nil") cal=\(snapshot.calendarTitle) recurring=\(snapshot.hasRecurrenceRules) url=\(snapshot.url?.absoluteString ?? "nil") notesLen=\(snapshot.notes?.count ?? 0)")
        }
        for event in events.prefix(20) {
            dlog("  mapped id=\(event.id) title=\(event.title) join=\(event.joinURL?.absoluteString ?? "nil") platform=\(event.platform.rawValue) rsvp=\(event.responseType.rawValue)")
        }
        #endif
        return events
    }

    func validateCredentials() async throws {
        var status = await store.authorizationStatus()
        if status == .notDetermined {
            status = try await store.requestAccess()
        }
        switch status {
        case .fullAccess: return
        case .writeOnly: throw EventKitStoreError.writeOnlyAccess
        case .notDetermined: throw EventKitStoreError.accessNotDetermined
        case .denied, .restricted: throw EventKitStoreError.accessDenied
        }
    }

    /// Participants and the full note already arrive with the event, so this only ever runs for an
    /// event restored from a cache written before that was true.
    func fetchDetails(for event: CalendarEvent) async throws -> CalendarEventDetails {
        guard let identifiers = selectedCalendarIdentifiers() else {
            throw CalendarProviderError.notSupported
        }
        let snapshots = try await store.events(
            from: event.startDate.addingTimeInterval(-1),
            to: event.endDate.addingTimeInterval(1),
            calendarIdentifiers: identifiers
        )
        guard
            let match = snapshots.first(where: { EventKitEventMapper.identity(for: $0) == event.id }),
            let mapped = mapper.map(match, accountID: account.id)
        else {
            throw CalendarProviderError.notSupported
        }
        return CalendarEventDetails(
            attendees: mapped.detailedAttendees ?? [],
            body: mapped.fullBody,
            bodyHTML: nil
        )
    }

    /// Calendar identifiers to query, or `nil` when the account deliberately selects none.
    ///
    /// A never-configured account (`nil` in the model) reads every calendar; an account whose
    /// selection is an empty list reads nothing. Collapsing the two would turn "I unchecked
    /// everything" into "show me all of it".
    private func selectedCalendarIdentifiers() -> [String]? {
        guard let selected = account.calendarIdentifiers else { return [] }
        return selected.isEmpty ? nil : selected
    }

    #if DEBUG
    private static let debugLogURL = URL(fileURLWithPath: "/tmp/owawidget_eventkit.log")

    private static func setupDebugLog() {
        let header = "=== EventKitCalendarProvider log started \(Date()) ===\n"
        try? header.write(to: debugLogURL, atomically: true, encoding: .utf8)
    }

    private func dlog(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: Self.debugLogURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: Self.debugLogURL, options: .atomic)
        }
    }
    #endif
}
