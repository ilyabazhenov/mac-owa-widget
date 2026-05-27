import SwiftUI
import UserNotifications
import AppKit

@main
struct OWAWidgetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

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
        DiagnosticLog.event("App init")
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
                    setupGlobalHotkeyJoin()
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
            .onAppear {
                DiagnosticLog.event("Window create-meeting appeared")
                AppDelegate.createMeetingWindowVisible = true
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
            }
            .onDisappear {
                AppDelegate.createMeetingWindowVisible = false
                NSApp.setActivationPolicy(.accessory)
            }
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
                    DiagnosticLog.event("Window settings appeared")
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

    private func setupGlobalHotkeyJoin() {
        GlobalHotkeyJoinService.shared.start(calendarService: calendarService)
    }

    private func configureAppIcon() {
        if let icon = NSImage(named: "AppIcon") ?? NSImage(named: "AppIcon.icns") {
            NSApplication.shared.applicationIconImage = icon
        }
    }
}

// MARK: - App delegate

/// Brings the create-meeting window to the front when the app is activated via Cmd+Tab.
/// Needed because dynamic setActivationPolicy(.regular) from LSUIElement doesn't
/// automatically raise windows on activation.
///
/// IMPORTANT: this must NOT touch any other window (e.g. the settings window).
/// applicationDidBecomeActive fires during SwiftUI's window-construction phase when a
/// new Window scene mounts; calling makeKeyAndOrderFront on a half-constructed window
/// reliably crashes on macOS Sequoia (15.x). The settings window stays in `.accessory`
/// mode, isn't reachable via Cmd+Tab, and doesn't need the raise — so we scope this
/// strictly to create-meeting via a flag set in its onAppear/onDisappear plus an
/// identifier check as a belt-and-suspenders guard.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Flipped to `true` while the create-meeting window is on screen.
    /// Mutated from SwiftUI onAppear/onDisappear (main thread). Read from
    /// applicationDidBecomeActive (main thread). Single-thread access only.
    nonisolated(unsafe) static var createMeetingWindowVisible = false

    func applicationDidBecomeActive(_ notification: Notification) {
        let createMeetingVisible = AppDelegate.createMeetingWindowVisible
        DiagnosticLog.event(
            "AppDelegate.applicationDidBecomeActive createMeetingVisible=\(createMeetingVisible)"
        )
        guard createMeetingVisible else { return }
        NSApp.windows
            .filter {
                AppDelegate.shouldRaiseWindow(
                    createMeetingVisible: createMeetingVisible,
                    identifier: $0.identifier?.rawValue,
                    canBecomeMain: $0.canBecomeMain,
                    isPanel: $0 is NSPanel,
                    isVisible: $0.isVisible
                )
            }
            .forEach { $0.makeKeyAndOrderFront(nil) }
    }

    /// Pure predicate deciding whether a given AppKit window should be raised on
    /// `applicationDidBecomeActive`. Extracted from the inline filter so the branching
    /// can be unit-tested without instantiating real `NSWindow` objects.
    ///
    /// The rules, in order:
    ///   1. If the create-meeting window is not currently on screen — never raise anything.
    ///      Settings and any other window stay where they are.
    ///   2. The candidate window must be a normal main window (not a panel, popover or
    ///      utility window) and currently visible. Raising a half-constructed or hidden
    ///      window is what crashed v1.0.37 on Sequoia.
    ///   3. The candidate window must be the create-meeting window specifically,
    ///      identified by `Window(id:)` matching `"create-meeting"`. We match by
    ///      `contains` because SwiftUI may decorate the raw identifier with suffixes
    ///      (e.g. `"create-meeting-AppWindow-1"`) and the exact format isn't a stable
    ///      contract across macOS versions.
    static func shouldRaiseWindow(
        createMeetingVisible: Bool,
        identifier: String?,
        canBecomeMain: Bool,
        isPanel: Bool,
        isVisible: Bool
    ) -> Bool {
        guard createMeetingVisible else { return false }
        guard canBecomeMain, !isPanel, isVisible else { return false }
        guard let identifier, identifier.contains("create-meeting") else { return false }
        return true
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
