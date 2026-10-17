import AppKit
import SwiftUI

/// Small presentation helpers shared by the mail views.
@MainActor
enum MailPresentation {
    /// Window subtitle under the folder name: "Unread: 12 · updated 16:44".
    static func windowSubtitle(unread: Int?, lastChecked: Date?, localization: LocalizationService) -> String {
        var parts: [String] = []
        if let unread, unread > 0 { parts.append(localization.tr("mail.window.subtitle.unread", unread)) }
        if let lastChecked {
            parts.append(localization.tr("mail.window.subtitle.updated", localization.shortTime(lastChecked)))
        } else {
            parts.append(localization.tr("mail.window.subtitle.notUpdated"))
        }
        let text = parts.joined(separator: " · ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    static func folderIcon(_ folder: MailFolder) -> String {
        switch folder.distinguished {
        case .inbox: "tray"
        case .drafts: "doc"
        case .sentitems: "paperplane"
        case .deleteditems: "trash"
        case .junkemail: "xmark.bin"
        case .archive: "archivebox"
        case .outbox: "tray.and.arrow.up"
        default: "folder"
        }
    }

    /// A stable color for a category name: OWA's master category list (with the user's colors)
    /// is not loaded, so well-known default names get their color and the rest a hashed one.
    static func categoryColor(_ name: String) -> Color {
        let lower = name.lowercased()
        let known: [(String, Color)] = [
            ("крас", .red), ("red", .red), ("оранж", .orange), ("orange", .orange), ("желт", .yellow), ("жёлт", .yellow),
            ("yellow", .yellow), ("зел", .green), ("green", .green), ("син", .blue), ("blue", .blue), ("фиолет", .purple),
            ("purple", .purple),
        ]
        if let match = known.first(where: { lower.contains($0.0) }) { return match.1 }
        let palette: [Color] = [.teal, .indigo, .pink, .mint, .brown, .cyan, .purple, .orange]
        let hash = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
        return palette[hash % palette.count]
    }

    /// The list's time column: "20:07" today, "Вчера 20:07", "Пт 20:07" this week, "16 окт." older.
    static func listTime(_ date: Date?, localization: LocalizationService, now: Date = Date()) -> String {
        guard let date else { return "" }
        let calendar = AppTimeZone.calendar
        let time = localization.shortTime(date)
        if calendar.isDate(date, inSameDayAs: now) { return time }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day, days < 7 {
            if days == 1 { return localization.tr("mail.time.yesterday") + " " + time }
            return localization.formatDate(date, format: "EE") + " " + time
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return localization.formatDate(date, format: sameYear ? "d MMM" : "d MMM yyyy")
    }

    /// Days back from today, capped at 7: the list's day sections ("Today", "Yesterday",
    /// a weekday for the rest of the week, then "Earlier").
    static func dayBucket(_ date: Date?, now: Date = Date()) -> Int {
        guard let date else { return 7 }
        let calendar = AppTimeZone.calendar
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 7
        return min(max(days, 0), 7)
    }

    /// For each row, the section that starts at it (`nil` when it continues the previous one).
    static func sectionStarts(_ dates: [Date?], now: Date = Date()) -> [Int?] {
        var previous: Int?
        return dates.map { date in
            let bucket = dayBucket(date, now: now)
            defer { previous = bucket }
            return bucket == previous ? nil : bucket
        }
    }

    static func sectionTitle(_ bucket: Int, sample: Date?, localization: LocalizationService) -> String {
        switch bucket {
        case 0: return localization.tr("mail.section.today")
        case 1: return localization.tr("mail.section.yesterday")
        case 7: return localization.tr("mail.section.earlier")
        default: return sample.map { localization.formatDate($0, format: "EEEE, d MMMM") }.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? ""
        }
    }

    /// The row's time under a day section: the time within the week, the date before it.
    static func rowTime(_ date: Date?, localization: LocalizationService, now: Date = Date()) -> String {
        guard let date else { return "" }
        if dayBucket(date, now: now) < 7 { return localization.shortTime(date) }
        let calendar = AppTimeZone.calendar
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return localization.formatDate(date, format: sameYear ? "d MMM" : "d MMM yyyy")
    }

    /// The line an invitation shows in place of an empty preview.
    static func meetingLine(_ conversation: MailConversationSummary, interval: DateInterval?, localization: LocalizationService) -> String? {
        if conversation.isMeetingCancellation { return localization.tr("mail.list.meetingCancelled") }
        guard conversation.isMeetingRequest else { return nil }
        guard let interval else { return localization.tr("mail.list.invitation") }
        let day = localization.formatDate(interval.start, format: "EE, d MMM")
        return localization.tr("mail.list.invitationAt", day, localization.shortTime(interval.start), localization.shortTime(interval.end))
    }

    /// The reader's message time: as in the list, but older dates keep their time too.
    static func messageTime(_ date: Date?, localization: LocalizationService, now: Date = Date()) -> String {
        guard let date else { return "" }
        let calendar = AppTimeZone.calendar
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day, days < 7 {
            return listTime(date, localization: localization, now: now)
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return localization.formatDate(date, format: sameYear ? "d MMM, HH:mm" : "d MMM yyyy, HH:mm")
    }

    static func fullTime(_ date: Date?, localization: LocalizationService) -> String {
        guard let date else { return "" }
        return localization.formatDate(date, format: "EEEE, d MMMM yyyy, HH:mm")
    }

    static func byteCount(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// `text` with every occurrence of the search terms highlighted.
    static func highlighted(_ text: String, terms: [String]) -> AttributedString {
        var attributed = AttributedString(text)
        for term in terms where term.count >= 2 {
            var searchStart = attributed.startIndex
            while searchStart < attributed.endIndex,
                  let range = attributed[searchStart...].range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) {
                attributed[range].backgroundColor = Color.yellow.opacity(0.4)
                searchStart = range.upperBound
            }
        }
        return attributed
    }
}

/// Which folders the sidebar shows. Exchange keeps service folders next to mail ones
/// (conversation history, sync issues, scheduled, outbox): they only add noise.
enum MailSidebarPolicy {

    static let shownSystemFolders: [MailDistinguishedFolder] = [.inbox, .drafts, .sentitems, .archive, .deleteditems, .junkemail]

    /// Folders under a hidden service folder are hidden with it.
    static func visibleFolders(_ folders: [MailFolder]) -> [MailFolder] {
        let byID = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func isHidden(_ folder: MailFolder) -> Bool {
            var current: MailFolder? = folder
            var depth = 0
            while let item = current, depth < 10 {
                if let distinguished = item.distinguishedID, distinguished != "msgfolderroot" {
                    if let known = MailDistinguishedFolder(rawValue: distinguished) {
                        if known == .outbox, item.totalCount == 0 { return true }
                    } else {
                        return true
                    }
                }
                current = item.parentID.flatMap { byID[$0] }
                depth += 1
            }
            return false
        }
        return folders.filter { $0.distinguished != .msgfolderroot && !isHidden($0) }
    }

    static func children(of parentID: String, in folders: [MailFolder]) -> [MailFolder] {
        folders.filter { $0.parentID == parentID }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    /// Top-level custom folders: their parent is the mailbox root or not in the list.
    static func topLevelCustom(_ folders: [MailFolder]) -> [MailFolder] {
        let ids = Set(folders.map(\.id))
        return folders.filter { folder in
            folder.distinguished == nil && (folder.parentID.map { !ids.contains($0) } ?? true)
        }
        .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    /// Unread messages in a folder and everything under it, for a collapsed folder's badge.
    static func unreadIncludingChildren(_ folder: MailFolder, in folders: [MailFolder], depth: Int = 0) -> Int {
        guard depth < 10 else { return folder.unreadCount }
        return folder.unreadCount + children(of: folder.id, in: folders).reduce(0) {
            $0 + unreadIncludingChildren($1, in: folders, depth: depth + 1)
        }
    }
}

// MARK: - Sidebar

struct MailSidebarView: View {
    @ObservedObject var model: MailWindowModel
    @ObservedObject var service: MailService
    @EnvironmentObject private var localization: LocalizationService
    @Environment(\.scrollerInset) private var scrollerInset

    private var visible: [MailFolder] { MailSidebarPolicy.visibleFolders(model.folders) }

    private var system: [MailFolder] {
        MailSidebarPolicy.shownSystemFolders.compactMap { name in visible.first { $0.distinguished == name } }
    }

    private var pinned: [MailFolder] {
        service.settings.pinnedFolderIDs.compactMap { id in visible.first { $0.id == id } }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    if service.mailAccounts.count > 1 {
                        Picker("", selection: Binding(
                            get: { service.account?.id },
                            set: { id in service.updateSettings { $0.accountID = id } }
                        )) {
                            ForEach(service.mailAccounts) { account in
                                Text(account.displayName).tag(Optional(account.id))
                            }
                        }
                        .labelsHidden()
                        .padding(.horizontal, 6)
                        .padding(.bottom, 6)
                    }
                    ForEach(system) { tree($0, depth: 0) }
                    if !pinned.isEmpty {
                        header(localization.tr("mail.sidebar.pinned"))
                        ForEach(pinned) { row($0, depth: 0, hasChildren: false) }
                    }
                    let custom = MailSidebarPolicy.topLevelCustom(visible)
                    if !custom.isEmpty {
                        header(localization.tr("mail.sidebar.folders"))
                        ForEach(custom) { tree($0, depth: 0) }
                    }
                }
                .padding(8)
                .padding(.trailing, scrollerInset)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }

    private func tree(_ folder: MailFolder, depth: Int) -> AnyView {
        let children = MailSidebarPolicy.children(of: folder.id, in: visible)
        let isOpen = model.expandedFolderIDs.contains(folder.id)
        return AnyView(VStack(alignment: .leading, spacing: 1) {
            row(folder, depth: depth, hasChildren: !children.isEmpty)
            if isOpen, depth < 6 {
                ForEach(children) { tree($0, depth: depth + 1) }
            }
        })
    }

    private func row(_ folder: MailFolder, depth: Int, hasChildren: Bool) -> some View {
        let selected = model.isSelected(folder) && !model.isSearching
        let isOpen = model.expandedFolderIDs.contains(folder.id)
        let isPinned = service.settings.pinnedFolderIDs.contains(folder.id)
        // A collapsed folder shows what is unread inside it too.
        let unread = hasChildren && !isOpen ? MailSidebarPolicy.unreadIncludingChildren(folder, in: visible) : folder.unreadCount
        let showsCount = unread > 0 && folder.distinguished != .sentitems && folder.distinguished != .deleteditems
            && folder.distinguished != .drafts
        return HStack(spacing: 4) {
            Group {
                if hasChildren {
                    Button { withAnimation(.easeInOut(duration: 0.12)) { model.toggleFolder(folder) } } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                            .frame(width: 12, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                } else {
                    Color.clear.frame(width: 12, height: 18)
                }
            }
            Button {
                model.select(folder: folder)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: MailPresentation.folderIcon(folder))
                        .font(.system(size: 12))
                        .foregroundStyle(selected ? Color.accentColor : .secondary)
                        .frame(width: 16)
                    Text(folder.displayName)
                        .font(.system(size: 13, weight: showsCount ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    if showsCount {
                        Text("\(unread)")
                            .font(.system(size: 11, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(selected ? Color.primary : Color.accentColor)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(folder.displayName)
        }
        .padding(.leading, 2 + CGFloat(min(depth, 4)) * 12)
        .padding(.trailing, 8)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.18) : .clear))
        .contextMenu {
            Button(localization.tr(isPinned ? "mail.sidebar.unpin" : "mail.sidebar.pin")) {
                service.updateSettings { settings in
                    if isPinned { settings.pinnedFolderIDs.removeAll { $0 == folder.id } } else { settings.pinnedFolderIDs.append(folder.id) }
                }
            }
            if folder.unreadCount > 0 {
                Button(localization.tr("mail.list.markAllRead")) {
                    model.select(folder: folder)
                    model.confirmsMarkAllRead = true
                }
            }
        }
    }
}

// MARK: - Window toolbar

/// The list filters as segments in the window toolbar: one click, and the active one is visible.
struct MailModePicker: View {
    @ObservedObject var model: MailWindowModel
    /// A narrow window shows a drop-down: the segments would push the folder title out.
    var compact = false
    @EnvironmentObject private var localization: LocalizationService

    var body: some View {
        let picker = Picker(localization.tr("mail.mode.help"), selection: $model.mode) {
            ForEach(MailListMode.allCases) { mode in
                Text(localization.tr("mail.mode.short.\(mode.rawValue)")).tag(mode)
            }
        }
        Group {
            if compact {
                picker.pickerStyle(.menu)
            } else {
                // Small: the filters must not outshine the folder title next to them.
                picker.pickerStyle(.segmented).controlSize(.small)
            }
        }
        .labelsHidden()
        .fixedSize()
        .disabled(model.isSearching)
        .help(localization.tr("mail.mode.help"))
    }
}

/// List options that are not filters: bundling system mail and marking the folder read.
struct MailListOptionsMenu: View {
    @ObservedObject var model: MailWindowModel
    @ObservedObject var service: MailService
    @EnvironmentObject private var localization: LocalizationService

    var body: some View {
        Menu {
            Toggle(localization.tr("mail.list.bundle"), isOn: Binding(
                get: { service.settings.bundleAutomated },
                set: { value in service.updateSettings { $0.bundleAutomated = value } }
            ))
            Divider()
            Button(localization.tr("mail.list.markAllRead")) { model.confirmsMarkAllRead = true }
                .disabled((model.selectedFolderInfo?.unreadCount ?? 0) == 0 || model.isSearching)
        } label: {
            Label(localization.tr("mail.list.options"), systemImage: "ellipsis.circle")
        }
        .menuIndicator(.hidden)
        .help(localization.tr("mail.list.options"))
    }
}

// MARK: - Conversation list

struct MailConversationListView: View {
    @ObservedObject var model: MailWindowModel
    @ObservedObject var service: MailService
    @EnvironmentObject private var localization: LocalizationService
    @Environment(\.scrollerInset) private var scrollerInset

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.isSearching { searchFilters; Divider() }
            if model.selectedIDs.count > 1 { bulkBar; Divider() }
            content
        }
        .frame(maxHeight: .infinity)
        .confirmationDialog(
            localization.tr("mail.list.markAllRead.title", model.selectedFolderInfo?.displayName ?? ""),
            isPresented: $model.confirmsMarkAllRead
        ) {
            Button(localization.tr("mail.list.markAllRead.confirm", model.selectedFolderInfo?.unreadCount ?? 0)) {
                Task { await model.markAllRead() }
            }
            Button(localization.tr("mail.cancel"), role: .cancel) {}
        }
    }

    private var title: String {
        if model.isSearching { return localization.tr("mail.search.title") }
        return model.selectedFolderInfo?.displayName ?? localization.tr("mail.folder.inbox")
    }

    /// The folder name, its counts and the list filters live in the window toolbar; this row
    /// appears only for what belongs to the list itself: search scope and bulk progress.
    @ViewBuilder
    private var header: some View {
        if model.isSearching || model.bulkProgress != nil {
            headerRow
            Divider()
        }
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            if model.isSearching {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            if let progress = model.bulkProgress {
                ProgressView().controlSize(.small)
                Text(localization.tr("mail.list.marking", progress)).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if model.isSearching {
                Picker("", selection: Binding(
                    get: { model.searchFilters.mailboxWide },
                    set: { value in
                        model.searchFilters.mailboxWide = value
                        Task { await model.submitSearch() }
                    }
                )) {
                    Text(localization.tr("mail.search.scope.folder")).tag(false)
                    Text(localization.tr("mail.search.scope.mailbox")).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var bulkBar: some View {
        let targets = model.actionTargets
        return HStack(spacing: 10) {
            Text(localization.tr("mail.list.selected", targets.count)).font(.system(size: 12, weight: .medium))
            Spacer(minLength: 4)
            Button { Task { await model.markRead(targets, true) } } label: { Image(systemName: "envelope.open") }
                .help(localization.tr("mail.action.markRead"))
            Button { Task { await model.markRead(targets, false) } } label: { Image(systemName: "envelope.badge") }
                .help(localization.tr("mail.action.markUnread"))
            Button { Task { await model.flag(targets, true) } } label: { Image(systemName: "flag") }
                .help(localization.tr("mail.action.flag"))
            moveMenu(targets)
            Button { Task { await model.move(targets, to: .distinguished(.deleteditems)) } } label: { Image(systemName: "trash") }
                .help(localization.tr("mail.action.delete"))
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.08))
    }

    private func moveMenu(_ targets: [MailConversationSummary]) -> some View {
        Menu {
            ForEach(MailSidebarPolicy.visibleFolders(model.folders)) { folder in
                Button(folder.displayName) {
                    Task { await model.move(targets, to: folder.distinguished.map { .distinguished($0) } ?? .id(folder.id)) }
                }
            }
        } label: {
            Image(systemName: "folder")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(localization.tr("mail.action.move"))
    }

    private var searchFilters: some View {
        VStack(alignment: .leading, spacing: 6) {
            FlowRow(spacing: 6) {
                ForEach(model.searchFilters.from, id: \.self) { refiner in
                    if case .sender(let name, _, _) = refiner {
                        chip(icon: "person", text: localization.tr("mail.search.from", name)) {
                            model.searchFilters.from.removeAll { $0 == refiner }
                            Task { await model.submitSearch() }
                        }
                    }
                }
                if case .folder(_, let folderID, _)? = model.searchFilters.folderRefiner {
                    chip(icon: "folder", text: model.folderName(for: folderID) ?? localization.tr("mail.search.folder")) {
                        model.searchFilters.folderRefiner = nil
                        Task { await model.submitSearch() }
                    }
                }
                Menu {
                    ForEach(MailSearchFilters.Period.allCases) { period in
                        Button(localization.tr(period.localizationKey)) {
                            model.searchFilters.period = period
                            Task { await model.submitSearch() }
                        }
                    }
                } label: {
                    Label(localization.tr(model.searchFilters.period.localizationKey), systemImage: "calendar")
                        .font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Toggle(isOn: Binding(
                    get: { model.searchFilters.hasAttachments },
                    set: { value in
                        model.searchFilters.hasAttachments = value
                        Task { await model.submitSearch() }
                    }
                )) {
                    Label(localization.tr("mail.search.hasAttachments"), systemImage: "paperclip").font(.system(size: 11))
                }
                .toggleStyle(.button)
                .controlSize(.small)
            }
            let suggestions = model.refiners.filter { refiner in
                switch refiner {
                case .sender: !model.searchFilters.from.contains(refiner)
                case .folder: model.searchFilters.folderRefiner == nil
                case .attachments: false
                }
            }
            if !suggestions.isEmpty {
                FlowRow(spacing: 6) {
                    Text(localization.tr("mail.search.refine"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    ForEach(suggestions, id: \.self) { refiner in
                        Button {
                            Task { await model.applyRefiner(refiner) }
                        } label: {
                            Text(refinerLabel(refiner)).font(.system(size: 11))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func refinerLabel(_ refiner: MailSearchRefiner) -> String {
        switch refiner {
        case .sender(let name, _, let count): "\(name) · \(count)"
        case .folder(_, let folderID, let count): "\(model.folderName(for: folderID) ?? localization.tr("mail.search.folder")) · \(count)"
        case .attachments(_, let count): "\(localization.tr("mail.search.hasAttachments")) · \(count)"
        }
    }

    private func chip(icon: String, text: String, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10))
            Text(text).font(.system(size: 11)).lineLimit(1)
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.accentColor.opacity(0.16)))
        .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.4), lineWidth: 1))
    }

    @ViewBuilder
    private var content: some View {
        let rows = model.rows
        if rows.isEmpty {
            VStack(spacing: 8) {
                if model.isLoadingList {
                    ProgressView().controlSize(.small)
                } else if let error = model.listError {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(error).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button(localization.tr("mail.retry")) { Task { await model.reloadList() } }
                } else {
                    Text(localization.tr(model.isSearching ? "mail.search.empty" : (model.mode == .all ? "mail.list.empty" : "mail.list.emptyFiltered")))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if model.canLoadMore, model.mode == .people || model.mode == .awaitingReply {
                        Button(localization.tr("mail.list.loadMore")) { Task { await model.loadMore() } }
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        let starts = MailPresentation.sectionStarts(rows.map(\.date))
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            if let bucket = starts[index] {
                                sectionHeader(MailPresentation.sectionTitle(bucket, sample: row.date, localization: localization))
                            }
                            switch row {
                            case .conversation(let conversation):
                                conversationRow(conversation, indented: false)
                            case .bundle(let sender, let list):
                                bundleRow(sender: sender, conversations: list)
                                if model.expandedBundles.contains(sender) {
                                    ForEach(list) { conversationRow($0, indented: true) }
                                }
                            }
                        }
                        footer
                    }
                    .padding(.trailing, scrollerInset)
                }
                .onChange(of: model.selectedConversationID) { id in
                    guard let id else { return }
                    withAnimation(.easeInOut(duration: 0.12)) { proxy.scrollTo(id) }
                }
            }
        }
    }

    private func conversationRow(_ conversation: MailConversationSummary, indented: Bool) -> some View {
        VStack(spacing: 0) {
            MailConversationRow(
                conversation: conversation,
                isSelected: model.isPicked(conversation.id),
                isSentFolder: model.selectedFolder.isSentItems && !model.isSearching,
                terms: model.searchTerms,
                folderName: model.isSearching ? model.folderName(for: conversation.parentFolderID) : nil,
                compactPreview: conversation.isAutomated,
                isExternal: conversation.hasExternalBanner || service.isExternal(conversation.senderEmail),
                meetingLine: MailPresentation.meetingLine(
                    conversation,
                    interval: conversation.isMeetingRequest ? service.meetingInterval(forTopic: conversation.topic) : nil,
                    localization: localization
                ),
                underDaySection: true
            )
            .padding(.leading, indented ? 16 : 0)
            .contentShape(Rectangle())
            .onTapGesture { model.click(conversation, modifiers: NSEvent.modifierFlags) }
            .contextMenu { contextMenu(for: conversation) }
            Divider()
        }
        .id(conversation.id)
    }

    @ViewBuilder
    private func contextMenu(for conversation: MailConversationSummary) -> some View {
        let targets = model.selectedIDs.contains(conversation.id) && model.selectedIDs.count > 1 ? model.actionTargets : [conversation]
        if targets.contains(where: \.isUnread) {
            Button(localization.tr("mail.action.markRead")) { Task { await model.markRead(targets, true) } }
        } else {
            Button(localization.tr("mail.action.markUnread")) { Task { await model.markRead(targets, false) } }
        }
        Button(localization.tr(targets.allSatisfy(\.isFlagged) ? "mail.action.unflag" : "mail.action.flag")) {
            Task { await model.flag(targets, !targets.allSatisfy(\.isFlagged)) }
        }
        Menu(localization.tr("mail.action.move")) {
            ForEach(MailSidebarPolicy.visibleFolders(model.folders)) { folder in
                Button(folder.displayName) {
                    Task { await model.move(targets, to: folder.distinguished.map { .distinguished($0) } ?? .id(folder.id)) }
                }
            }
        }
        Divider()
        Button(localization.tr("mail.action.delete"), role: .destructive) {
            Task { await model.move(targets, to: .distinguished(.deleteditems)) }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 4)
            Divider()
        }
    }

    private func bundleRow(sender: String, conversations: [MailConversationSummary]) -> some View {
        let expanded = model.expandedBundles.contains(sender)
        let unread = conversations.reduce(0) { $0 + $1.unreadCount }
        let newest = conversations.first
        return VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .foregroundStyle(.secondary)
                    .frame(width: 7)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: "square.stack.3d.up").font(.system(size: 11)).foregroundStyle(.secondary)
                        Text(sender).font(.system(size: 13, weight: unread > 0 ? .semibold : .regular)).lineLimit(1)
                        Text(localization.tr("mail.bundle.count", conversations.count))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1))
                        Spacer(minLength: 4)
                        Text(MailPresentation.rowTime(newest?.lastDelivery, localization: localization))
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                    HStack(spacing: 6) {
                        Text(newest?.topic ?? "")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if unread > 0 {
                            Button {
                                Task { await model.markRead(conversations.filter(\.isUnread), true) }
                            } label: {
                                Text(localization.tr("mail.bundle.markRead", unread)).font(.system(size: 11))
                            }
                            .buttonStyle(.borderless)
                            .fixedSize()
                        }
                    }
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.12)) {
                    if expanded { model.expandedBundles.remove(sender) } else { model.expandedBundles.insert(sender) }
                }
            }
            .contextMenu {
                Button(localization.tr("mail.action.markRead")) { Task { await model.markRead(conversations, true) } }
                Button(localization.tr("mail.action.delete"), role: .destructive) {
                    Task { await model.move(conversations, to: .distinguished(.deleteditems)) }
                }
            }
            .background(Color.secondary.opacity(0.05))
            Divider()
        }
    }

    @ViewBuilder
    private var footer: some View {
        if model.canLoadMore {
            HStack {
                if model.isLoadingList { ProgressView().controlSize(.small) }
                Text(localization.tr("mail.list.loadingMore"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(10)
            .onAppear { Task { await model.loadMore() } }
        } else if model.isSearching, model.searchMoreAvailable || model.conversations.count >= OWAMailPayloads.searchResultsCap {
            Label(localization.tr("mail.search.cap", OWAMailPayloads.searchResultsCap), systemImage: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(10)
        }
    }
}

struct MailConversationRow: View {
    let conversation: MailConversationSummary
    let isSelected: Bool
    let isSentFolder: Bool
    let terms: [String]
    let folderName: String?
    /// One line of preview: system mail repeats the same opening in every message.
    var compactPreview = false
    /// The sender is outside the organization (address, or the server's warning banner).
    var isExternal = false
    /// For an invitation: its time, shown where the (usually empty) preview would be.
    var meetingLine: String? = nil
    /// The row sits under a day section, so the time alone is enough within the week.
    var underDaySection = false
    @EnvironmentObject private var localization: LocalizationService

    private var previewLine: String {
        let preview = conversation.preview.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let meetingLine else { return preview }
        return preview.isEmpty ? meetingLine : meetingLine + " · " + preview
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Circle()
                .fill(conversation.isUnread ? Color.accentColor : .clear)
                .frame(width: 7, height: 7)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    let people = isSentFolder && !conversation.recipients.isEmpty ? conversation.recipients : conversation.senders
                    Text(people.joined(separator: ", "))
                        .font(.system(size: 13, weight: conversation.isUnread ? .semibold : .regular))
                        .lineLimit(1)
                    if isExternal {
                        Text(localization.tr("mail.external"))
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 3).fill(Color.orange.opacity(0.16)))
                            .foregroundStyle(.orange)
                            .fixedSize()
                    }
                    Spacer(minLength: 4)
                    if conversation.isFlagged { Image(systemName: "flag.fill").font(.system(size: 9)).foregroundStyle(.orange) }
                    if conversation.hasAttachments { Image(systemName: "paperclip").font(.system(size: 10)).foregroundStyle(.secondary) }
                    Text(underDaySection
                         ? MailPresentation.rowTime(conversation.lastDelivery, localization: localization)
                         : MailPresentation.listTime(conversation.lastDelivery, localization: localization))
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                HStack(spacing: 5) {
                    if conversation.isMeetingRequest || conversation.isMeetingCancellation {
                        Image(systemName: conversation.isMeetingCancellation ? "calendar.badge.minus" : "calendar")
                            .font(.system(size: 10))
                            .foregroundStyle(conversation.isMeetingCancellation ? Color.secondary : Color.accentColor)
                    }
                    if conversation.importance == .high {
                        Text("!").font(.system(size: 12, weight: .bold)).foregroundStyle(.red)
                    }
                    ForEach(conversation.categories.prefix(3), id: \.self) { name in
                        RoundedRectangle(cornerRadius: 2).fill(MailPresentation.categoryColor(name)).frame(width: 8, height: 8).help(name)
                    }
                    if conversation.isProtected { Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(.secondary) }
                    Text(MailPresentation.highlighted(conversation.topic.isEmpty ? localization.tr("mail.noSubject") : conversation.topic, terms: terms))
                        .font(.system(size: 12, weight: conversation.isUnread ? .medium : .regular))
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    if conversation.messageCount > 1 {
                        Text("\(conversation.messageCount)")
                            .font(.system(size: 10))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1))
                    }
                }
                // No empty third line: rows without a preview (most invitations) stay compact.
                if folderName != nil || !previewLine.isEmpty {
                    HStack(alignment: .top, spacing: 4) {
                        if let folderName {
                            Text(folderName)
                                .font(.system(size: 10))
                                .padding(.horizontal, 4)
                                .background(RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.15)))
                        }
                        Text(MailPresentation.highlighted(previewLine, terms: terms))
                            .font(.system(size: 11.5))
                            .lineLimit(compactPreview || meetingLine != nil ? 1 : 2)
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 12)
        .padding(.vertical, compactPreview ? 6 : 8)
        .background(isSelected ? Color.accentColor.opacity(0.14) : .clear)
    }
}

/// Lays children out left to right, wrapping to new lines (macOS 13 `Layout`).
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: min(maxX, width), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
