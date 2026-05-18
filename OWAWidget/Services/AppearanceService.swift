import AppKit
import Foundation

@MainActor
final class AppearanceService: ObservableObject {
    static let storageKey = "appTheme"

    @Published var selectedTheme: AppTheme {
        didSet {
            UserDefaults.standard.set(selectedTheme.rawValue, forKey: Self.storageKey)
            apply()
        }
    }

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
    }

    private func apply() {
        switch selectedTheme {
        case .system: NSApp.appearance = nil
        case .light:  NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:   NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
