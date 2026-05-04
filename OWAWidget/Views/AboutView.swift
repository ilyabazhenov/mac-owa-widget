import SwiftUI

struct AboutView: View {
    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    @EnvironmentObject private var localization: LocalizationService

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)

            Text(localization.tr("app.name"))
                .font(.title2.bold())

            Text(localization.tr("about.version", version))
                .foregroundStyle(.secondary)

            Divider().frame(width: 200)

            Text(localization.tr("about.description"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
