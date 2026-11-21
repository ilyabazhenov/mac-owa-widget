import SwiftUI

/// Strings for the invitation panel. The panel is owned by `CalendarService`, outside the SwiftUI
/// environment, so it receives resolved strings the same way the reminder banner does.
struct MeetingInvitationLocalization: Sendable, Equatable {
    let localeIdentifier: String
    let titleSingle: String
    /// `%d` = number of rows.
    let titleMultipleFormat: String
    let titleUpdates: String
    let kindInvited: String
    let kindRescheduled: String
    let kindCancelled: String
    /// `%@` = organiser name.
    let organizerFormat: String
    /// `%@` = previous date and time.
    let previousTimeFormat: String
    /// `%d` = occurrences folded into the row.
    let seriesFormat: String
    let allDay: String
    let today: String
    let tomorrow: String
    let acceptTitle: String
    let tentativeTitle: String
    let declineTitle: String
    let openTitle: String
    let hideTitle: String
    let closeTitle: String
    let sendFailed: String
    /// `%d` = rows that did not fit.
    let moreFormat: String
    let notifyOnHelp: String
    let notifyOffHelp: String
    /// `%d` = occurrences answered at once.
    let seriesAllFormat: String
    let seriesAllSilentFormat: String
    let doneAccept: String
    let doneTentative: String
    let doneDecline: String
    let doneSeries: String
    let doneSent: String
    let doneSilent: String

    static let english = MeetingInvitationLocalization(
        localeIdentifier: "en",
        titleSingle: "New invitation",
        titleMultipleFormat: "New invitations · %d",
        titleUpdates: "Calendar changes",
        kindInvited: "Invitation",
        kindRescheduled: "Rescheduled",
        kindCancelled: "Cancelled",
        organizerFormat: "from %@",
        previousTimeFormat: "was %@",
        seriesFormat: "Series (%d)",
        allDay: "All day",
        today: "Today",
        tomorrow: "Tomorrow",
        acceptTitle: "Accept",
        tentativeTitle: "Tentative",
        declineTitle: "Decline",
        openTitle: "Open",
        hideTitle: "Hide",
        closeTitle: "Close",
        sendFailed: "Failed to send response",
        moreFormat: "%d more",
        notifyOnHelp: "The organizer gets an email. Click to answer without one",
        notifyOffHelp: "The organizer gets no email. Click to send one",
        seriesAllFormat: "Answers all %d occurrences",
        seriesAllSilentFormat: "Answers all %d occurrences · the organizer won't know",
        doneAccept: "Accepted",
        doneTentative: "Tentative",
        doneDecline: "Declined",
        doneSeries: "for the whole series",
        doneSent: "response sent",
        doneSilent: "organizer not notified"
    )

    /// "Accepted for the whole series · organizer not notified" after an answer from the panel.
    func summary(action: MeetingResponseAction, series: Bool, notify: Bool) -> String {
        let strings = [
            "meeting.reply.done.accept": doneAccept, "meeting.reply.done.tentative": doneTentative,
            "meeting.reply.done.decline": doneDecline, "meeting.reply.done.series": doneSeries,
            "meeting.reply.done.sent": doneSent, "meeting.reply.done.sentWithComment": doneSent,
            "meeting.reply.done.silent": doneSilent,
        ]
        return MeetingReplySummary.text(
            action: action,
            options: MeetingReplyOptions(series: series, notifyOrganizer: notify),
            tr: { strings[$0] ?? $0 }
        )
    }

