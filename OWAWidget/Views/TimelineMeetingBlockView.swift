import SwiftUI
import AppKit

struct TimelineMeetingBlockView: View {
    let event: CalendarEvent

    @EnvironmentObject private var localization: LocalizationService

    var body: some View {
        HStack(spacing: 7) {
            Rectangle()
                .fill(accentColor)
                .frame(width: 4)

            VStack(alignment: .leading, spacing: 3) {
                Text(event.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text("\(localization.shortTime(event.startDate))–\(localization.shortTime(event.endDate))")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if let organizer = event.organizer {
                        Text("· \(organizer)")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if event.platform != .generic {
                Image(systemName: event.platform.systemIcon)
                    .font(.system(size: 12))
                    .foregroundStyle(event.platform.color)
                    .help(event.platform.displayName(localization: localization))
            }

            if let url = event.joinURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(accentColor)
                }
                .buttonStyle(.plain)
                .help(localization.tr("meeting.join.help", event.platform.displayName(localization: localization)))
            }
        }
        .frame(maxHeight: .infinity)
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(borderColor, lineWidth: event.isHappeningNow ? 1.5 : 1)
        }
    }

    private var accentColor: Color {
        event.isHappeningNow ? .orange : event.platform.color
    }

    private var backgroundColor: Color {
        event.isHappeningNow ? Color.orange.opacity(0.16) : event.platform.color.opacity(0.13)
    }

    private var borderColor: Color {
        event.isHappeningNow ? .orange : event.platform.color.opacity(0.28)
    }
}
