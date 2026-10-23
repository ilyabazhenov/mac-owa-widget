import SwiftUI

/// A section title of the overview: a coloured icon, the title, an optional count capsule and
/// an optional quiet note after it.
struct MailDigestSectionHeader: View {
    let title: String
    var count: Int?
    let icon: String
    let tint: Color
    var countIsUrgent = false
    var note: String?

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon).font(.app(.headline)).foregroundStyle(tint)
            Text(title).font(.app(.headline, weight: .semibold))
            if let count {
                Text("\(count)")
                    .font(.app(.caption, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(countIsUrgent ? AnyShapeStyle(tint) : AnyShapeStyle(.secondary))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(countIsUrgent ? tint.opacity(0.16) : Color.secondary.opacity(0.12)))
            }
            if let note {
                Text(note).font(.app(.footnote)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

// MARK: - Today's load

/// One line on today's meetings under the title, and a strip of the working day with the
/// meetings on it, a mark for now and a red outline where two meetings overlap.
struct MailDigestDayLoadView: View {
    @EnvironmentObject private var calendar: CalendarService
    @EnvironmentObject private var localization: LocalizationService

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            if let load = MailDigestSchedule.dayLoad(events: calendar.events, now: context.date) {
                content(load, now: context.date)
            }
        }
    }

    private func content(_ load: MailDigestSchedule.DayLoad, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            summary(load)
            strip(load, now: now)
                .frame(height: 12)
                .accessibilityHidden(true)
            hours(load)
        }
        .accessibilityElement(children: .combine)
    }

    private func summary(_ load: MailDigestSchedule.DayLoad) -> some View {
        var main = [
            localization.tr("mail.digest.load.today", localization.meetings(load.meetingCount)),
            localization.compactDuration(minutes: Int((load.meetingSeconds / 60).rounded())),
        ]
        main.append(load.remainingCount > 0
            ? localization.tr("mail.digest.load.remaining", load.remainingCount)
            : localization.tr("mail.digest.load.done"))
        return (Text(main.joined(separator: " · ")).foregroundColor(.primary)
            + Text(freeText(load).map { " · \($0)" } ?? "").foregroundColor(.secondary))
            .font(.app(.footnote))
            .lineLimit(1)
            .truncationMode(.tail)
    }

    /// "свободно до 10:30, 12:30–14:00": the next two windows at most.
    private func freeText(_ load: MailDigestSchedule.DayLoad) -> String? {
        let parts = load.freeSlots.prefix(2).map { slot in
            switch slot {
            case .until(let end): localization.tr("mail.digest.load.until", localization.shortTime(end))
            case .between(let window): "\(localization.shortTime(window.start))–\(localization.shortTime(window.end))"
            case .after(let start): localization.tr("mail.digest.load.after", localization.shortTime(start))
            }
        }
        guard !parts.isEmpty else { return nil }
        return localization.tr("mail.digest.load.free", parts.joined(separator: ", "))
    }

    private func strip(_ load: MailDigestSchedule.DayLoad, now: Date) -> some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let span = max(load.axis.duration, 1)
            let x = { (date: Date) in CGFloat(date.timeIntervalSince(load.axis.start) / span) * width }
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.1))
                ForEach(load.blocks.indices, id: \.self) { index in
                    let block = load.blocks[index]
                    let isNow = block.interval.contains(now)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(block.isOver ? Color.secondary.opacity(0.35) : Color.accentColor.opacity(isNow ? 1 : 0.6))
                        .frame(width: max(2, x(block.interval.end) - x(block.interval.start)), height: 8)
                        .offset(x: x(block.interval.start))
                }
                ForEach(load.overlaps.indices, id: \.self) { index in
                    let overlap = load.overlaps[index]
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(Color.red, lineWidth: 1)
                        .frame(width: max(3, x(overlap.end) - x(overlap.start)), height: 12)
                        .offset(x: x(overlap.start))
                }
                if load.axis.contains(now) {
                    Capsule().fill(Color.red).frame(width: 2, height: 14).offset(x: x(now) - 1)
                }
            }
        }
    }

    /// Every second hour under the strip.
    private func hours(_ load: MailDigestSchedule.DayLoad) -> some View {
        let calendar = AppTimeZone.calendar
        let first = calendar.component(.hour, from: load.axis.start)
        let count = Int((load.axis.duration / 3600).rounded())
        let step = count > 12 ? 3 : 2
        let marks = stride(from: 0, through: count, by: step).map { first + $0 }
        return GeometryReader { geometry in
            ForEach(marks, id: \.self) { hour in
                Text("\(hour % 24)")
                    .font(.app(.micro))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .fixedSize()
                    .position(x: CGFloat(hour - first) / CGFloat(max(count, 1)) * geometry.size.width, y: 5)
            }
        }
        .frame(height: 10)
        .padding(.horizontal, 2)
        .accessibilityHidden(true)
    }
}

// MARK: - Up next

