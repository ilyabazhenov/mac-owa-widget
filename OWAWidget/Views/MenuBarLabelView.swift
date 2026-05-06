import SwiftUI

struct MenuBarLabelView: View {
    @EnvironmentObject var service: CalendarService
    @EnvironmentObject private var localization: LocalizationService
    @State private var pulseOpacity: Double = 1.0
    @State private var now: Date = .init()

    private let ticker = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: iconName)
                .imageScale(.medium)

            if let label = countdownLabel {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .frame(minWidth: 28, alignment: .trailing)
            }
        }
        .opacity(pulseOpacity)
        .onReceive(ticker) { now = $0 }
        .onChange(of: isHappeningNow) { happening in
            if happening {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    pulseOpacity = 0.3
                }
            } else {
                withAnimation { pulseOpacity = 1.0 }
            }
        }
        .help(helpText)
    }

    private var iconName: String {
        isHappeningNow ? "calendar.badge.clock" : "calendar"
    }

    private var isHappeningNow: Bool {
        service.events.contains { $0.startDate <= now && $0.endDate > now }
    }

    private var nextUpcomingEvent: CalendarEvent? {
        service.events
            .filter { $0.startDate > now }
            .sorted { $0.startDate < $1.startDate }
            .first
    }

    private var countdownLabel: String? {
        guard let event = nextUpcomingEvent else { return nil }
        let minutes = Int(event.startDate.timeIntervalSince(now) / 60)
        guard minutes > 0 else { return nil }
        if minutes < 60 { return "\(minutes)m" }
        return localization.shortTime(event.startDate)
    }

    private var helpText: String {
        let count = service.events.filter { $0.startDate.isToday }.count
        return count == 0
            ? localization.tr("menubar.no.meetings.today")
            : localization.tr("menubar.meetings.today", localization.meetings(count))
    }
}
