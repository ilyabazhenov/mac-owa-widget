import SwiftUI
import AppKit

struct MeetingDetailPanelView: View {
    let event: CalendarEvent
    let onClose: () -> Void

    @EnvironmentObject private var localization: LocalizationService

    var body: some View {
        VStack(spacing: 0) {
            panelHeader

            Divider()

            ScrollView(.vertical, showsIndicators: false) {
                MeetingDetailContentView(event: event)
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

            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .labelColor))
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
                    .foregroundStyle(event.isHappeningNow ? .orange : event.platform.color)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
    }
}

struct MeetingDetailContentView: View {
    let event: CalendarEvent

    @EnvironmentObject private var localization: LocalizationService

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MeetingDetailActionsView(event: event)

            VStack(alignment: .leading, spacing: 8) {
                detailRow(
                    systemImage: "clock",
                    text: "\(dayLabel) · \(localization.shortTime(event.startDate))–\(localization.shortTime(event.endDate))"
                )

                detailRow(systemImage: "mappin.and.ellipse", text: locationLabel)

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
        formatter.dateFormat = "EEEE, d MMMM"
        return formatter.string(from: event.startDate)
    }

    private var locationLabel: String {
        let trimmed = event.location?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? localization.tr("meeting.location.unspecified") : trimmed
    }
}

private struct MeetingDetailActionsView: View {
    let event: CalendarEvent

    @EnvironmentObject private var localization: LocalizationService
    @State private var didCopy = false

    var body: some View {
        if let url = event.joinURL {
            HStack(spacing: 10) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.right.circle.fill")
                        Text(localization.tr("meeting.join"))
                            .fontWeight(.semibold)
                    }
                    .font(.system(size: 12))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(event.isHappeningNow ? Color.orange : event.platform.color)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)

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
            }
        }
    }
}
