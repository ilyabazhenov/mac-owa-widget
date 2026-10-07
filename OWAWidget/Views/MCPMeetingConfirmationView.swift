import AppKit
import SwiftUI

/// What an MCP client wants to create, with "Edit…", "Cancel" and a button named after what it
/// does ("Add to Calendar" / "Send Invitations"). Shown by `MCPMeetingConfirmationController`;
/// nothing is sent to Exchange before that button. Edit hands the meeting to the New Meeting
/// window instead, where the user changes it and sends it themselves.
struct MCPMeetingConfirmationView: View {
    /// Internal attendees shown per section; external ones are always all shown.
    static let visibleAttendeeLimit = 8
    /// Longer agendas scroll instead of being cut: whatever the attendees get, the user must be
    /// able to read before confirming.
    static let inlineAgendaLimit = 300
    /// The countdown turns orange for the last seconds, so the panel does not vanish unexpectedly.
    static let urgentSeconds: TimeInterval = 10

    let proposal: MCPMeetingProposal
    let shownAt: Date
    let deadline: Date
    let localization: LocalizationService
    let onConfirm: () -> Void
    let onReject: () -> Void
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                header
                meeting
                attendees
                if !proposal.conflicts.isEmpty { conflicts }
                if !agendaText.isEmpty { agenda }
            }
            .padding(16)

            TimelineView(.animation(minimumInterval: 0.25)) { context in
                countdownBar(remaining: remaining(at: context.date))
            }
            footer
        }
        .frame(width: 420, alignment: .leading)
        // Empty areas drag the window: it opens in the middle of the screen and may cover what
        // the user needs to see to decide.
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
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            MCPPanelBrandBar(localization: localization) { EmptyView() }
            title
        }
    }

    private var title: some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar.badge.plus")
                .font(.system(size: 15))
                .foregroundStyle(Color.accentColor)
            Text(proposal.client.isEmpty
                ? localization.tr("mcp.confirm.titleUnknownClient")
                : localization.tr("mcp.confirm.title", proposal.client))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            // Up here rather than in the footer: three buttons leave the footer no room for it.
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

    private var meeting: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(proposal.title)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Text(dayText)
                .font(.system(size: 12))
            Text(timeText)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
            if !proposal.location.isEmpty {
                note(proposal.location, icon: "mappin.and.ellipse")
                    .padding(.top, 2)
            }
        }
    }

    @ViewBuilder
    private var attendees: some View {
        if proposal.required.isEmpty && proposal.optional.isEmpty {
            note(localization.tr("mcp.confirm.noAttendees"), icon: "person.crop.circle.badge.xmark")
        } else {
            VStack(alignment: .leading, spacing: 4) {
                attendeeSection(localization.tr("mcp.confirm.required"), proposal.required)
                attendeeSection(localization.tr("mcp.confirm.optional"), proposal.optional)
                if !proposal.externalCheckAvailable {
                    note(localization.tr("mcp.confirm.externalUnknown"), icon: "questionmark.diamond.fill", color: .orange)
                        .padding(.top, 2)
                } else if proposal.hasExternalAttendees {
                    note(localization.tr("mcp.confirm.externalWarning"), icon: "exclamationmark.triangle.fill", color: .orange)
                        .padding(.top, 2)
                }
            }
        }
    }

    @ViewBuilder
    private func attendeeSection(_ title: String, _ people: [MCPMeetingProposal.Attendee]) -> some View {
        if !people.isEmpty {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            let visible = Self.visibleAttendees(people)
            ForEach(visible, id: \.email) { person in
                HStack(spacing: 6) {
                    if let name = person.name, !name.isEmpty {
                        Text(name).font(.system(size: 12)).lineLimit(1)
                    }
                    Text(person.email)
                        .font(.system(size: 11))
                        .foregroundStyle(person.isExternal ? .orange : .secondary)
                        .lineLimit(1)
                    if person.isExternal {
                        Text(localization.tr("mcp.confirm.external"))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange.opacity(0.15)))
                    }
                }
            }
            if people.count > visible.count {
                Text(localization.tr("mcp.confirm.more", people.count - visible.count))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var conflicts: some View {
        VStack(alignment: .leading, spacing: 2) {
            note(localization.tr("mcp.confirm.conflicts"), icon: "exclamationmark.circle", color: .orange)
            ForEach(Array(proposal.conflicts.prefix(3).enumerated()), id: \.offset) { _, conflict in
                Text("\(Self.hoursText(conflict.start, conflict.end, locale: localization.locale))  \(conflict.title)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.leading, 18)
            }
        }
    }

    /// The text the attendees will get, framed so it does not read as the app's own notes.
    private var agenda: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(hasAttendees ? localization.tr("mcp.confirm.agendaForAttendees") : localization.tr("mcp.confirm.agenda"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Group {
                if isLongAgenda {
                    ScrollView { agendaBody }
                        .frame(height: 150)
                } else {
                    agendaBody
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
        }
    }

    private var agendaBody: some View {
        Text(agendaText)
            .font(.system(size: 12))
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
            // Away from the other two, and borderless: it neither sends nor cancels, and a
            // third bordered button would not fit next to "Send Invitations".
            Button(localization.tr("mcp.confirm.edit"), action: onEdit)
                .buttonStyle(.borderless)
                // Borderless text is grey in this panel and reads as disabled.
                .foregroundStyle(Color.accentColor)
                .help(localization.tr("mcp.confirm.edit.help"))
                .fixedSize()
            Spacer(minLength: 4)
            Button(localization.tr("mcp.confirm.reject"), action: onReject)
                .keyboardShortcut(.cancelAction)
                .fixedSize()
            // No default-action shortcut: a stray Return must not send invitations.
            Button(confirmTitle, action: onConfirm)
                .buttonStyle(.borderedProminent)
                .fixedSize()
        }
        .controlSize(.regular)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func note(_ text: String, icon: String, color: Color = .secondary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .frame(width: 12)
            Text(text)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(color)
    }

    // MARK: - Text

    private var hasAttendees: Bool {
        !(proposal.required.isEmpty && proposal.optional.isEmpty)
    }

    /// Named after the consequence: with attendees the button sends mail to people.
    private var confirmTitle: String {
        hasAttendees ? localization.tr("mcp.confirm.sendInvitations") : localization.tr("mcp.confirm.addToCalendar")
    }

    private var agendaText: String {
        proposal.agenda.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isLongAgenda: Bool {
        agendaText.count > Self.inlineAgendaLimit || agendaText.filter { $0 == "\n" }.count >= 6
    }

    private var dayText: String {
        Self.dayText(proposal.start, now: shownAt, localization: localization)
    }

    private var timeText: String {
        Self.timeText(proposal.start, proposal.end, now: shownAt, localization: localization)
    }

    private func remaining(at date: Date) -> TimeInterval {
        max(0, deadline.timeIntervalSince(date))
    }

    private func countdownColor(_ remaining: TimeInterval) -> Color {
        remaining <= Self.urgentSeconds ? .orange : .secondary
    }

    /// "Завтра, среда, 7 октября" / "Tomorrow, Wednesday, October 7"; the relative word only for
    /// today and tomorrow, in the display time zone the calendar is shown in.
    static func dayText(_ start: Date, now: Date, localization: LocalizationService) -> String {
        let calendar = AppTimeZone.calendar
        let formatter = DateFormatter()
        formatter.locale = localization.locale
        formatter.timeZone = AppTimeZone.zone
        formatter.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        var text = formatter.string(from: start)
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: start)
        let offset = calendar.dateComponents([.day], from: today, to: day).day
        if offset == 0 {
            text = localization.tr("mcp.confirm.today") + ", " + text
        } else if offset == 1 {
            text = localization.tr("mcp.confirm.tomorrow") + ", " + text
        }
        return text.prefix(1).uppercased(with: localization.locale) + text.dropFirst()
    }

    /// "19:00–19:15 · 15 минут", with the zone when it is not the Mac's: the app may show
    /// Samara time on a Mac set to Moscow, and an unlabelled hour would be an hour off.
    static func timeText(_ start: Date, _ end: Date, now: Date, localization: LocalizationService) -> String {
        var text = hoursText(start, end, locale: localization.locale)
        if AppTimeZone.zone.secondsFromGMT(for: start) != TimeZone.current.secondsFromGMT(for: start) {
            text += " (\(AppTimeZone.shortLabel))"
        }
        let minutes = Int(end.timeIntervalSince(start) / 60)
        return text + " · " + localization.minutes(minutes)
    }

    static func hoursText(_ start: Date, _ end: Date, locale: Locale) -> String {
        let time = DateFormatter()
        time.locale = locale
        time.timeZone = AppTimeZone.zone
        time.setLocalizedDateFormatFromTemplate("Hmm")
        return "\(time.string(from: start))–\(time.string(from: end))"
    }

    /// External addresses always, then internal ones up to the limit: the address the user most
    /// needs to see must never hide behind "and N more".
    static func visibleAttendees(_ people: [MCPMeetingProposal.Attendee]) -> [MCPMeetingProposal.Attendee] {
        let external = people.filter(\.isExternal)
        let internalPeople = people.filter { !$0.isExternal }
        return external + internalPeople.prefix(max(0, visibleAttendeeLimit - external.count))
    }
}

extension MCPMeetingProposal {
    var hasExternalAttendees: Bool {
        (required + optional).contains(where: \.isExternal)
    }
}

/// Lets a borderless window be dragged by its empty areas. Sits behind the content, so buttons
/// and selectable text keep their clicks.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}
