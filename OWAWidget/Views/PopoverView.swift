import SwiftUI
import AppKit

struct PopoverView: View {
    @EnvironmentObject var service: CalendarService
    @EnvironmentObject private var localization: LocalizationService
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 420)
        .frame(minHeight: 380, maxHeight: 660)
        .background(Color(nsColor: .windowBackgroundColor))
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
            } else {
                Button {
                    service.syncNow()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .help(localization.tr("popover.sync.now"))
            }

            Button { openSettings() } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .help(localization.tr("popover.settings"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if service.accounts.isEmpty {
            noAccountState
        } else if service.syncStatus.isError {
            errorState
        } else {
            VStack(spacing: 0) {
                if !nextEvents.isEmpty {
                    NextMeetingBannerView(events: nextEvents)
                    Divider().padding(.top, 8)
                }
                MeetingListView(sections: eventSections)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        Text(localization.syncStatusText(service.syncStatus))
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
    }

    private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "settings")
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

    /// Meetings starting within 5 minutes of the earliest upcoming, sorted: with URL first
    private var nextEvents: [CalendarEvent] {
        let upcoming = service.events
            .filter { $0.startDate > now || $0.isHappeningNow }
            .sorted { $0.startDate < $1.startDate }

        guard let earliest = upcoming.first else { return [] }

        // Only surface the banner for meetings starting within 30 minutes
        guard earliest.minutesUntilStart <= 30 || earliest.isHappeningNow else { return [] }

        let group = upcoming.filter {
            abs($0.startDate.timeIntervalSince(earliest.startDate)) <= 300
        }
        return group.sorted { ($0.joinURL != nil ? 0 : 1) < ($1.joinURL != nil ? 0 : 1) }
    }

    private var eventSections: [(label: String, events: [CalendarEvent])] {
        let calendar = Calendar.current
        let todayEnd = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: now)!)
        let tomorrowEnd = calendar.date(byAdding: .day, value: 1, to: todayEnd)!

        let today = service.events.filter { $0.startDate < todayEnd && $0.endDate > calendar.startOfDay(for: now) }
        let tomorrow = service.events.filter { $0.startDate >= todayEnd && $0.startDate < tomorrowEnd }
        let later = service.events.filter { $0.startDate >= tomorrowEnd }

        // Group "later" by day
        var sections: [(label: String, events: [CalendarEvent])] = [
            (localization.tr("date.today"), today),
            (localization.tr("date.tomorrow"), tomorrow)
        ]

        let laterByDay = Dictionary(grouping: later) {
            localization.daySectionLabel(for: $0.startDate, calendar: calendar)
        }
        let sortedKeys = laterByDay.keys.sorted()
        for key in sortedKeys {
            sections.append((key, laterByDay[key]!))
        }

        return sections
    }
}
