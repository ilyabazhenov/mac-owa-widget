import SwiftUI

struct MeetingReminderBannerView: View {
    let title: String
    let subtitle: String
    let items: [MeetingReminderItem]
    let accentColor: Color
    let joinTitle: String
    let dismissTitle: String
    let onJoin: (MeetingReminderItem) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

            }
            .padding(.horizontal, 12)
            .padding(.top, 10)

            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .padding(.bottom, 10)

            meetingRows

            Divider()
                .opacity(0.7)

            HStack(spacing: 8) {
                Button(dismissTitle, action: onDismiss)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .keyboardShortcut(.cancelAction)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 340, alignment: .leading)
        .background(bannerBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(accentColor.opacity(0.22), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
    }

    private var bannerBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(accentColor.opacity(0.12))
        }
    }

    @ViewBuilder
    private var meetingRows: some View {
        VStack(spacing: 6) {
            ForEach(items, id: \.eventID) { item in
                HStack(spacing: 8) {
                    Image(systemName: item.platform.systemIcon)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(accentColor)
                        .frame(width: 14)

                    Text(timeRange(item))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 84, alignment: .leading)

                    Text(item.title)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if item.hasJoinURL {
                        Button(joinTitle) {
                            onJoin(item)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(accentColor)
                    } else {
                        Text("-")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private func timeRange(_ item: MeetingReminderItem) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return "\(formatter.string(from: item.startDate))–\(formatter.string(from: item.endDate))"
    }
}
