import XCTest
@testable import OWAWidget

/// Directory search and free/busy.
///
/// Both are built on unverified token tables (pages 10, 15 and 16), so what can be pinned here
/// is the logic around them — the search fallback and the positional guarantee — rather than
/// the wire format, which only the live server can confirm.
final class EASPeopleSearchTests: XCTestCase {

    private let accountID = UUID()

    private func session(_ transport: ScriptedTransport) -> EASAccountSession {
        EASAccountSession(
            accountID: accountID,
            client: transport,
            store: EASInMemorySyncStore(),
            filterType: 0
        )
    }

    private func person(_ name: String, _ email: String, title: String? = nil) -> ResolvedAttendee {
        ResolvedAttendee(displayName: name, email: email, jobTitle: title)
    }

    // MARK: The search fallback

    /// A directory that fails to match a full name as a phrase is normal. Without a fallback,
    /// searching by full name returns nobody — which reads as "this person does not exist".
    func testFallbackTokenIsTheLongestWord() {
        XCTAssertEqual(EASPeopleSearch.fallbackToken(for: "Иван Петров"), "Петров")
        XCTAssertEqual(EASPeopleSearch.fallbackToken(for: "Anna de Vries"), "Vries")
        XCTAssertNil(EASPeopleSearch.fallbackToken(for: "Петров"), "a single word has nothing to fall back to")
        XCTAssertNil(EASPeopleSearch.fallbackToken(for: "   "))
    }

    func testNarrowingKeepsOnlyPeopleMatchingTheDroppedWords() {
        let candidates = [
            person("Иван Петров", "ipetrov@example.com"),
            person("Ольга Петрова", "opetrova@example.com"),
            person("Пётр Петров", "ppetrov@example.com"),
        ]
        let narrowed = EASPeopleSearch.narrow(candidates, query: "Иван Петров", searchedToken: "Петров")
        XCTAssertEqual(narrowed.map(\.email), ["ipetrov@example.com"])
    }

    /// The user types Cyrillic; the directory answers in Latin. Matching without
    /// transliteration would discard every correct result.
    func testNarrowingMatchesAcrossScripts() {
        let candidates = [person("Ivan Petrov", "ipetrov@example.com")]
        let narrowed = EASPeopleSearch.narrow(candidates, query: "Иван Петров", searchedToken: "Петров")
        XCTAssertEqual(narrowed.count, 1)
    }

    func testNarrowingIsANoOpForASingleWord() {
        let candidates = [person("Иван Петров", "ipetrov@example.com")]
        XCTAssertEqual(
            EASPeopleSearch.narrow(candidates, query: "Петров", searchedToken: "Петров").count,
            1
        )
    }

    func testSessionPassesTheQueryThrough() async throws {
        let transport = ScriptedTransport([])
        await transport.setSearchResults(["Петров": [person("Иван Петров", "i@example.com")]])
        let session = session(transport)

        let found = try await session.searchPeople(query: "Петров")

        XCTAssertEqual(found.map(\.email), ["i@example.com"])
        let queries = await transport.searchQueries
        XCTAssertEqual(queries, ["Петров"])
    }

    // MARK: The mailbox's own address

    /// The account login is `DOMAIN\user`, which is not an address — the free/busy view needs
    /// the real one to tell the organiser's row from everyone else's.
    func testSmtpAddressIsCachedForTheLifeOfTheSession() async throws {
        let transport = ScriptedTransport([])
        await transport.setSmtpAddress("ivan@example.com")
        let session = session(transport)

        let first = try await session.smtpAddress()
        let second = try await session.smtpAddress()

        XCTAssertEqual(first, "ivan@example.com")
        XCTAssertEqual(second, "ivan@example.com")
        let calls = await transport.smtpCalls
        XCTAssertEqual(calls, 1, "the address does not change; asking twice is waste")
    }

    // MARK: Free/busy slots

