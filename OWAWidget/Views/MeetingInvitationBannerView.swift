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
    let acceptTitle: String
    let tentativeTitle: String
    let declineTitle: String
    let openTitle: String
    let hideTitle: String
    let closeTitle: String
    let sendFailed: String
    /// `%d` = rows that did not fit.
    let moreFormat: String

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
        acceptTitle: "Accept",
        tentativeTitle: "Tentative",
        declineTitle: "Decline",
        openTitle: "Open",
        hideTitle: "Hide",
        closeTitle: "Close",
        sendFailed: "Failed to send response",
        moreFormat: "%d more"
    )

    /// "Fri, 26 Sep · 14:00–15:00" in the display time zone.
    func dateLine(start: Date, end: Date, isAllDay: Bool) -> String {
        let locale = Locale(identifier: localeIdentifier)
        let day = DateFormatter()
        day.locale = locale
        day.timeZone = AppTimeZone.zone
        day.setLocalizedDateFormatFromTemplate("EEEdMMM")
        guard !isAllDay else { return "\(day.string(from: start)) · \(allDay)" }

        let time = DateFormatter()
        time.locale = locale
        time.timeZone = AppTimeZone.zone
        time.dateStyle = .none
        time.timeStyle = .short
        return "\(day.string(from: start)) · \(time.string(from: start))–\(time.string(from: end))"
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
    /// RSVP buttons are shown only for a single meeting that still awaits an answer. A folded
    /// series is left to the detail card: answering one occurrence would not answer the others.
    var canRespond: Bool
    var sendingAction: MeetingResponseAction?
    var errorMessage: String?

    var id: String { alert.id }
}

struct MeetingInvitationBannerView: View {
    let title: String
    let rows: [MeetingInvitationRow]
    let hiddenRowCount: Int
    let localization: MeetingInvitationLocalization
    let onRespond: (MeetingInvitationRow, MeetingResponseAction) -> Void
    let onOpen: (MeetingInvitationRow) -> Void
    let onHide: (MeetingInvitationRow) -> Void
    let onClose: () -> Void

    private let accentColor = Color.accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "envelope.badge")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(accentColor)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
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
                    .font(.system(size: 11))
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
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(kindColor(alert.change))
                if let organizer = alert.organizer, !organizer.isEmpty {
                    Text("· " + String(format: localization.organizerFormat, organizer))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Button { onHide(row) } label: {
                    Text(localization.hideTitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Text(alert.title)
                .font(.system(size: 12, weight: .semibold))
                .strikethrough(alert.change == .cancelled)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            // Without RSVP buttons "Open" shares the date line instead of taking a row of its own.
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                Text(detailLine(alert))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !row.canRespond {
                    openButton(row)
                }
            }

            if row.canRespond {
                HStack(spacing: 6) {
                    responseButton(row, .accept, localization.acceptTitle, "checkmark", .green)
                    responseButton(row, .tentative, localization.tentativeTitle, "questionmark", .orange)
                    responseButton(row, .decline, localization.declineTitle, "xmark", .red)
                    Spacer(minLength: 0)
                    openButton(row)
                }
                .padding(.top, 2)
            }

            if let error = row.errorMessage {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func openButton(_ row: MeetingInvitationRow) -> some View {
        Button(localization.openTitle) { onOpen(row) }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold))
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
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(color)
                }
                Text(title)
                    .font(.system(size: 11))
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

    private func detailLine(_ alert: MeetingInvitationAlert) -> String {
        var line = localization.dateLine(start: alert.startDate, end: alert.endDate, isAllDay: alert.isAllDay)
        if alert.occurrenceCount > 1 {
            line += " · " + String(format: localization.seriesFormat, alert.occurrenceCount)
        }
        guard case .rescheduled(let previousStart, let previousEnd) = alert.change else { return line }
        let previous = localization.dateLine(start: previousStart, end: previousEnd, isAllDay: alert.isAllDay)
        return line + "\n" + String(format: localization.previousTimeFormat, previous)
    }
}
