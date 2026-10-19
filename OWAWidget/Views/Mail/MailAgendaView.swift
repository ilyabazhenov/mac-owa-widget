import SwiftUI

/// The calendar column of the mail window: one day of meetings next to the mail, so a reply can
/// say when the user is free, and an invitation in the open thread shows where it falls.
struct MailAgendaView: View {
    @ObservedObject var model: MailWindowModel
    @ObservedObject var mail: MailService
    @EnvironmentObject private var calendar: CalendarService
    @EnvironmentObject private var localization: LocalizationService
    @Environment(\.scrollerInset) private var scrollerInset

    @State private var dayOffset = 0
    @State private var expandedEventID: String?
    @State private var now = Date()
    private let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private var day: Date {
        AppTimeZone.calendar.date(byAdding: .day, value: dayOffset, to: AppTimeZone.calendar.startOfDay(for: now)) ?? now
    }

    private var dayEvents: [CalendarEvent] {
        MailAgendaPolicy.events(on: day, in: calendar.events)
    }

    /// The meeting the open thread is about (an invitation in it), when it is in the calendar.
    private var threadMeetingID: String? {
        model.thread?.messages.compactMap(\.meeting?.associatedCalendarItemID).first
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        let events = dayEvents
                        let allDay = events.filter(\.isAllDay)
                        let timed = events.filter { !$0.isAllDay }
                        if dayOffset == 0, let status = MailAgendaPolicy.freeStatus(timed, now: now, localization: localization) {
                            Label(status, systemImage: "clock")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .padding(.bottom, 2)
                        }
                        if !allDay.isEmpty {
                            ForEach(allDay) { event in
                                Text(event.title)
                                    .font(.system(size: 11, weight: .medium))
                                    .lineLimit(1)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.orange.opacity(0.14)))
                            }
                        }
                        if timed.isEmpty {
                            Text(localization.tr("mail.agenda.empty"))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .padding(.top, 8)
                        }
                        ForEach(Array(timed.enumerated()), id: \.element.id) { index, event in
                            if dayOffset == 0, MailAgendaPolicy.nowLineGoesBefore(index: index, events: timed, now: now) {
                                nowLine
                            }
                            eventRow(event)
                                .id(event.id)
                        }
                        if dayOffset == 0, let last = timed.last, last.endDate <= now {
                            nowLine
                        }
                        if dayOffset == 0, MailAgendaPolicy.showsTomorrow(timed, now: now) {
                            tomorrowBlock
                        }
                    }
                    .padding(12)
                    .padding(.trailing, scrollerInset)
                }
                .onChange(of: threadMeetingID) { id in
                    guard let id, let event = calendar.events.first(where: { $0.id == id }) else { return }
                    let days = AppTimeZone.calendar.dateComponents([.day], from: AppTimeZone.calendar.startOfDay(for: now), to: AppTimeZone.calendar.startOfDay(for: event.startDate)).day ?? 0
                    dayOffset = days
                    expandedEventID = id
                    DispatchQueue.main.async { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
        .onReceive(ticker) { now = $0 }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button { dayOffset -= 1 } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.mailIcon)
                .help(localization.tr("mail.agenda.previous"))
            Text(MailAgendaPolicy.dayLabel(day, offset: dayOffset, localization: localization))
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
            if dayOffset != 0 {
                Button(localization.tr("mail.agenda.today")) { dayOffset = 0 }
                    .buttonStyle(.mailIcon)
                    .foregroundStyle(Color.accentColor)
                    .font(.system(size: 11))
            }
            Button { dayOffset += 1 } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.mailIcon)
                .help(localization.tr("mail.agenda.next"))
        }
        .padding(.horizontal, 10)
        .frame(height: MailColumnWidths.headerHeight)
    }

    /// Evening: today is done, so the column looks ahead instead of standing empty.
    private var tomorrowBlock: some View {
        let tomorrow = AppTimeZone.calendar.date(byAdding: .day, value: 1, to: AppTimeZone.calendar.startOfDay(for: now)) ?? now
        let events = MailAgendaPolicy.events(on: tomorrow, in: calendar.events)
        let timed = events.filter { !$0.isAllDay }
        return VStack(alignment: .leading, spacing: 2) {
            Button {
                dayOffset = 1
            } label: {
                HStack(spacing: 4) {
                    Text(MailAgendaPolicy.dayLabel(tomorrow, offset: 1, localization: localization))
                        .font(.system(size: 11, weight: .semibold))
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(MailIconButtonStyle(horizontalPadding: 4, verticalPadding: 2))
            .padding(.leading, -4)
            .help(localization.tr("mail.agenda.next"))
            .padding(.top, 10)
            ForEach(events.filter(\.isAllDay)) { event in
                Text(event.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.orange.opacity(0.14)))
            }
            if timed.isEmpty {
                Text(localization.tr("mail.agenda.empty")).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(timed) { event in
                eventRow(event).id(event.id)
            }
        }
    }

    private var nowLine: some View {
        HStack(spacing: 4) {
            Circle().fill(Color.red).frame(width: 6, height: 6)
            Rectangle().fill(Color.red.opacity(0.7)).frame(height: 1)
            Text(localization.shortTime(now)).font(.system(size: 10, weight: .semibold)).foregroundStyle(.red).fixedSize()
        }
    }

    private func eventRow(_ event: CalendarEvent) -> some View {
        let past = event.endDate <= now
        let live = event.startDate <= now && now < event.endDate
        let linked = event.id == threadMeetingID
        let expanded = expandedEventID == event.id
        let declined = event.responseType == .declined || event.isEffectivelyCancelled
        let detail = MailAgendaPolicy.detailLine(event, expanded: expanded)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(MailAgendaPolicy.accent(event))
                    .frame(width: 3)
                // Start over end, beside the title: a meeting takes two short lines, so a whole
                // working day fits the column without scrolling.
                VStack(alignment: .trailing, spacing: 1) {
                    Text(localization.shortTime(event.startDate))
                        .font(.system(size: 11, weight: .medium))
                    Text(localization.shortTime(event.endDate))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .monospacedDigit()
                .fixedSize()
                VStack(alignment: .leading, spacing: 1) {
                    Text(event.title)
                        .font(.system(size: 12, weight: live ? .semibold : .medium))
                        .strikethrough(declined)
                        .lineLimit(expanded ? 4 : 1)
                    if let detail {
                        Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(expanded ? 2 : 1)
                    }
                }
                .help(event.title)
                Spacer(minLength: 2)
                if event.responseType == .notResponded, !event.isOrganizer, !past {
                    Image(systemName: "questionmark.circle").font(.system(size: 11)).foregroundStyle(.orange)
                        .padding(.top, 2)
                        .help(localization.tr("mail.agenda.notAnswered"))
                }
                if let url = event.joinURLForActions, !past, !declined {
                    Button {
                        calendar.openJoinURL(for: event)
                    } label: {
                        Image(systemName: "video.fill").font(.system(size: 11))
                    }
                    .buttonStyle(MailIconButtonStyle(horizontalPadding: 4, verticalPadding: 2))
                    .foregroundStyle(live ? Color.accentColor : Color.secondary)
                    .help(url.host ?? localization.tr("mail.agenda.join"))
                }
            }
            if expanded, mail.isAvailable {
                MeetingRelatedMailView(mail: mail, event: event, attendees: event.detailedAttendees ?? [])
                    .padding(.leading, 11)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(linked ? Color.accentColor.opacity(0.16) : (live ? Color.accentColor.opacity(0.08) : Color.clear))
        )
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(linked ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1))
        .mailHover(cornerRadius: 7, enabled: !linked)
        .opacity(past && !expanded ? 0.55 : 1)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.12)) { expandedEventID = expanded ? nil : event.id }
        }
    }
}

