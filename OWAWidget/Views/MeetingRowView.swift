import SwiftUI
import AppKit

struct MeetingRowView: View {
    let event: CalendarEvent
    var compact: Bool = false
    @EnvironmentObject private var localization: LocalizationService

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
                    .foregroundStyle(event.isHappeningNow ? .primary : .primary)

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
                        .foregroundStyle(event.platform.color)
                        .font(.system(size: compact ? 12 : 14))
                        .help(event.platform.displayName(localization: localization))
                }

                if let url = event.joinURL {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Text(localization.tr("meeting.join"))
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(event.platform.color.opacity(0.15))
                            .foregroundStyle(event.platform.color)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .help(localization.tr("meeting.join.help", event.platform.displayName(localization: localization)))
                }
            }
        }
        .padding(.vertical, compact ? 5 : 8)
        .padding(.horizontal, 14)
        .background(event.isHappeningNow ? Color.orange.opacity(0.06) : Color.clear)
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
                    .padding(.trailing, event.joinURL != nil ? 64 : 14)
            }
        }
    }

    private var timeColor: Color {
        event.isHappeningNow ? .orange : .secondary
    }

    private var statusColor: Color {
        event.isHappeningNow ? .orange : event.platform.color.opacity(0.7)
    }
}
