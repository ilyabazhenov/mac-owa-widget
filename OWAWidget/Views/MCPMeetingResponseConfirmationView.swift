import SwiftUI

/// The answer an MCP client wants to give to an invitation: the meeting, the answer and its scope,
/// whether the organizer hears of it, the note. Shown by `MCPMeetingResponseConfirmationController`;
/// nothing reaches Exchange before the button.
struct MCPMeetingResponseConfirmationView: View {
    let proposal: MCPMeetingResponseProposal
    let shownAt: Date
    let deadline: Date
    let localization: LocalizationService
    let onConfirm: () -> Void
    let onReject: () -> Void

    /// Same guard as the other MCP panels: the click the user was about to make elsewhere must not
    /// answer for them.
    @State private var armed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    MCPPanelBrandBar(localization: localization) { EmptyView() }
                    title
                }
                meeting
                answer
                if !proposal.comment.isEmpty { comment }
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
        .task(id: shownAt) {
            armed = false
            try? await Task.sleep(for: MCPClientApprovalView.armingDelay)
            armed = true
        }
    }

    // MARK: - Sections

    private var title: some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar.badge.checkmark")
                .font(.app(.title))
                .foregroundStyle(Color.accentColor)
            Text(proposal.client.isEmpty
                ? localization.tr("mcp.respond.titleUnknownClient")
                : localization.tr("mcp.respond.title", proposal.client))
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
            if let organizer = proposal.organizer, !organizer.isEmpty {
                note(localization.tr("mcp.respond.organizer", organizer), icon: "person")
            }
        }
    }

    /// The answer, what it covers and who learns about it: that is what the user is deciding.
    private var answer: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: Self.icon(proposal.action))
                    .foregroundStyle(Self.color(proposal.action))
                Text(localization.tr("mcp.respond.answer.\(proposal.action.name)"))
                    .font(.app(.body, weight: .semibold))
                if proposal.isRecurring {
                    Text(localization.tr(proposal.series ? "mcp.respond.scope.series" : "mcp.respond.scope.occurrence"))
                        .font(.app(.body))
                        .foregroundStyle(.secondary)
                }
            }
            if proposal.current != .notResponded, proposal.current != .organizer {
                note(localization.tr("mcp.respond.current.\(proposal.current.rawValue)"), icon: "clock.arrow.circlepath")
            }
            if proposal.action == .decline {
                note(localization.tr("mcp.respond.declineNotice"), icon: "calendar.badge.minus")
            }
            if proposal.sendResponse {
                note(
                    proposal.organizer.map { localization.tr("mcp.respond.sendNotice", $0) }
                        ?? localization.tr("mcp.respond.sendNoticeUnknown"),
                    icon: "envelope.badge",
                    color: .orange
                )
            } else {
                note(localization.tr("mcp.respond.silentNotice"), icon: "bell.slash")
            }
        }
    }

    private var comment: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(localization.tr("mcp.respond.comment"))
                .font(.app(.footnote, weight: .medium))
                .foregroundStyle(.secondary)
            Group {
                if proposal.comment.count > MCPMeetingConfirmationView.inlineAgendaLimit {
                    ScrollView { commentBody }
                        .frame(height: 120)
                        .scrollIndicators(.visible)
                } else {
                    commentBody
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
        }
    }

    private var commentBody: some View {
        Text(proposal.comment)
            .font(.app(.body))
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .padding(8)
    }

    static func icon(_ action: MeetingResponseAction) -> String {
        switch action {
        case .accept: "checkmark.circle.fill"
        case .tentative: "questionmark.circle.fill"
        case .decline: "xmark.circle.fill"
        }
    }

    static func color(_ action: MeetingResponseAction) -> Color {
        switch action {
        case .accept: .green
        case .tentative: .purple
        case .decline: .red
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
            Spacer(minLength: 4)
            Button(localization.tr("mcp.respond.reject"), action: onReject)
                .keyboardShortcut(.cancelAction)
                .fixedSize()
            // No default-action shortcut: a stray Return must not answer for the user.
            Button(localization.tr("mcp.respond.confirm.\(proposal.action.name)"), action: onConfirm)
                .buttonStyle(.borderedProminent)
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
