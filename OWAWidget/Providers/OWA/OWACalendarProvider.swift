import Foundation
import os.log

actor OWACalendarProvider: CalendarProvider {
    let account: CalendarAccount
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

    // MARK: - Mapping

    private func mapItem(_ item: OWACalendarItem) -> CalendarEvent? {
        guard
            let subject = item.Subject,
            let startStr = item.Start,
            let endStr = item.End,
            let startDate = parseDate(startStr),
            let endDate = parseDate(endStr)
        else { return nil }

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
            categories: Self.normalizedCategories(from: item)
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
