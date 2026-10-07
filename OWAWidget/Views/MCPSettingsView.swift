import AppKit
import SwiftUI

/// Settings tab for the MCP server: the switch, its privacy warning, ready-to-paste client
/// configuration, the clients that have connected and the in-memory call journal.
struct MCPSettingsView: View {
    @ObservedObject private var server = MCPServerService.shared
    @EnvironmentObject private var localization: LocalizationService
    @State private var copiedSnippet: Snippet?

    enum Snippet: String, CaseIterable, Identifiable {
        case claudeCode, codex, claudeDesktop, vsCode
        var id: String { rawValue }
    }

    var body: some View {
        Form {
            Section {
                Toggle(localization.tr("mcp.enabled"), isOn: $server.isEnabled)
                Text(localization.tr("mcp.description"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Label {
                    Text(localization.tr("mcp.privacy.warning"))
                        .font(.system(size: 11))
                } icon: {
                    Image(systemName: "exclamationmark.shield")
                        .foregroundStyle(.orange)
                }
                LabeledContent(localization.tr("mcp.status"), value: statusText)
            }

            Section {
                Toggle(localization.tr("mcp.createMeetings"), isOn: $server.canCreateMeetings)
                    .disabled(!server.isEnabled)
                Text(localization.tr("mcp.createMeetings.description"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section(localization.tr("mcp.connect.section")) {
                if server.isBridgeInstalled {
                    ForEach(Snippet.allCases) { snippet in
                        snippetRow(snippet)
                    }
                    Text(localization.tr("mcp.connect.hint"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    Text(localization.tr("mcp.connect.bridgeMissing"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Section(localization.tr("mcp.clients.section")) {
                Toggle(localization.tr("mcp.clients.ask"), isOn: $server.askNewClients)
                    .disabled(!server.isEnabled)
                Text(localization.tr(server.askNewClients ? "mcp.clients.ask.on" : "mcp.clients.ask.off"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if server.knownClients.isEmpty {
                    Text(localization.tr("mcp.clients.empty"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(server.knownClients) { client in
                        clientRow(client)
                    }
                }
                Text(localization.tr("mcp.clients.hint"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section(localization.tr("mcp.journal.section")) {
                if server.journal.isEmpty {
                    Text(localization.tr("mcp.journal.empty"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(server.journal.prefix(15)) { entry in
                        HStack(spacing: 6) {
                            Image(systemName: entry.isError ? "xmark.circle" : "checkmark.circle")
                                .foregroundStyle(entry.isError ? .orange : .secondary)
                            Text(entry.tool)
                                .font(.system(size: 11, design: .monospaced))
                            if let client = entry.client, !client.isEmpty {
                                Text(client)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(entry.date, style: .time)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(localization.tr("mcp.journal.hint"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 320, minHeight: 420)
    }

    private var statusText: String {
        switch server.status {
        case .stopped:
            return localization.tr("mcp.status.stopped")
        case .unavailable(let reason):
            return localization.tr("mcp.status.unavailable", reason)
        case .listening:
            guard server.isEnabled else { return localization.tr("mcp.status.disabled") }
            let connected = server.clients.count
            return connected == 0
                ? localization.tr("mcp.status.ready")
                : localization.tr("mcp.status.connected", connected)
        }
    }

    private func clientRow(_ client: MCPKnownClient) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(server.isConnected(client.key) ? Color.green : Color.secondary.opacity(0.3))
                .frame(width: 7, height: 7)
                .padding(.top, 5)
                .help(server.isConnected(client.key) ? localization.tr("mcp.clients.connectedNow") : "")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(client.name)
                        .font(.system(size: 12, weight: .medium))
                    accessBadge(client.access)
                    if let note = kindNote(client.lastKind) {
                        Text(note)
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                    }
                }
                if let declared = client.declaredName, declared != client.name {
                    Text(localization.tr("mcp.clients.declared", declared))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Text([client.executablePath, client.script].compactMap { $0 }.joined(separator: " "))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .truncationMode(.middle)
                Text(localization.tr("mcp.clients.lastSeen", lastSeenText(client.lastSeen)))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            accessButtons(client)
            Button {
                server.forgetKnownClient(client.key)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help(localization.tr("mcp.clients.forget"))
        }
    }

    @ViewBuilder
    private func accessBadge(_ access: MCPClientAccess) -> some View {
        switch access {
        case .allowed:
            EmptyView()
        case .denied:
            Text(localization.tr("mcp.clients.access.denied"))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.red)
        case .pending:
            Text(localization.tr("mcp.clients.access.pending"))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private func accessButtons(_ client: MCPKnownClient) -> some View {
        // Each button with its own style: in a form row, buttons without one can all fire on a
        // single click, and Deny would also remove the client.
        HStack(spacing: 4) {
            if client.access != .allowed {
                Button(localization.tr("mcp.approve.allow")) { server.setAccess(.allowed, forKey: client.key) }
                    .buttonStyle(.bordered)
            }
            if client.access != .denied {
                Button(localization.tr("mcp.approve.deny")) { server.setAccess(.denied, forKey: client.key) }
                    .buttonStyle(.bordered)
            }
        }
        .controlSize(.small)
    }

    private func kindNote(_ kind: MCPPeerKind) -> String? {
        switch kind {
        case .bridge: nil
        case .staleBridge: localization.tr("mcp.clients.kind.staleBridge")
        case .direct: localization.tr("mcp.clients.kind.direct")
        }
    }

    private func lastSeenText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = localization.locale
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func snippetRow(_ snippet: Snippet) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title(snippet))
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Button(copiedSnippet == snippet ? localization.tr("mcp.connect.copied") : localization.tr("mcp.connect.copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text(snippet), forType: .string)
                    copiedSnippet = snippet
                }
                .controlSize(.small)
            }
            Text(text(snippet))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(nil)
        }
    }

    private func title(_ snippet: Snippet) -> String {
        switch snippet {
        case .claudeCode: localization.tr("mcp.connect.claudeCode")
        case .codex: localization.tr("mcp.connect.codex")
        case .claudeDesktop: localization.tr("mcp.connect.claudeDesktop")
        case .vsCode: localization.tr("mcp.connect.vsCode")
        }
    }

    private func text(_ snippet: Snippet) -> String {
        let path = server.bridgePath
        switch snippet {
        case .claudeCode:
            return "claude mcp add owa-widget -- \"\(path)\""
        case .codex:
            return "codex mcp add owa-widget -- \"\(path)\""
        case .claudeDesktop:
            return Self.json(["mcpServers": ["owa-widget": ["command": path]]])
        case .vsCode:
            return Self.json(["servers": ["owa-widget": ["type": "stdio", "command": path]]])
        }
    }

    private static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
