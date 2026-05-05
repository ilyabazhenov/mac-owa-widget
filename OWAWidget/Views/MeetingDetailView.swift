import SwiftUI
import AppKit

struct MeetingDetailView: View {
    let event: CalendarEvent
    @EnvironmentObject private var localization: LocalizationService
    @State private var didCopy = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(event.title)
                    .font(.system(size: 15, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 6) {
                    Label(
                        "\(dayLabel) · \(localization.shortTime(event.startDate))–\(localization.shortTime(event.endDate))",
                        systemImage: "clock"
                    )
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                    if let location = event.location {
                        Label(location, systemImage: "mappin.and.ellipse")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }

                    if let organizer = event.organizer {
                        Label(organizer, systemImage: "person")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }

                    if !event.attendees.isEmpty {
                        Label(event.attendees.joined(separator: ", "), systemImage: "person.2")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }

                if let body = event.bodyPreview,
                   !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Divider()
                    Text(body)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                HStack(spacing: 10) {
                    if let url = event.joinURL {
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

                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "arrow.right.circle.fill")
                                Text(localization.tr("meeting.join"))
                                    .fontWeight(.semibold)
                            }
                            .font(.system(size: 12))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(event.platform.color)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(event.title)
        .navigationSubtitle(localization.shortTime(event.startDate))
    }

    private var dayLabel: String {
        let df = DateFormatter()
        df.dateFormat = "EEEE, d MMMM"
        return df.string(from: event.startDate)
    }
}
