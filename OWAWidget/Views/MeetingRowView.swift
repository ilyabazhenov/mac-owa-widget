import SwiftUI
import AppKit

struct MeetingRowView: View {
    let event: CalendarEvent
    var compact: Bool = false
    @EnvironmentObject private var calendarService: CalendarService
    @EnvironmentObject private var localization: LocalizationService
    @State private var didCopy = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            // Time column
            VStack(alignment: .trailing, spacing: 1) {
                Text(localization.shortTime(event.startDate))
                    .font(.system(size: compact ? 10 : 11, weight: .medium))
                    .foregroundStyle(timeColor)
                if !compact {
                    Text(localization.shortTime(event.endDate))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: compact ? 40 : 50, alignment: .trailing)

            // Status bar
            RoundedRectangle(cornerRadius: 1.5)
                .fill(statusColor)
                .frame(width: 3, height: compact ? 20 : 32)

            // Title + organizer
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.system(size: compact ? 12 : 13, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(event.isEffectivelyCancelled ? .secondary : .primary)
                    .strikethrough(event.isEffectivelyCancelled)

                if !compact, let organizer = event.organizer {
                    Text(organizer)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            // Platform icon + Join button
            HStack(spacing: 6) {
                if event.platform != .generic {
                    Image(systemName: event.platform.systemIcon)
                        .foregroundStyle(meetingAccentColor(for: event))
                        .font(.system(size: compact ? 12 : 14))
                        .help(event.platform.displayName(localization: localization))
                        .accessibilityLabel(event.platform.displayName(localization: localization))
                }

                if let url = event.joinURLForActions {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                        didCopy = true
                        Task { try? await Task.sleep(for: .seconds(1.5)); didCopy = false }
                    } label: {
                        Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                            .font(.system(size: compact ? 11 : 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(localization.tr("meeting.copy.link"))
                    .accessibilityLabel(localization.tr("meeting.copy.link"))
                    .accessibilityHint(localization.tr("a11y.meeting.copy.link.hint"))

                    Button {
                        calendarService.openJoinURL(for: event, source: .meetingRow)
                        PostJoinDismissController.shared.dismissAfterJoin(context: .popoverContent)
                    } label: {
                        Text(localization.tr("meeting.join"))
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(meetingAccentColor(for: event).opacity(0.15))
                            .foregroundStyle(meetingAccentColor(for: event))
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .help(localization.tr("meeting.join.help", event.platform.displayName(localization: localization)))
                    .accessibilityLabel(localization.tr("a11y.meeting.join", event.title))
                    .accessibilityHint(localization.tr("meeting.join.help", event.platform.displayName(localization: localization)))
                }
            }
        }
        .padding(.vertical, compact ? 5 : 8)
        .padding(.horizontal, 14)
        .background(rowBackground)
        .contentShape(Rectangle())
        .overlay(alignment: .trailing) {
            if event.isHappeningNow && !compact {
                Text(localization.tr("meeting.now"))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.orange)
                    .clipShape(Capsule())
                    .padding(.trailing, event.joinURLForActions != nil ? 90 : 14)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(a11yEventSummary)
    }

    private var a11yEventSummary: String {
        let time: String
        if compact {
            time = localization.shortTime(event.startDate)
        } else {
            time = "\(localization.shortTime(event.startDate))–\(localization.shortTime(event.endDate))"
        }

        var parts: [String] = [event.title, time]
        if event.isHappeningNow {
            parts.append(localization.tr("meeting.happening.now"))
        }
        if !compact, let organizer = event.organizer, !organizer.isEmpty {
            parts.append(organizer)
        }
        if event.joinURLForActions != nil {
            parts.append(localization.tr("a11y.meeting.has.join"))
        }
        if event.isEffectivelyCancelled {
            parts.append(localization.tr("meeting.status.cancelled"))
        }
        return parts.joined(separator: ", ")
    }

    private var rowBackground: Color {
        if event.isEffectivelyCancelled {
            return Color.secondary.opacity(0.06)
        }
        return event.isHappeningNow ? Color.orange.opacity(0.06) : Color.clear
    }

    private var timeColor: Color {
        .secondary
    }

    private var statusColor: Color {
        if event.isEffectivelyCancelled {
            return Color.secondary.opacity(0.45)
        }
        return meetingAccentColor(for: event).opacity(0.7)
    }
}
