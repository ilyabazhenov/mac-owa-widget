import SwiftUI
import UserNotifications
import AppKit

@main
struct OWAWidgetApp: App {
    // Using property-initializer syntax so SwiftUI evaluates each expression exactly once,
    // regardless of how many times the App struct is re-instantiated during startup.
    // With the old pattern (_foo = StateObject(wrappedValue: Foo()) inside an explicit init()),
    // SwiftUI can call init() multiple times, each creating a live CalendarService + background
    // tasks — causing duplicate reminder panels.
    @StateObject private var localizationService = LocalizationService(resourceBundle: .main)
    @StateObject private var calendarService = CalendarService()
    @StateObject private var updateCheckService = UpdateCheckService()
    @StateObject private var appearanceService = AppearanceService()

    // Static: one delegate instance survives across App struct re-evaluations.
    private static let notificationDelegate = AppNotificationDelegate()

    init() {
        UNUserNotificationCenter.current().delegate = Self.notificationDelegate
        configureAppIcon()
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environmentObject(calendarService)
                .environmentObject(localizationService)
                .environmentObject(updateCheckService)
                .environmentObject(appearanceService)
                .environment(\.locale, localizationService.locale)
                .onAppear {
                    setupNotificationDelegate()
                    syncLocalization()
                }
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
                    appearanceService.applyOnLaunch()
                }
        }
        .menuBarExtraStyle(.window)

        Window(localizationService.tr("window.create.meeting.title"), id: "create-meeting") {
            Group {
                if let account = calendarService.accounts.first {
                    CreateMeetingView(calendarService: calendarService, accountID: account.id)
                        .environmentObject(localizationService)
                        .environmentObject(appearanceService)
                        .environment(\.locale, localizationService.locale)
                }
            }
            .onAppear { NSApp.setActivationPolicy(.regular) }
            .onDisappear { NSApp.setActivationPolicy(.accessory) }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 900, height: 680)
        .defaultPosition(.center)

        Window(localizationService.tr("window.settings.title"), id: "settings") {
            SettingsView(calendarService: calendarService)
                .environmentObject(localizationService)
                .environmentObject(updateCheckService)
                .environmentObject(appearanceService)
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

    /// Wires the notification delegate to the live CalendarService owned by SwiftUI.
    /// Called from onAppear so it runs after @StateObject is fully initialised.
    private func setupNotificationDelegate() {
        Self.notificationDelegate.onJoinFromNotification = { [calendarService] item in
            calendarService.openJoinURL(for: item, source: .reminderNotification)
            PostJoinDismissController.shared.dismissAfterJoin(context: .notificationAction)
        }
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
        let handled = removeDeliveredForJoinAction(
            actionIdentifier: response.actionIdentifier,
            requestIdentifier: response.notification.request.identifier,
            removeDelivered: { ids in
                center.removeDeliveredNotifications(withIdentifiers: ids)
            }
        )
        guard handled else { return }

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

    @discardableResult
    func removeDeliveredForJoinAction(
        actionIdentifier: String,
        requestIdentifier: String,
        removeDelivered: ([String]) -> Void
    ) -> Bool {
        guard actionIdentifier == NotificationService.actionID ||
              actionIdentifier == UNNotificationDefaultActionIdentifier
        else { return false }

        // Ensure the clicked notification is removed from Notification Center.
        // Without this, macOS may keep the delivered banner visible after Join.
        removeDelivered([requestIdentifier])

        return true
    }
}
