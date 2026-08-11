import SwiftUI
import AppKit

struct MeetingDetailPanelView: View {
    let event: CalendarEvent
    let onClose: () -> Void

    @EnvironmentObject private var localization: LocalizationService
    @AccessibilityFocusState private var closeButtonFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            panelHeader

            Divider()

            // Indicators stay on: a full agenda can be several screens long, and without the
            // scrollbar users read the clipped text as "the description is truncated".
            ScrollView(.vertical) {
                MeetingDetailContentView(event: event) {
                    onClose()
                }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 230, maxHeight: 400)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(localization.tr("a11y.meeting.details"))
        .onAppear { closeButtonFocused = true }
    }

    private var panelHeader: some View {
        HStack(spacing: 10) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .labelColor))
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(localization.tr("a11y.close"))
            .accessibilityHint(localization.tr("a11y.meeting.details.close.hint"))
            .accessibilityFocused($closeButtonFocused)

            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(nsColor: event.isEffectivelyCancelled ? .secondaryLabelColor : .labelColor))
                    .strikethrough(event.isEffectivelyCancelled)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text("\(localization.shortTime(event.startDate))–\(localization.shortTime(event.endDate))")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if event.platform != .generic {
                Image(systemName: event.platform.systemIcon)
                    .font(.system(size: 13))
                    .foregroundStyle(event.isHappeningNow ? .orange : meetingAccentColor(for: event))
                    .accessibilityLabel(event.platform.displayName(localization: localization))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
    }
}

struct MeetingDetailContentView: View {
    let event: CalendarEvent
    var onJoinCompleted: () -> Void = {}

    @EnvironmentObject private var localization: LocalizationService
    @EnvironmentObject private var calendarService: CalendarService

    /// Attendees and the full agenda arrive in one `GetCalendarEvent` response, so the load lives
    /// here (above both consumers) instead of inside the attendee list.
    @State private var detailsState: DetailsLoadState = .idle

    enum DetailsLoadState: Equatable {
        case idle, loading, loaded(CalendarEventDetails), failed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MeetingDetailActionsView(event: event, onJoinCompleted: onJoinCompleted)

            VStack(alignment: .leading, spacing: 8) {
                // Time lives in the header; this row carries only the date to avoid repeating it.
                detailRow(systemImage: "clock", text: dayLabel)

                if event.isEffectivelyCancelled {
                    detailRow(systemImage: "xmark.circle", text: localization.tr("meeting.status.cancelled"))
                }

                if event.isOrganizer {
                    detailRow(systemImage: "person.fill.checkmark", text: localization.tr("meeting.role.organizer"))
                }

                if let locationLabel {
                    detailRow(systemImage: "mappin.and.ellipse", text: locationLabel)
                }

                if let categoriesLine = categoriesLine {
                    detailRow(systemImage: "tag", text: categoriesLine)
                }

                // The organizer's own name is redundant when "You are the organizer" already shows above.
                if let organizer = event.organizer, !event.isOrganizer {
                    detailRow(systemImage: "person", text: organizer)
                }

                MeetingAttendeesView(event: event, state: detailsState)
            }

            if let body = bodyText {
                Divider()
                MeetingBodyView(text: body)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: event.id) {
            detailsState = .loading
            do {
                let details = try await calendarService.loadDetails(for: event)
                guard !Task.isCancelled else { return }
                detailsState = .loaded(details)
            } catch {
                // A cancelled task (panel dismissed or switched meetings) must not clobber the
                // state the replacement task is already setting.
                guard !Task.isCancelled else { return }
                detailsState = .failed
            }
        }
    }

    /// The truncated preview is shown right away and replaced by the full agenda once it loads,
    /// so the panel never sits empty while the request is in flight.
    private var bodyText: String? {
        if case .loaded(let details) = detailsState,
           let full = details.body?.trimmingCharacters(in: .whitespacesAndNewlines),
           !full.isEmpty {
            return full
        }
        return event.displayBody
    }

    private func detailRow(systemImage: String, text: String) -> some View {
        Label {
            Text(text)
                .lineLimit(2)
        } icon: {
            Image(systemName: systemImage)
                .frame(width: 16)
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }

    private var dayLabel: String {
        let formatter = DateFormatter()
        formatter.timeZone = AppTimeZone.zone
        formatter.dateFormat = "EEEE, d MMMM"
        return formatter.string(from: event.startDate)
    }

    private var locationLabel: String? {
        let trimmed = event.location?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            return localization.tr("meeting.location.unspecified")
        }
        // When the "location" is just the join link, the Join/Copy buttons already represent it.
        if let join = event.joinURL?.absoluteString,
           trimmed == join.trimmingCharacters(in: .whitespacesAndNewlines) {
            return nil
        }
        return trimmed
    }

