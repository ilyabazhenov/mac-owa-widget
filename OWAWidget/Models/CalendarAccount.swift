import Foundation

enum AccountType: String, Codable, Sendable, CaseIterable {
    case owa = "owa"
    /// The same Exchange mailbox reached over Exchange ActiveSync instead of the OWA
    /// endpoints. ActiveSync is published to the internet where `/owa/service.svc` and
    /// `/EWS/Exchange.asmx` typically are not, so this account type keeps working with the
    /// VPN off — which is the whole reason it exists alongside ``owa``.
    case eas = "eas"
    case googleCalendar = "googleCalendar"
    /// Calendars the system already syncs (Google, iCloud, local) read through EventKit.
    case eventKit = "eventKit"

    var displayName: String {
        switch self {
        case .owa: "Microsoft Exchange (OWA)"
        case .eas: "Microsoft Exchange (ActiveSync)"
        case .googleCalendar: "Google Calendar"
        case .eventKit: "macOS Calendar"
        }
    }

    /// Whether the account authenticates with a password kept in the Keychain.
    ///
    /// `false` means `rebuildProviders()` must not require a Keychain entry: EventKit accounts
    /// are authorized once by the system TCC prompt, and direct Google Calendar will use OAuth.
    var requiresPassword: Bool {
        switch self {
        case .owa, .eas: true
        case .googleCalendar, .eventKit: false
        }
    }

    /// Whether an account of this type can back the "create meeting" window.
    ///
    /// Read-only providers answer `notSupported` to `createMeeting`, so the entry point has to be
    /// hidden rather than left to fail at the end of a filled-in form.
    var supportsMeetingCreation: Bool {
        switch self {
        // ActiveSync creates meetings with a Sync Add carrying an Attendees collection.
        case .owa, .eas: true
        case .googleCalendar, .eventKit: false
        }
    }

    /// Whether an account of this type can answer "is this colleague busy right now".
    ///
    /// Free/busy for other mailboxes is an Exchange question. EventKit hands over the calendars
    /// macOS syncs and knows nothing about anyone else's, so the colleagues section is hidden for
    /// those accounts rather than shown permanently empty.
    var supportsColleagueAvailability: Bool {
        switch self {
        // ActiveSync answers this with ResolveRecipients.
        case .owa, .eas: true
        case .googleCalendar, .eventKit: false
        }
    }

    /// Whether the account carries an ``EASDeviceProfile``, which the settings UI exposes.
    var usesDeviceProfile: Bool { self == .eas }
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
    /// What an ActiveSync account tells the server it is. `nil` for every other type, and for
    /// accounts written before this field existed — both read back as ``EASDeviceProfile/default``.
    ///
    /// Not a secret: these values are visible to the Exchange administrator in
    /// `Get-MobileDevice`, which is why they live here rather than in the Keychain.
    var easDevice: EASDeviceProfile?

    init(
        id: UUID = UUID(),
        displayName: String,
        serverURL: String,
        email: String,
        accountType: AccountType = .owa,
        calendarIdentifiers: [String]? = nil,
        sourceIdentifier: String? = nil,
        easDevice: EASDeviceProfile? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.serverURL = serverURL
        self.email = email
        self.accountType = accountType
        self.calendarIdentifiers = calendarIdentifiers
        self.sourceIdentifier = sourceIdentifier
        self.easDevice = easDevice
    }

    /// The device profile to send, with defaults filled in. Never `nil`, so call sites do not
    /// have to decide what an absent profile means.
    var resolvedDeviceProfile: EASDeviceProfile {
        (easDevice ?? .default).normalized
    }

    // Password is intentionally excluded — stored in Keychain
    enum CodingKeys: String, CodingKey {
        case id, displayName, serverURL, email, accountType
        case calendarIdentifiers, sourceIdentifier, easDevice
    }
}
