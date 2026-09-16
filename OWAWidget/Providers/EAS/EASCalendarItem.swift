import Foundation

// MARK: - Dates

/// ActiveSync timestamps.
///
/// The calendar class uses the compact form — `20260915T070000Z` — while some other classes
/// use the extended one with separators. Both are accepted here because a date that fails to
/// parse becomes a meeting that silently does not appear.
/// Parsed by hand rather than with a shared `DateFormatter`.
///
/// Two reasons, and the second is the real one. A cached formatter is shared mutable state that
/// Swift 6 will not let cross isolation boundaries, and the usual workaround — an unchecked
/// global — trades a compiler guarantee for a promise. The compact form is fixed-width digits,
/// so parsing it directly is both safe by construction and faster than a formatter.
enum EASDate {

    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    static func parse(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        if let date = parseCompact(value) { return date }
        return parseExtended(value)
    }

    /// `20260915T070000Z` — what the calendar class uses.
    private static func parseCompact(_ value: String) -> Date? {
        let characters = Array(value)
        guard characters.count == 16, characters[8] == "T", characters[15] == "Z" else { return nil }

        func number(_ range: Range<Int>) -> Int? { Int(String(characters[range])) }
        guard let year = number(0..<4), let month = number(4..<6), let day = number(6..<8),
              let hour = number(9..<11), let minute = number(11..<13), let second = number(13..<15)
        else { return nil }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        return utc.date(from: components)
    }

    /// `2026-09-15T07:00:00Z`, with or without fractional seconds. Other ActiveSync classes use
    /// it, and a server is free to answer in it — rare enough to pay for a formatter here.
    private static func parseExtended(_ value: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: value) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }

    /// The extended form, with milliseconds: `2026-09-15T00:00:00.000Z`.
    ///
    /// `ResolveRecipients` wants this rather than the compact calendar form. Sending the wrong
    /// one does not fail — the reply comes back without free/busy data, which reads exactly like
    /// a server that publishes none.
    static func formatExtended(_ date: Date) -> String {
        let c = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d.000Z",
            c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0
        )
    }

    /// The form requests must use.
    static func format(_ date: Date) -> String {
        let c = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d%02d%02dT%02d%02d%02dZ",
            c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0
        )
    }
}

// MARK: - Item

struct EASAttendee: Codable, Sendable, Hashable {
    let name: String
    let email: String?
    /// `calendar:AttendeeType` — 1 required, 2 optional, 3 resource.
    let type: Int?
    /// `calendar:AttendeeStatus` — 0 unknown, 2 tentative, 3 accepted, 4 declined, 5 not responded.
    let status: Int?
}

/// One appointment as ActiveSync returned it, before recurrence is expanded.
///
/// Kept raw and persisted as-is so a restart does not force a full resynchronisation: the
/// server hands out only changes once a `SyncKey` exists, and the local copy is the rest of
/// the picture.
struct EASCalendarItem: Codable, Sendable, Hashable {
    let serverId: String

    var subject: String?
    var location: String?
    var start: Date?
    var end: Date?
    var isAllDay: Bool
    var organizerName: String?
    var organizerEmail: String?
    var attendees: [EASAttendee]
    var categories: [String]
    var uid: String?

    /// `calendar:MeetingStatus`, a bit field. Bit 0 — this is a meeting rather than a plain
    /// appointment; bit 1 — the user received it rather than organised it; bit 2 — cancelled.
    var meetingStatus: Int?
    /// `calendar:ResponseType` — 1 organizer, 2 tentative, 3 accepted, 4 declined, 5 not responded.
    var responseType: Int?
    var busyStatus: Int?

    var bodyText: String?
    var bodyTruncated: Bool
    var onlineMeetingConfLink: String?
    var onlineMeetingExternalLink: String?

    /// Base64 `TIME_ZONE_INFORMATION`. A series repeats at a wall-clock time, so expanding one
    /// without its zone puts half the year's occurrences an hour out.
    var timezone: String?
    /// The repetition rule, when this item is a series master. The server never sends the
    /// occurrences themselves.
    var recurrence: EASRecurrence?
    /// Occurrences the organiser moved or removed.
    var exceptions: [EASException]

