import SwiftUI
import AppKit

struct PopoverView: View {
    @EnvironmentObject var service: CalendarService
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
            Text("OWA Widget")
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
                .help("Sync now")
            }

            Button { openSettings() } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .help("Settings")
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
        Text(service.syncStatus.displayText)
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
            Text("No accounts configured")
                .font(.system(size: 13, weight: .medium))
            Text("Open Settings to add your Exchange account.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button { openSettings() } label: {
                Text("Open Settings")
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
            Text(service.syncStatus.displayText)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry") { service.syncNow() }
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
            ("Today", today),
            ("Tomorrow", tomorrow)
        ]

        let laterByDay = Dictionary(grouping: later) { $0.startDate.sectionLabel }
        let sortedKeys = laterByDay.keys.sorted()
        for key in sortedKeys {
            sections.append((key, laterByDay[key]!))
        }

        return sections
    }
}
