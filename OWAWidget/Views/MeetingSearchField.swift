import SwiftUI

/// Lightweight search field for filtering already-loaded meetings.
/// Mirrors `AttendeeSearchField` visually but has no view model, debounce or
/// async spinner — filtering is synchronous over events already in memory.
struct MeetingSearchField: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    let placeholder: String
    let onClear: () -> Void
    let onCancel: () -> Void
    @EnvironmentObject private var localization: LocalizationService

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
                .frame(width: 14, height: 14)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused(isFocused)
                .onExitCommand { onCancel() }
                .accessibilityLabel(localization.tr("a11y.search.field"))

            if !text.isEmpty {
                Button {
                    onClear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(localization.tr("search.clear"))
                .accessibilityLabel(localization.tr("search.clear"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    isFocused.wrappedValue ? Color.accentColor : Color(nsColor: .separatorColor),
                    lineWidth: isFocused.wrappedValue ? 1.5 : 0.5
                )
        )
    }
}
