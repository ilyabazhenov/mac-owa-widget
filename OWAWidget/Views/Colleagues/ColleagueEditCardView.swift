import SwiftUI

/// Editing card for one colleague: the address-book fields are shown, and the only thing the user
/// types is the link to that person's permanent room.
struct ColleagueEditCardView: View {
    let colleague: WatchedColleague
    let onSave: (WatchedColleague) -> Void
    let onCancel: () -> Void
    let onRemove: () -> Void

    @EnvironmentObject private var localization: LocalizationService
    @State private var roomText: String
    @FocusState private var roomFieldFocused: Bool

    init(
        colleague: WatchedColleague,
        onSave: @escaping (WatchedColleague) -> Void,
        onCancel: @escaping () -> Void,
        onRemove: @escaping () -> Void
    ) {
        self.colleague = colleague
        self.onSave = onSave
        self.onCancel = onCancel
        self.onRemove = onRemove
        _roomText = State(initialValue: colleague.roomURL ?? "")
    }

    private var trimmedRoom: String { roomText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isAcceptable: Bool { ColleagueRoomLink.isAcceptableInput(roomText) }
    private var detectedPlatform: MeetingPlatform? {
        guard ColleagueRoomLink.isValid(roomText) else { return nil }
        let platform = ColleagueRoomLink.platform(for: roomText)
        return platform == .generic ? nil : platform
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                InitialsAvatar(name: colleague.displayName, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(colleague.displayName)
                        .font(.app(.headline, weight: .semibold))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.app(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(localization.tr("colleagues.edit.room.label"))
                    .font(.app(.footnote, weight: .semibold))
                    .foregroundStyle(.secondary)

                TextField(localization.tr("colleagues.edit.room.placeholder"), text: $roomText)
                    .textFieldStyle(.roundedBorder)
                    .font(.app(.footnote))
                    .focused($roomFieldFocused)
                    .onSubmit(save)

                if !isAcceptable {
                    Text(localization.tr("colleagues.edit.room.invalid"))
                        .font(.app(.caption))
                        .foregroundStyle(.red)
                } else if let detectedPlatform {
                    HStack(spacing: 5) {
                        Image(systemName: detectedPlatform.systemIcon)
                            .font(.app(.caption))
                        Text(localization.tr("colleagues.edit.detected", detectedPlatform.displayName(localization: localization)))
                            .font(.app(.caption))
                    }
                    .foregroundStyle(.secondary)
                } else {
                    Text(localization.tr("colleagues.edit.room.hint"))
                        .font(.app(.caption))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 8) {
                Button(localization.tr("colleagues.menu.remove"), role: .destructive, action: onRemove)
                    .buttonStyle(.plain)
                    .font(.app(.footnote))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                Button(localization.tr("colleagues.edit.cancel"), action: onCancel)
                    .controlSize(.small)

                Button(localization.tr("colleagues.edit.save"), action: save)
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isAcceptable)
            }
        }
        .padding(12)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onAppear { roomFieldFocused = true }
    }

    private var subtitle: String {
        guard let jobTitle = colleague.jobTitle, !jobTitle.isEmpty else { return colleague.email }
        return "\(jobTitle) · \(colleague.email)"
    }

    private func save() {
        guard isAcceptable else { return }
        var updated = colleague
        updated.roomURL = trimmedRoom.isEmpty ? nil : trimmedRoom
        onSave(updated)
    }
}
