import Foundation

/// When opening a message marks it as read.
enum MailMarkReadPolicy: String, CaseIterable, Identifiable, Sendable {
    case onOpen
    case afterDelay
    case manual

    var id: String { rawValue }

    /// Seconds a message has to stay open before it is marked; `nil` never.
    var delay: TimeInterval? {
        switch self {
        case .onOpen: 0
        case .afterDelay: 3
        case .manual: nil
        }
    }

    var localizationKey: String { "mail.settings.markRead.\(rawValue)" }
}

/// When a new message deserves a system notification.
enum MailNotifyMode: String, CaseIterable, Identifiable, Sendable {
    case off
    /// Any new message from a person (not from a system).
    case people
    /// Only from people the user deals with: today's meeting participants and watched colleagues.
    case important

    var id: String { rawValue }
    var localizationKey: String { "mail.settings.notify.\(rawValue)" }
}

/// The mail switches. They are interface preferences (what the user sees and how often the app
/// checks), so they live in `UserDefaults`; the switches deciding what AI clients may read are in
/// `MCPSettings`, in the encrypted store.
struct MailSettings: Equatable, Sendable {
    /// Off by default: the mail window, the popover section and the unread check all depend on it.
    var enabled = false
    var popoverSectionEnabled = true
    var menuBarBadgeEnabled = false
    var markReadPolicy: MailMarkReadPolicy = .onOpen
    /// Unread check interval, minutes.
    var pollMinutes = 2
    /// Folders pinned in the mail window's sidebar, by id.
    var pinnedFolderIDs: [String] = []
    /// The account the mail window shows, when several have mail.
    var accountID: UUID?
    /// Fold conversations from systems (CI, trackers) into one row per sender in the list. Off by
    /// default: the user asked for the plain list first.
    var bundleAutomated = false
    /// The popover list and the menu bar count show mail from people only.
    var peopleOnly = true
    var notifyMode: MailNotifyMode = .off

    static let pollOptions = [1, 2, 5, 10, 15]

    private enum Key {
        static let enabled = "mailEnabled"
        static let popoverSection = "mailPopoverSectionEnabled"
        static let menuBarBadge = "mailMenuBarBadgeEnabled"
        // A new key: settings are saved whole, so the old default (after 3 s) sits in
        // everyone's defaults whether they chose it or not.
        static let markRead = "mailMarkReadMode"
        static let pollMinutes = "mailPollMinutes"
        static let pinned = "mailPinnedFolderIDs"
        static let accountID = "mailAccountID"
        // A new key: v3 saved the old default (on) for everyone who touched a mail setting.
        static let bundleAutomated = "mailBundleBySender"
        static let peopleOnly = "mailPeopleOnly"
        static let notifyMode = "mailNotifyMode"
    }

    static func load(from defaults: UserDefaults = .standard) -> MailSettings {
        var settings = MailSettings()
        settings.enabled = defaults.bool(forKey: Key.enabled)
        if defaults.object(forKey: Key.popoverSection) != nil {
            settings.popoverSectionEnabled = defaults.bool(forKey: Key.popoverSection)
        }
        settings.menuBarBadgeEnabled = defaults.bool(forKey: Key.menuBarBadge)
        if let raw = defaults.string(forKey: Key.markRead), let policy = MailMarkReadPolicy(rawValue: raw) {
            settings.markReadPolicy = policy
        }
        let minutes = defaults.integer(forKey: Key.pollMinutes)
        if pollOptions.contains(minutes) { settings.pollMinutes = minutes }
        settings.pinnedFolderIDs = defaults.stringArray(forKey: Key.pinned) ?? []
        settings.accountID = defaults.string(forKey: Key.accountID).flatMap(UUID.init(uuidString:))
        if defaults.object(forKey: Key.bundleAutomated) != nil { settings.bundleAutomated = defaults.bool(forKey: Key.bundleAutomated) }
        if defaults.object(forKey: Key.peopleOnly) != nil { settings.peopleOnly = defaults.bool(forKey: Key.peopleOnly) }
        if let raw = defaults.string(forKey: Key.notifyMode), let mode = MailNotifyMode(rawValue: raw) { settings.notifyMode = mode }
        return settings
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: Key.enabled)
        defaults.set(popoverSectionEnabled, forKey: Key.popoverSection)
        defaults.set(menuBarBadgeEnabled, forKey: Key.menuBarBadge)
        defaults.set(markReadPolicy.rawValue, forKey: Key.markRead)
        defaults.set(pollMinutes, forKey: Key.pollMinutes)
        defaults.set(pinnedFolderIDs, forKey: Key.pinned)
        defaults.set(accountID?.uuidString, forKey: Key.accountID)
        defaults.set(bundleAutomated, forKey: Key.bundleAutomated)
        defaults.set(peopleOnly, forKey: Key.peopleOnly)
        defaults.set(notifyMode.rawValue, forKey: Key.notifyMode)
    }
}