    /// "Today · 14:00–15:00", "Tomorrow · 9:30–10:00", "Fri, 26 Sep · 14:00–15:00" in the
    /// display time zone (`calendar`) — the same day words as the popover's invitation section.
    /// `midSentence` lowercases the day for use inside a phrase ("was: today · …", "было: вт, 6 окт.").
    func dateLine(
        start: Date,
        end: Date,
        isAllDay: Bool,
        now: Date,
        calendar: Calendar = AppTimeZone.calendar,
        midSentence: Bool = false
    ) -> String {
        let locale = Locale(identifier: localeIdentifier)
        var dayLabel: String
        if calendar.isDate(start, inSameDayAs: now) {
            dayLabel = today
        } else if let nextDay = calendar.date(byAdding: .day, value: 1, to: now),
                  calendar.isDate(start, inSameDayAs: nextDay) {
            dayLabel = tomorrow
        } else {
            let day = DateFormatter()
            day.locale = locale
            day.timeZone = calendar.timeZone
            day.setLocalizedDateFormatFromTemplate("EEEdMMM")
            dayLabel = day.string(from: start)
        }
        if midSentence { dayLabel = dayLabel.lowercased(with: locale) }
        guard !isAllDay else { return "\(dayLabel) · \(allDay)" }

        let time = DateFormatter()
        time.locale = locale
        time.timeZone = calendar.timeZone
        time.dateStyle = .none
        time.timeStyle = .short
        return "\(dayLabel) · \(time.string(from: start))–\(time.string(from: end))"
    }

    /// The row's date line, plus the series size and, for a moved meeting, the previous time.
    func detailLine(for alert: MeetingInvitationAlert, now: Date, calendar: Calendar = AppTimeZone.calendar) -> String {
        var line = dateLine(start: alert.startDate, end: alert.endDate, isAllDay: alert.isAllDay, now: now, calendar: calendar)
        if alert.occurrenceCount > 1 {
            line += " · " + String(format: seriesFormat, alert.occurrenceCount)
        }
        guard case .rescheduled(let previousStart, let previousEnd) = alert.change else { return line }
        let previous = dateLine(start: previousStart, end: previousEnd, isAllDay: alert.isAllDay, now: now, calendar: calendar, midSentence: true)
        return line + "\n" + String(format: previousTimeFormat, previous)
    }

    func title(for alerts: [MeetingInvitationAlert]) -> String {
        let allInvitations = alerts.allSatisfy { $0.change == .invited }
        guard allInvitations else { return titleUpdates }
        return alerts.count == 1 ? titleSingle : String(format: titleMultipleFormat, alerts.count)
    }
}

/// One row of the panel as the controller sees it: the alert plus what the UI is doing with it.
struct MeetingInvitationRow: Identifiable, Equatable {
    let alert: MeetingInvitationAlert
    /// What the row says after its answer went through, for the moment before it leaves.
    struct Result: Equatable {
        let text: String
        /// Answered without telling the organizer: drawn with a crossed-out bell.
        let isSilent: Bool
    }

    /// RSVP buttons are shown while any meeting of the row still awaits an answer. A folded
    /// series is answered as a whole.
    var canRespond: Bool
    var sendingAction: MeetingResponseAction?
    var errorMessage: String?
    /// The bell: whether the answer from this row emails the organizer.
    var notifyOrganizer = true
    var result: Result?

    var id: String { alert.id }
}

struct MeetingInvitationBannerView: View {
    let title: String
    let rows: [MeetingInvitationRow]
    let hiddenRowCount: Int
    let localization: MeetingInvitationLocalization
    /// What "today" and "tomorrow" are measured against.
    let now: Date
    let onRespond: (MeetingInvitationRow, MeetingResponseAction) -> Void
    let onToggleNotify: (MeetingInvitationRow) -> Void
    let onOpen: (MeetingInvitationRow) -> Void
    let onHide: (MeetingInvitationRow) -> Void
    let onClose: () -> Void

