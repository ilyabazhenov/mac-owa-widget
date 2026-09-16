import Foundation

/// The single place that turns a ``CalendarAccount`` into a ``CalendarProvider``.
///
/// It exists because there were two construction sites — `CalendarService.rebuildProviders()`
/// and the settings connection test — and they could disagree. A connection test that built a
/// provider differently from the one the sync loop uses would report success for something the
/// app then fails to do, which is the worst kind of green check.
enum CalendarProviderFactory {

    enum FactoryError: LocalizedError {
        /// The account type authenticates with a password and none was supplied.
        case passwordRequired(AccountType)

        var errorDescription: String? {
            switch self {
            case .passwordRequired(let type):
                return "\(type.displayName) accounts require a password."
            }
        }
    }

    /// Builds the provider for `account`.
    ///
    /// - Parameters:
    ///   - password: required for account types whose `requiresPassword` is true. Callers pass
    ///     the Keychain value during a rebuild and the in-flight field value during a
    ///     connection test — which is exactly why it is a parameter and not read here.
    ///   - eventKitStore: injected so tests never reach the real EventKit database.
    static func make(
        account: CalendarAccount,
        password: String?,
        eventKitStore: (any EventKitStoring)? = nil
    ) throws -> any CalendarProvider {
        switch account.accountType {
        case .owa:
            let password = try requirePassword(password, for: account.accountType)
            return try OWACalendarProvider(account: account, password: password)

        case .eas:
            let password = try requirePassword(password, for: account.accountType)
            return try EASCalendarProvider(account: account, password: password)

        case .googleCalendar:
            return GoogleCalendarProvider(account: account)

        case .eventKit:
            // Authorised once by the system prompt; holds no secret of its own.
            return EventKitCalendarProvider(
                account: account,
                store: eventKitStore ?? SystemEventKitStore.shared
            )
        }
    }

    private static func requirePassword(_ password: String?, for type: AccountType) throws -> String {
        guard let password, !password.isEmpty else {
            throw FactoryError.passwordRequired(type)
        }
        return password
    }
}
