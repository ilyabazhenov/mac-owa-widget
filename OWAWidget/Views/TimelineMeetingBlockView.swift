import SwiftUI
import AppKit

struct TimelineMeetingBlockView: View {
    let event: CalendarEvent
    var compact: Bool = false
    /// When `nil`, organizer is shown iff `!compact` (legacy). When set, overrides that rule.
    var showsOrganizer: Bool?
    var isSelected: Bool = false

    @EnvironmentObject private var localization: LocalizationService
    @EnvironmentObject private var calendarService: CalendarService
    @State private var didCopy = false
    /// The copy button shows on hover (and on the selected card) only: a column of identical
    /// copy icons down the timeline was noise next to the titles. Join stays visible — whether a
    /// meeting has a call to join is worth seeing at a glance.
    @State private var isHovering = false

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
                    .font(.app(compact ? .footnote : .body, weight: .semibold))
                    .foregroundStyle(event.isEffectivelyCancelled ? .secondary : .primary)
                    .strikethrough(event.isEffectivelyCancelled)
                    .lineLimit(compact ? 1 : 1)

                HStack(spacing: metaItemsSpacing) {
                    Text("\(localization.shortTime(event.startDate))–\(localization.shortTime(event.endDate))")
                        .font(.app(compact ? .micro : .caption, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if event.responseType == .notResponded {
                        Image(systemName: "questionmark.circle")
                            .font(.app(.micro))
                            .foregroundStyle(.secondary)
                            .help(localization.tr("meeting.rsvp.pending.help"))
                            .accessibilityLabel(localization.tr("a11y.meeting.rsvp.pending"))
                    }

                    if event.isOrganizer {
                        Text(localization.tr("meeting.role.organizer.short"))
                            .font(.app(.micro, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                            .accessibilityLabel(localization.tr("meeting.role.organizer"))
                    }

                    if shouldShowOrganizer, let organizer = event.organizer {
                        Text("· \(organizer)")
                            .font(.app(.caption))
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
                            MeetingClipboard.copy(url.absoluteString)
                            didCopy = true
                            Task { try? await Task.sleep(for: .seconds(1.5)); didCopy = false }
                        } label: {
                            Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                                .copyFeedbackTransition(value: didCopy)
                                .font(.app(.footnote))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 3)
                        // Faded rather than removed, so the title keeps its width and does not
                        // reflow under the pointer.
                        .opacity(showsCopyButton ? 1 : 0)
                        .allowsHitTesting(showsCopyButton)
                        .animation(.easeOut(duration: 0.12), value: showsCopyButton)
                        .help(localization.tr("meeting.copy.link"))
                        .accessibilityLabel(localization.tr("meeting.copy.link"))
                        .accessibilityHint(localization.tr("a11y.meeting.copy.link.hint"))
                    }

                    Button {
                        calendarService.openJoinURL(for: event)
                        PostJoinDismissController.shared.dismissAfterJoin(context: .popoverContent)
                    } label: {
                        Image(systemName: "arrow.right.circle.fill")
                            .font(.app(compact ? .headline : .title))
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
        .opacity((calendarService.dimPastMeetingsOnTimeline && event.isPast) ? 0.58 : 1.0)
        .onHover { isHovering = $0 }
        .meetingCopyContextMenu(event, localization: localization)
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

    private var showsCopyButton: Bool {
        isHovering || isSelected || didCopy
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
        return meetingAccentColor(for: event)
    }

    private var backgroundColor: Color {
        if event.isEffectivelyCancelled {
            return Color(nsColor: .controlBackgroundColor).opacity(0.55)
        }
        if isSelected {
            return meetingAccentColor(for: event).opacity(0.20)
        }
        return meetingAccentColor(for: event).opacity(0.13)
    }

    private var borderColor: Color {
        if event.isEffectivelyCancelled {
            return Color.secondary.opacity(0.22)
        }
        if isSelected {
            return accentColor
        }
        return meetingAccentColor(for: event).opacity(0.28)
    }

    var borderWidth: CGFloat {
        isSelected || event.isHappeningNow ? 1.5 : 1
    }
}
