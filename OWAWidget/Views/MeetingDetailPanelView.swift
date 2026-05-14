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

            ScrollView(.vertical, showsIndicators: false) {
                MeetingDetailContentView(event: event) {
                    onClose()
                }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 230, maxHeight: 286)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MeetingDetailActionsView(event: event, onJoinCompleted: onJoinCompleted)

            VStack(alignment: .leading, spacing: 8) {
                detailRow(
                    systemImage: "clock",
                    text: "\(dayLabel) · \(localization.shortTime(event.startDate))–\(localization.shortTime(event.endDate))"
                )

                if event.isEffectivelyCancelled {
                    detailRow(systemImage: "xmark.circle", text: localization.tr("meeting.status.cancelled"))
                }

                if event.isOrganizer {
                    detailRow(systemImage: "person.fill.checkmark", text: localization.tr("meeting.role.organizer"))
                }

                detailRow(systemImage: "mappin.and.ellipse", text: locationLabel)

                if let categoriesLine = categoriesLine {
                    detailRow(systemImage: "tag", text: categoriesLine)
                }

                if let organizer = event.organizer {
                    detailRow(systemImage: "person", text: organizer)
                }

                if !event.attendees.isEmpty {
                    detailRow(systemImage: "person.2", text: event.attendees.joined(separator: ", "))
                }
            }

            if let body = event.bodyPreview?.trimmingCharacters(in: .whitespacesAndNewlines),
               !body.isEmpty {
                Divider()
                Text(body)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private var locationLabel: String {
        let trimmed = event.location?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? localization.tr("meeting.location.unspecified") : trimmed
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
