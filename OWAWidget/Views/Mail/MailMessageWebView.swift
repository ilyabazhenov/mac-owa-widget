import AppKit
import SwiftUI
import WebKit

/// Blocks every network load in the reader, compiled once. The document's CSP blocks them too;
/// this does not depend on the document.
@MainActor
enum MailContentBlocker {
    private static var ruleList: WKContentRuleList?
    private static var isCompiling = false

    /// One rule per scheme: WebKit's `url-filter` has no alternation (`a|b`), and a list that
    /// fails to compile silently leaves the reader without this layer.
    static let rules = """
    [{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},
     {"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}},
     {"trigger":{"url-filter":"^ftp://"},"action":{"type":"block"}},
     {"trigger":{"url-filter":"^file:"},"action":{"type":"block"}}]
    """

    static func prepare() {
        guard ruleList == nil, !isCompiling else { return }
        isCompiling = true
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "owawidget-mail-block-all", encodedContentRuleList: rules) { list, error in
            if let error {
                DiagnosticLog.event("Mail content blocker failed to compile: \(error.localizedDescription)")
            }
            Task { @MainActor in
                ruleList = list
                isCompiling = false
            }
        }
    }

    static func apply(to controller: WKUserContentController) {
        if let ruleList { controller.add(ruleList) }
    }
}

/// What every reader web view shares. One store for all of them: a store of its own per view
/// started a new WebKit process for each message (about a quarter of a second before the first
/// body showed). Sharing is safe here: no page script runs and nothing loads from the network,
/// so one message has no way to leave anything for another.
@MainActor
enum MailReaderWebKit {
    static let dataStore = WKWebsiteDataStore.nonPersistent()
    private static var warmView: WKWebView?

    /// Starts WebKit's processes while the window opens, before the first message is clicked.
    static func prewarm() {
        guard warmView == nil else { return }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.loadHTMLString("<!DOCTYPE html><html><body></body></html>", baseURL: nil)
        warmView = view
    }

    static func release() {
        warmView = nil
    }
}

/// A link the user clicked in a message: where it goes and what it said.
struct MailLinkActivation: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let text: String?
}

