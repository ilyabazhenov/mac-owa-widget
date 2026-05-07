import SwiftUI
import UserNotifications
import AppKit

@main
struct OWAWidgetApp: App {
    @StateObject private var calendarService = CalendarService()
    @StateObject private var localizationService = LocalizationService(resourceBundle: .main)
    @StateObject private var updateCheckService = UpdateCheckService()
    private let notificationDelegate = AppNotificationDelegate()

    init() {
        UNUserNotificationCenter.current().delegate = notificationDelegate
        notificationDelegate.onJoinFromNotification = { [calendarService] item in
            calendarService.openJoinURL(for: item, source: .reminderNotification)
            PostJoinDismissController.shared.dismissAfterJoin(context: .notificationAction)
        }
        configureAppIcon()
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environmentObject(calendarService)
                .environmentObject(localizationService)
                .environmentObject(updateCheckService)
                .environment(\.locale, localizationService.locale)
                .onAppear { syncLocalization() }
                .onChange(of: localizationService.selectedLanguage) { _ in
                    syncLocalization()
                }
        } label: {
            MenuBarLabelView()
                .environmentObject(calendarService)
                .environmentObject(localizationService)
                .environment(\.locale, localizationService.locale)
                .onAppear {
                    syncLocalization()
                    updateCheckService.start()

                }
        }
        .menuBarExtraStyle(.window)

        Window(localizationService.tr("window.settings.title"), id: "settings") {
            SettingsView(calendarService: calendarService)
                .environmentObject(localizationService)
                .environmentObject(updateCheckService)
                .environment(\.locale, localizationService.locale)
                .frame(minWidth: 480, minHeight: 360)
                .onAppear {
                    syncLocalization()
                    updateCheckService.start()
                }
                .onChange(of: localizationService.selectedLanguage) { _ in
                    syncLocalization()
                }
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }

    private func syncLocalization() {
        calendarService.setNotificationLocalization(localizationService.notificationLocalization)
    }

    private func configureAppIcon() {
        if let icon = NSImage(named: "AppIcon") ?? NSImage(named: "AppIcon.icns") {
            NSApplication.shared.applicationIconImage = icon
        }
    }
}

// MARK: - Notification delegate

final class AppNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    var onJoinFromNotification: ((MeetingReminderItem) -> Void)?

    // Called when user taps a notification or its action button
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }

        guard response.actionIdentifier == NotificationService.actionID ||
              response.actionIdentifier == UNNotificationDefaultActionIdentifier
        else { return }

        let userInfo = response.notification.request.content.userInfo
        if let items = Self.decodeItems(from: userInfo), !items.isEmpty {
            DispatchQueue.main.async {
                if items.count == 1, let item = items.first {
                    self.onJoinFromNotification?(item)
                    return
                }
                MeetingJoinSelectionController.shared.present(items: items) { selected in
                    self.onJoinFromNotification?(selected)
                }
            }
            return
        }

        if let urlString = userInfo["joinURL"] as? String,
           let url = URL(string: urlString) {
            DispatchQueue.main.async {
                NSWorkspace.shared.open(url)
                PostJoinDismissController.shared.dismissAfterJoin(context: .notificationAction)
            }
        }
    }

    // Show banner even when app is frontmost
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    static func decodeItems(from userInfo: [AnyHashable: Any]) -> [MeetingReminderItem]? {
        guard let raw = userInfo[NotificationService.itemsUserInfoKey] as? String,
              let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([MeetingReminderItem].self, from: data)
    }
}
