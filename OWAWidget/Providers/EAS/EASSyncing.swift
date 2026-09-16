import Foundation

/// The answer to a meeting invitation. Values are `UserResponse` as [MS-ASCMD] defines them.
enum EASMeetingResponse: Int, Sendable {
    case accepted = 1
    case tentative = 2
    case declined = 3

    init(_ action: MeetingResponseAction) {
        switch action {
        case .accept:   self = .accepted
        case .tentative: self = .tentative
        case .decline:  self = .declined
        }
    }
}

/// One round of `Sync` against a collection.
struct EASSyncResult: Sendable {
    let syncKey: String
    /// More changes are waiting; call again with the new key.
    let moreAvailable: Bool
    /// Items added or changed, both applied the same way to a keyed map.
    let upserted: [EASCalendarItem]
    let deletedIds: [String]
}

/// The part of the transport ``EASAccountSession`` depends on.
///
/// A protocol rather than the concrete client because the session holds the subtle logic —
/// the priming round that carries no data, the `MoreAvailable` loop, the `Status=3` reset that
/// must also discard the local copy — and every one of those fails silently when wrong. None of
/// it is testable against a real server, so the seam exists to let a fake drive it.
protocol EASSyncing: Sendable {
    func provision() async throws
    func defaultCalendarFolder() async throws -> EASFolder
    func sync(
        collectionId: String,
        syncKey: String,
        windowSize: Int,
        filterType: Int,
        bodyTruncationSize: Int
    ) async throws -> EASSyncResult

    func meetingResponse(
        collectionId: String,
        requestId: String,
        instanceId: String?,
        response: EASMeetingResponse
    ) async throws

    func fetchItem(
        collectionId: String,
        syncKey: String,
        serverId: String,
        truncationSize: Int
    ) async throws -> (syncKey: String, item: EASCalendarItem?)

    func searchGAL(query: String, limit: Int) async throws -> [ResolvedAttendee]

    func userSmtpAddress() async throws -> String?

    func resolveAvailability(
        emails: [String],
        from start: Date,
        to end: Date
    ) async throws -> [String: String]

    func createEvent(
        collectionId: String,
        syncKey: String,
        subject: String,
        agenda: String,
        location: String,
        start: Date,
        end: Date,
        requiredAttendees: [ResolvedAttendee],
        optionalAttendees: [ResolvedAttendee],
        timeZone: TimeZone
    ) async throws -> (syncKey: String, serverId: String?)
}

extension EASClient: EASSyncing {}
