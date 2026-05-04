import SwiftUI

struct MenuBarLabelView: View {
    @EnvironmentObject var service: CalendarService
    @State private var pulseOpacity: Double = 1.0

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: iconName)
                .imageScale(.medium)
                .opacity(pulseOpacity)
                .onChange(of: isHappeningNow) { happening in
                    if happening {
                        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                            pulseOpacity = 0.3
                        }
                    } else {
                        withAnimation { pulseOpacity = 1.0 }
                    }
                }

            let label = menuBarLabel
            if !label.isEmpty {
                Text(label)
                    .font(.system(size: 12, weight: .medium, design: .default))
            }
        }
        .help(helpText)
    }

    private var iconName: String {
        isHappeningNow ? "calendar.badge.clock" : "calendar"
    }

    private var isHappeningNow: Bool {
        service.events.contains { $0.isHappeningNow }
    }

    private var menuBarLabel: String {
        let events = service.events
        let now = Date()

        if isHappeningNow { return "● now" }

        let upcoming = events
            .filter { $0.startDate > now }
            .sorted { $0.startDate < $1.startDate }

        guard let next = upcoming.first else {
            let todayCount = events.filter { $0.startDate.isToday }.count
            return todayCount > 0 ? "\(todayCount) today" : ""
        }

        let minutes = next.minutesUntilStart
        if minutes <= 60 {
            // Group concurrent meetings (within 5 min window)
            let concurrent = upcoming.filter {
                abs($0.startDate.timeIntervalSince(next.startDate)) <= 300
            }
            return concurrent.count > 1 ? "\(concurrent.count) in \(minutes)m" : "in \(minutes)m"
        }

        let todayCount = events.filter { $0.startDate.isToday }.count
        return todayCount > 0 ? "\(todayCount) today" : ""
    }

    private var helpText: String {
        let count = service.events.filter { $0.startDate.isToday }.count
        return count == 0 ? "No meetings today" : "\(count) meeting\(count == 1 ? "" : "s") today"
    }
}