    private var categoriesLine: String? {
        let cats = event.categories
        guard !cats.isEmpty else { return nil }
        let maxShow = 2
        let head = cats.prefix(maxShow).joined(separator: ", ")
        guard cats.count > maxShow else {
            return "\(localization.tr("meeting.categories")): \(head)"
        }
        let rest = cats.count - maxShow
        return "\(localization.tr("meeting.categories")): \(head) (\(localization.tr("meeting.categories.more", rest)))"
    }
}

/// Meeting body: selectable text with clickable links.
///
/// Agendas routinely carry wiki/tracker links, and before this the text was a plain `Text` —
/// unselectable and unclickable, so the only way to follow a link was to reopen the meeting in
/// OWA itself.
private struct MeetingBodyView: View {
    let text: String

    @EnvironmentObject private var localization: LocalizationService

    var body: some View {
        Text(MeetingBodyLinkFormatter.attributedBody(text))
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .environment(\.openURL, OpenURLAction { url in
                // The formatter already filtered schemes; opening through MeetingURLOpener keeps
                // the allow-list in one place. The popover is dismissed like after "Join", so the
                // browser doesn't come up behind a floating panel.
                guard MeetingURLOpener.open(url) else { return .discarded }
                PostJoinDismissController.shared.dismissAfterJoin(context: .detailPanel)
                return .handled
            })
            .contextMenu {
                Button(localization.tr("meeting.body.copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
            .accessibilityLabel(text)
    }
}

private struct MeetingAttendeesView: View {
    let event: CalendarEvent
    /// Owned by `MeetingDetailContentView`: attendees and the agenda share one request.
    let state: MeetingDetailContentView.DetailsLoadState

    @EnvironmentObject private var localization: LocalizationService

    /// `nil` = follow the automatic policy; set once the user clicks the header.
    @State private var expandOverride: Bool?

    var body: some View {
        Group {
            switch state {
            case .idle, .loading:
                statusRow {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.mini)
                        Text(localization.tr("meeting.attendees.loading"))
                    }
                }
            case .failed:
                statusRow { Text(localization.tr("meeting.attendees.failed")) }
            case .loaded(let details):
                attendeesList(details.attendees)
            }
        }
        // Switching meetings inside the same panel must not carry the previous choice over.
        .onChange(of: event.id) { _ in expandOverride = nil }
    }

    /// Two flexible columns so long Russian full names share the panel width; truncated names
    /// reveal in full on hover (`.help`).
    private let columns = [
        GridItem(.flexible(), spacing: 10, alignment: .leading),
        GridItem(.flexible(), spacing: 10, alignment: .leading),
    ]

    @ViewBuilder
    private func attendeesList(_ attendees: [EventAttendee]) -> some View {
        let visible = MeetingAttendeeList.forDisplay(attendees, organizer: event.organizer)
        if !visible.isEmpty {
            let required = visible.filter { $0.kind == .required }
            let optional = visible.filter { $0.kind == .optional }
            // Exchange exposes per-attendee response tracking only to the organizer; for everyone
            // else every status comes back "Unknown", so we drop the (meaningless) circles and explain.
            let showStatus = event.isOrganizer

            let isExpanded = expandOverride ?? MeetingAttendeeList.autoExpands(count: visible.count)

            VStack(alignment: .leading, spacing: 8) {
                header(count: visible.count, isExpanded: isExpanded)

                if isExpanded {
                    if !showStatus {
                        Label(localization.tr("meeting.attendees.status.organizerOnly"), systemImage: "info.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, 22)
                    }

                    group(titleKey: "meeting.attendees.required", attendees: required, showStatus: showStatus)
                    group(titleKey: "meeting.attendees.optional", attendees: optional, showStatus: showStatus)
                }
            }
        }
    }

    /// Clickable header: on a 200-person invite the roster otherwise buries the agenda, so a large
    /// list starts folded and the count alone stays visible.
    private func header(count: Int, isExpanded: Bool) -> some View {
        Button {
            expandOverride = !isExpanded
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "person.2")
                    .frame(width: 16)
                Text(localization.tr("meeting.attendees.title"))
                Text("\(count)")
                    .foregroundStyle(.tertiary)
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(localization.tr(isExpanded ? "meeting.attendees.collapse" : "meeting.attendees.expand"))
        .accessibilityLabel(localization.tr(isExpanded ? "meeting.attendees.collapse" : "meeting.attendees.expand"))
        .accessibilityValue("\(count)")
    }

    @ViewBuilder
    private func group(titleKey: String, attendees: [EventAttendee], showStatus: Bool) -> some View {
        if !attendees.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(localization.tr(titleKey))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
                    ForEach(attendees) { attendee in
                        attendeeRow(attendee, showStatus: showStatus)
                    }
                }
            }
            .padding(.leading, 22)
        }
    }

    @ViewBuilder
    private func attendeeRow(_ attendee: EventAttendee, showStatus: Bool) -> some View {
        HStack(spacing: 6) {
            if showStatus {
                statusIcon(for: attendee.response)
            } else {
                // Neutral bullet: no status available, so don't imply "no response".
                Image(systemName: "circle.fill")
                    .font(.system(size: 3))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14)
                    .accessibilityHidden(true)
            }
            Text(attendee.name)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(attendee.name)
    }

    private func statusIcon(for response: MeetingResponseType) -> some View {
        let style = responseStyle(response)
        return Image(systemName: style.icon)
            .foregroundStyle(style.color)
            .frame(width: 14)
            .accessibilityLabel(localization.tr(style.a11yKey))
    }

    @ViewBuilder
    private func statusRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "person.2")
                .frame(width: 16)
            content()
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }

    private func responseStyle(_ response: MeetingResponseType) -> (icon: String, color: Color, a11yKey: String) {
        switch response {
        case .accepted:     return ("checkmark.circle.fill", .green, "meeting.attendees.status.accepted")
        case .tentative:    return ("questionmark.circle.fill", .orange, "meeting.attendees.status.tentative")
        case .declined:     return ("xmark.circle.fill", .red, "meeting.attendees.status.declined")
        case .organizer:    return ("person.fill.checkmark", .secondary, "meeting.attendees.status.organizer")
        case .notResponded: return ("circle", .secondary, "meeting.attendees.status.noresponse")
        }
    }
}

