import SwiftUI

struct MeetingReminderBannerView: View {
    let title: String
    let subtitle: String
    let joinTitle: String
    let joinURL: URL?
    let onJoin: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Text(title)
                    .font(.headline)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }

            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if joinURL != nil {
                Button(joinTitle, action: onJoin)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
    }
}
