import Foundation

enum ConnectionTestMessage {
    @MainActor
    static func failure(for error: Error, localization: LocalizationService) -> String {
        if case OWAError.authenticationFailed = error {
            return localization.tr("settings.account.connection.auth.failed")
        }

        return error.localizedDescription
    }
}
