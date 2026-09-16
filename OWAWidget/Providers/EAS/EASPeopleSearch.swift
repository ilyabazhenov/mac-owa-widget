import Foundation

/// The parts of directory search and free/busy that are pure functions of their input.
///
/// Separated from the provider because the provider needs a registry, a device identity and a
/// Keychain entry to exist at all, while these two pieces of logic carry the consequences —
/// a search that finds nobody, and a colleague list that shows one person's schedule under
/// another's name.
enum EASPeopleSearch {

    /// The token to retry a failed multi-word search on.
    ///
    /// Directories routinely fail to match a full name as a phrase while matching either half,
    /// so a query that found nobody is tried again on its most distinctive word — the longest,
    /// as a stand-in for specificity. `nil` when there is nothing to fall back to.
    static func fallbackToken(for query: String) -> String? {
        let tokens = query
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { !$0.isEmpty }
        guard tokens.count > 1 else { return nil }
        return tokens.max { $0.count < $1.count }
    }

    /// Keeps only the people who also match every word the broadened search dropped.
    ///
    /// Matching goes through ``OWAPersonSearchTokenMatch``, which transliterates, because the
    /// user types Cyrillic while the directory frequently answers in Latin.
    static func narrow(
        _ people: [ResolvedAttendee],
        query: String,
        searchedToken: String
    ) -> [ResolvedAttendee] {
        let remaining = query
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { !$0.isEmpty && $0 != searchedToken }
        guard !remaining.isEmpty else { return people }

        return people.filter { person in
            remaining.allSatisfy { token in
                OWAPersonSearchTokenMatch.personContainsToken(
                    displayName: person.displayName,
                    email: person.email,
                    token: token
                )
            }
        }
    }

    /// Free/busy is reported in fixed 30-minute slots.
    static let slotMinutes = 30

    static func slotCount(from start: Date, to end: Date) -> Int {
        let seconds = end.timeIntervalSince(start)
        guard seconds > 0 else { return 0 }
        return Int((seconds / Double(slotMinutes * 60)).rounded(.up))
    }

    /// One row per requested address, in the order they were asked for.
    ///
    /// The positional guarantee is a hard requirement rather than a convenience:
    /// `ColleaguePresenceService` checks `rows.count == emails.count` and treats a mismatch as a
    /// failed refresh. Since the server may omit an address it could not resolve, a gap is
    /// filled with a "no data" row — dropping it instead would slide every later colleague onto
    /// someone else's schedule.
    static func availabilityRows(
        emails: [String],
        merged byAddress: [String: String],
        from start: Date,
        to end: Date
    ) -> [AttendeeAvailability] {
        // Exchange uses 4 for "no information", and `ColleaguePresence` already reads anything
        // it does not recognise as no data.
        let unknown = String(repeating: "4", count: slotCount(from: start, to: end))

        return emails.map { email in
            let key = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return AttendeeAvailability(
                email: email,
                mergedFreeBusy: byAddress[key] ?? unknown,
                windowStart: start,
                intervalMinutes: slotMinutes
            )
        }
    }
}
