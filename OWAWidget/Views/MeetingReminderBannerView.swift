import SwiftUI

struct MeetingReminderBannerView: View {
    let title: String
    let subtitle: String
    let timeRange: String
    let platformIcon: String
    let accentColor: Color
    let joinTitle: String
    let dismissTitle: String
    let joinURL: URL?
    let onJoin: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: platformIcon)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(accentColor)
                    Text(timeRange)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                }

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

            Divider()
                .opacity(0.7)

            HStack(spacing: 8) {
                Button(dismissTitle, action: onDismiss)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .keyboardShortcut(.cancelAction)

                Spacer()

                if joinURL != nil {
                    Button {
                        onJoin()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.right.circle.fill")
                            Text(joinTitle)
                                .fontWeight(.semibold)
                        }
                        .font(.system(size: 12))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(accentColor)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
                }
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
}