    private let accentColor = Color.accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "envelope.badge")
                    .font(.app(.body, weight: .semibold))
                    .foregroundStyle(accentColor)
                Text(title)
                    .font(.app(.headline, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.app(.caption, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help(localization.closeTitle)
                .accessibilityLabel(localization.closeTitle)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)

            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 {
                    Divider().padding(.horizontal, 12)
                }
                rowView(row)
            }

            if hiddenRowCount > 0 {
                Divider().padding(.horizontal, 12)
                Text(String(format: localization.moreFormat, hiddenRowCount))
                    .font(.app(.footnote))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
        }
        .padding(.bottom, 4)
        .frame(width: 360, alignment: .leading)
        .background(bannerBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(accentColor.opacity(0.22), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
    }

    private var bannerBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(accentColor.opacity(0.10))
        }
    }

    @ViewBuilder
    private func rowView(_ row: MeetingInvitationRow) -> some View {
        let alert = row.alert
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(kindLabel(alert.change))
                    .font(.app(.caption, weight: .semibold))
                    .foregroundStyle(kindColor(alert.change))
                if let organizer = alert.organizer, !organizer.isEmpty {
                    Text("· " + String(format: localization.organizerFormat, organizer))
                        .font(.app(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Button { onHide(row) } label: {
                    Text(localization.hideTitle)
                        .font(.app(.caption))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Text(alert.title)
                .font(.app(.body, weight: .semibold))
                .strikethrough(alert.change == .cancelled)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if let result = row.result {
                Label(result.text, systemImage: result.isSilent ? "bell.slash" : "checkmark.circle.fill")
                    .font(.app(.footnote))
                    .foregroundStyle(.green)
                    .lineLimit(2)
            } else {
                // "Open" shares the date line: next to the answer buttons and the bell it would
                // not fit in the panel's 360 pt.
                HStack(alignment: .lastTextBaseline, spacing: 6) {
                    Text(localization.detailLine(for: alert, now: now))
                        .font(.app(.footnote))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    openButton(row)
                }

                if row.canRespond {
                    HStack(spacing: 6) {
                        responseButton(row, .accept, localization.acceptTitle, "checkmark", .green)
                        responseButton(row, .tentative, localization.tentativeTitle, "questionmark", .orange)
                        responseButton(row, .decline, localization.declineTitle, "xmark", .red)
                        bellButton(row)
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 2)

                    if alert.occurrenceCount > 1 {
                        Text(String(
                            format: row.notifyOrganizer ? localization.seriesAllFormat : localization.seriesAllSilentFormat,
                            alert.occurrenceCount
                        ))
                        .font(.app(.caption))
                        .foregroundStyle(.secondary)
                    }
                }
            }

            if let error = row.errorMessage {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.app(.caption))
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Whether the answer emails the organizer. Off is tinted orange so a silent answer is never
    /// sent by accident.
    private func bellButton(_ row: MeetingInvitationRow) -> some View {
        let help = row.notifyOrganizer ? localization.notifyOnHelp : localization.notifyOffHelp
        return Button { onToggleNotify(row) } label: {
            Image(systemName: row.notifyOrganizer ? "bell" : "bell.slash")
                .font(.app(.footnote))
                .foregroundStyle(row.notifyOrganizer ? Color.secondary : Color.orange)
                .frame(width: 24, height: 22)
                .background {
                    if !row.notifyOrganizer {
                        RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.18))
                    }
                }
                .overlay {
                    if !row.notifyOrganizer {
                        RoundedRectangle(cornerRadius: 6).strokeBorder(Color.orange.opacity(0.45), lineWidth: 1)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(row.sendingAction != nil)
        .help(help)
        .accessibilityLabel(help)
    }

    private func openButton(_ row: MeetingInvitationRow) -> some View {
        Button(localization.openTitle) { onOpen(row) }
            .buttonStyle(.plain)
            .font(.app(.footnote, weight: .semibold))
            .foregroundStyle(accentColor)
    }

    private func responseButton(
        _ row: MeetingInvitationRow,
        _ action: MeetingResponseAction,
        _ title: String,
        _ icon: String,
        _ color: Color
    ) -> some View {
        let isSending = row.sendingAction == action
        let isDisabled = row.sendingAction != nil
        return Button { onRespond(row, action) } label: {
            HStack(spacing: 3) {
                if isSending {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 9, height: 9)
                } else {
                    Image(systemName: icon)
                        .font(.app(.micro, weight: .semibold))
                        .foregroundStyle(color)
                }
                Text(title)
                    .font(.app(.footnote))
                    .lineLimit(1)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            }
            .opacity(isDisabled && !isSending ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityLabel(title)
    }

    private func kindLabel(_ change: MeetingInvitationChange) -> String {
        switch change {
        case .invited: localization.kindInvited
        case .rescheduled: localization.kindRescheduled
        case .cancelled: localization.kindCancelled
        }
    }

    private func kindColor(_ change: MeetingInvitationChange) -> Color {
        switch change {
        case .invited: accentColor
        case .rescheduled: .orange
        case .cancelled: .red
        }
    }
}