    var isRecurring: Bool { recurrence != nil }

    var isMeeting: Bool { ((meetingStatus ?? 0) & 1) != 0 }
    var isCancelled: Bool { ((meetingStatus ?? 0) & 4) != 0 }
    /// A meeting the user organised. A plain appointment is not "organised" by anyone.
    var isOrganizer: Bool {
        guard isMeeting else { return false }
        return ((meetingStatus ?? 0) & 2) == 0
    }
}

extension EASCalendarItem {

    /// Builds an item from the `ApplicationData` of a `Sync` `Add` or `Change`.
    ///
    /// Returns `nil` only when the element carries no usable identity; missing individual
    /// fields are normal and left as `nil` for the mapper to decide about.
    init?(serverId: String, applicationData item: WBNode) {
        guard !serverId.isEmpty else { return nil }
        self.serverId = serverId

        subject = item.value(CAL.subject)?.trimmedOrNil
        location = item.value(CAL.location)?.trimmedOrNil
        start = EASDate.parse(item.value(CAL.startTime))
        end = EASDate.parse(item.value(CAL.endTime))
        isAllDay = item.value(CAL.allDayEvent) == "1"
        organizerName = item.value(CAL.organizerName)?.trimmedOrNil
        organizerEmail = item.value(CAL.organizerEmail)?.trimmedOrNil
        uid = item.value(CAL.uid)?.trimmedOrNil

        attendees = (item.child(CAL.attendees)?.all(CAL.attendee) ?? []).compactMap { node in
            let name = node.value(CAL.name)?.trimmedOrNil
            let email = node.value(CAL.email)?.trimmedOrNil
            guard name != nil || email != nil else { return nil }
            return EASAttendee(
                name: name ?? email ?? "",
                email: email,
                type: node.value(CAL.attendeeType).flatMap(Int.init),
                status: node.value(CAL.attendeeStatus).flatMap(Int.init)
            )
        }

        categories = (item.child(CAL.categories)?.all(CAL.category) ?? [])
            .compactMap { $0.text.trimmedOrNil }

        meetingStatus = item.value(CAL.meetingStatus).flatMap(Int.init)
        responseType = item.value(CAL.responseType).flatMap(Int.init)
        busyStatus = item.value(CAL.busyStatus).flatMap(Int.init)

        // The body arrives on AirSyncBase from protocol 12.0 onward, never on the calendar page.
        let body = item.child(ASB.body)
        bodyText = body?.value(ASB.data)?.trimmedOrNil
        bodyTruncated = body?.value(ASB.truncated) == "1"

        onlineMeetingConfLink = item.value(CAL.onlineMeetingConfLink)?.trimmedOrNil
        onlineMeetingExternalLink = item.value(CAL.onlineMeetingExternalLink)?.trimmedOrNil

        timezone = item.value(CAL.timezone)?.trimmedOrNil
        recurrence = item.child(CAL.recurrence).flatMap(EASCalendarItem.parseRecurrence)
        exceptions = (item.child(CAL.exceptions)?.all(CAL.exception) ?? [])
            .compactMap(EASCalendarItem.parseException)
    }

    /// `Type` and `Interval` are the only fields every rule carries; the rest depend on the kind.
    static func parseRecurrence(_ node: WBNode) -> EASRecurrence? {
        guard let rawType = node.value(CAL.type).flatMap(Int.init),
              let kind = EASRecurrenceKind(rawValue: rawType)
        else { return nil }

        return EASRecurrence(
            kind: kind,
            // Absent means every period; zero would mean an infinite loop.
            interval: max(1, node.value(CAL.interval).flatMap(Int.init) ?? 1),
            until: EASDate.parse(node.value(CAL.until)),
            occurrences: node.value(CAL.occurrences).flatMap(Int.init),
            dayOfWeekMask: node.value(CAL.dayOfWeek).flatMap(Int.init),
            dayOfMonth: node.value(CAL.dayOfMonth).flatMap(Int.init),
            weekOfMonth: node.value(CAL.weekOfMonth).flatMap(Int.init),
            monthOfYear: node.value(CAL.monthOfYear).flatMap(Int.init),
            firstDayOfWeek: node.value(CAL.firstDayOfWeek).flatMap(Int.init)
        )
    }

