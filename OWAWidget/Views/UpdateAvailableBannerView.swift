import SwiftUI

struct UpdateAvailableBannerView: View {
    @ObservedObject var updateCheck: UpdateCheckService
    var horizontalPadding: CGFloat = 12

    @EnvironmentObject private var localization: LocalizationService

    var body: some View {
        Group {
            if let update = updateCheck.availableUpdate {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.blue)
                        .imageScale(.medium)

                    Text(localization.tr("update.banner.title", update.version))
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Button {
                        updateCheck.openRelease(update)
                    } label: {
                        Text(localization.tr("update.banner.action.open"))
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        updateCheck.skip(version: update.version)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(localization.tr("update.banner.action.skip"))
                    .accessibilityLabel(localization.tr("update.banner.action.skip"))
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.08))
                .accessibilityElement(children: .combine)
            }
        }
    }
}
