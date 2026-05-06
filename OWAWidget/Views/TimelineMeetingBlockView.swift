import SwiftUI
import AppKit

struct TimelineMeetingBlockView: View {
    let event: CalendarEvent
    var compact: Bool = false
    /// When `nil`, organizer is shown iff `!compact` (legacy). When set, overrides that rule.
    var showsOrganizer: Bool?
    var isSelected: Bool = false

    @EnvironmentObject private var localization: LocalizationService
    @State private var didCopy = false

    init(event: CalendarEvent, compact: Bool = false, showsOrganizer: Bool? = nil, isSelected: Bool = false) {
        self.event = event
        self.compact = compact
        self.showsOrganizer = showsOrganizer
        self.isSelected = isSelected
    }

    var body: some View {
        HStack(alignment: .top, spacing: 5) {
            VStack(alignment: .leading, spacing: titleToMetaSpacing) {
                Text(event.title)
                    .font(.system(size: compact ? 11 : 12, weight: .semibold))
                    .foregroundStyle(event.isEffectivelyCancelled ? .secondary : .primary)
                    .strikethrough(event.isEffectivelyCancelled)
                    .lineLimit(compact ? 1 : 1)

                HStack(spacing: metaItemsSpacing) {
                    Text("\(localization.shortTime(event.startDate))–\(localization.shortTime(event.endDate))")
                        .font(.system(size: compact ? 9 : 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if event.isOrganizer {
                        Text(localization.tr("meeting.role.organizer.short"))
                            .font(.system(size: compact ? 8 : 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                            .accessibilityLabel(localization.tr("meeting.role.organizer"))
                    }

                    if shouldShowOrganizer, let organizer = event.organizer {
                        Text("· \(organizer)")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let url = event.joinURLForActions {
                HStack(alignment: .top, spacing: 4) {
                    if !compact {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url.absoluteString, forType: .string)
                            didCopy = true
                            Task { try? await Task.sleep(for: .seconds(1.5)); didCopy = false }
                        } label: {
                            Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 3)
                        .help(localization.tr("meeting.copy.link"))
                        .accessibilityLabel(localization.tr("meeting.copy.link"))
                        .accessibilityHint(localization.tr("a11y.meeting.copy.link.hint"))
                    }

                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Image(systemName: "arrow.right.circle.fill")
                            .font(.system(size: compact ? 13 : 14))
                            .foregroundStyle(accentColor)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, compact ? 1 : 2)
                    .help(localization.tr("meeting.join.help", event.platform.displayName(localization: localization)))
                    .accessibilityLabel(localization.tr("a11y.meeting.join", event.title))
                    .accessibilityHint(localization.tr("meeting.join.help", event.platform.displayName(localization: localization)))
                }
            }
        }
        .padding(.leading, contentLeadingPadding)
        .padding(.top, contentTopPadding)
        .padding(.trailing, compact ? 4 : 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(backgroundColor)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(accentColor)
                .frame(width: accentWidth)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(borderColor, lineWidth: borderWidth)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(a11yEventSummary)
    }

    private var a11yEventSummary: String {
        let time = "\(localization.shortTime(event.startDate))–\(localization.shortTime(event.endDate))"
        var parts: [String] = [event.title, time]
        if event.isHappeningNow {
            parts.append(localization.tr("meeting.happening.now"))
        }
        if let organizer = event.organizer, !organizer.isEmpty {
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

    private var shouldShowOrganizer: Bool {
        if let showsOrganizer {
            return showsOrganizer
        }
        return !compact
    }

    private var accentWidth: CGFloat { 3 }

    private var contentLeadingPadding: CGFloat {
        accentWidth + 5 + (compact ? 4 : 6)
    }

    var contentTopPadding: CGFloat {
        if isShortMeeting {
            return compact ? 0 : 1
        }
        return compact ? 2 : 3
    }

    private var isShortMeeting: Bool {
        event.duration <= 30 * 60
    }

    private var titleToMetaSpacing: CGFloat {
        isShortMeeting ? 1 : 2
    }

    private var metaItemsSpacing: CGFloat {
        isShortMeeting ? 2 : 4
    }

    private var accentColor: Color {
        if event.isEffectivelyCancelled {
            return Color.secondary.opacity(0.45)
        }
        return event.isHappeningNow ? .orange : meetingAccentColor(for: event)
    }

    private var backgroundColor: Color {
        if event.isEffectivelyCancelled {
            return Color(nsColor: .controlBackgroundColor).opacity(0.55)
        }
        if isSelected {
            return event.isHappeningNow ? Color.orange.opacity(0.22) : meetingAccentColor(for: event).opacity(0.20)
        }
        return event.isHappeningNow ? Color.orange.opacity(0.16) : meetingAccentColor(for: event).opacity(0.13)
    }

    private var borderColor: Color {
        if event.isEffectivelyCancelled {
            return Color.secondary.opacity(0.22)
        }
        if isSelected {
            return accentColor
        }
        return event.isHappeningNow ? .orange : meetingAccentColor(for: event).opacity(0.28)
    }

    var borderWidth: CGFloat {
        isSelected || event.isHappeningNow ? 1.5 : 1
    }
}
