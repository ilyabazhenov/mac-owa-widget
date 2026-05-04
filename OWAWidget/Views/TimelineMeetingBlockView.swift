import SwiftUI
import AppKit

struct TimelineMeetingBlockView: View {
    let event: CalendarEvent
    var compact: Bool = false

    @EnvironmentObject private var localization: LocalizationService

    var body: some View {
        HStack(alignment: .top, spacing: 5) {
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.system(size: compact ? 11 : 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(compact ? 1 : 1)

                HStack(spacing: 4) {
                    Text("\(localization.shortTime(event.startDate))–\(localization.shortTime(event.endDate))")
                        .font(.system(size: compact ? 9 : 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if !compact, let organizer = event.organizer {
                        Text("· \(organizer)")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 4) {
                if event.platform != .generic {
                    Image(systemName: event.platform.systemIcon)
                        .font(.system(size: compact ? 11 : 12))
                        .foregroundStyle(event.platform.color)
                        .help(event.platform.displayName(localization: localization))
                }

                if let url = event.joinURL {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Image(systemName: "arrow.right.circle.fill")
                            .font(.system(size: compact ? 13 : 14))
                            .foregroundStyle(accentColor)
                    }
                    .buttonStyle(.plain)
                    .help(localization.tr("meeting.join.help", event.platform.displayName(localization: localization)))
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
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(borderColor, lineWidth: event.isHappeningNow ? 1.5 : 1)
        }
    }

    private var accentWidth: CGFloat { 3 }

    private var contentLeadingPadding: CGFloat {
        accentWidth + 5 + (compact ? 4 : 6)
    }

    var contentTopPadding: CGFloat {
        compact ? 2 : 3
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