    /// An exception without `ExceptionStartTime` cannot be matched to the slot it overrides, so
    /// it is dropped rather than applied to the wrong occurrence.
    static func parseException(_ node: WBNode) -> EASException? {
        guard let originalStart = EASDate.parse(node.value(CAL.exceptionStartTime)) else { return nil }

        let body = node.child(ASB.body)
        let attendeeNodes = node.child(CAL.attendees)?.all(CAL.attendee)

        return EASException(
            originalStart: originalStart,
            isDeleted: node.value(CAL.deleted) == "1",
            start: EASDate.parse(node.value(CAL.startTime)),
            end: EASDate.parse(node.value(CAL.endTime)),
            subject: node.value(CAL.subject)?.trimmedOrNil,
            location: node.value(CAL.location)?.trimmedOrNil,
            isAllDay: node.value(CAL.allDayEvent).map { $0 == "1" },
            bodyText: body?.value(ASB.data)?.trimmedOrNil,
            meetingStatus: node.value(CAL.meetingStatus).flatMap(Int.init),
            responseType: node.value(CAL.responseType).flatMap(Int.init),
            onlineMeetingConfLink: node.value(CAL.onlineMeetingConfLink)?.trimmedOrNil,
            attendees: attendeeNodes.map { nodes in
                nodes.compactMap { node -> EASAttendee? in
                    let name = node.value(CAL.name)?.trimmedOrNil
                    let email = node.value(CAL.email)?.trimmedOrNil
                    guard name != nil || email != nil else { return nil }
                    return EASAttendee(
                        name: name ?? email ?? "",
                        email: email,
                        type: node.value(CAL.attendeeType).flatMap(Int.init),
                        status: node.value(CAL.attendeeStatus).flatMap(Int.init)
                    )
                }
            }
        )
    }
}

extension EASCalendarItem {
    /// An item built from the data the client just sent to create it.
    ///
    /// Used when the server issued a `ServerId` but did not return the item through `Fetch`. This
    /// version is deliberately less complete than the server's — it lacks normalization,
    /// organizer, and time zone — but shows the meeting immediately. The first sync that touches
    /// it replaces this version with the real one.
    init(
        serverId: String,
        locallyCreated subject: String,
        location: String,
        start: Date,
        end: Date,
        agenda: String,
        requiredAttendees: [ResolvedAttendee],
        optionalAttendees: [ResolvedAttendee]
    ) {
        let attendees =
            requiredAttendees.map { EASAttendee(name: $0.displayName, email: $0.email, type: 1, status: nil) }
            + optionalAttendees.map { EASAttendee(name: $0.displayName, email: $0.email, type: 2, status: nil) }

        self.init(
            serverId: serverId,
            subject: subject,
            location: location.isEmpty ? nil : location,
            start: start,
            end: end,
            isAllDay: false,
            organizerName: nil,
            organizerEmail: nil,
            attendees: attendees,
            categories: [],
            uid: nil,
            // 1 is a meeting organized by this user; 0 is a personal item without attendees.
            // This is the same value sent in the create request.
            meetingStatus: attendees.isEmpty ? 0 : 1,
            responseType: nil,
            busyStatus: 2,
            bodyText: agenda.isEmpty ? nil : agenda,
            // This is only the optimistic local copy. Opening details must try to replace it
            // with the server version, which carries normalization and organizer metadata.
            bodyTruncated: true,
            onlineMeetingConfLink: nil,
            onlineMeetingExternalLink: nil,
            timezone: nil,
            recurrence: nil,
            exceptions: []
        )
    }
}

private extension String {
    var trimmedOrNil: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
