import Foundation

/// A section of the Settings window, listed in its sidebar.
///
/// Grouped by what the user is looking for rather than by where the code lives: a feature and its
/// menu bar counter sit together (invitations with ✉︎N, mail with @N), and sync sits with the
/// accounts it belongs to. A sidebar has no limit on its entries, unlike the tab bar it replaced,
/// which at 600 pt folded into a ">>" menu at the fifth tab — new settings go into the section
/// they belong to.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case accounts
    case menuBar
    case reminders
    case invitations
    case mail
    case colleagues
    case mcp
    case about

    var id: String { rawValue }

    /// The last section shown, so the window opens where the user left it. Also written before
    /// opening the window to land on a particular section (Accounts from a sync error).
    static let storageKey = "settingsPane"

    var titleKey: String {
        switch self {
        case .general: "settings.pane.general"
        case .accounts: "settings.tab.accounts"
        case .menuBar: "settings.pane.menuBar"
        case .reminders: "settings.pane.reminders"
        case .invitations: "settings.pane.invitations"
        case .mail: "settings.tab.mail"
        case .colleagues: "preferences.colleagues.section"
        case .mcp: "settings.tab.mcp"
        case .about: "settings.tab.about"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .accounts: "person.2"
        case .menuBar: "menubar.rectangle"
        case .reminders: "bell"
        case .invitations: "envelope.open"
        case .mail: "envelope"
        case .colleagues: "person.crop.circle"
        case .mcp: "sparkles"
        case .about: "info.circle"
        }
    }

    /// Words a user may type that are not on the page itself — synonyms and the names of
    /// things the section controls ("notifications" for Reminders, "hotkey" for General).
    var keywordsKey: String { "settings.search.keywords.\(rawValue)" }

    /// The strings shown in the section, searched along with its title and keywords. Kept next to
    /// the section list so a new setting is found by search as soon as its key is added here;
    /// a test checks every key exists in both languages.
    var searchedKeys: [String] {
        switch self {
        case .general:
            [
                "preferences.startup.section", "preferences.startup.launchAtLogin",
                "preferences.startup.requiresApproval", "preferences.startup.openSettings",
                "settings.group.languageTheme", "language.picker.title", "appearance.picker.title",
                "preferences.timezone.section", "preferences.timezone.picker", "preferences.timezone.hint",
                "preferences.shortcuts.section", "preferences.shortcuts.joinMeeting",
                "preferences.shortcuts.createMeeting", "preferences.shortcuts.openMail",
                "preferences.shortcuts.always.hint",
                "preferences.updates.section", "preferences.updates.toggle", "preferences.updates.hint",
                "preferences.updates.checkNow",
            ]
        case .accounts:
            [
                "settings.accounts.add", "preferences.sync.section", "preferences.sync.interval",
            ]
        case .menuBar:
            [
                "preferences.menubar.section", "preferences.menubar.display",
                "preferences.menubar.display.countdown", "preferences.menubar.display.status",
                "preferences.menubar.display.smart", "preferences.menubar.counters.hint",
                "preferences.popover.section", "preferences.popover.size",
                "preferences.timeline.dimPastMeetings",
            ]
        case .reminders:
            [
                "preferences.reminders.group.before", "preferences.notifications.remind",
                "preferences.notifications.sound", "preferences.reminders.group.banner",
                "preferences.notifications.screen", "preferences.notifications.position",
            ]
        case .invitations:
            [
                "preferences.invitations.enabled", "preferences.invitations.popoverSection",
                "preferences.invitations.menuBarBadge", "preferences.invitations.hint",
            ]
        case .mail:
            [
                "mail.settings.enabled", "mail.settings.enabled.hint", "mail.settings.account",
                "mail.settings.noAccount",
                "mail.settings.section.popover", "mail.settings.popoverSection", "mail.settings.popoverSection.hint",
                "mail.settings.menuBarBadge", "mail.settings.peopleOnly", "mail.settings.peopleOnly.hint",
                "mail.settings.notify", "mail.settings.poll", "mail.settings.poll.hint", "mail.settings.section.reading",
                "mail.list.bundle", "mail.list.groupByConversation", "mail.settings.swipeActions",
                "mail.settings.swipeActions.hint",
                "mail.settings.markRead", "mail.settings.privacy",
            ]
        case .colleagues:
            [
                "preferences.colleagues.enabled", "preferences.colleagues.refreshOnOpen",
                "preferences.colleagues.cache", "preferences.colleagues.rows", "preferences.colleagues.hint",
            ]
        case .mcp:
            [
                "mcp.access.section", "mcp.enabled", "mcp.description", "mcp.privacy.warning", "mcp.status",
                "mcp.createMeetings", "mcp.createMeetings.description",
                "mcp.cancelMeetings", "mcp.cancelMeetings.description",
                "mcp.mail.section", "mcp.mail.needsMail", "mcp.mail.read", "mcp.mail.read.description",
                "mcp.mail.send", "mcp.mail.send.description", "mcp.mail.warning", "mcp.connect.section",
                "mcp.clients.section", "mcp.clients.ask", "mcp.journal.section",
            ]
        case .about:
            [
                "app.name", "about.description", "about.github", "menu.copy.diagnostics",
            ]
        }
    }
}

/// Which sections match a search. Case- and diacritic-insensitive substring match over the
/// section's title, keywords and on-page strings in the current language; an empty query matches
/// everything. Pure, so it is tested without the window.
enum SettingsSearch {
    static func matches(_ pane: SettingsPane, query: String, translate: (String) -> String) -> Bool {
        let needle = normalized(query)
        guard !needle.isEmpty else { return true }
        let haystack = ([pane.titleKey, pane.keywordsKey] + pane.searchedKeys)
            .map { normalized(translate($0)) }
        return haystack.contains { $0.contains(needle) }
    }

    static func panes(matching query: String, translate: (String) -> String) -> [SettingsPane] {
        SettingsPane.allCases.filter { matches($0, query: query, translate: translate) }
    }

    /// "Ё" folds to "е" as well: Russian users type either.
    static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "ё", with: "е")
    }
}
