import SwiftUI

struct AttendeeSearchField: View {
    @ObservedObject var vm: CreateMeetingViewModel
    let kind: AttendeeKind
    let placeholder: String
    @FocusState private var isFocused: Bool

    private var query: Binding<String> {
        Binding(
            get: { kind == .required ? vm.requiredQuery : vm.optionalQuery },
            set: { newValue in
                if kind == .required { vm.requiredQuery = newValue }
                else { vm.optionalQuery = newValue }
            }
        )
    }

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .opacity(vm.isSearching(for: kind) ? 0 : 1)
                if vm.isSearching(for: kind) {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 14, height: 14)
                }
            }
            .frame(width: 14, height: 14)

            TextField(placeholder, text: query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isFocused)
                .onSubmit { vm.selectFirstResult(kind: kind) }
                .onExitCommand { vm.clearSearch(kind: kind) }
                .onChange(of: isFocused) { focused in
                    if focused {
                        vm.focusedSearchKind = kind
                    } else if vm.focusedSearchKind == kind {
                        vm.focusedSearchKind = nil
                    }
                }

            if !query.wrappedValue.isEmpty {
                Button {
                    vm.clearSearch(kind: kind)
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
