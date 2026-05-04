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

        return CalendarEvent(
            id: id,
            title: subject,
            startDate: startDate,
            endDate: endDate,
            location: item.Location?.DisplayName,
            bodyPreview: item.TextBody?.Value.map { stripHTML($0) },
            joinURL: joinURL,
            platform: platform,
            isAllDay: item.IsAllDayEvent ?? false,
            organizer: item.Organizer?.Mailbox?.Name,
            accountID: account.id
        )
    }

    private func resolveJoinURL(from item: OWACalendarItem) -> (URL?, MeetingPlatform) {
        // 1. Dedicated join URL field
        if let urlStr = item.JoinOnlineMeetingUrl, !urlStr.isEmpty, let url = URL(string: urlStr) {
            return (url, urlDetector.detectPlatform(from: urlStr))
        }
        // 2. Location display name
        if let loc = item.Location?.DisplayName, !loc.isEmpty {
            if let detected = urlDetector.detect(in: loc) {
                return (detected.url, detected.platform)
            }
        }
        // 3. Body text
        if let body = item.TextBody?.Value, !body.isEmpty {
            if let detected = urlDetector.detect(in: body) {
                return (detected.url, detected.platform)
            }
        }
        return (nil, .generic)
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
