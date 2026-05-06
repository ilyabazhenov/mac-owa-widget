import SwiftUI

struct AboutView: View {
    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    private static let appIcon = NSImage(named: "AppIcon") ?? NSImage(named: "AppIcon.icns")
    private static let authorEmailAddress = "amio.env@gmail.com"
    private static let authorEmailURL = URL(string: "mailto:amio.env@gmail.com")!
    private static let githubRepositoryURL = URL(string: "https://github.com/ilyabazhenov/mac-owa-widget")!

    @EnvironmentObject private var localization: LocalizationService
    @State private var isEmailHovered = false
    @State private var isGitHubHovered = false

    var body: some View {
        VStack(spacing: 12) {
            if let appIcon = Self.appIcon {
                Image(nsImage: appIcon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 72, height: 72)
                    .accessibilityLabel(localization.tr("app.name"))
            } else {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 48))
                    .foregroundColor(.accentColor)
                    .frame(width: 72, height: 72)
                    .accessibilityLabel(localization.tr("app.name"))
            }

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

            HStack(spacing: 6) {
                Text("Ilya Bazhenov")
                Text("·").foregroundStyle(.secondary)
                Link(Self.authorEmailAddress, destination: Self.authorEmailURL)
                    .underline(isEmailHovered)
                    .foregroundStyle(isEmailHovered ? Color.accentColor : Color.secondary)
                    .onHover { hovering in
                        isEmailHovered = hovering
                    }
                Text("·").foregroundStyle(.secondary)
                Link(localization.tr("about.github"), destination: Self.githubRepositoryURL)
                    .underline(isGitHubHovered)
                    .foregroundStyle(isGitHubHovered ? Color.accentColor : Color.secondary)
                    .onHover { hovering in
                        isGitHubHovered = hovering
                    }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.top, 4)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