/// Pure presentation logic for the attendee list, factored out for testing: drops the organizer
/// (who is shown on their own row, and whom Exchange also lists among the required attendees) and
/// sorts the remainder alphabetically.
enum MeetingAttendeeList {
    /// Up to this many participants the list is worth showing straight away; beyond it the roster
    /// (company-wide invites run into the hundreds) would push the agenda out of the panel.
    static let autoExpandLimit = 8

    static func autoExpands(count: Int) -> Bool { count <= autoExpandLimit }

    static func forDisplay(_ attendees: [EventAttendee], organizer: String?) -> [EventAttendee] {
        let organizerKey = organizer?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return attendees
            .filter { attendee in
                if attendee.response == .organizer { return false }
                if let organizerKey, !organizerKey.isEmpty,
                   attendee.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == organizerKey {
                    return false
                }
                return true
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

private struct MeetingDetailActionsView: View {
    let event: CalendarEvent
    var onJoinCompleted: () -> Void = {}

    @EnvironmentObject private var localization: LocalizationService
    @EnvironmentObject private var calendarService: CalendarService
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let url = event.joinURLForActions {
                HStack(spacing: 10) {
                    Button {
                        calendarService.openJoinURL(for: event, source: .detailPanel)
                        onJoinCompleted()
                        PostJoinDismissController.shared.dismissAfterJoin(context: .detailPanel)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.right.circle.fill")
                            Text(localization.tr("meeting.join"))
                                .fontWeight(.semibold)
                        }
                        .font(.system(size: 12))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(event.isHappeningNow ? Color.orange : meetingAccentColor(for: event))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(localization.tr("a11y.meeting.join", event.title))
                    .accessibilityHint(localization.tr("meeting.join.help", event.platform.displayName(localization: localization)))

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                        didCopy = true
                        Task { try? await Task.sleep(for: .seconds(1.5)); didCopy = false }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                            Text(localization.tr("meeting.copy.link"))
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(localization.tr("meeting.copy.link"))
                    .accessibilityLabel(localization.tr("meeting.copy.link"))
                    .accessibilityHint(localization.tr("a11y.meeting.copy.link.hint"))
                }
            }

            if !event.isOrganizer && event.responseType != .organizer && event.changeKey != nil {
                RSVPActionsView(event: event)
            }
        }
    }
}

private struct RSVPActionsView: View {
    let event: CalendarEvent
    @EnvironmentObject private var calendarService: CalendarService
    @EnvironmentObject private var localization: LocalizationService