/// The agenda column's rules, kept pure for tests.
enum MailAgendaPolicy {
    static func events(on day: Date, in events: [CalendarEvent], calendar: Calendar = AppTimeZone.calendar) -> [CalendarEvent] {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        return events
            .filter { $0.startDate < end && $0.endDate > start }
            .sorted { ($0.isAllDay ? 0 : 1, $0.startDate, $0.endDate) < ($1.isAllDay ? 0 : 1, $1.startDate, $1.endDate) }
    }

    /// Today has nothing left (no meeting still to end): show tomorrow under it.
    static func showsTomorrow(_ timed: [CalendarEvent], now: Date) -> Bool {
        !timed.contains { $0.endDate > now }
    }

    /// Where the "now" line goes: before the first meeting that has not ended yet.
    static func nowLineGoesBefore(index: Int, events: [CalendarEvent], now: Date) -> Bool {
        guard let first = events.firstIndex(where: { $0.endDate > now }) else { return false }
        return index == first && events[first].startDate > now
    }

    /// "Free until 15:00" / "In a meeting until 12:30" / "Free for the rest of the day".
    @MainActor
    static func freeStatus(_ events: [CalendarEvent], now: Date, localization: LocalizationService) -> String? {
        let active = events.filter { $0.responseType != .declined && !$0.isEffectivelyCancelled }
        if let current = active.filter({ $0.startDate <= now && now < $0.endDate }).max(by: { $0.endDate < $1.endDate }) {
            return localization.tr("mail.agenda.busyUntil", localization.shortTime(current.endDate))
        }
        if let next = active.first(where: { $0.startDate > now }) {
            return localization.tr("mail.agenda.freeUntil", localization.shortTime(next.startDate))
        }
        return localization.tr("mail.agenda.freeRest")
    }

    @MainActor
    static func dayLabel(_ day: Date, offset: Int, localization: LocalizationService) -> String {
        let date = localization.formatDate(day, format: "EE, d MMMM")
        switch offset {
        case 0: return localization.tr("mail.agenda.todayLabel", date)
        case 1: return localization.tr("mail.agenda.tomorrowLabel", date)
        default: return date
        }
    }

    /// The line under a meeting's title: where it is or who called it. A link in the location is
    /// left out while the row is folded, since the camera button already opens it.
    static func detailLine(_ event: CalendarEvent, expanded: Bool) -> String? {
        if let location = event.location?.trimmingCharacters(in: .whitespacesAndNewlines), !location.isEmpty {
            let isLink = location.lowercased().hasPrefix("http://") || location.lowercased().hasPrefix("https://")
            if expanded || !isLink { return location }
        }
        if let organizer = event.organizer, !organizer.isEmpty, !event.isOrganizer { return organizer }
        return nil
    }

    static func accent(_ event: CalendarEvent) -> Color {
        if event.isEffectivelyCancelled || event.responseType == .declined { return .gray }
        switch event.responseType {
        case .tentative, .notResponded: return .orange
        default: return .accentColor
        }
    }
}
