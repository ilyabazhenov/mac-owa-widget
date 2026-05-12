import SwiftUI
import AppKit

struct PopoverView: View {
    @EnvironmentObject var service: CalendarService
    @EnvironmentObject private var localization: LocalizationService
    @EnvironmentObject private var updateCheck: UpdateCheckService
    @Environment(\.openWindow) private var openWindow
    private let popoverSize = PopoverSize.defaultValue
    private let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    private let appBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    private var fullVersion: String { "\(appVersion).\(appBuild)" }
    let contentHorizontalPadding: CGFloat = 12
    @State private var selectedDayOffset: Int = 0
    @State private var selectedEvent: CalendarEvent? = nil
    private let maxDayOffset = 6

    enum DateNavBarPolicy {
        static func shouldShowJumpToToday(selectedDayOffset: Int) -> Bool {
            selectedDayOffset > 0
        }

        static func canGoToPreviousDay(selectedDayOffset: Int) -> Bool {
            selectedDayOffset > 0
        }

        static func canGoToNextDay(selectedDayOffset: Int, maxDayOffset: Int) -> Bool {
            selectedDayOffset < maxDayOffset
        }
    }

    enum MeetingDetailStatePolicy {
        static func selectedEventAfterPopoverDisappear(_ currentSelection: CalendarEvent?) -> CalendarEvent? {
            nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: CGFloat(popoverSize.width), height: CGFloat(popoverSize.height))
        .background(Color(nsColor: .windowBackgroundColor))
        .background {
            PopoverWindowAligner(popoverSize: popoverSize)
                .frame(width: 0, height: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(localization.tr("app.name"))
        .onDisappear {
            resetMeetingDetailState()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text(localization.tr("app.name"))
                .font(.system(size: 13, weight: .semibold))

            Spacer()

            if service.syncStatus.isSyncing {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 16, height: 16)
                    .accessibilityLabel(localization.tr("sync.status.syncing"))
            } else {
                Button {
                    service.syncNow()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .help(localization.tr("popover.sync.now"))
                .accessibilityLabel(localization.tr("popover.sync.now"))
            }

            Button { openSettings() } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .help(localization.tr("popover.settings"))
            .accessibilityLabel(localization.tr("popover.settings"))

            Button { quitApp() } label: {
                Image(systemName: "power")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .help(localization.tr("popover.quit"))
            .accessibilityLabel(localization.tr("popover.quit"))
        }
        .padding(.horizontal, contentHorizontalPadding)
        .padding(.vertical, 11)
        .accessibilitySortPriority(selectedEvent == nil ? 1 : 0)
    }

    private var footerEngagementIndicator: some View {
        let snapshot = service.engagementSnapshot
        let percent = Int(snapshot.conversionRate * 100)
        return HStack(spacing: 4) {
            CompactCircularProgress(
                progress: snapshot.conversionRate,
                title: nil,
                lineWidth: 2
            )
            Text("\(percent)%")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .help(localization.effectiveLanguageCode == "ru" ? "Доля подключений: \(snapshot.joinedViaWidget)/\(snapshot.eligibleMeetings)" : "Join rate: \(snapshot.joinedViaWidget)/\(snapshot.eligibleMeetings)")
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        Group {
            if service.accounts.isEmpty {
                noAccountState
            } else if SyncPresentationPolicy.shouldShowErrorState(
                syncStatus: service.syncStatus,
                eventsCount: service.events.count
            ) {
                errorState
            } else {
                dayTimelineContent
            }
        }
    }

    private var dayTimelineContent: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                dateNavBar
                Divider()
                UpdateAvailableBannerView(
                    updateCheck: updateCheck,
                    horizontalPadding: contentHorizontalPadding
                )
                if updateCheck.availableUpdate != nil {
                    Divider()
                }
                if selectedDayOffset == 0 && !nextEvents.isEmpty {
                    NextMeetingBannerView(
                        events: nextEvents,
                        horizontalPadding: contentHorizontalPadding,
                        onSelect: selectEvent
                    )
                    Divider().padding(.top, 8)
                }
                MeetingListView(
                    sections: eventSections,
                    contentHorizontalPadding: contentHorizontalPadding,
                    selectedEventID: selectedEvent?.id,
                    onSelect: selectEvent
                )
            }
            .accessibilityHidden(selectedEvent != nil)
            .overlay {
                if selectedEvent != nil {
                    Color(nsColor: .windowBackgroundColor)
                        .opacity(0.26)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }

            if let selectedEvent {
                MeetingDetailPanelView(event: selectedEvent) {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        resetMeetingDetailState()
                    }
                }
                .padding(.horizontal, contentHorizontalPadding)
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(1)
                .accessibilityAddTraits(.isModal)
                .accessibilitySortPriority(100)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: selectedEvent?.id)
    }

    private var dateNavBar: some View {
        HStack {
            Button {
                if DateNavBarPolicy.canGoToPreviousDay(selectedDayOffset: selectedDayOffset) {
                    selectedDayOffset -= 1
                    resetMeetingDetailState()
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .disabled(!DateNavBarPolicy.canGoToPreviousDay(selectedDayOffset: selectedDayOffset))
            .accessibilityLabel(localization.tr("a11y.nav.previous.day"))

            Spacer()

            Text(localization.daySectionLabel(for: selectedDate, calendar: .current))
                .font(.system(size: 12, weight: .semibold))

            Spacer()

            if DateNavBarPolicy.shouldShowJumpToToday(selectedDayOffset: selectedDayOffset) {
                Button {
                    selectedDayOffset = 0
                    resetMeetingDetailState()
                } label: {
                    Label(localization.tr("popover.nav.today"), systemImage: "arrow.uturn.backward.circle")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .padding(.trailing, 2)
                .accessibilityLabel(localization.tr("a11y.nav.today"))
            }

            Button {
                if DateNavBarPolicy.canGoToNextDay(selectedDayOffset: selectedDayOffset, maxDayOffset: maxDayOffset) {
                    selectedDayOffset += 1
                    resetMeetingDetailState()
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .disabled(!DateNavBarPolicy.canGoToNextDay(selectedDayOffset: selectedDayOffset, maxDayOffset: maxDayOffset))
            .accessibilityLabel(localization.tr("a11y.nav.next.day"))
        }
        .padding(.horizontal, contentHorizontalPadding)
        .padding(.vertical, 6)
        .accessibilitySortPriority(selectedEvent == nil ? 10 : 0)
    }

    // MARK: - Footer

    private var footer: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 8) {
                Text(localization.syncStatusText(service.syncStatus, relativeTo: context.date))
                    .lineLimit(1)

                if service.syncStatus.isOfflineCached {
                    Image(systemName: "wifi.slash")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                }

                Spacer(minLength: 8)
                footerEngagementIndicator

                Text("v\(fullVersion)")
                    .lineLimit(1)
            }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.horizontal, contentHorizontalPadding)
                .padding(.vertical, 7)
        }
    }

    private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "settings")
    }

