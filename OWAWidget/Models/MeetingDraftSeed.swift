import Foundation

/// A meeting handed to the New Meeting window to finish by hand: what an AI assistant proposed
/// through `create_meeting` when the user pressed Edit instead of Create. Nothing of it has been
/// sent to Exchange.
struct MeetingDraftSeed: Sendable, Equatable {
    let id: UUID
    let title: String
    let agenda: String
    let location: String
    let required: [ResolvedAttendee]
    let optional: [ResolvedAttendee]
    /// The exact time that was proposed; the window selects it in the grid.
    let slot: DateInterval
    let accountID: UUID
    /// The MCP client that proposed it ("Claude Code"), empty when unknown.
    let client: String

    init(
        id: UUID = UUID(),
        title: String,
        agenda: String,
        location: String,
        required: [ResolvedAttendee],
        optional: [ResolvedAttendee],
        slot: DateInterval,
        accountID: UUID,
        client: String
    ) {
        self.id = id
        self.title = title
        self.agenda = agenda
        self.location = location
        self.required = required
        self.optional = optional
        self.slot = slot
        self.accountID = accountID
        self.client = client
    }

    init(proposal: MCPMeetingProposal, accountID: UUID) {
        let resolved = { (people: [MCPMeetingProposal.Attendee]) in
            people.map { person in
                let name = person.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return ResolvedAttendee(displayName: name.isEmpty ? person.email : name, email: person.email, jobTitle: nil)
            }
        }
        self.init(
            title: proposal.title,
            agenda: proposal.agenda,
            location: proposal.location,
            required: resolved(proposal.required),
            optional: resolved(proposal.optional),
            slot: DateInterval(start: proposal.start, end: proposal.end),
            accountID: accountID,
            client: proposal.client
        )
    }

    /// The duration chip to select: the shortest preset the meeting fits into. The grid searches
    /// whole 30-minute cells anyway, so 45 minutes needs the same free time as an hour; the
    /// selected slot itself keeps the exact length.
    var durationMinutes: Int {
        let minutes = Int((slot.duration / 60).rounded(.up))
        return MeetingDraft.durationPresets.first { $0 >= minutes } ?? minutes
    }

    /// The window's form filled from this seed, on the week of the proposed time.
    func makeDraft() -> MeetingDraft {
        var draft = MeetingDraft()
        draft.title = title
        draft.agenda = RichText(plain: agenda)
        draft.location = location
        draft.requiredAttendees = required
        draft.optionalAttendees = optional.filter { !required.contains($0) }
        draft.selectedWeekStart = MeetingDraft.mondayOfWeek(containing: slot.start)
        draft.durationMinutes = durationMinutes
        return draft
    }
}
