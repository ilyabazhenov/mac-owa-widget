import Foundation

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case russian = "ru"

    var id: String { rawValue }

    var localizationKey: String {
        switch self {
        case .system: "language.option.system"
        case .english: "language.option.english"
        case .russian: "language.option.russian"
        }
    }
}

@MainActor
final class LocalizationService: ObservableObject {
    static let storageKey = "appLanguage"

    @Published var selectedLanguage: AppLanguage {
        didSet {
            userDefaults.set(selectedLanguage.rawValue, forKey: Self.storageKey)
        }
    }

    private let userDefaults: UserDefaults
    private let preferredLanguagesProvider: () -> [String]
    private let resourceBundle: Bundle

    var effectiveLanguageCode: String {
        switch selectedLanguage {
        case .english:
            return AppLanguage.english.rawValue
        case .russian:
            return AppLanguage.russian.rawValue
        case .system:
            return Self.supportedLanguageCode(from: preferredLanguagesProvider())
        }
    }

    var locale: Locale {
        Locale(identifier: effectiveLanguageCode)
    }

    init(
        userDefaults: UserDefaults = .standard,
        selectedLanguage: AppLanguage? = nil,
        preferredLanguages: [String]? = nil,
        resourceBundle: Bundle? = nil
    ) {
        self.userDefaults = userDefaults
        self.preferredLanguagesProvider = { preferredLanguages ?? Locale.preferredLanguages }
        self.resourceBundle = resourceBundle ?? Self.defaultResourceBundle()

        if let selectedLanguage {
            self.selectedLanguage = selectedLanguage
        } else if
            let stored = userDefaults.string(forKey: Self.storageKey),
            let storedLanguage = AppLanguage(rawValue: stored)
        {
            self.selectedLanguage = storedLanguage
        } else {
            self.selectedLanguage = .system
        }
    }

    func tr(_ key: String, _ args: CVarArg...) -> String {
        let format = localizedString(forKey: key)
        guard !args.isEmpty else { return format }
        return String(format: format, locale: locale, arguments: args)
    }

    func minutes(_ count: Int) -> String {
        plural(key: "unit.minutes", count: count)
    }

    func minutesShort(_ count: Int) -> String {
        plural(key: "unit.minutes.short", count: count)
    }

    func meetings(_ count: Int) -> String {
        plural(key: "unit.meetings", count: count)
    }

    var notificationLocalization: NotificationLocalization {
        NotificationLocalization(
            localeIdentifier: effectiveLanguageCode,
            joinActionTitle: tr("notification.action.join"),
            dismissActionTitle: tr("notification.action.dismiss"),
            bodyWithJoinFormat: tr("notification.body.with.join"),
            bodyWithoutJoinFormat: tr("notification.body.without.join"),
            clusterTitleFormat: tr("notification.title.cluster")
        )
    }

    func syncStatusText(_ status: SyncStatus, relativeTo now: Date = Date()) -> String {
        switch status {
        case .idle:
            return tr("sync.status.idle")
        case .syncing:
            return tr("sync.status.syncing")
        case .lastSynced(let date):
            let elapsedSeconds = max(0, Int(now.timeIntervalSince(date).rounded(.down)))
            return tr("sync.status.synced", tr("sync.elapsed.seconds", elapsedSeconds))
        case .offlineCached(let message):
            return tr("sync.status.offline.cached", message)
        case .error(let message):
            return tr("sync.status.error", message)
        }
    }

    func daySectionLabel(for date: Date, calendar: Calendar = AppTimeZone.calendar, relativeTo referenceNow: Date = Date()) -> String {
        if calendar.isDate(date, inSameDayAs: referenceNow) {
            return "\(tr("date.today")), \(dayAndMonthLabel(for: date, calendar: calendar))"
        }
        let startOfReference = calendar.startOfDay(for: referenceNow)
        if let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: startOfReference),
           calendar.isDate(date, inSameDayAs: tomorrowStart) {
            return tr("date.tomorrow")
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = AppTimeZone.zone
        return formatter.string(from: date)
    }

    func shortTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        formatter.locale = locale
        formatter.timeZone = AppTimeZone.zone
        return formatter.string(from: date)
    }

    private func plural(key: String, count: Int) -> String {
        let format = localizedString(forKey: key)
        return String.localizedStringWithFormat(format, count)
    }

    private func dayAndMonthLabel(for date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = AppTimeZone.zone
        formatter.setLocalizedDateFormatFromTemplate("d MMMM")
        return formatter.string(from: date)
    }

    private func localizedString(forKey key: String) -> String {
        localizedBundle.localizedString(forKey: key, value: key, table: nil)
    }

    private var localizedBundle: Bundle {
        guard
            let path = resourceBundle.path(forResource: effectiveLanguageCode, ofType: "lproj"),
            let bundle = Bundle(path: path)
        else {
            return resourceBundle
        }
        return bundle
    }

    private static func supportedLanguageCode(from preferredLanguages: [String]) -> String {
        for language in preferredLanguages {
            let code = Locale(identifier: language).language.languageCode?.identifier
                ?? language.split(separator: "-").first.map(String.init)
            if code == AppLanguage.russian.rawValue { return AppLanguage.russian.rawValue }
            if code == AppLanguage.english.rawValue { return AppLanguage.english.rawValue }
        }
        return AppLanguage.english.rawValue
    }

    private static func defaultResourceBundle() -> Bundle {
        if hasLocalizationResources(in: .main) {
            return .main
        }

        let sourceResourcesURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("OWAWidget/Resources")
        if
            FileManager.default.fileExists(atPath: sourceResourcesURL.path),
            let sourceResourcesBundle = Bundle(path: sourceResourcesURL.path)
        {
            return sourceResourcesBundle
        }

        return .main
    }

    private static func hasLocalizationResources(in bundle: Bundle) -> Bool {
        AppLanguage.allCases.contains { language in
            guard language != .system else { return false }
            return bundle.path(forResource: language.rawValue, ofType: "lproj") != nil
        }
    }
}
