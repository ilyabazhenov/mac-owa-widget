import Foundation

enum AccountType: String, Codable, Sendable, CaseIterable {
    case owa = "owa"
    case googleCalendar = "googleCalendar"
    /// Calendars the system already syncs (Google, iCloud, local) read through EventKit.
    case eventKit = "eventKit"

    var displayName: String {
        switch self {
        case .owa: "Microsoft Exchange (OWA)"
        case .googleCalendar: "Google Calendar"
        case .eventKit: "macOS Calendar"
        }
    }

    /// Whether the account authenticates with a password kept in the Keychain.
    ///
    /// `false` means `rebuildProviders()` must not require a Keychain entry: EventKit accounts
    /// are authorised once by the system TCC prompt and hold no secret of their own.
    var requiresPassword: Bool {
        switch self {
        case .owa, .googleCalendar: true
        case .eventKit: false
        }
    }

    /// Whether an account of this type can back the "create meeting" window.
    ///
    /// Read-only providers answer `notSupported` to `createMeeting`, so the entry point has to be
    /// hidden rather than left to fail at the end of a filled-in form.
    var supportsMeetingCreation: Bool {
        switch self {
        case .owa: true
        case .googleCalendar, .eventKit: false
        }
    }
}

struct CalendarAccount: Identifiable, Codable, Sendable, Hashable {
    let id: UUID
    var displayName: String
    var serverURL: String
    var email: String
    var accountType: AccountType
    /// EventKit calendars this account pulls from, by `EKCalendar.calendarIdentifier`.
    ///
    /// Identifiers, not titles: one source can hold several calendars sharing a name (a Google
    /// account with two "Todoist" calendars is a real case). `nil` for server accounts.
    var calendarIdentifiers: [String]?
    /// `EKSource.sourceIdentifier` the calendars above came from, kept to group and re-resolve
    /// them in the settings UI. `nil` for server accounts.
    var sourceIdentifier: String?

    init(
        id: UUID = UUID(),
        displayName: String,
        serverURL: String,
        email: String,
        accountType: AccountType = .owa,
        calendarIdentifiers: [String]? = nil,
        sourceIdentifier: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.serverURL = serverURL
        self.email = email
        self.accountType = accountType
        self.calendarIdentifiers = calendarIdentifiers
        self.sourceIdentifier = sourceIdentifier
    }

    // Password is intentionally excluded — stored in Keychain
    enum CodingKeys: String, CodingKey {
        case id, displayName, serverURL, email, accountType
        case calendarIdentifiers, sourceIdentifier
    }
}
