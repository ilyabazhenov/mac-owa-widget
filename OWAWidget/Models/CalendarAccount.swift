import Foundation

enum AccountType: String, Codable, Sendable, CaseIterable {
    case owa = "owa"
    case googleCalendar = "googleCalendar"

    var displayName: String {
        switch self {
        case .owa: "Microsoft Exchange (OWA)"
        case .googleCalendar: "Google Calendar"
        }
    }
}

struct CalendarAccount: Identifiable, Codable, Sendable, Hashable {
    let id: UUID
    var displayName: String
    var serverURL: String
    var email: String
    var accountType: AccountType

    init(
        id: UUID = UUID(),
        displayName: String,
        serverURL: String,
        email: String,
        accountType: AccountType = .owa
    ) {
        self.id = id
        self.displayName = displayName
        self.serverURL = serverURL
        self.email = email
        self.accountType = accountType
    }

    // Password is intentionally excluded — stored in Keychain
    enum CodingKeys: String, CodingKey {
        case id, displayName, serverURL, email, accountType
    }
}
