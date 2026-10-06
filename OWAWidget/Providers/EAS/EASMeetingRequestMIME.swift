import Foundation

/// The invitation email that turns a calendar item into a meeting request.
///
/// ActiveSync splits creating a meeting into two unrelated halves: `Sync Add` puts the
/// appointment on the organiser's own calendar, and this message — sent with `SendMail` — is
/// what actually reaches the attendees. Exchange parses the `text/calendar` part, rewrites it
/// as an `IPM.Schedule.Meeting.Request`, and only then do the invitees get a mail and a
/// tentative item on their calendars. Skipping it produces exactly the failure this was
/// written for: a meeting visible to its organiser and to nobody else.
///
/// Pure and static because every mistake available here is silent. A `UID` that does not match
/// the calendar item leaves responses unattributable, a `METHOD` other than `REQUEST` arrives
/// as a plain mail with an attachment, and a mis-folded line corrupts whichever property it
/// lands in — none of which the server reports.
enum EASMeetingRequestMIME {

    struct Organizer: Sendable {
        let name: String
        let email: String
    }

    /// - Parameters:
    ///   - uid: must be byte-for-byte the `calendar:UID` of the item written by `Sync Add`.
    ///     Exchange correlates responses to the meeting through it; a mismatch produces
    ///     acceptances that never land on the organiser's copy.
    ///   - boundary: injectable for tests only. The default is random, as a boundary must be.
    static func message(
        organizer: Organizer,
        subject: String,
        agenda: String,
        location: String,
        start: Date,
        end: Date,
        requiredAttendees: [ResolvedAttendee],
        optionalAttendees: [ResolvedAttendee],
        uid: String,
        timeZone: TimeZone = AppTimeZone.zone,
        stamp: Date = Date(),
        boundary: String = "owa-" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    ) -> String {
        let calendar = iCalendar(
            organizer: organizer,
            subject: subject,
            agenda: agenda,
            location: location,
            start: start,
            end: end,
            requiredAttendees: requiredAttendees,
            optionalAttendees: optionalAttendees,
            uid: uid,
            stamp: stamp
        )

        var headers: [String] = [
            "MIME-Version: 1.0",
            "Date: \(rfc5322Date(stamp, in: timeZone))",
            "From: \(address(name: organizer.name, email: organizer.email))",
        ]
        if !requiredAttendees.isEmpty {
            headers.append("To: " + addressList(requiredAttendees))
        }
        if !optionalAttendees.isEmpty {
            headers.append("Cc: " + addressList(optionalAttendees))
        }
        headers.append("Subject: " + encodedHeaderText(subject))
        headers.append("Content-Type: multipart/alternative; boundary=\"\(boundary)\"")

        // Both parts carry the same meeting: a client that understands `text/calendar` shows the
        // invitation, one that does not falls back to the text. `multipart/alternative` orders
        // parts least-preferred first, which is why the calendar comes second.
        let parts = [
            [
                "--\(boundary)",
                "Content-Type: text/plain; charset=\"utf-8\"",
                "Content-Transfer-Encoding: base64",
                "",
                base64Body(
                    textBody(
                        agenda: agenda,
                        location: location,
                        start: start,
                        end: end,
                        timeZone: timeZone
                    )
                ),
            ].joined(separator: "\r\n"),
            [
                "--\(boundary)",
                "Content-Type: text/calendar; charset=\"utf-8\"; method=REQUEST",
                "Content-Transfer-Encoding: base64",
                "",
                base64Body(calendar),
            ].joined(separator: "\r\n"),
            "--\(boundary)--",
        ]

        return headers.joined(separator: "\r\n") + "\r\n\r\n" + parts.joined(separator: "\r\n") + "\r\n"
    }

    // MARK: - iCalendar

    /// The `METHOD:REQUEST` body Exchange reads the meeting out of.
    static func iCalendar(
        organizer: Organizer,
        subject: String,
        agenda: String,
        location: String,
        start: Date,
        end: Date,
        requiredAttendees: [ResolvedAttendee],
        optionalAttendees: [ResolvedAttendee],
        uid: String,
        stamp: Date
    ) -> String {
        var lines: [String] = [
            "BEGIN:VCALENDAR",
            "PRODID:-//OWAWidget//Calendar//EN",
            "VERSION:2.0",
            "CALSCALE:GREGORIAN",
            // Without this the message is a published event, not an invitation: no response
            // buttons, no tentative item on the invitee's calendar.
            "METHOD:REQUEST",
            "BEGIN:VEVENT",
            "UID:\(escape(uid))",
            "DTSTAMP:\(EASDate.format(stamp))",
            // UTC throughout, so the event needs no VTIMEZONE to be unambiguous.
            "DTSTART:\(EASDate.format(start))",
            "DTEND:\(EASDate.format(end))",
            "SUMMARY:\(escape(subject))",
        ]

        if !agenda.isEmpty {
            lines.append("DESCRIPTION:\(escape(agenda))")
        }
        if !location.isEmpty {
            lines.append("LOCATION:\(escape(location))")
        }

        lines.append("ORGANIZER\(commonName(organizer.name)):MAILTO:\(organizer.email)")
        for attendee in requiredAttendees {
            lines.append(attendeeLine(attendee, role: "REQ-PARTICIPANT"))
        }
        for attendee in optionalAttendees {
            lines.append(attendeeLine(attendee, role: "OPT-PARTICIPANT"))
        }

        lines.append(contentsOf: [
            "CLASS:PUBLIC",
            "SEQUENCE:0",
            "STATUS:CONFIRMED",
            "TRANSP:OPAQUE",
            "END:VEVENT",
            "END:VCALENDAR",
        ])

        return lines.map(fold).joined(separator: "\r\n") + "\r\n"
    }