    private func quitApp() {
        NSApp.terminate(nil)
    }

    private func selectEvent(_ event: CalendarEvent) {
        withAnimation(.easeInOut(duration: 0.18)) {
            selectedEvent = event
        }
    }

    private func resetMeetingDetailState() {
        selectedEvent = MeetingDetailStatePolicy.selectedEventAfterPopoverDisappear(selectedEvent)
    }

    // MARK: - Error / empty states

    private var noAccountState: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.badge.plus")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(localization.tr("popover.no.accounts.title"))
                .font(.system(size: 13, weight: .medium))
            Text(localization.tr("popover.no.accounts.subtitle"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button { openSettings() } label: {
                Text(localization.tr("popover.open.settings"))
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }

    private var errorState: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 24))
                .foregroundStyle(.orange)
            Text(localization.syncStatusText(service.syncStatus))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(localization.tr("popover.retry")) { service.syncNow() }
                .font(.system(size: 12))
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Derived data

    private var now: Date { Date() }

    private var selectedDate: Date {
        Calendar.current.date(byAdding: .day, value: selectedDayOffset,
            to: Calendar.current.startOfDay(for: Date()))!
    }

    /// Meetings starting within 5 minutes of the earliest upcoming, sorted: with URL first
    private var nextEvents: [CalendarEvent] {
        NextEventsPolicy.nextEvents(from: service.events, now: now)
    }

    enum NextEventsPolicy {
        static func nextEvents(from events: [CalendarEvent], now: Date) -> [CalendarEvent] {
            let upcoming = events
                .filter {
                    !$0.isAllDay &&
                        !$0.isEffectivelyCancelled &&
                        ($0.startDate > now || $0.isHappeningNow)
                }
                .sorted { $0.startDate < $1.startDate }

            guard let earliest = upcoming.first else { return [] }

            // Only surface the banner for meetings starting within 30 minutes
            let secondsUntilEarliestStart = earliest.startDate.timeIntervalSince(now)
            guard secondsUntilEarliestStart <= 30 * 60 || earliest.isHappeningNow else { return [] }

            let promoted = upcoming.first {
                !$0.isHappeningNow && $0.startDate.timeIntervalSince(now) <= 5 * 60
            }
            let reference = promoted ?? earliest

            let group = upcoming.filter {
                abs($0.startDate.timeIntervalSince(reference.startDate)) <= 300
            }
            return group.sorted { ($0.joinURL != nil ? 0 : 1) < ($1.joinURL != nil ? 0 : 1) }
        }
    }

    private var eventSections: [(label: String, date: Date, events: [CalendarEvent])] {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: selectedDate)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!

        let events = service.events.filter { $0.startDate < dayEnd && $0.endDate > dayStart }
        return [(localization.daySectionLabel(for: dayStart, calendar: calendar), dayStart, events)]
    }
}

private struct CompactCircularProgress: View {
    let progress: Double
    let title: String?
    var lineWidth: CGFloat = 3

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.22), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0, min(progress, 1)))
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if let title {
                Text(title)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 16, height: 16)
    }
}
