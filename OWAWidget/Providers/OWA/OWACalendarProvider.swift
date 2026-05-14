import Foundation
import os.log

actor OWACalendarProvider: CalendarProvider {
    nonisolated let account: CalendarAccount
    private let client: OWAClient
    private let urlDetector = MeetingURLDetector()
    private let log = Logger(subsystem: "com.owawidget", category: "OWACalendarProvider")

    init(account: CalendarAccount, password: String) throws {
        self.account = account
        self.client = try OWAClient(serverURL: account.serverURL, username: account.email, password: password)
    }

    func fetchEvents(from start: Date, to end: Date) async throws -> [CalendarEvent] {
        let syncID = SyncDiagnostics.syncIDText
        let accountID = String(account.id.uuidString.prefix(8))
        log.info(
            "OWA provider fetch started sync=\(syncID, privacy: .public) account=\(accountID, privacy: .public)"
        )
        let items: [OWACalendarItem]
        do {
            items = try await client.fetchCalendarView(from: start, to: end)
        } catch {
            log.error(
                "OWA provider fetch failed sync=\(syncID, privacy: .public) account=\(accountID, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
        log.info(
            "OWA provider fetch complete sync=\(syncID, privacy: .public) account=\(accountID, privacy: .public) rawItems=\(items.count, privacy: .public)"
        )
        return items.compactMap { mapItem($0) }
    }

    func validateCredentials() async throws {
        try await client.authenticate()
    }

    func respondToMeeting(_ event: CalendarEvent, action: MeetingResponseAction) async throws {
        guard let changeKey = event.changeKey else { throw OWAError.invalidResponse }
        try await client.respondToMeeting(itemId: event.id, changeKey: changeKey, action: action)
    }

    func findPeople(query: String) async throws -> [ResolvedAttendee] {
        try await client.findPeople(query: query)
    }

    func resolveOrganizerSMTPEmail() async throws -> String? {
        try await client.resolveOrganizerSMTPEmail()
    }

    func getUserAvailability(emails: [String], from start: Date, to end: Date) async throws -> [AttendeeAvailability] {
        try await client.getUserAvailabilityInternal(emails: emails, from: start, to: end)
    }

    func createMeeting(
        title: String,
        agenda: String,
        start: Date,
        end: Date,
        requiredAttendees: [ResolvedAttendee],
        optionalAttendees: [ResolvedAttendee]
    ) async throws {
        let folderIdentifier = await client.resolvedFolderIdentifier
        try await client.createCalendarEvent(
            title: title,
            agenda: agenda,
            start: start,
            end: end,
            requiredAttendees: requiredAttendees,
            optionalAttendees: optionalAttendees,
            folderIdentifier: folderIdentifier
        )
    }

    // MARK: - Mapping

    private func mapItem(_ item: OWACalendarItem) -> CalendarEvent? {
        guard
            let subject = item.Subject,
            let startStr = item.Start,
            let endStr = item.End,
            let startDate = parseDate(startStr),
            let endDate = parseDate(endStr)
        else {
            #if DEBUG
            if let subject = item.Subject {
                let line = "[mapItem] dropped: subject='\(subject)' startStr=\(item.Start ?? "nil") endStr=\(item.End ?? "nil")\n"
                if let data = line.data(using: .utf8) {
                    let logURL = URL(fileURLWithPath: "/tmp/owawidget_freeslots.log")
                    if let fh = try? FileHandle(forWritingTo: logURL) {
                        fh.seekToEndOfFile(); fh.write(data); try? fh.close()
                    }
                }
            }
            #endif
            return nil
        }
        #if DEBUG
        // One-shot dump of the raw start string so we can see what timezone format OWA returns.
        if subject.contains("9:00") || subject.contains("9 утр") {
            let line = "[mapItem RAW] subject='\(subject)' startStr='\(startStr)' parsedAsLocal=\(startDate)\n"
            if let data = line.data(using: .utf8) {
                let logURL = URL(fileURLWithPath: "/tmp/owawidget_freeslots.log")
                if let fh = try? FileHandle(forWritingTo: logURL) {
                    fh.seekToEndOfFile(); fh.write(data); try? fh.close()
                }
            }
        }
        #endif

        let id = item.ItemId?.Id ?? UUID().uuidString
        let (joinURL, platform) = resolveJoinURL(from: item)

        let requiredNames = item.RequiredAttendees?.attendees.compactMap { $0.Mailbox?.Name } ?? []
        let optionalNames = item.OptionalAttendees?.attendees.compactMap { $0.Mailbox?.Name } ?? []
        let attendees = (requiredNames + optionalNames).filter { !$0.isEmpty }

        return CalendarEvent(
            id: id,
            title: subject,
            startDate: startDate,
            endDate: endDate,
            location: item.Location?.DisplayName,
            bodyPreview: Self.bodyText(from: item).map { stripHTML($0) },
            joinURL: joinURL,
            platform: platform,
            isAllDay: item.IsAllDayEvent ?? false,
            organizer: item.Organizer?.Mailbox?.Name,
            attendees: attendees,
            accountID: account.id,
            isCancelled: item.IsCancelled ?? false,
            isOrganizer: item.IsOrganizer ?? false,
            categories: Self.normalizedCategories(from: item),
            responseType: Self.mapResponseType(item.ResponseType, isOrganizer: item.IsOrganizer ?? false),
            changeKey: item.ItemId?.ChangeKey,
            instanceKey: item.InstanceKey
        )
    }

    private func resolveJoinURL(from item: OWACalendarItem) -> (URL?, MeetingPlatform) {
        Self.resolveJoinURL(from: item, using: urlDetector)
    }

    static func resolveJoinURL(from item: OWACalendarItem, using detector: MeetingURLDetector = MeetingURLDetector())
        -> (URL?, MeetingPlatform)
    {
        // 1. Dedicated join URL field
        if let urlStr = item.JoinOnlineMeetingUrl, !urlStr.isEmpty, let url = URL(string: urlStr) {
            return (url, detector.detectPlatform(from: urlStr))
        }

        // 2. Location display name
        let locationText = item.Location?.DisplayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !locationText.isEmpty {
            if let detected = detector.detect(in: locationText) {
                return (detected.url, detected.platform)
            }
        }

        // 3. Body text fallback
        for body in bodyTexts(from: item) {
            if let detected = detector.detect(in: body) {
                return (detected.url, detected.platform)
            }
        }
        return (nil, .generic)
    }

    private static func bodyText(from item: OWACalendarItem) -> String? {
        bodyTexts(from: item).first
    }

    private static func mapResponseType(_ raw: String?, isOrganizer: Bool) -> MeetingResponseType {
        if isOrganizer { return .organizer }
        switch raw {
        case "Accept":    return .accepted
        case "Tentative": return .tentative
        case "Decline":   return .declined
        case "Organizer": return .organizer
        default:          return .notResponded
        }
    }

    private static func normalizedCategories(from item: OWACalendarItem) -> [String] {
        (item.Categories ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private static func bodyTexts(from item: OWACalendarItem) -> [String] {
        let candidates: [String?] = [
            item.TextBody?.Value,
            item.UniqueBody?.Value,
            item.Body?.Value,
            item.NormalizedBody?.Value,
            item.Preview,
        ]

        var result: [String] = []
        result.reserveCapacity(candidates.count)
        for candidate in candidates {
            guard let text = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
            result.append(text)
        }
        return result
    }

    // MARK: - Date parsing

    private let dateFormats = [
        "yyyy-MM-dd'T'HH:mm:ss",
        "yyyy-MM-dd'T'HH:mm:ssZ",
        "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
    ]

    private func parseDate(_ string: String) -> Date? {
        // /Date(milliseconds)/ or /Date(ms+offset)/
        if string.hasPrefix("/Date(") {
            let inner = string.dropFirst(6)
            let msStr = inner.prefix(while: { $0.isNumber || $0 == "-" })
            if let ms = TimeInterval(msStr) {
                return Date(timeIntervalSince1970: ms / 1000)
            }
        }

        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone.current

        for format in dateFormats {
            fmt.dateFormat = format
            if let d = fmt.date(from: string) { return d }
        }
        return nil
    }

    private func stripHTML(_ string: String) -> String {
        guard string.contains("<") else { return string }
        guard let re = try? NSRegularExpression(pattern: "<[^>]+>") else { return string }
        let ns = string as NSString
        return re.stringByReplacingMatches(in: string, range: NSRange(location: 0, length: ns.length), withTemplate: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
