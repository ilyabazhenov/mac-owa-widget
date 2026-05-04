import SwiftUI
import AppKit

/// Shows the next meeting(s). If multiple meetings start within 5 minutes of each other,
/// they are shown as a stack inside a single banner.
struct NextMeetingBannerView: View {
    let events: [CalendarEvent]  // pre-sorted: joinURL first

    var body: some View {
        if events.isEmpty { EmptyView() }
        else if events.count == 1 {
            singleBanner(events[0])
        } else {
            stackBanner(events)
        }
    }

    // MARK: - Single event banner

    private func singleBanner(_ event: CalendarEvent) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "play.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(countdownLabel(event))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if event.platform != .generic {
                    Image(systemName: event.platform.systemIcon)
                        .foregroundStyle(event.platform.color)
                        .font(.system(size: 13))
                }
            }

            Text(event.title)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(2)

            HStack(spacing: 8) {
                Text(event.startDate.timeRange(to: event.endDate))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Spacer()

                if let url = event.joinURL {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.right.circle.fill")
                            Text("Join")
                                .fontWeight(.semibold)
                        }
                        .font(.system(size: 12))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(event.platform.color)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .background(bannerBackground(event))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 12)
        .padding(.top, 12)
    }

    // MARK: - Multiple concurrent events

    private func stackBanner(_ events: [CalendarEvent]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "play.fill")
                    .font(.system(size: 10))
                Text("\(events.count) meetings at \(events[0].startDate.shortTime)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Divider()

            // Each meeting as a compact row
            ForEach(events) { event in
                MeetingRowView(event: event, compact: true)
                if event.id != events.last?.id {
                    Divider().padding(.leading, 12)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
        )
        .padding(.horizontal, 12)
        .padding(.top, 12)
    }

    // MARK: - Helpers

    private func countdownLabel(_ event: CalendarEvent) -> String {
        if event.isHappeningNow { return "Happening now" }
        let m = event.minutesUntilStart
        return m == 0 ? "Starting now" : "in \(m) min"
    }

    private func bannerBackground(_ event: CalendarEvent) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(event.platform.color.opacity(0.08))
            RoundedRectangle(cornerRadius: 10)
                .stroke(event.platform.color.opacity(0.25), lineWidth: 1)
        }
    }
}
