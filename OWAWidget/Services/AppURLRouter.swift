import AppKit
import Foundation

/// What a link (`AppURLRoute`) does, decided apart from the windows so it can be tested.
enum AppURLAction: Equatable {
    case openMail
    case openThread(String)
    case openMessage(String)
    /// The mail window opens with this notice instead of a conversation.
    case notice(MailListNotice)
    /// Nothing opens; the reason goes to the diagnostic log only.
    case ignore(String)

    /// - Parameters:
    ///   - windowAccountID: the account the mail window shows; `nil` when there is none.
    ///   - resolve: the full Exchange id behind an MCP short id, `nil` when unknown.
    static func decide(
        _ route: AppURLRoute,
        mailEnabled: Bool,
        windowAccountID: UUID?,
        resolve: (String) -> String?
    ) -> AppURLAction {
        // Mail off: nothing opens, as with the Ctrl+Option+M shortcut.
        guard mailEnabled else { return .ignore("mail off") }
        guard let windowAccountID else { return .ignore("no mail account") }
        switch route {
        case .mail:
            return .openMail
        case .thread(let id, let accountID), .message(let id, let accountID):
            if let accountID, accountID != windowAccountID { return .notice(.linkOtherAccount) }
            let fullID = AppURLRoute.isShortHandle(id) ? resolve(id) : id
            guard let fullID else { return .notice(.linkNotFound) }
            if case .thread = route { return .openThread(fullID) }
            return .openMessage(fullID)
        }
    }
}

/// Takes `owawidget://` links from the system and opens what they name in the mail window.
///
/// A link can arrive before the app is ready: one that launches the app comes while SwiftUI is
/// still building the menu bar label, the one view that opens windows. The last such link waits
/// here until `attach` and is then followed.
@MainActor
final class AppURLRouter {
    static let shared = AppURLRouter()

    private weak var mailService: MailService?
    private var resolveMailID: ((String) -> String?)?
    private var pending: AppURLRoute?

    /// Called once the menu bar label is on screen and mail is wired up.
    func attach(mailService: MailService, resolveMailID: @escaping (String) -> String?) {
        self.mailService = mailService
        self.resolveMailID = resolveMailID
        guard let route = pending else { return }
        pending = nil
        // Next turn: the label's `onChange(of: openRequest)` must already be watching.
        DispatchQueue.main.async { [weak self] in self?.follow(route) }
    }

    func handle(_ url: URL) {
        guard let route = AppURLRoute.parse(url) else {
            DiagnosticLog.event("URL link refused scheme=\(url.scheme ?? "-") host=\(url.host ?? "-")")
            return
        }
        guard mailService != nil else {
            DiagnosticLog.event("URL link waits for launch route=\(Self.name(route))")
            pending = route
            return
        }
        follow(route)
    }

    private func follow(_ route: AppURLRoute) {
        guard let mail = mailService else { return }
        let action = AppURLAction.decide(
            route,
            mailEnabled: mail.settings.enabled,
            windowAccountID: mail.account?.id,
            resolve: { [resolveMailID] in resolveMailID?($0) }
        )
        DiagnosticLog.event("URL link route=\(Self.name(route)) action=\(Self.name(action))")
        switch action {
        case .openMail: mail.open(conversationID: "")
        case .openThread(let id): mail.open(conversationID: id)
        case .openMessage(let id): mail.open(messageID: id)
        case .notice(let notice): mail.openWindow(notice: notice)
        case .ignore: break
        }
    }

    // Ids stay out of the log: it is shared with support.
    private static func name(_ route: AppURLRoute) -> String {
        switch route {
        case .mail: "mail"
        case .thread(let id, let account): "thread short=\(AppURLRoute.isShortHandle(id)) account=\(account != nil)"
        case .message(let id, let account): "message short=\(AppURLRoute.isShortHandle(id)) account=\(account != nil)"
        }
    }

    private static func name(_ action: AppURLAction) -> String {
        switch action {
        case .openMail: "openMail"
        case .openThread: "openThread"
        case .openMessage: "openMessage"
        case .notice(let notice): "notice \(notice == .linkNotFound ? "notFound" : "otherAccount")"
        case .ignore(let reason): "ignore \(reason)"
        }
    }
}