    private static func attendeeLine(_ attendee: ResolvedAttendee, role: String) -> String {
        // RSVP=TRUE and PARTSTAT=NEEDS-ACTION are what make the invitee's client offer
        // accept/decline instead of showing a fixed appointment.
        "ATTENDEE\(commonName(attendee.displayName));ROLE=\(role);PARTSTAT=NEEDS-ACTION;RSVP=TRUE"
            + ":MAILTO:\(attendee.email)"
    }

    /// `;CN="Name"`, or nothing when there is no name worth sending.
    ///
    /// Quoted unconditionally: a parameter value containing a colon, semicolon or comma is
    /// invalid unquoted, and "Ivanov, Ivan" is the normal shape of a directory display name.
    private static func commonName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        // A quoted parameter cannot contain a quote; there is no escape for it in RFC 5545.
        return ";CN=\"\(trimmed.replacingOccurrences(of: "\"", with: "'"))\""
    }

    /// RFC 5545 text escaping. Backslash first, or it would escape the escapes.
    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\n")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
    }

    /// Folds a content line to 75 octets, continuing with a leading space.
    ///
    /// Counted in octets rather than characters, and split on character boundaries: a fold
    /// through the middle of a multi-byte character produces two invalid sequences, which is
    /// how a Cyrillic subject turns into rubble on the invitee's screen.
    static func fold(_ line: String) -> String {
        let limit = 75
        guard line.utf8.count > limit else { return line }

        var folded = ""
        var current = ""
        var currentBytes = 0
        // Continuation lines carry one leading space, which counts towards their own limit.
        var budget = limit

        for character in line {
            let size = String(character).utf8.count
            if currentBytes + size > budget {
                folded += folded.isEmpty ? current : "\r\n " + current
                current = ""
                currentBytes = 0
                budget = limit - 1
            }
            current.append(character)
            currentBytes += size
        }
        if !current.isEmpty {
            folded += folded.isEmpty ? current : "\r\n " + current
        }
        return folded
    }

    // MARK: - The plain-text alternative

    private static func textBody(
        agenda: String,
        location: String,
        start: Date,
        end: Date,
        timeZone: TimeZone
    ) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        formatter.timeZone = timeZone

        var lines = ["\(formatter.string(from: start)) — \(shortTime(end, in: timeZone))"]
        if !location.isEmpty {
            lines.append(location)
        }
        if !agenda.isEmpty {
            lines.append("")
            lines.append(agenda)
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    private static func shortTime(_ date: Date, in timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }

    // MARK: - MIME encoding

    /// Base64 at 76 characters per line, as RFC 2045 requires.
    ///
    /// Everything non-ASCII goes through here rather than out as raw UTF-8, which keeps the
    /// whole message 7-bit clean and independent of what the transport tolerates.
    private static func base64Body(_ text: String) -> String {
        Data(text.utf8).base64EncodedString(
            options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]
        )
    }

    private static func addressList(_ attendees: [ResolvedAttendee]) -> String {
        // One address per line: an address list is the one header that reliably grows past any
        // line limit, and folding it between addresses is always legal.
        attendees
            .map { address(name: $0.displayName, email: $0.email) }
            .joined(separator: ",\r\n ")
    }

    private static func address(name: String, email: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != email else { return "<\(email)>" }
        return "\(encodedHeaderText(trimmed)) <\(email)>"
    }

    /// Header text as-is when it is plain ASCII, RFC 2047 encoded words otherwise.
    ///
    /// ASCII text is also quoted when it carries a character that would otherwise be read as
    /// address syntax — a comma in "Ivanov, Ivan" splits one recipient into two.
    static func encodedHeaderText(_ text: String) -> String {
        guard text.contains(where: { !$0.isASCII }) else {
            guard text.contains(where: { "()<>@,;:\\\".[]".contains($0) }) else { return text }
            let escaped = text
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }

        // An encoded word may not exceed 75 characters including the `=?utf-8?B?` wrapper and
        // the `?=` terminator, so the text is cut into pieces that fit and emitted as several
        // words. Splitting on characters rather than bytes: half a character encodes to
        // something the other side cannot decode back.
        let wrapperLength = "=?utf-8?B??=".count
        let payloadBudget = 75 - wrapperLength
        // Base64 turns every 3 octets into 4 characters.
        let byteBudget = (payloadBudget / 4) * 3

        var words: [String] = []
        var chunk = ""
        var chunkBytes = 0
        for character in text {
            let size = String(character).utf8.count
            if chunkBytes + size > byteBudget {
                words.append(encodedWord(chunk))
                chunk = ""
                chunkBytes = 0
            }
            chunk.append(character)
            chunkBytes += size
        }
        if !chunk.isEmpty {
            words.append(encodedWord(chunk))
        }
        // Encoded words are folded onto continuation lines; the space between them is the
        // separator RFC 2047 requires and is not part of the decoded text.
        return words.joined(separator: "\r\n ")
    }

    private static func encodedWord(_ text: String) -> String {
        "=?utf-8?B?\(Data(text.utf8).base64EncodedString())?="
    }

    private static func rfc5322Date(_ date: Date, in timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        // Fixed locale: the date header is protocol syntax, not something to localise.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }
}