    @State private var sendingAction: MeetingResponseAction? = nil
    @State private var feedbackState: FeedbackState = .none

    private enum FeedbackState: Equatable {
        case none, success, failure(String)
    }

    private struct RSVPOption {
        let action: MeetingResponseAction
        let responseType: MeetingResponseType
        let icon: String
        let labelKey: String
        let color: Color
    }

    private let options: [RSVPOption] = [
        RSVPOption(action: .accept, responseType: .accepted, icon: "checkmark", labelKey: "meeting.rsvp.accept", color: .green),
        RSVPOption(action: .tentative, responseType: .tentative, icon: "questionmark", labelKey: "meeting.rsvp.tentative", color: .orange),
        RSVPOption(action: .decline, responseType: .declined, icon: "xmark", labelKey: "meeting.rsvp.decline", color: .red),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ForEach(options, id: \.action) { option in
                    rsvpButton(for: option)
                }
            }

            switch feedbackState {
            case .none:
                EmptyView()
            case .success:
                Label(localization.tr("meeting.rsvp.response.sent"), systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
                    .accessibilityLabel(localization.tr("meeting.rsvp.response.sent"))
                    .transition(.opacity.combined(with: .move(edge: .top)))
            case .failure(let message):
                Label(message, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(message)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: feedbackState == .none)
    }

    @ViewBuilder
    private func rsvpButton(for option: RSVPOption) -> some View {
        let isActive = event.responseType == option.responseType
        let isSending = sendingAction == option.action
        let isDisabled = sendingAction != nil

        Button {
            send(option)
        } label: {
            HStack(spacing: 4) {
                if isSending {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 10, height: 10)
                } else {
                    Image(systemName: option.icon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(option.color)
                }
                Text(localization.tr(option.labelKey))
                    .font(.system(size: 11))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(isActive ? option.color.opacity(0.15) : Color(nsColor: .controlBackgroundColor))
            .foregroundStyle(isActive ? option.color : Color(nsColor: .secondaryLabelColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        isActive ? option.color.opacity(0.5) : Color(nsColor: .separatorColor),
                        lineWidth: isActive ? 1.5 : 1
                    )
            }
            .opacity(isDisabled && !isSending ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(localization.tr(option.labelKey))
        .accessibilityLabel(localization.tr(option.labelKey))
    }

    private func send(_ option: RSVPOption) {
        guard sendingAction == nil else { return }
        sendingAction = option.action
        feedbackState = .none

        Task {
            do {
                try await calendarService.respondToMeeting(event, action: option.action)
                feedbackState = .success
                try? await Task.sleep(for: .seconds(2))
                feedbackState = .none
            } catch {
                feedbackState = .failure(rsvpFailureMessage(for: error))
                try? await Task.sleep(for: .seconds(5))
                feedbackState = .none
            }
            sendingAction = nil
        }
    }

    private func rsvpFailureMessage(for error: Error) -> String {
        if let calendarError = error as? CalendarProviderError, case .notSupported = calendarError {
            return localization.tr("meeting.rsvp.error.provider.not.supported")
        }
        let headline = localization.tr("meeting.rsvp.error.send.failed")
        guard let detail = rsvpFailureDetailLine(for: error), !detail.isEmpty else {
            return headline
        }
        return "\(headline)\n\(detail)"
    }

    /// Secondary line for diagnostics (e.g. EWS / HTTP reason); keep short for the popover.
    private func rsvpFailureDetailLine(for error: Error) -> String? {
        if error is CancellationError { return nil }
        if let localized = error as? LocalizedError, let d = localized.errorDescription?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty {
            return String(d.prefix(240))
        }
        let raw = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty || Self.isGenericSystemFailureText(raw) { return nil }
        return String(raw.prefix(240))
    }

    private static func isGenericSystemFailureText(_ s: String) -> Bool {
        let lower = s.lowercased()
        if lower == "the operation couldn’t be completed." { return true }
        if lower == "the operation couldn't be completed." { return true }
        // Common CancellationError phrasing on Apple platforms
        if lower.contains("cancel") && (lower.contains("operation") || lower.contains("операц")) { return true }
        return false
    }
}
