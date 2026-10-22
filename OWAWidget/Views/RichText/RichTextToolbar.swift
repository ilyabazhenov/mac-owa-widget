import SwiftUI

/// The buttons over a `RichTextEditor`: styles, lists, list levels and a link. A button is lit
/// while the selection has what it sets.
struct RichTextToolbar: View {
    @ObservedObject var controller: RichTextEditorController
    @EnvironmentObject private var localization: LocalizationService
    @State private var linkAddress = ""

    var body: some View {
        HStack(spacing: 2) {
            styleButton(.bold, symbol: "bold", key: "richtext.bold", shortcut: "⌘B")
            styleButton(.italic, symbol: "italic", key: "richtext.italic", shortcut: "⌘I")
            styleButton(.underline, symbol: "underline", key: "richtext.underline", shortcut: "⌘U")
            styleButton(.strikethrough, symbol: "strikethrough", key: "richtext.strikethrough", shortcut: "⇧⌘X")
            separator
            button(
                symbol: "list.bullet", help: tooltip("richtext.bulletList", "⇧⌘8"),
                isOn: controller.state.list.last == .bullet
            ) { controller.toggleList(.bullet) }
            button(
                symbol: "list.number", help: tooltip("richtext.numberedList", "⇧⌘7"),
                isOn: controller.state.list.last == .numbered
            ) { controller.toggleList(.numbered) }
            button(symbol: "decrease.indent", help: tooltip("richtext.outdent", "⇧Tab"), isOn: false) { controller.indent(by: -1) }
                .disabled(controller.state.list.isEmpty)
            button(symbol: "increase.indent", help: tooltip("richtext.indent", "Tab"), isOn: false) { controller.indent(by: 1) }
                .disabled(controller.state.list.isEmpty || controller.state.list.count >= RichText.maxListDepth)
            separator
            button(symbol: "link", help: tooltip("richtext.link", "⌘K"), isOn: controller.state.link != nil) { controller.beginLink() }
                .popover(isPresented: $controller.isEditingLink, arrowEdge: .bottom) { linkEditor }
        }
        .onChange(of: controller.isEditingLink) { editing in
            if editing { linkAddress = controller.suggestedLink }
        }
    }

    private var separator: some View {
        Divider().frame(height: 14).padding(.horizontal, 4)
    }

    private func tooltip(_ key: String, _ shortcut: String) -> String {
        "\(localization.tr(key)) (\(shortcut))"
    }

    private func styleButton(_ style: RichText.Style, symbol: String, key: String, shortcut: String) -> some View {
        button(symbol: symbol, help: tooltip(key, shortcut), isOn: controller.state.style.contains(style)) {
            controller.toggle(style)
        }
    }

    private func button(symbol: String, help: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        RichTextToolbarButton(symbol: symbol, isOn: isOn, action: action)
            .help(help)
            .accessibilityLabel(help)
    }

    private var linkEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(localization.tr("richtext.link.title")).font(.app(.body, weight: .semibold))
            TextField(localization.tr("richtext.link.placeholder"), text: $linkAddress)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit(submitLink)
            if !linkAddress.trimmingCharacters(in: .whitespaces).isEmpty, RichTextEditorController.linkURL(from: linkAddress) == nil {
                Text(localization.tr("richtext.link.invalid")).font(.app(.footnote)).foregroundStyle(.secondary)
            }
            HStack {
                if controller.state.link != nil {
                    Button(localization.tr("richtext.link.remove")) { controller.finishLink(nil) }
                }
                Spacer()
                Button(localization.tr("richtext.link.cancel")) {
                    controller.isEditingLink = false
                }
                .keyboardShortcut(.cancelAction)
                Button(localization.tr("richtext.link.apply"), action: submitLink)
                    .keyboardShortcut(.defaultAction)
                    .disabled(RichTextEditorController.linkURL(from: linkAddress) == nil)
            }
        }
        .padding(14)
    }

    private func submitLink() {
        guard RichTextEditorController.linkURL(from: linkAddress) != nil else { return }
        controller.finishLink(linkAddress)
    }
}

/// A toolbar button: an icon, lit while what it sets is on.
private struct RichTextToolbarButton: View {
    let symbol: String
    let isOn: Bool
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.app(.body, weight: .medium))
                .frame(width: 26, height: 22)
                .foregroundStyle(isOn ? Color.accentColor : Color.primary.opacity(isEnabled ? 0.8 : 0.3))
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isOn ? Color.accentColor.opacity(0.18) : Color.primary.opacity(isHovered && isEnabled ? 0.08 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { isHovered = $0 }
    }
}
