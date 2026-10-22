import SwiftUI

/// What an MCP client wants to cancel, decline or delete, with "Keep" and a red button named after
/// what happens. Shown by `MCPMeetingRemovalConfirmationController`; nothing reaches Exchange
/// before that button.
struct MCPMeetingRemovalConfirmationView: View {
    let proposal: MCPMeetingRemovalProposal
    let shownAt: Date
    let deadline: Date
    let localization: LocalizationService
    let onConfirm: () -> Void
    let onReject: () -> Void

    /// Same guard as the other MCP panels: the click the user was about to make elsewhere must not
    /// cancel a meeting.
    @State private var armed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    MCPPanelBrandBar(localization: localization) { EmptyView() }
                    title
                }
                meeting
                consequence
                if proposal.isOccurrence {
                    note(localization.tr("mcp.remove.occurrence"), icon: "repeat")
                }
                if !proposal.message.isEmpty { message }
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
                .stroke(Color.red.opacity(0.3), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        .task(id: shownAt) {
            armed = false
            try? await Task.sleep(for: MCPClientApprovalView.armingDelay)
            armed = true
        }
    }

    // MARK: - Sections

    private var title: some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar.badge.minus")
                .font(.app(.title))
                .foregroundStyle(.red)
            Text(proposal.client.isEmpty
                ? localization.tr("mcp.remove.titleUnknownClient.\(proposal.mode.rawValue)")
                : localization.tr("mcp.remove.title.\(proposal.mode.rawValue)", proposal.client))
                .font(.app(.body, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            TimelineView(.animation(minimumInterval: 0.25)) { context in
                let remaining = remaining(at: context.date)
                Text(localization.tr("mcp.confirm.countdown", Int(remaining.rounded(.up))))
                    .font(.app(.footnote).monospacedDigit())
                    .foregroundStyle(countdownColor(remaining))
                    .lineLimit(1)
            }
            .fixedSize()
        }
    }

    private var meeting: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(proposal.title)
                .font(.app(.title, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(MCPMeetingConfirmationView.dayText(proposal.start, now: shownAt, localization: localization))
                .font(.app(.body))
            Text(MCPMeetingConfirmationView.timeText(proposal.start, proposal.end, now: shownAt, localization: localization))
                .font(.app(.body).monospacedDigit())
                .foregroundStyle(.secondary)
            if !proposal.location.isEmpty {
                note(proposal.location, icon: "mappin.and.ellipse")
                    .padding(.top, 2)
            }
        }
    }

    /// Who learns about it, said plainly: that is what the user is deciding.
    @ViewBuilder
    private var consequence: some View {
        switch proposal.mode {
        case .cancelForAttendees:
            VStack(alignment: .leading, spacing: 4) {
                note(localization.tr("mcp.remove.cancelNotice", proposal.attendees.count + proposal.unaddressedAttendees.count), icon: "envelope.badge", color: .orange)
                let visible = MCPMeetingConfirmationView.visibleAttendees(proposal.attendees)
                ForEach(visible, id: \.email) { person in
                    HStack(spacing: 6) {
                        if let name = person.name, !name.isEmpty {
                            Text(name).font(.app(.body)).lineLimit(1)
                        }
                        Text(person.email)
                            .font(.app(.footnote))
                            .foregroundStyle(person.isExternal ? .orange : .secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(person.email)
                        if person.isExternal {
                            Text(localization.tr("mcp.confirm.external"))
                                .font(.app(.caption, weight: .semibold))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.orange.opacity(0.15)))
                        }
                    }
                    .padding(.leading, 18)
                }
                // Names only: Exchange did not say their address, but they get the cancellation too.
                let names = proposal.unaddressedAttendees.prefix(max(0, MCPMeetingConfirmationView.visibleAttendeeLimit - visible.count))
                ForEach(Array(names.enumerated()), id: \.offset) { _, name in
                    Text(name)
                        .font(.app(.body))
                        .lineLimit(1)
                        .padding(.leading, 18)
                }
                let hidden = proposal.attendees.count - visible.count + proposal.unaddressedAttendees.count - names.count
                if hidden > 0 {
                    Text(localization.tr("mcp.confirm.more", hidden))
                        .font(.app(.footnote))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 18)
                }
                if !proposal.externalCheckAvailable {
                    note(localization.tr("mcp.confirm.externalUnknown"), icon: "questionmark.diamond.fill", color: .orange)
                        .padding(.top, 2)
                }
            }
        case .decline:
            note(
                proposal.organizer.map { localization.tr("mcp.remove.declineNotice", $0) }
                    ?? localization.tr("mcp.remove.declineNoticeUnknown"),
                icon: "envelope.badge",
                color: .orange
            )
        case .deleteSilently:
            note(
                localization.tr(
                    proposal.isAlreadyCancelled ? "mcp.remove.deleteCancelledNotice"
                        : proposal.isAlreadyDeclined ? "mcp.remove.deleteDeclinedNotice" : "mcp.remove.deleteNotice"
                ),
                icon: "trash"
            )
        }
    }

    private var message: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(localization.tr(proposal.mode == .decline ? "mcp.remove.messageForOrganizer" : "mcp.remove.messageForAttendees"))
                .font(.app(.footnote, weight: .medium))
                .foregroundStyle(.secondary)
            Group {
                if proposal.message.count > MCPMeetingConfirmationView.inlineAgendaLimit {
                    ScrollView { messageBody }
                        .frame(height: 120)
                        .scrollIndicators(.visible)
                } else {
                    messageBody
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
        }
    }

    private var messageBody: some View {
        Text(proposal.message)
            .font(.app(.body))
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .padding(8)
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
            Spacer(minLength: 4)
            Button(localization.tr("mcp.remove.keep"), action: onReject)
                .keyboardShortcut(.cancelAction)
                .fixedSize()
            // No default-action shortcut: a stray Return must not cancel a meeting.
            Button(localization.tr("mcp.remove.confirm.\(proposal.mode.rawValue)"), role: .destructive, action: onConfirm)
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!armed)
                .fixedSize()
        }
        .controlSize(.regular)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func note(_ text: String, icon: String, color: Color = .secondary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon)
                .font(.app(.footnote))
                .frame(width: 12)
            Text(text)
                .font(.app(.footnote))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(color)
    }

    private func remaining(at date: Date) -> TimeInterval {
        max(0, deadline.timeIntervalSince(date))
    }

    private func countdownColor(_ remaining: TimeInterval) -> Color {
        remaining <= MCPMeetingConfirmationView.urgentSeconds ? .orange : .secondary
    }
}