/// The meeting up next: a card with a countdown and Join while there is one today, a single quiet
/// line naming the next working day's first meeting once today's are over.
struct MailDigestNextMeetingView: View {
    @EnvironmentObject private var calendar: CalendarService
    @EnvironmentObject private var localization: LocalizationService

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            switch MailDigestSchedule.nextUp(events: calendar.events, now: context.date) {
            case .inProgress(let event, let next): card(event, happening: true, next: next, now: context.date)
            case .upcoming(let event): card(event, happening: false, next: nil, now: context.date)
            case .laterDay(let event): laterDay(event)
            case nil: EmptyView()
            }
        }
    }

    private func card(_ event: CalendarEvent, happening: Bool, next: CalendarEvent?, now: Date) -> some View {
        let tint: Color = happening ? .orange : .accentColor
        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: event.platform != .generic ? event.platform.systemIcon : "calendar")
                .font(.app(.title))
                .foregroundStyle(tint)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(countdown(event, happening: happening, now: now))
                    .font(.app(.footnote, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                Text(event.title)
                    .font(.app(.headline, weight: .semibold))
                    .lineLimit(1)
                Text(meta(event))
                    .font(.app(.footnote))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let next {
                    Text(localization.tr("mail.digest.next.after", localization.shortTime(next.startDate), next.title))
                        .font(.app(.footnote))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            // The text reads as one element; Join stays a button of its own, so moving through
            // the card does not press it.
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            if event.joinURLForActions != nil {
                Button {
                    calendar.openJoinURL(for: event)
                } label: {
                    Text(localization.tr("meeting.join"))
                        .font(.app(.body, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 7).fill(tint))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(localization.tr("a11y.meeting.join", event.title))
                .help(localization.tr("meeting.join.help", event.platform.displayName(localization: localization)))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(0.3), lineWidth: 0.5))
        .meetingCopyContextMenu(event, localization: localization)
        .accessibilityElement(children: .contain)
    }

    private func countdown(_ event: CalendarEvent, happening: Bool, now: Date) -> String {
        if happening {
            let minutes = max(1, Int((event.endDate.timeIntervalSince(now) / 60).rounded(.up)))
            return localization.tr("mail.digest.next.remaining", localization.compactDuration(minutes: minutes))
        }
        let minutes = Int((event.startDate.timeIntervalSince(now) / 60).rounded(.up))
        let time = "\(localization.shortTime(event.startDate))–\(localization.shortTime(event.endDate))"
        guard minutes > 0 else { return "\(localization.tr("meeting.starting.now")) · \(time)" }
        return "\(localization.tr("mail.digest.next.inTime", localization.compactDuration(minutes: minutes))) · \(time)"
    }

    private func meta(_ event: CalendarEvent) -> String {
        var parts: [String] = []
        if event.platform != .generic { parts.append(event.platform.displayName(localization: localization)) }
        if let location = event.location?.trimmingCharacters(in: .whitespacesAndNewlines), !location.isEmpty, event.platform == .generic {
            parts.append(location)
        }
        if let organizer = event.organizer, !event.isOrganizer { parts.append(organizer) }
        return parts.joined(separator: " · ")
    }

    private func laterDay(_ event: CalendarEvent) -> some View {
        let day = localization.formatDate(event.startDate, format: "EE, d MMM")
        return HStack(spacing: 7) {
            Image(systemName: "moon.stars")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("\(localization.tr("mail.digest.next.noMore")) · \(day), \(localization.shortTime(event.startDate)) — \(event.title)")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.app(.footnote))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Colleagues

/// The watched colleagues, free ones first, each with Call when a room link is known. Statuses
/// come from the free/busy grid already downloaded for the popover, recomputed from the clock;
/// the overview never asks for a refresh. Hidden while there is no usable grid.
struct MailDigestColleaguesView: View {
    @EnvironmentObject private var presence: ColleaguePresenceService
    @EnvironmentObject private var localization: LocalizationService

    static let limit = 8

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let now = context.date
            let shown = presence.isSectionVisible && presence.freshness != .none
                ? Array(MailDigestSchedule.orderedColleagues(presence.colleagues.map { ($0, presence.status(for: $0, now: now)) }) { $0.1.presence }
                    .prefix(Self.limit))
                : []
            if !shown.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    MailDigestSectionHeader(
                        title: localization.tr("mail.digest.colleagues"),
                        icon: "person.crop.circle.badge.checkmark",
                        tint: .green,
                        note: staleNote
                    )
                    FlowRow(spacing: 8) {
                        ForEach(shown, id: \.0.id) { colleague, status in
                            card(colleague, status: status, now: now)
                        }
                    }
                }
            }
        }
    }

    private var staleNote: String? {
        guard case .stale = presence.freshness, let at = presence.lastSuccessAt else { return nil }
        return localization.tr("mail.digest.colleagues.asOf", localization.shortTime(at))
    }

    private func card(_ colleague: WatchedColleague, status: ColleagueStatus, now: Date) -> some View {
        let room = ColleagueRoomLink.normalized(colleague.roomURL)
        let prominent = ColleaguePresenceStyle.joinIsProminent(for: status.presence)
        return HStack(spacing: 8) {
            Circle()
                .fill(ColleaguePresenceStyle.color(for: status.presence))
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(ColleagueNameFormatter.abbreviated(colleague.displayName))
                    .font(.app(.body, weight: .medium))
                    .lineLimit(1)
                    .help(colleague.displayName)
                Text(ColleagueStatusFormatter.text(for: status, now: now, localization: localization))
                    .font(.app(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            if let room, prominent {
                Button {
                    MeetingURLOpener.open(room)
                } label: {
                    Image(systemName: "phone.fill")
                        .font(.app(.footnote))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.accentColor.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .help(localization.tr("colleagues.menu.join"))
                .accessibilityLabel(localization.tr("a11y.colleagues.join", colleague.displayName))
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, room != nil && prominent ? 6 : 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5))
        .accessibilityElement(children: .contain)
    }
}
