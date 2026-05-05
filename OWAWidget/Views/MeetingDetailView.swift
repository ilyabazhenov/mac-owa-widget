import SwiftUI
import AppKit

struct MeetingDetailView: View {
    let event: CalendarEvent
    @EnvironmentObject private var localization: LocalizationService
    @Environment(\.dismiss) private var dismiss
    @State private var didCopy = false

    private let headerSideWidth: CGFloat = 64
    private let headerHeight: CGFloat = 64
    private let backButtonSize: CGFloat = 40

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(
                            "\(dayLabel) · \(localization.shortTime(event.startDate))–\(localization.shortTime(event.endDate))",
                            systemImage: "clock"
                        )
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                        Label(locationLabel, systemImage: "mappin.and.ellipse")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)

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
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .navigationBarBackButtonHidden(true)
    }

    private var header: some View {
        HStack(spacing: 0) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Color(nsColor: .labelColor))
                    .frame(width: backButtonSize, height: backButtonSize)
                    .background(
                        Circle()
                            .fill(Color(nsColor: .controlBackgroundColor))
                            .shadow(color: .black.opacity(0.10), radius: 5, y: 2)
                    )
                    .overlay(
                        Circle()
                            .stroke(Color(nsColor: .separatorColor).opacity(0.25), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .frame(width: headerSideWidth, alignment: .leading)

            VStack(spacing: 2) {
                Text(event.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .labelColor))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(localization.shortTime(event.startDate))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .lineLimit(1)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)

            Color.clear
                .frame(width: headerSideWidth, height: backButtonSize)
        }
        .padding(.horizontal, 16)
        .frame(height: headerHeight)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var dayLabel: String {
        let df = DateFormatter()
        df.dateFormat = "EEEE, d MMMM"
        return df.string(from: event.startDate)
    }

    private var locationLabel: String {
        let trimmed = event.location?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? localization.tr("meeting.location.unspecified") : trimmed
    }
}
