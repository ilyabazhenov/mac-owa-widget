import SwiftUI

/// Subtle pill showing which timezone the app displays times in. Visible only when the display
/// timezone differs from the user's system timezone — otherwise the badge would be redundant.
struct TimeZoneBadge: View {
    var prominent: Bool = false

    private var shouldShow: Bool {
        TimeZone.current.secondsFromGMT() != AppTimeZone.zone.secondsFromGMT()
    }

    var body: some View {
        if shouldShow {
            HStack(spacing: 4) {
                Image(systemName: "globe")
                    .font(.system(size: prominent ? 10 : 9, weight: .medium))
                Text(AppTimeZone.shortLabel)
                    .font(.system(size: prominent ? 11 : 10, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, prominent ? 8 : 6)
            .padding(.vertical, prominent ? 3 : 2)
            .background(
                Capsule().fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                Capsule().stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
            .help("\(AppTimeZone.zone.identifier) (\(AppTimeZone.utcOffsetLabel))")
        }
    }
}
