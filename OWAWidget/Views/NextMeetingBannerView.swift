import SwiftUI
import AppKit

/// Shows the next meeting(s). If multiple meetings start within 5 minutes of each other,
/// they are shown as a stack inside a single banner.
struct NextMeetingBannerView: View {
    let events: [CalendarEvent]  // pre-sorted: joinURL first
    var horizontalPadding: CGFloat = 6
    var onSelect: (CalendarEvent) -> Void = { _ in }
    @EnvironmentObject private var localization: LocalizationService
    @State private var didCopy = false

    var body: some View {
        if events.isEmpty { EmptyView() }
        else if events.count == 1 {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                singleBanner(events[0], now: context.date)
            }
        } else {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                stackBanner(events, now: context.date)
            }
        }
    }

    // MARK: - Single event banner

    private func singleBanner(_ event: CalendarEvent, now: Date) -> some View {
        let happening = isNow(event, now: now)

        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    if happening {
                        PulsingDot()
                        Text(remainingLabel(event, now: now))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.orange)
                    } else {
                        Image(systemName: "play.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        Text(countdownLabel(event, now: now))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if event.platform != .generic {
                        Image(systemName: event.platform.systemIcon)
                            .foregroundStyle(happening ? .orange : event.platform.color)
                            .font(.system(size: 12))
                            .accessibilityLabel(event.platform.displayName(localization: localization))
                    }
                }

                Text(event.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)

                HStack(spacing: 8) {
                    Text(metaString(event))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer()

                    if let url = event.joinURLForActions {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url.absoluteString, forType: .string)
                            didCopy = true
                            Task { try? await Task.sleep(for: .seconds(1.5)); didCopy = false }
                        } label: {
                            Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(localization.tr("meeting.copy.link"))
                        .accessibilityLabel(localization.tr("meeting.copy.link"))
                        .accessibilityHint(localization.tr("a11y.meeting.copy.link.hint"))

                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.right.circle.fill")
                                Text(localization.tr("meeting.join"))
                                    .fontWeight(.semibold)
                            }
                            .font(.system(size: 12))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(happening ? Color.orange : event.platform.color)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(localization.tr("a11y.meeting.join", event.title))
                        .accessibilityHint(localization.tr("meeting.join.help", event.platform.displayName(localization: localization)))
                    }
                }
            }
            .padding(.top, 10)
            .padding(.horizontal, 12)
            .padding(.bottom, happening ? 6 : 10)

            if happening {
                MeetingProgressBar(progress: progress(event, now: now))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
        }
        .background(bannerBackground(event, happening: happening))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { onSelect(event) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(a11yBannerLabel(event, now: now))
        .accessibilityHint(localization.tr("a11y.meeting.open.details.hint"))
        .accessibilityAddTraits(.isButton)
        .padding(.horizontal, horizontalPadding)
        .padding(.top, 10)
    }

    // MARK: - Multiple concurrent events

    private func stackBanner(_ events: [CalendarEvent], now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "play.fill")
                    .font(.system(size: 10))
                Text(localization.tr("meeting.multiple.at.time", events.count, localization.shortTime(events[0].startDate)))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Divider()

            ForEach(events) { event in
                Button { onSelect(event) } label: {
                    MeetingRowView(event: event, compact: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(a11yBannerLabel(event, now: now))
                .accessibilityHint(localization.tr("a11y.meeting.open.details.hint"))
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
        .padding(.horizontal, horizontalPadding)
        .padding(.top, 12)
    }

    // MARK: - Helpers

    private func isNow(_ event: CalendarEvent, now: Date) -> Bool {
        event.startDate <= now && event.endDate > now
    }

    private func minsUntilStart(_ event: CalendarEvent, now: Date) -> Int {
        max(0, Int(event.startDate.timeIntervalSince(now) / 60))
    }

    private func minsRemaining(_ event: CalendarEvent, now: Date) -> Int {
        max(0, Int(event.endDate.timeIntervalSince(now) / 60))
    }

    private func progress(_ event: CalendarEvent, now: Date) -> Double {
        guard event.duration > 0 else { return 0 }
        return min(1, max(0, now.timeIntervalSince(event.startDate) / event.duration))
    }

    private func metaString(_ event: CalendarEvent) -> String {
        let time = "\(localization.shortTime(event.startDate))–\(localization.shortTime(event.endDate))"
        guard let organizer = event.organizer else { return time }
        return "\(time) · \(organizer)"
    }

    private func countdownLabel(_ event: CalendarEvent, now: Date) -> String {
        let m = minsUntilStart(event, now: now)
        return m == 0 ? localization.tr("meeting.starting.now") : localization.tr("meeting.in.minutes", localization.minutesShort(m))
    }

    private func remainingLabel(_ event: CalendarEvent, now: Date) -> String {
        let m = minsRemaining(event, now: now)
        return m == 0 ? localization.tr("meeting.happening.now") : localization.tr("meeting.remaining.minutes", localization.minutesShort(m))
    }

    private func a11yBannerLabel(_ event: CalendarEvent, now: Date) -> String {
        let time = "\(localization.shortTime(event.startDate))–\(localization.shortTime(event.endDate))"
        var parts: [String] = [event.title, time]
        if isNow(event, now: now) {
            parts.append(localization.tr("meeting.happening.now"))
        } else {
            parts.append(countdownLabel(event, now: now))
        }
        if event.joinURLForActions != nil {
            parts.append(localization.tr("a11y.meeting.has.join"))
        }
        if event.isEffectivelyCancelled {
            parts.append(localization.tr("meeting.status.cancelled"))
        }
        return parts.joined(separator: ", ")
    }

    private func bannerBackground(_ event: CalendarEvent, happening: Bool) -> some View {
        let color: Color = happening ? .orange : event.platform.color
        return ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(color.opacity(happening ? 0.10 : 0.08))
            RoundedRectangle(cornerRadius: 10)
                .stroke(color.opacity(happening ? 0.35 : 0.25), lineWidth: 1)
        }
    }
}

// MARK: - Sub-views

private struct PulsingDot: View {
    var body: some View {
        Circle()
            .fill(Color.orange)
            .frame(width: 6, height: 6)
            .opacity(0.9)
    }
}

private struct MeetingProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.orange.opacity(0.2))
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.orange)
                        .frame(width: geo.size.width * progress)
                }
        }
        .frame(height: 3)
    }
}
