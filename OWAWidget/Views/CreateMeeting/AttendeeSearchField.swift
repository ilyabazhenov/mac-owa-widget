import SwiftUI

struct AttendeeSearchField: View {
    @ObservedObject var vm: CreateMeetingViewModel
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .opacity(vm.isSearching ? 0 : 1)
                if vm.isSearching {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 14, height: 14)
                }
            }
            .frame(width: 14, height: 14)

            TextField(
                vm.draft.attendees.isEmpty ? "Поиск по имени или email…" : "Добавить участника…",
                text: $vm.searchQuery
            )
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .focused($isFocused)
            .onSubmit { vm.selectFirstResult() }
            .onExitCommand { vm.searchQuery = "" }

            if !vm.searchQuery.isEmpty {
                Button {
                    vm.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
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
                    isFocused ? Color.accentColor : Color(nsColor: .separatorColor),
                    lineWidth: isFocused ? 1.5 : 0.5
                )
        )
    }
}
