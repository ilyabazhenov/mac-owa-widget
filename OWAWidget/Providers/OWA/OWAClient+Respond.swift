import Foundation

/// An answer to an invitation as OWA's own calendar sends it (`RespondToCalendarEvent`, seen in a
/// HAR of Exchange 2019 on 2026-11-21): one occurrence by its own id, the whole series by the same
/// id wrapped in `RecurringMasterItemId`, an optional note, and whether the organizer hears of it
/// ("Don't send a response" sends `SendResponse: false`).
///
/// The app's invitation panel still answers with EWS `CreateItem`/`AcceptItem`, which has neither
/// a series scope nor a way to answer without a message: this is the MCP tool's path.
enum OWARespondToCalendarEventPayload {
    static func response(_ action: MeetingResponseAction) -> String {
        switch action {
        case .accept: "Accept"
        case .tentative: "Tentative"
        case .decline: "Decline"
        }
    }

    /// The note as OWA sends it: HTML, every line escaped, line breaks kept.
    static func notesHTML(_ text: String) -> String {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let body = lines.map { line in line.isEmpty ? "<br>" : escapeHTML(line) }.map { "<div>\($0)</div>" }.joined()
        return "<html><head><meta http-equiv=\"Content-Type\" content=\"text/html; charset=UTF-8\"></head><body>\(text.isEmpty ? "" : body)</body></html>"
    }

    static func escapeHTML(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(character)
            }
        }
        return out
    }

    static func json(
        itemID: String,
        changeKey: String?,
        series: Bool,
        action: MeetingResponseAction,
        notes: String,
        sendResponse: Bool,
        timeZoneID: String
    ) -> [String: Any] {
        var eventID: [String: Any] = series
            ? ["__type": "RecurringMasterItemId:#Exchange", "OccurrenceId": itemID]
            : ["__type": "ItemId:#Exchange", "Id": itemID]
        if let changeKey { eventID["ChangeKey"] = changeKey }
        return [
            "__type": "RespondToCalendarEventJsonRequest:#Exchange",
            "Header": OWAMailPayloads.header(version: "Exchange2013", timeZoneID: timeZoneID),
            "Body": [
                "__type": "RespondToCalendarEventRequest:#Exchange",
                "EventId": eventID,
                "Response": response(action),
                "Notes": ["__type": "BodyContentType:#Exchange", "BodyType": "HTML", "Value": notesHTML(notes)] as [String: Any],
                "SendResponse": sendResponse,
            ] as [String: Any],
        ]
    }

    /// `NoError`, or the code Exchange gave (as `OWAError.ewsError`).
    static func check(_ data: Data) throws {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let body = json["Body"] as? [String: Any] else { throw OWAError.invalidResponse }
        let code = body["ResponseCode"] as? String ?? ""
        guard code == "NoError" else { throw OWAError.ewsError(code.isEmpty ? "NoResponseCode" : code) }
    }
}

extension OWAClient {
    func respondToCalendarEvent(
        itemID: String,
        changeKey: String?,
        series: Bool,
        action: MeetingResponseAction,
        notes: String,
        sendResponse: Bool
    ) async throws {
        let payload = OWARespondToCalendarEventPayload.json(
            itemID: itemID, changeKey: changeKey, series: series, action: action,
            notes: notes, sendResponse: sendResponse, timeZoneID: windowsTimezoneID()
        )
        let data = try await mailServiceCall(action: "RespondToCalendarEvent", payload: payload)
        try OWARespondToCalendarEventPayload.check(data)
    }
}
