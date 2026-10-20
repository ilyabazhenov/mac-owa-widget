import AppKit
import Foundation

/// The one source of the app's light/dark look: the popover, the inbox panel beside it and the
/// mail windows all take it from `NSApp.appearance`, which is always set here explicitly.
///
/// "System" is resolved here too rather than left to AppKit (`NSApp.appearance = nil`): with
/// nil, a window that was off screen when macOS switched on its own could keep the old look,
/// and the inbox panel ended up light beside a dark calendar (and the other way round).
@MainActor
final class AppearanceService: ObservableObject {
    static let storageKey = "appTheme"

    @Published var selectedTheme: AppTheme {
        didSet {
            UserDefaults.standard.set(selectedTheme.rawValue, forKey: Self.storageKey)
            apply()
        }
    }

    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init() {
        if let raw = UserDefaults.standard.string(forKey: Self.storageKey),
           let theme = AppTheme(rawValue: raw) {
            self.selectedTheme = theme
        } else {
            self.selectedTheme = .system
        }
    }

    func applyOnLaunch() {
        apply()
        guard observers.isEmpty else { return }
        // macOS announces its own switch (manual or automatic) with this notification; after a
        // sleep it may come late or not at all, so waking up re-checks as well.
        let sources: [(NotificationCenter, Notification.Name)] = [
            (DistributedNotificationCenter.default(), Notification.Name("AppleInterfaceThemeChangedNotification")),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification),
        ]
        for (center, name) in sources {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.apply() }
                // The setting may be written a moment after the announcement: look once more.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    MainActor.assumeIsolated { self?.apply() }
                }
            }
            observers.append((center, token))
        }
    }

    /// Re-reads the system look when following it; a no-op when nothing changed.
    func apply() {
        let name = Self.appearanceName(for: selectedTheme, systemIsDark: Self.systemIsDark())
        guard NSApp.appearance?.name != name else { return }
        NSApp.appearance = NSAppearance(named: name)
        DiagnosticLog.event("Appearance theme=\(selectedTheme.rawValue) applied=\(name.rawValue)")
    }

    nonisolated static func appearanceName(for theme: AppTheme, systemIsDark: Bool) -> NSAppearance.Name {
        switch theme {
        case .system: systemIsDark ? .darkAqua : .aqua
        case .light: .aqua
        case .dark: .darkAqua
        }
    }

    /// The system's own setting, read fresh: `AppleInterfaceStyle` is "Dark" in dark mode and
    /// absent in light mode, and macOS rewrites it when it switches automatically.
    nonisolated static func systemIsDark() -> Bool {
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        let style = CFPreferencesCopyAppValue("AppleInterfaceStyle" as CFString, kCFPreferencesAnyApplication) as? String
        return style?.caseInsensitiveCompare("Dark") == .orderedSame
    }
}
