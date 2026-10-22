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
///
/// `isEnabled` switches off the toggle only: the "?" stays clickable, because what a disabled
/// option would do is exactly what someone deciding whether to turn on its parent wants to read.
/// (A `.disabled` modifier on the whole row would take the explanation with it.)
struct SettingsToggle: View {
    let title: String
    var info: String?
    @Binding var isOn: Bool
    var isEnabled = true

    var body: some View {
        LabeledContent {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(!isEnabled)
        } label: {
            SettingsInfoLabel(title: title, info: info, isEnabled: isEnabled)
        }
    }
}

/// A setting's title with its explanation button, dimmed like a disabled control's label when
/// the setting is off.
struct SettingsInfoLabel: View {
    let title: String
    var info: String?
    var isEnabled = true

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .foregroundStyle(isEnabled ? .primary : .secondary)
            if let info { SettingsInfoButton(text: info) }
        }
    }
}
