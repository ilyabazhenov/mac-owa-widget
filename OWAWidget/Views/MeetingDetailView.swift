import SwiftUI
import AppKit

struct MeetingDetailView: View {
    let event: CalendarEvent
    @EnvironmentObject private var localization: LocalizationService
    @Environment(\.dismiss) private var dismiss

    private let headerSideWidth: CGFloat = 64
    private let headerHeight: CGFloat = 64
    private let backButtonSize: CGFloat = 40

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                MeetingDetailContentView(event: event)
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

}