/// One message body in a WebKit view that runs no page script, loads nothing from the network
/// and navigates nowhere: clicks on links are handed to `onLink`.
///
/// The view has no scrolling of its own — it is sized to its content (`height`) and the wheel
/// goes to the enclosing scroll view, so a thread scrolls as one page.
struct MailMessageWebView: NSViewRepresentable {
    let html: String
    @Binding var height: CGFloat
    /// The one item of the body's context menu.
    var copyTitle = "Copy"
    let onLink: (MailLinkActivation) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> MailReaderWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = MailReaderWebKit.dataStore
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        MailContentBlocker.apply(to: configuration.userContentController)
        let view = MailReaderWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        view.allowsMagnification = false
        view.allowsBackForwardNavigationGestures = false
        // Force click previews a link in a web view of WebKit's own: script on, network on, no CSP
        // and no link dialog.
        view.allowsLinkPreview = false
        view.copyTitle = copyTitle
        view.onWidthChange = { [weak coordinator = context.coordinator, weak view] in
            guard let view else { return }
            coordinator?.measure(view)
        }
        context.coordinator.load(html, into: view)
        return view
    }

    func updateNSView(_ view: MailReaderWebView, context: Context) {
        context.coordinator.parent = self
        view.copyTitle = copyTitle
        if context.coordinator.loadedHTML != html {
            context.coordinator.load(html, into: view)
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: MailMessageWebView
        private(set) var loadedHTML: String?
        private var linkTexts: [String: String] = [:]

        init(_ parent: MailMessageWebView) { self.parent = parent }

        func load(_ html: String, into view: WKWebView) {
            loadedHTML = html
            linkTexts = [:]
            view.loadHTMLString(html, baseURL: nil)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            // The document itself (loaded from a string) is the only navigation allowed.
            if navigationAction.navigationType == .other, navigationAction.request.url?.absoluteString == "about:blank" {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                parent.onLink(MailLinkActivation(url: url, text: linkTexts[url.absoluteString]))
            }
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            // `target="_blank"` links (the server adds them) arrive here instead.
            if let url = navigationAction.request.url {
                parent.onLink(MailLinkActivation(url: url, text: linkTexts[url.absoluteString]))
            }
            return nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            measure(webView)
            // Fonts and data: images settle a moment later.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self, weak webView] in
                guard let webView else { return }
                self?.measure(webView)
            }
            // App-side script in its own world: page script stays off. Collects each link's text
            // so a click can be checked against where the link really goes.
            let collect = "Array.from(document.links).slice(0, 500).map(a => [a.href, (a.innerText || '').slice(0, 200)])"
            webView.evaluateJavaScript(collect, in: nil, in: .defaultClient) { [weak self] result in
                guard case .success(let value) = result, let pairs = value as? [[String]] else { return }
                Task { @MainActor in
                    for pair in pairs where pair.count == 2 { self?.linkTexts[pair[0]] = pair[1] }
                }
            }
        }

        /// Fits a wide message (fixed-width newsletter tables) to the view by scaling it down, as
        /// Mail does, then reports the height of the content itself and the width the page laid
        /// out against. The viewport is not measured: it is as tall as the frame, so the frame
        /// could only ever grow.
        static let fitScript = """
        (function () {
          var r = document.getElementById('owaw-root');
          var w = document.documentElement.clientWidth;
          if (!r) { return [document.documentElement.scrollHeight, w]; }
          r.style.transform = ''; r.style.width = '';
          var s = r.scrollWidth;
          var z = 1;
          if (s > w + 1) {
            z = Math.max(0.45, w / s);
            r.style.width = (w / z) + 'px';
            r.style.transformOrigin = '0 0';
            r.style.transform = 'scale(' + z + ')';
          }
          return [Math.ceil(r.offsetHeight * z), w];
        })()
        """

        /// Bumped by every new measurement, so retries of an older one stop.
        private var measureGeneration = 0

        func measure(_ webView: WKWebView) {
            measureGeneration += 1
            measure(webView, generation: measureGeneration, attempt: 0)
        }

        /// During a live resize WebKit hands the page its new size a little after the frame
        /// changes: a fit made against the old width pins the message to it (`#owaw-root` gets
        /// that width and a scale), and a window made wider kept the narrow layout. Until the page
        /// reports the view's own width the fit is made again.
        private func measure(_ webView: WKWebView, generation: Int, attempt: Int) {
            webView.evaluateJavaScript(Self.fitScript, in: nil, in: .defaultClient) { [weak self, weak webView] result in
                guard case .success(let value) = result, let pair = value as? [NSNumber], pair.count == 2 else { return }
                Task { @MainActor in
                    guard let self, let webView, generation == self.measureGeneration else { return }
                    let height = CGFloat(truncating: pair[0])
                    if abs(self.parent.height - height) > 1 { self.parent.height = max(20, height) }
                    let pageWidth = CGFloat(truncating: pair[1])
                    if abs(pageWidth - webView.bounds.width) > 1, attempt < 20 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak webView] in
                            guard let self, let webView else { return }
                            self.measure(webView, generation: generation, attempt: attempt + 1)
                        }
                    }
                }
            }
        }
    }
}

/// Passes the scroll wheel on to the enclosing scroll view and reports width changes, which
/// reflow the text and change the height.
final class MailReaderWebView: WKWebView {
    var onWidthChange: (() -> Void)?
    var copyTitle = "Copy"
    private var lastWidth: CGFloat = 0

    /// WebKit's own items can download an image or a linked file, open one in a new window or
    /// preview it through Look Up — outside the reader's CSP, content blocker and link dialog.
    /// Their identifiers are not public API, so instead of filtering them the menu keeps Copy.
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        menu.removeAllItems()
        menu.addItem(withTitle: copyTitle, action: #selector(NSText.copy(_:)), keyEquivalent: "")
        super.willOpenMenu(menu, with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if abs(newSize.width - lastWidth) > 0.5 {
            lastWidth = newSize.width
            onWidthChange?()
        }
    }
}
