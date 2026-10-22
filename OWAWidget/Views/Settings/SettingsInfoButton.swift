import SwiftUI

/// A small "?" next to a setting that shows its explanation in a popover. Long explanations used
/// to sit under the controls as paragraphs and turned each section into a wall of grey text.
/// Short, essential notes (what leaves the Mac, privacy) stay on the page instead.
struct SettingsInfoButton: View {
    let text: String
    @State private var isShown = false

    var body: some View {
        Button {
            isShown.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(text)
        .accessibilityLabel(text)
        .popover(isPresented: $isShown, arrowEdge: .trailing) {
            Text(text)
                .font(.app(.footnote))
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 280, alignment: .leading)
                .padding(12)
        }
    }
}

/// A toggle whose label carries an explanation button.
struct SettingsToggle: View {
    let title: String
    var info: String?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 6) {
                Text(title)
                if let info { SettingsInfoButton(text: info) }
            }
        }
    }
}
