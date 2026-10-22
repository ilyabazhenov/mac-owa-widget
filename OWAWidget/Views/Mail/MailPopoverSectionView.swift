import SwiftUI

/// The "Mail" strip in the popover: the inbox's unread count, expanding to the latest unread
/// conversations. Collapsed by default, like the invitations strip, so it never eats the timeline.
struct MailPopoverSectionView: View {
    @ObservedObject var mail: MailService
    let horizontalPadding: CGFloat
    let onOpen: (String?) -> Void

    @EnvironmentObject private var localization: LocalizationService
    @AppStorage("mailPopoverSectionExpanded") private var isExpanded = false

    var body: some View {
        let _ = PerfProbe.body("MailPopoverSectionView")
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "tray")
                        .font(.app(.footnote, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    Text(localization.tr(mail.settings.peopleOnly ? "mail.popover.titlePeople" : "mail.popover.title"))
                        .font(.app(.body, weight: .semibold))
                    if let unread = mail.popoverUnreadCount, unread > 0 {
                        Text(mail.settings.peopleOnly && mail.unreadPageWasFull ? "\(unread)+" : "\(unread)")
                            .font(.app(.caption, weight: .semibold))
                            .monospacedDigit()
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                            .foregroundStyle(Color.accentColor)
                    }
                    Spacer(minLength: 0)
                    statusText
                    Image(systemName: "chevron.down")
                        .font(.app(.micro, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.mailRow(cornerRadius: 0))
            .accessibilityLabel(localization.tr("mail.popover.a11y", mail.popoverUnreadCount ?? 0))

            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    if mail.popoverUnread.isEmpty {
                        Text(localization.tr(emptyKey))
                            .font(.app(.footnote))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, horizontalPadding + 2)
                            .padding(.vertical, 4)
                    } else {
                        ForEach(mail.popoverUnread) { conversation in
                            row(conversation)
                        }
                    }
                    Button {
                        onOpen(nil)
                    } label: {
                        HStack(spacing: 4) {
                            Text(localization.tr("mail.popover.open"))
                            Image(systemName: "arrow.right").font(.app(.micro, weight: .semibold))
                        }
                        .font(.app(.footnote))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, horizontalPadding + 18)
                        .padding(.top, 3)
                        .padding(.bottom, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        // Not for the prewarm's unseen build: that is no opening, and mail is checked on its own.
        .onAppear { if !PopoverPrewarmer.isPrewarming { mail.popoverDidAppear() } }
    }

    private var emptyKey: String {
        if mail.inboxUnreadCount == nil { return "mail.popover.loading" }
        if mail.settings.peopleOnly, (mail.inboxUnreadCount ?? 0) > 0 { return "mail.popover.noPeople" }
        return "mail.popover.allRead"
    }

    @ViewBuilder
    private var statusText: some View {
        switch mail.checkState {
        case .blocked:
            Image(systemName: "exclamationmark.lock").font(.app(.caption)).foregroundStyle(.orange)
        case .failed:
            Image(systemName: "exclamationmark.triangle").font(.app(.caption)).foregroundStyle(.orange)
                .help(localization.tr("mail.popover.failed"))
        default:
            if let latest = mail.popoverUnread.first?.lastDelivery {
                Text(localization.tr("mail.popover.latest", MailPresentation.listTime(latest, localization: localization)))
                    .font(.app(.footnote))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ conversation: MailConversationSummary) -> some View {
        Button {
            onOpen(conversation.id)
        } label: {
            HStack(spacing: 8) {
                Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                HStack(spacing: 4) {
                    Text(conversation.senders.first ?? "")
                        .font(.app(.body, weight: .semibold))
                        .lineLimit(1)
                    if mail.isExternalSender(conversation) { MailExternalTag() }
                }
                .frame(width: 112, alignment: .leading)
                Text(conversation.topic.isEmpty ? localization.tr("mail.noSubject") : conversation.topic)
                    .font(.app(.body))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if conversation.hasAttachments {
                    Image(systemName: "paperclip").font(.app(.caption)).foregroundStyle(.secondary)
                }
                Text(MailPresentation.listTime(conversation.lastDelivery, localization: localization))
                    .font(.app(.footnote))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, horizontalPadding + 2)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.mailRow(cornerRadius: 0))
        .help(conversation.preview)
    }
}

/// The mail sections of the Preferences tab. Changes apply at once, like the language and theme
/// pickers there: they do not wait for "Save Preferences".
struct MailSettingsSections: View {
    @ObservedObject var mail: MailService
    @EnvironmentObject private var localization: LocalizationService

    private func binding<T>(_ keyPath: WritableKeyPath<MailSettings, T>) -> Binding<T> {
        Binding(get: { mail.settings[keyPath: keyPath] }, set: { value in mail.updateSettings { $0[keyPath: keyPath] = value } })
    }

    var body: some View {
        Group {
            Section(localization.tr("settings.tab.mail")) {
                Toggle(localization.tr("mail.settings.enabled"), isOn: binding(\.enabled))
                Text(localization.tr("mail.settings.enabled.hint"))
                    .font(.app(.footnote))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if mail.mailAccounts.isEmpty {
                    Label(localization.tr("mail.settings.noAccount"), systemImage: "info.circle")
                        .font(.app(.footnote))
                        .foregroundStyle(.secondary)
                } else if mail.mailAccounts.count > 1 {
                    Picker(localization.tr("mail.settings.account"), selection: Binding(
                        get: { mail.account?.id },
                        set: { id in mail.updateSettings { $0.accountID = id } }
                    )) {
                        ForEach(mail.mailAccounts) { account in
                            Text(account.displayName).tag(Optional(account.id))
                        }
                    }
                    .disabled(!mail.settings.enabled)
                }
            }

            Section(localization.tr("mail.settings.section.popover")) {
                Toggle(localization.tr("mail.settings.popoverSection"), isOn: binding(\.popoverSectionEnabled))
                    .disabled(!mail.settings.enabled)
                Text(localization.tr("mail.settings.popoverSection.hint", "Ctrl+Option+M"))
                    .font(.app(.footnote))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle(localization.tr("mail.settings.menuBarBadge"), isOn: binding(\.menuBarBadgeEnabled))
                    .disabled(!mail.settings.enabled)
                Toggle(localization.tr("mail.settings.peopleOnly"), isOn: binding(\.peopleOnly))
                    .disabled(!mail.settings.enabled)
                Text(localization.tr("mail.settings.peopleOnly.hint"))
                    .font(.app(.footnote))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Picker(localization.tr("mail.settings.notify"), selection: binding(\.notifyMode)) {
                    ForEach(MailNotifyMode.allCases) { mode in
                        Text(localization.tr(mode.localizationKey)).tag(mode)
                    }
                }
                .disabled(!mail.settings.enabled)
                Picker(localization.tr("mail.settings.poll"), selection: binding(\.pollMinutes)) {
                    ForEach(MailSettings.pollOptions, id: \.self) { minutes in
                        Text(localization.tr("mail.settings.poll.minutes", minutes)).tag(minutes)
                    }
                }
                .disabled(!mail.settings.enabled)
                Text(localization.tr("mail.settings.poll.hint"))
                    .font(.app(.footnote))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(localization.tr("mail.settings.section.reading")) {
                Toggle(localization.tr("mail.list.bundle"), isOn: binding(\.bundleAutomated))
                    .disabled(!mail.settings.enabled)
                Toggle(localization.tr("mail.list.groupByConversation"), isOn: binding(\.groupByConversation))
                    .disabled(!mail.settings.enabled)
                Toggle(localization.tr("mail.settings.swipeActions"), isOn: binding(\.swipeActionsEnabled))
                    .disabled(!mail.settings.enabled)
                Text(localization.tr("mail.settings.swipeActions.hint"))
                    .font(.app(.footnote))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Picker(localization.tr("mail.settings.markRead"), selection: binding(\.markReadPolicy)) {
                    ForEach(MailMarkReadPolicy.allCases) { policy in
                        Text(localization.tr(policy.localizationKey)).tag(policy)
                    }
                }
                .disabled(!mail.settings.enabled)
                Text(localization.tr("mail.settings.privacy"))
                    .font(.app(.footnote))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
