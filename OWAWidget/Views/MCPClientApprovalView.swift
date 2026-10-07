import SwiftUI

/// "A new client wants your calendar": who it is as the app found it, what it will get, and
/// Deny / Allow. Shown by `MCPClientApprovalController`; the client gets nothing before Allow.
struct MCPClientApprovalView: View {
    static let urgentSeconds: TimeInterval = 10
    /// Buttons come alive this long after the panel appears. Once a question is answered, the
    /// next client's question takes its place, and the second click of a double click would
    /// otherwise allow a client nobody read about.
    static let armingDelay: Duration = .milliseconds(800)

    let request: MCPClientApprovalRequest
    let clientIcon: NSImage?
    let shownAt: Date
    let deadline: Date
    let localization: LocalizationService
    let onAllow: () -> Void
    let onDeny: () -> Void
    @State private var armed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                header
                client
                Text(localization.tr(request.canCreateMeetings ? "mcp.approve.scopeWithMeetings" : "mcp.approve.scope"))
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                Text(localization.tr("mcp.approve.hint"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)

            TimelineView(.animation(minimumInterval: 0.25)) { context in
                countdownBar(remaining: remaining(at: context.date))
            }
            footer
        }
        .frame(width: 420, alignment: .leading)
        .background(WindowDragArea())
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        .task(id: request.key) {
            armed = false
            try? await Task.sleep(for: Self.armingDelay)
            armed = true
        }
    }

    private var header: some View {
        MCPPanelBrandBar(localization: localization) {
            TimelineView(.animation(minimumInterval: 0.25)) { context in
                let remaining = remaining(at: context.date)
                Text(localization.tr("mcp.confirm.countdown", Int(remaining.rounded(.up))))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(countdownColor(remaining))
                    .lineLimit(1)
            }
            .fixedSize()
        }
    }

    private var client: some View {
        HStack(alignment: .top, spacing: 12) {
            if let clientIcon {
                Image(nsImage: clientIcon)
                    .resizable()
                    .frame(width: 40, height: 40)
            }
            clientDetails
        }
    }

    private var clientDetails: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(localization.tr("mcp.approve.title", request.name))
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            if let declared = request.declaredName, declared != request.name {
                Text(localization.tr("mcp.clients.declared", declared))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text([request.executablePath, request.script].compactMap { $0 }.joined(separator: " "))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(4)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
            if let note = kindNote {
                Label(note, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
    }

    private var kindNote: String? {
        switch request.kind {
        case .bridge: nil
        case .staleBridge: localization.tr("mcp.approve.kind.staleBridge")
        case .direct: localization.tr("mcp.approve.kind.direct")
        }
    }

    private func countdownBar(remaining: TimeInterval) -> some View {
        let total = max(1, deadline.timeIntervalSince(shownAt))
        return GeometryReader { geometry in
            Rectangle()
                .fill(countdownColor(remaining).opacity(0.7))
                .frame(width: geometry.size.width * max(0, min(1, remaining / total)))
        }
        .frame(height: 2)
        .background(Color.primary.opacity(0.08))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            Button(localization.tr("mcp.approve.deny"), action: onDeny)
                .keyboardShortcut(.cancelAction)
                .fixedSize()
            // No default-action shortcut: a stray Return must not let a client in.
            Button(localization.tr("mcp.approve.allow"), action: onAllow)
                .buttonStyle(.borderedProminent)
                .fixedSize()
                .disabled(!armed)
        }
        .controlSize(.regular)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func remaining(at date: Date) -> TimeInterval {
        max(0, deadline.timeIntervalSince(date))
    }

    private func countdownColor(_ remaining: TimeInterval) -> Color {
        remaining <= Self.urgentSeconds ? .orange : .secondary
    }
}
