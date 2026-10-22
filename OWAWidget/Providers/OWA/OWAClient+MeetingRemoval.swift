import Foundation

extension OWAClient {
    /// Cancels, declines or deletes one meeting (an occurrence id affects that occurrence only).
    ///
    /// EWS SOAP, like every request that reaches other people. A dropped connection may be
    /// resent: the item can be cancelled, declined or deleted once, so a repeat can only fail.
    /// A stale `ChangeKey` is not retried without it, unlike RSVP: the user confirmed the version
    /// they saw, and a meeting the organizer has changed since deserves a second look.
    func removeMeeting(itemId: String, changeKey: String?, mode: MeetingRemovalMode, message: String) async throws {
        let soap = OWAMeetingRemovalPayload.soap(itemId: itemId, changeKey: changeKey, mode: mode, message: message)
        _ = try await ewsCall(
            action: OWAMeetingRemovalPayload.action(for: mode),
            soap: soap,
            mayRepeat: true,
            note: "removeMeeting mode=\(mode.rawValue)",
            area: "Meeting"
        )
    }
}