    func testSlotCountCoversTheWholeWindow() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(EASPeopleSearch.slotCount(from: start, to: start.addingTimeInterval(3600)), 2)
        XCTAssertEqual(EASPeopleSearch.slotCount(from: start, to: start.addingTimeInterval(86_400)), 48)
        // A partial slot still needs a character, or the string ends before the window does.
        XCTAssertEqual(EASPeopleSearch.slotCount(from: start, to: start.addingTimeInterval(1800 + 60)), 2)
        XCTAssertEqual(EASPeopleSearch.slotCount(from: start, to: start), 0)
        XCTAssertEqual(EASPeopleSearch.slotCount(from: start, to: start.addingTimeInterval(-3600)), 0)
    }

    // MARK: The positional guarantee

    /// `ColleaguePresenceService` zips rows against the addresses it asked for and treats a
    /// count mismatch as a failed refresh. A dropped row would be worse than that: every later
    /// colleague would be shown someone else's schedule.
    func testEveryRequestedAddressGetsARowInOrder() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = start.addingTimeInterval(3600)
        let rows = EASPeopleSearch.availabilityRows(
            emails: ["anna@example.com", "boris@example.com", "clara@example.com"],
            merged: [
                "anna@example.com": "02",
                "clara@example.com": "22",
            ],
            from: start,
            to: end
        )

        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.map(\.email), ["anna@example.com", "boris@example.com", "clara@example.com"])
        XCTAssertEqual(rows[0].mergedFreeBusy, "02")
        XCTAssertEqual(rows[1].mergedFreeBusy, "44", "an unresolved address reads as no data, not as free")
        XCTAssertEqual(rows[2].mergedFreeBusy, "22")
    }

    /// "No data" must not be mistaken for "free" — proposing a slot because a colleague's
    /// schedule failed to load is exactly the wrong answer.
    func testUnknownRowsReadAsNoDataRatherThanFree() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let rows = EASPeopleSearch.availabilityRows(
            emails: ["nobody@example.com"],
            merged: [:],
            from: start,
            to: start.addingTimeInterval(3600)
        )
        let codes = try? XCTUnwrap(rows.first).mergedFreeBusy
        XCTAssertEqual(codes, "44")
        for character in codes ?? "" {
            XCTAssertEqual(ColleaguePresence(freeBusyCode: character), .noData)
        }
    }

    func testAddressMatchingIgnoresCaseAndPadding() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let rows = EASPeopleSearch.availabilityRows(
            emails: ["  Anna@Example.COM  "],
            merged: ["anna@example.com": "02"],
            from: start,
            to: start.addingTimeInterval(3600)
        )
        XCTAssertEqual(rows.first?.mergedFreeBusy, "02")
        XCTAssertEqual(rows.first?.email, "  Anna@Example.COM  ", "the caller's spelling is echoed back")
    }

    func testRowsCarryTheWindowAndInterval() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let rows = EASPeopleSearch.availabilityRows(
            emails: ["a@example.com"],
            merged: ["a@example.com": "00"],
            from: start,
            to: start.addingTimeInterval(3600)
        )
        XCTAssertEqual(rows.first?.windowStart, start)
        XCTAssertEqual(rows.first?.intervalMinutes, 30)
    }

    func testSessionForwardsTheRequestedAddresses() async throws {
        let transport = ScriptedTransport([])
        await transport.setAvailability(["a@example.com": "02"])
        let session = session(transport)
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        let merged = try await session.availability(
            emails: ["a@example.com", "b@example.com"],
            from: start,
            to: start.addingTimeInterval(3600)
        )

        XCTAssertEqual(merged["a@example.com"], "02")
        let requests = await transport.availabilityRequests
        XCTAssertEqual(requests, [["a@example.com", "b@example.com"]])
    }

    // MARK: The extended timestamp format

    /// `ResolveRecipients` wants the extended form. Sending the compact calendar one does not
    /// fail — it returns a reply with no availability, which looks like a server that publishes
    /// none.
    func testExtendedTimestampFormat() throws {
        let date = try XCTUnwrap(EASDate.parse("20260915T070000Z"))
        XCTAssertEqual(EASDate.formatExtended(date), "2026-09-15T07:00:00.000Z")
        XCTAssertEqual(EASDate.format(date), "20260915T070000Z", "the calendar form is unchanged")
    }
}
