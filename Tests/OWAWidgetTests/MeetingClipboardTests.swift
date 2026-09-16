import XCTest
import AppKit
@testable import OWAWidget

@MainActor
final class MeetingClipboardTests: XCTestCase {
    private let localization = LocalizationService(selectedLanguage: .russian, preferredLanguages: ["ru-RU"])

    func testSummaryHasTitleDateTimeAndLink() {
        let event = makeEvent(joinURL: URL(string: "https://example.com/join/123"))

        let lines = MeetingClipboard.summary(of: event, localization: localization).components(separatedBy: "\n")

        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0], "Бархатный Champ Camp #1")
        XCTAssertTrue(lines[1].contains("16 сентября"), lines[1])
        XCTAssertTrue(lines[1].hasSuffix(", 17:00–18:00"), lines[1])
        XCTAssertEqual(lines[2], "https://example.com/join/123")
    }

    func testSummaryWithoutLinkStopsAtTime() {
        let lines = MeetingClipboard.summary(of: makeEvent(joinURL: nil), localization: localization)
            .components(separatedBy: "\n")

        XCTAssertEqual(lines.count, 2)
    }

    func testAllDaySummaryOmitsTime() {
        let lines = MeetingClipboard.summary(of: makeEvent(joinURL: nil, isAllDay: true), localization: localization)
            .components(separatedBy: "\n")

        XCTAssertFalse(lines[1].contains("17:00"), lines[1])
    }

    /// A cancelled meeting hides its Join/Copy link everywhere else; the summary must not leak it.
    func testCancelledSummaryOmitsLink() {
        let event = makeEvent(joinURL: URL(string: "https://example.com/join/123"), isCancelled: true)

        XCTAssertFalse(MeetingClipboard.summary(of: event, localization: localization).contains("https://"))
    }

    func testCopyReplacesPasteboardContents() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("MeetingClipboardTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("old", forType: .string)

        MeetingClipboard.copy("Бархатный Champ Camp #1", to: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), "Бархатный Champ Camp #1")
    }

    private func makeEvent(joinURL: URL?, isAllDay: Bool = false, isCancelled: Bool = false) -> CalendarEvent {
        let calendar = AppTimeZone.calendar
        let start = calendar.date(from: DateComponents(year: 2026, month: 9, day: 16, hour: 17))!
        return CalendarEvent(
            id: "1",
            title: "Бархатный Champ Camp #1",
            startDate: start,
            endDate: start.addingTimeInterval(3600),
            location: nil,
            bodyPreview: nil,
            joinURL: joinURL,
            platform: .generic,
            isAllDay: isAllDay,
            organizer: nil,
            accountID: UUID(),
            isCancelled: isCancelled
        )
    }
}
