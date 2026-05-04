import SwiftUI

struct MenuBarLabelView: View {
    @EnvironmentObject var service: CalendarService
    @EnvironmentObject private var localization: LocalizationService
    @State private var pulseOpacity: Double = 1.0

    var body: some View {
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
            .help(helpText)
    }

    private var iconName: String {
        isHappeningNow ? "calendar.badge.clock" : "calendar"
    }

    private var isHappeningNow: Bool {
        service.events.contains { $0.isHappeningNow }
    }

    private var helpText: String {
        let count = service.events.filter { $0.startDate.isToday }.count
        return count == 0
            ? localization.tr("menubar.no.meetings.today")
            : localization.tr("menubar.meetings.today", localization.meetings(count))
    }
}
